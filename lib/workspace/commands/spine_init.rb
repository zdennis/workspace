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
      DEFAULT_TEMPLATE = "default"

      # The stage file (and folder) a main checkout's spine leaves out: it has no branch to ship.
      SHIP_STAGE = /\A\d{1,3}-ship(\.md)?\z/

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are, and makes the directory
      # @param library [Workspace::Library] finds the template
      # @param project_config [Workspace::ProjectConfig] gives a workspace's checkout
      # @param git [Workspace::Git] names the checkout's branch
      # @param task_store [Workspace::TaskStore] gives the workspace's task title
      # @param output [IO]
      def initialize(notes:, library:, project_config:, git:, task_store:, output: $stdout)
        @notes = notes
        @library = library
        @project_config = project_config
        @git = git
        @task_store = task_store
        @output = output
      end

      # @param name [String] the workspace
      # @param template [String, nil] the template name; nil is `default`
      # @param dry_run [Boolean] report what would be written and write nothing
      # @param json [Boolean] print the document documented in docs/README.spine.md instead of a sentence
      # @return [Hash] the answer: `outcome` is `created`, `exists` or `would_create`
      # @raise [Workspace::Error] `unknown_workspace`, `unknown_template`, `notes_dir_unresolved`,
      #   `config_parse` or `spine_unwritable`
      def call(name:, template: nil, dry_run: false, json: false)
        root = @project_config.project_root_for(name)
        raise Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name}) unless root
        root = File.expand_path(root)
        entry = @library.spine_template(template || DEFAULT_TEMPLATE, cwd: root)
        notes_dir = @notes.info(name: name)["dir"]
        spine_dir = File.join(real(notes_dir), "spine")
        main = WorkspaceLineage.split_worktree_name(name).nil?

        outcome, files = plan(entry, spine_dir, main, dry_run)
        outcome = "exists" if outcome == "created" && !write(name, root, spine_dir, files)

        answer = {"workspace" => name, "outcome" => outcome,
                  "template" => {"name" => entry["name"], "scope" => entry["scope"]},
                  "dir" => spine_dir, "files" => (outcome == "exists") ? [] : files.map(&:first)}
        print(answer, json)
        answer
      end

      private

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

      def print(answer, json)
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
