module Workspace
  module Commands
    # Deletes a plain project's generated files: its tmuxinator config, its
    # project settings file and its state entry. The project's directory, git
    # worktrees and notes are never touched. A running session or a worktree
    # project is refused; `kill`, `finish` and `prune` handle worktrees.
    class Remove
      # @param project_config [Workspace::ProjectConfig] tmuxinator config management
      # @param project_settings [Workspace::ProjectSettings] per-project settings files
      # @param state [Workspace::State] state persistence
      # @param tmux [Workspace::Tmux] says whether the project's session is up
      # @param git [Workspace::Git] says whether the project's root is a linked worktree
      # @param file_backup [Workspace::FileBackup] copies each file aside before it is deleted
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for the confirmation prompt
      def initialize(project_config:, project_settings:, state:, tmux:, git:, file_backup:, output: $stdout, input: $stdin)
        @project_config = project_config
        @project_settings = project_settings
        @state = state
        @tmux = tmux
        @git = git
        @file_backup = file_backup
        @output = output
        @input = input
      end

      # @param name [String] the workspace to remove
      # @param yes [Boolean] skip the confirmation prompt
      # @param dry_run [Boolean] report what would go and change nothing
      # @return [Hash, nil] `{"workspace", "outcome" ("removed" or "would_remove"), "files", "backups", "state_entry"}`,
      #   or nil when the person declined
      # @raise [Workspace::Error] `unknown_workspace`, `session_running`, `not_removable` or `confirmation_required`
      def call(name, yes: false, dry_run: false)
        @state.load
        config_path = @project_config.config_path_for(name)
        settings_path = @project_settings.project_config_path(name)
        files = [config_path, settings_path].select { |path| File.exist?(path) }
        in_state = !@state[name].nil?
        if files.empty? && !in_state
          raise Workspace::Error.new("No workspace named '#{name}'. Run 'workspace list --all' to see them.",
            code: "unknown_workspace", details: {"name" => name})
        end

        refuse_if_running!(name)
        refuse_if_worktree!(name)

        verb = dry_run ? "Would remove" : "Remove"
        files.each { |path| @output.puts "#{verb}: #{path}" }
        @output.puts "#{verb} state entry: #{name}" if in_state
        @output.puts "The project directory and its notes are not touched."

        unless yes || dry_run
          answer = Prompt.ask(@input, @output, "Remove workspace '#{name}'? [y/N] ", retry_flags: ["--yes"], destructive: true)&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return nil
          end
        end

        backups = []
        unless dry_run
          files.each do |path|
            backup = @file_backup.backup(path, quiet: true)
            raise Workspace::Error, "Could not back up #{path}; nothing was removed." unless backup
            backups << backup
          end
          @project_config.remove(name, quiet: true)
          @project_settings.remove(name)
          if in_state
            @state.delete(name)
            @state.save
          end
          @output.puts "Removed workspace '#{name}'."
          backups.each { |path| @output.puts "  backup  #{path}" }
        end
        {"workspace" => name, "outcome" => dry_run ? "would_remove" : "removed",
         "files" => files, "backups" => backups, "state_entry" => in_state}
      end

      private

      # Checks the name as given and in lowercase, as a mixed-case workspace is
      # renamed to lowercase by NameMigration and its session may carry either.
      def refuse_if_running!(name)
        [name, name.downcase].uniq.each do |candidate|
          session = @tmux.session_name_for(candidate)
          [session, session.downcase].uniq.each do |session_name|
            next unless @tmux.session_exists?(session_name, project: candidate)
            raise Workspace::Error.new("'#{name}' has a running tmux session (#{session_name}). Run 'workspace stop #{name}' first.",
              code: "session_running", details: {"name" => name, "session" => session_name})
          end
        end
      end

      # A worktree project is told by its root being a linked worktree, by the
      # `.workspace-project` marker in its root, or by a worktree config name,
      # so a workspace with no config (and so no root) is still caught.
      def refuse_if_worktree!(name)
        root = @project_config.project_root_for(name)
        worktree = (root && @git.linked_worktree?(root)) ||
          marker_names(root).any? { |marker| lineage_worktree?(marker) } ||
          lineage_worktree?(name)
        return unless worktree
        raise Workspace::Error.new("'#{name}' is a worktree project. Use 'workspace kill', 'workspace finish' or 'workspace prune' to remove it with its worktree.",
          code: "not_removable", details: {"name" => name, "root" => root})
      end

      def marker_names(root)
        return [] unless root
        path = File.join(root, WorkspaceLineage::MARKER_FILE)
        File.file?(path) ? [File.read(path).strip] : []
      rescue SystemCallError
        []
      end

      def lineage_worktree?(name)
        !WorkspaceLineage.split_worktree_name(name).nil?
      end
    end
  end
end
