module Workspace
  module Commands
    # Reads a tmux pane's scrollback buffer and writes it to output.
    class Capture
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for captured text
      # @param error_output [IO] error output stream for error messages
      def initialize(tmux:, output: $stdout, error_output: $stderr)
        @tmux = tmux
        @output = output
        @error_output = error_output
      end

      # Captures a pane's scrollback buffer and writes it to @output.
      #
      # @param project [String] project/config name
      # @param pane [nil, :bottom, Integer, String] pane selector (see TmuxPane)
      # @param lines [Integer] number of lines from the bottom (default 100, ignored when all: true)
      # @param all [Boolean] capture full history up to tmux history-limit
      # @return [void]
      # @raise [Workspace::Error] if no active tmux session exists for the project
      # @raise [Workspace::Error] if the session's window has no panes
      # @raise [Workspace::Error] if pane cannot be found
      # @raise [Workspace::Error] if tmux capture-pane fails
      def call(project, pane: :bottom, lines: 100, all: false)
        session_name = @tmux.session_name_for(project)
        unless @tmux.sessions.include?(session_name)
          raise Workspace::Error,
            "No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it."
        end

        pane_index = TmuxPane.new(pane, tmux: @tmux).resolve(session_name)
        result = @tmux.capture_pane(session_name, pane_index, lines: lines, all: all)

        unless result
          raise Workspace::Error, "Failed to capture pane #{pane_index} of '#{project}'"
        end

        @output.print result
      end
    end
  end
end
