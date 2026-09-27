require "yaml"

module Workspace
  module Commands
    # Kills a worktree-based workspace project by stopping its session,
    # removing its git worktree, and cleaning up its tmuxinator config.
    # The inverse of Commands::Start.
    class Kill
      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config management
      # @param stop_command [Commands::Stop] stop command for session teardown
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(git:, project_config:, project_settings:, stop_command:, project_detector:, output: $stdout, input: $stdin)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @stop_command = stop_command
        @project_detector = project_detector
        @output = output
        @input = input
      end

      MARKER_FILE = ".workspace-project"

      # Kills a worktree project: stops the session, removes the worktree, and cleans up config.
      #
      # @param project [String, nil] project/config name, or nil to detect from cwd
      # @param force [Boolean] skip confirmation, and skip the unsaved-work refusal
      # @return [void]
      # @raise [Workspace::Error] if the project config is not a worktree project, or if it has
      #   unsaved work and force is false
      def call(project = nil, force: false, working_dir: Dir.pwd)
        project ||= @project_detector.detect_from_marker(working_dir)
        unless project
          raise Workspace::Error,
            "No project specified and no #{MARKER_FILE} found in current directory.\n" \
            "Run from inside a worktree, or specify the project name."
        end
        config_path = @project_config.config_path_for(project)
        unless File.exist?(config_path)
          raise Workspace::Error, "No config found for '#{project}'.\nRun 'workspace list' to see active projects."
        end

        worktree_path = read_worktree_path(config_path)
        unless worktree_path && @git.worktree_exists?(worktree_path)
          raise Workspace::Error, "'#{project}' does not appear to be a worktree project.\nUse 'workspace stop #{project}' to stop non-worktree projects."
        end

        check_unsaved_work!(project, worktree_path) unless force

        @output.puts "Stopping #{project}..."
        @output.puts "  Worktree: #{worktree_path}"

        unless force
          @output.print "Remove worktree and kill session? [y/N] "
          answer = @input.gets&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return
          end
        end

        remove_marker_file(worktree_path)

        @output.puts "Removing worktree..."
        @git.remove_worktree(worktree_path, force: force)

        # Remove the config/state entries before killing the tmux session:
        # this may be running from inside the very session it's about to
        # kill, which can end this process before later statements run.
        @project_config.remove(project)
        @project_settings.remove(project)

        @stop_command.call([project])

        @output.puts "Stopped #{project}."
        project
      end

      private

      def check_unsaved_work!(project, worktree_path)
        result = @git.unsaved_work(worktree_path)
        return if result.nil?

        if result == :unknown
          raise Workspace::Error,
            "Could not check '#{project}' for unsaved work (git couldn't answer).\n" \
            "Not removing the worktree at #{worktree_path}.\n" \
            "Commit/push, or rerun with --force."
        end

        branch = result[:branch] || "HEAD"
        raise Workspace::Error,
          "'#{project}' has unsaved work at #{worktree_path}: " \
          "#{result[:changed_files]} changed file(s) and #{result[:unpushed_commits]} unpushed commit(s) on #{branch}.\n" \
          "Commit/push, or rerun with --force."
      end

      def remove_marker_file(worktree_path)
        marker = File.join(worktree_path, MARKER_FILE)
        File.delete(marker) if File.exist?(marker)
      end

      def read_worktree_path(config_path)
        config = YAML.safe_load_file(config_path)
        config&.dig("root")
      rescue Psych::SyntaxError
        raise Workspace::Error, "Corrupt config file: #{config_path}"
      end
    end
  end
end
