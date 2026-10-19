require "json"
require "fileutils"

module Workspace
  module Commands
    # `spine init`: copies a spine template (a library entry of kind `spine`) into the
    # `spine/` folder of a workspace's notes directory, filling `{{WORKSPACE}}`, `{{BRANCH}}`
    # and `{{TITLE}}`. It never overwrites: a `spine/` that is there already is `exists` and
    # nothing is written. The folder is built beside `spine/` and renamed into place, so a
    # reader sees all of it or none.
    class SpineInit
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The template used when none is named.
      DEFAULT_TEMPLATE = SpineConfig::DEFAULT_TEMPLATE

      # How an error says where the template name came from.
      SOURCE_WORDS = {
        "flag" => "named with --template", "worktree" => "set by spine.template in the workspace's own config",
        "project" => "set by spine.template in the project's config", "global" => "set by spine.template in the global config",
        "default" => "the built-in default"
      }.freeze

      # The stage file (and folder) a main checkout's spine leaves out: it has no branch to ship.
      SHIP_STAGE = /\A\d{1,3}-ship(\.md)?\z/

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are, and makes the directory
      # @param library [Workspace::Library] finds the template
      # @param project_config [Workspace::ProjectConfig] gives a workspace's checkout
      # @param git [Workspace::Git] names the checkout's branch
      # @param task_store [Workspace::TaskStore] gives the workspace's task title
      # @param spine_config [Workspace::SpineConfig, nil] gives the template a call without one uses; nil is `default`
      # @param output [IO]
      def initialize(notes:, library:, project_config:, git:, task_store:, spine_config: nil, output: $stdout)
        @spine_config = spine_config
        @notes = notes
        @library = library
        @project_config = project_config
        @git = git
        @task_store = task_store
        @output = output
      end

      # @param name [String] the workspace
      # @param template [String, nil] the template name; nil is the workspace's `spine.template`, else `default`
      # @param dry_run [Boolean] report what would be written and write nothing
      # @param json [Boolean] print the document documented in docs/README.spine.md instead of a sentence
      # @param print [Boolean] false prints nothing and only returns the answer (for a caller with its own output)
      # @return [Hash] the answer: `outcome` is `created`, `exists` or `would_create`
      # @raise [Workspace::Error] `unknown_workspace`, `unknown_template`, `notes_dir_unresolved`,
      #   `config_parse` or `spine_unwritable`
      def call(name:, template: nil, dry_run: false, json: false, print: true)
        root = @project_config.project_root_for(name)
        raise Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name}) unless root
        root = File.expand_path(root)
        chosen = choose_template(name, template)
        entry = find_template(chosen, root)
        notes_dir = @notes.info(name: name)["dir"]
        spine_dir = File.join(real(notes_dir), "spine")
        main = WorkspaceLineage.split_worktree_name(name).nil?

        outcome, files = plan(entry, spine_dir, main, dry_run)
        outcome = "exists" if outcome == "created" && !write(name, root, spine_dir, files)

        answer = {"workspace" => name, "outcome" => outcome,
                  "template" => {"name" => entry["name"], "scope" => entry["scope"], "source" => chosen["source"]},
                  "dir" => spine_dir, "files" => (outcome == "exists") ? [] : files.map(&:first)}
        show(answer, json) if print
        answer
      end

      # Adds the template's ship stage (placeholders filled) to a workspace's existing `spine/`
      # that has none, as a spine moved from a main checkout does. Never overwrites a file and
      # never writes through a link; a spine that is missing, a link or not a directory is `no_spine`.
      #
      # @param name [String] the workspace
      # @param dry_run [Boolean] report what would be added and write nothing
      # @return [Hash] `outcome` (`added`, `would_add`, `present`: a ship stage is there already,
      #   `no_spine`, `skipped`: a template file's path is taken) and `files` (relative paths)
      # @raise [Workspace::Error] `unknown_workspace`, `unknown_template`, `notes_dir_unresolved` or `config_parse`
      def add_missing_ship(name:, dry_run: false)
        root = @project_config.project_root_for(name)
        raise Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name}) unless root
        root = File.expand_path(root)
        spine_dir = File.join(real(@notes.info(name: name)["dir"]), "spine")
        return {"outcome" => "no_spine", "files" => []} if File.symlink?(spine_dir) || !File.directory?(spine_dir)
        return {"outcome" => "present", "files" => []} if Dir.children(spine_dir).any? { |c| SHIP_STAGE.match?(c) }

        entry = find_template(choose_template(name, nil), root)
        template_root = File.realpath(entry["path"])
        files = entry["files"].select { |rel| SHIP_STAGE.match?(rel.split("/").first) }
        return {"outcome" => "present", "files" => []} if files.empty?
        return {"outcome" => "would_add", "files" => files} if dry_run

        values = fill_values(name, root)
        written = files.select { |rel| write_new(spine_dir, rel, File.binread(File.join(template_root, rel)), values) }
        {"outcome" => (written.size == files.size) ? "added" : "skipped", "files" => written}
      end

      private

      # Creates one file that is not there yet; false when the path is taken or runs through a link.
      def write_new(spine_dir, rel, bytes, values)
        target = File.join(spine_dir, rel)
        walk = spine_dir
        return false if rel.split("/")[0...-1].any? { |part| File.symlink?(walk = File.join(walk, part)) }
        FileUtils.mkdir_p(File.dirname(target))
        File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) { |f| f.write(fill(bytes, values)) }
        true
      rescue SystemCallError
        false
      end

      # @return [Hash{String=>String}] the template's "name" and "source" (`flag`, `worktree`, `project`,
      #   `global` or `default`)
      def choose_template(name, flag)
        return {"name" => flag, "source" => "flag"} if flag
        @spine_config&.template(name) || {"name" => DEFAULT_TEMPLATE, "source" => "default"}
      end

      # @raise [Workspace::Error] `unknown_template`, naming where the name came from
      def find_template(chosen, root)
        @library.spine_template(chosen["name"], cwd: root)
      rescue Error => e
        raise unless e.code == "unknown_template"
        raise Error.new("#{e.message.delete_suffix(".")} (#{SOURCE_WORDS.fetch(chosen["source"])}).",
          code: "unknown_template", details: (e.details || {}).merge("source" => chosen["source"]))
      end

      # @return [Array(String, Array<Array(String, String)>)] the outcome and the template's
      #   `[relative path, source path]` pairs
      def plan(entry, spine_dir, main, dry_run)
        if File.symlink?(spine_dir)
          raise unwritable(spine_dir, "#{spine_dir} is a link, and spine init does not write through links")
        end
        return ["exists", []] if File.exist?(spine_dir) && !empty_directory?(spine_dir)
        files = template_files(entry["path"], entry["files"], main)
        [dry_run ? "would_create" : "created", files]
      end

      # A folder with no entries at all, hidden ones included: nothing there to overwrite.
      def empty_directory?(path)
        File.directory?(path) && Dir.empty?(path)
      rescue SystemCallError
        false
      end

      def template_files(path, files, main)
        root = File.realpath(path)
        files.filter_map do |rel|
          next if main && SHIP_STAGE.match?(rel.split("/").first)
          [rel, File.join(root, rel)]
        end
      end

      # @return [Boolean] false when another writer made `spine/` first
      def write(name, root, spine_dir, files)
        values = fill_values(name, root)
        begin
          @notes.info(name: name, create: true)
        rescue Error => e
          raise unless e.code == "notes_dir_unwritable"
          raise unwritable(spine_dir, e.message)
        end
        tmp = "#{spine_dir}.tmp-#{Process.pid}"
        begin
          FileUtils.mkdir_p(tmp)
          files.each do |rel, source|
            target = File.join(tmp, rel)
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, fill(File.binread(source), values))
          end
          File.rename(tmp, spine_dir)
          true
        rescue Errno::ENOTEMPTY, Errno::EEXIST
          false
        rescue SystemCallError => e
          raise unwritable(spine_dir, e.message)
        ensure
          FileUtils.rm_rf(tmp)
        end
      end

      def fill_values(name, root)
        branch = @git.worktree_branch(root).to_s
        title = @task_store.active_for(name)&.dig("title").to_s
        title = branch if title.strip.empty?
        title = name if title.strip.empty?
        {"WORKSPACE" => name, "BRANCH" => branch, "TITLE" => one_line(title)}
      end

      # Placeholders become text; a template file that isn't UTF-8 is copied as it is.
      def fill(bytes, values)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return bytes unless text.valid_encoding?
        text.gsub(/\{\{(WORKSPACE|BRANCH|TITLE)\}\}/) { values[$1] }
      end

      def one_line(text)
        text.gsub(/[[:cntrl:]  ]+/, " ").strip
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        parent = File.dirname(path)
        return path if parent == path
        File.join(real(parent), File.basename(path))
      end

      def unwritable(path, reason)
        Error.new("Can't write the spine: #{reason.to_s.delete_suffix(".")}.", code: "spine_unwritable", details: {"path" => path})
      end

      def show(answer, json)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true}.merge(answer))
          return
        end
        count = answer["files"].size
        text = case answer["outcome"]
        when "exists" then "#{answer["workspace"]}: #{answer["dir"]} exists already; nothing written. Read it with: workspace spine show #{answer["workspace"]}"
        when "would_create" then "#{answer["workspace"]}: would write #{count} #{(count == 1) ? "file" : "files"} to #{answer["dir"]} from template #{answer["template"]["name"]}."
        else "#{answer["workspace"]}: wrote #{count} #{(count == 1) ? "file" : "files"} to #{answer["dir"]} from template #{answer["template"]["name"]}."
        end
        @output.puts text
        answer["files"].each { |f| @output.puts "  #{f}" } unless answer["outcome"] == "exists"
      end
    end
  end
end
