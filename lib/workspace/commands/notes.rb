require "json"
require "fileutils"

module Workspace
  module Commands
    # `workspace notes dir`: where one workspace's notes are kept. It is the one
    # answer for agents, scripts and the app, and the lazy way to set the
    # directory up for a workspace `start` never touched.
    #
    # The path comes from {Workspace::NotesDir}: the workspace's own `notes.dir`
    # (a worktree's own file, or the project's for a main checkout), else the
    # project's `notes.default_dir` rule, else `tmp/workspace-notes` in the
    # checkout. A stored value that fails its key's checks counts as unset, as it
    # does in `config show`. Nothing here writes config.
    class Notes
      # @param notes_dir [Workspace::NotesDir] the resolver
      # @param project_config [Workspace::ProjectConfig] gives a workspace's checkout root
      # @param config_resolver [Workspace::ConfigResolver] reads the config files
      # @param git_exclude [Workspace::GitExclude] reads and writes the common dir's `info/exclude`
      # @param output [IO] output stream
      def initialize(notes_dir:, project_config:, config_resolver:, git_exclude:, output: $stdout)
        @notes_dir = notes_dir
        @project_config = project_config
        @config_resolver = config_resolver
        @git_exclude = git_exclude
        @output = output
      end

      # Prints the notes directory of a workspace: the absolute path alone, or one
      # JSON document.
      #
      # @param name [String] the workspace, e.g. "api" or "api.worktree-x"
      # @param create [Boolean] make the directory; inside the checkout, also list it in `info/exclude`
      # @param json [Boolean] print the document instead of the path
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace` when the workspace has no checkout,
      #   `notes_dir_unresolved` when the rule needs a branch the checkout lacks,
      #   `notes_dir_unwritable` when `create` can't make the directory or write the exclude line,
      #   `config_parse` when a config file can't be parsed
      def dir(name:, create: false, json: false)
        answer = info(name: name, create: create)
        if json
          @output.puts JSON.generate({"schema_version" => 1, "ok" => true}.merge(answer))
        else
          @output.puts answer["dir"]
        end
      end

      # The answer {#dir} prints, as a Hash, so `start`, `add` and the rest ask the
      # same code and get the same directory.
      #
      # @param name [String] the workspace
      # @param create [Boolean] make the directory; inside the checkout, also list it in `info/exclude`
      # @return [Hash] `workspace`, `dir`, `source`, `exists`, `inside_worktree`, `excluded`
      # @raise [Workspace::Error] as {#dir}
      def info(name:, create: false)
        root = checkout_root(name)
        result = resolve(name, root)
        path = result.path
        real_root = real(root)
        real_path = real(path)
        inside = real_path.start_with?("#{real_root}/")
        pattern = inside ? exclude_pattern(real_root, real_path) : nil
        make(path, root, pattern) if create
        excluded = inside ? @git_exclude.listed?(root, pattern) : true

        {"workspace" => name, "dir" => path, "source" => result.source,
         "exists" => Dir.exist?(path), "inside_worktree" => inside, "excluded" => excluded}
      end

      # The notes a workspace would lose with its checkout: set only when the notes
      # directory is inside the checkout and holds at least one file. Never raises
      # for a workspace it can't resolve; the caller is about to delete, not to ask.
      #
      # @param name [String] the workspace
      # @return [Hash, nil] `{"dir" => absolute path, "files" => count}`, or nil
      def files_inside_worktree(name:)
        answer = info(name: name)
        return nil unless answer["inside_worktree"] && answer["exists"]
        count = Dir.glob(File.join(answer["dir"], "**", "*"), File::FNM_DOTMATCH).count { |path| File.file?(path) }
        count.zero? ? nil : {"dir" => answer["dir"], "files" => count}
      rescue Workspace::Error, SystemCallError
        nil
      end

      # @param name [String] the workspace
      # @return [String] its checkout root
      # @raise [Workspace::Error] `unknown_workspace`
      def checkout_root(name)
        root = @project_config.project_root_for(name)
        raise Workspace::Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name}) unless root
        File.expand_path(root)
      end

      private

      def resolve(name, root)
        view = @config_resolver.view(workspace: name)
        result = @notes_dir.resolve(stored: valid(view, "dir"), template: valid(view, "default_dir"),
          worktree: !WorkspaceLineage.split_worktree_name(name).nil?, root: root, workspace: name)
        return result if result.path
        raise Workspace::Error.new(
          "Can't work out the notes directory for '#{name}': notes.default_dir uses {branch} and the checkout at #{root} is on no branch (detached HEAD). Check out a branch, or set notes.dir for this workspace.",
          code: "notes_dir_unresolved", details: {"name" => name, "path" => root}
        )
      end

      # The stored `notes.<leaf>`, nil when unset or not valid for the key.
      def valid(view, leaf)
        value = view.raw("notes.#{leaf}")
        return nil if value.nil?
        ConfigSchema.parse("notes.#{leaf}", value)
      rescue ArgumentError
        nil
      end

      # +path+ with symlinks resolved as far as it exists, so a checkout reached through a link
      # (/tmp on macOS) still compares equal to a path under its real location.
      def real(path)
        File.realpath(path)
      rescue SystemCallError
        parent = File.dirname(path)
        return path if parent == path
        File.join(real(parent), File.basename(path))
      end

      # The rooted line for `info/exclude`, with the characters git reads as a glob escaped.
      def exclude_pattern(root, path)
        relative = path.delete_prefix("#{root}/").gsub(/[\\\[\]*?]/) { |c| "\\#{c}" }
        "/#{relative}/"
      end

      def make(path, root, pattern)
        FileUtils.mkdir_p(path)
        @git_exclude.add(root, pattern) if pattern
      rescue SystemCallError => e
        raise Workspace::Error.new("Can't set up the notes directory #{path}: #{e.message}", code: "notes_dir_unwritable", details: {"path" => path})
      end
    end
  end
end
