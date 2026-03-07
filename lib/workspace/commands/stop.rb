require "yaml"

module Workspace
  module Commands
    # Stops a worktree-based workspace project by killing its session,
    # removing its git worktree, and cleaning up its tmuxinator config.
    # The inverse of Commands::Start.
    class Stop
      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config management
      # @param kill_command [Commands::Kill] kill command for session teardown
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(git:, project_config:, kill_command:, output: $stdout, input: $stdin)
        @git = git
        @project_config = project_config
        @kill_command = kill_command
        @output = output
        @input = input
      end

      MARKER_FILE = ".workspace-project"

      # Stops a worktree project: kills the session, removes the worktree, and cleans up config.
      #
      # @param project [String, nil] project/config name, or nil to detect from cwd
      # @param force [Boolean] force worktree removal even with uncommitted changes
      # @return [void]
      # @raise [Workspace::Error] if the project config is not a worktree project
      def call(project = nil, force: false)
        project ||= detect_project
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
          raise Workspace::Error, "'#{project}' does not appear to be a worktree project.\nUse 'workspace kill #{project}' to stop non-worktree projects."
        end

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

        @output.puts "Removing worktree..."
        @git.remove_worktree(worktree_path, force: force)

        @kill_command.call([project])
        @project_config.remove(project)

        @output.puts "Stopped #{project}."
      end

      private

      def detect_project
        dir = Dir.pwd
        loop do
          marker = File.join(dir, MARKER_FILE)
          return File.read(marker).strip if File.exist?(marker)
          parent = File.dirname(dir)
          break if parent == dir
          dir = parent
        end
        nil
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
