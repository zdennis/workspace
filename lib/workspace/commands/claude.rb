module Workspace
  module Commands
    # Deactivates and reactivates Claude in project tmux panes.
    # Deactivate sends Ctrl-C to kill the running Claude process.
    # Reactivate sends the claude startup command to restart it.
    class Claude
      CLAUDE_PANE = "0.1"
      REACTIVATE_COMMAND = "claude --continue || claude"
      CTRL_C_COUNT = 3
      CTRL_C_DELAY = 0.5

      # @param state [Workspace::State] state persistence
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, tmux:, output: $stdout, error_output: $stderr)
        @state = state
        @tmux = tmux
        @output = output
        @error_output = error_output
      end

      # Sends Ctrl-C to the Claude pane to stop the running process.
      #
      # @param projects [Array<String>] project names to deactivate
      # @return [void]
      def deactivate(projects)
        each_active_session(projects) do |project, session_name|
          @output.puts "  Deactivating Claude in #{project}..."
          CTRL_C_COUNT.times do |i|
            @tmux.send_key(session_name, CLAUDE_PANE, "C-c")
            sleep CTRL_C_DELAY if i < CTRL_C_COUNT - 1
          end
        end
        @output.puts "Done."
      end

      # Sends the reactivate command to the Claude pane.
      #
      # @param projects [Array<String>] project names to reactivate
      # @return [void]
      def reactivate(projects)
        each_active_session(projects) do |project, session_name|
          @output.puts "  Reactivating Claude in #{project}..."
          @tmux.send_keys(session_name, CLAUDE_PANE, REACTIVATE_COMMAND)
        end
        @output.puts "Done."
      end

      private

      def each_active_session(projects)
        active_sessions = @tmux.sessions
        projects.each do |project|
          session_name = @tmux.session_name_for(project)
          unless active_sessions.include?(session_name)
            @error_output.puts "  Warning: No active tmux session for #{project}, skipping"
            next
          end
          yield project, session_name
        end
      end
    end
  end
end
