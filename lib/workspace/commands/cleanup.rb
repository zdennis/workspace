module Workspace
  module Commands
    # Detects and removes zombie sessions from state.
    # A zombie session is one where the state file has an entry but the
    # corresponding tmux session or iTerm window no longer exists.
    class Cleanup
      # @param state [Workspace::State] state persistence
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(state:, window_manager:, tmux:, output: $stdout, input: $stdin)
        @state = state
        @window_manager = window_manager
        @tmux = tmux
        @output = output
        @input = input
      end

      # Detects zombie sessions, lists them, asks for confirmation, and removes them.
      #
      # @param force [Boolean] skip confirmation and remove zombies immediately
      # @return [Array<String>] names of cleaned up projects
      def call(force: false)
        @state.load

        if @state.empty?
          @output.puts "No tracked sessions. State is clean."
          return []
        end

        zombies = detect_zombies

        if zombies.empty?
          @output.puts "No zombie sessions detected. State is clean."
          return []
        end

        list_zombies(zombies)

        unless force
          @output.print "\nRemove these #{zombies.size} zombie session(s) from state? [y/N] "
          answer = @input.gets&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return []
          end
        end

        remove_zombies(zombies)
        @state.save

        @output.puts "\nCleaned up #{zombies.size} zombie session(s)."
        zombies.map { |z| z[:project] }
      end

      private

      # Detects zombie sessions by checking if tmux sessions and iTerm windows exist.
      #
      # @return [Array<Hash>] array of zombie info hashes
      def detect_zombies
        active_sessions = @tmux.sessions
        live_window_ids = @window_manager.live_window_ids

        zombies = []
        @state.each do |project, info|
          session_name = @tmux.session_name_for(project)
          tmux_alive = active_sessions.include?(session_name)
          window_id = info["iterm_window_id"]
          window_alive = window_id && live_window_ids.include?(window_id.to_i)

          unless tmux_alive && window_alive
            zombies << {
              project: project,
              tmux_alive: tmux_alive,
              window_alive: window_alive,
              window_id: window_id
            }
          end
        end

        zombies
      end

      # Lists zombie sessions with their status.
      #
      # @param zombies [Array<Hash>] array of zombie info hashes
      # @return [void]
      def list_zombies(zombies)
        @output.puts "Found #{zombies.size} zombie session(s):\n\n"
        zombies.each do |z|
          @output.puts "  #{z[:project]}"
          @output.puts "    tmux session: #{z[:tmux_alive] ? "alive" : "DEAD"}"
          @output.puts "    iTerm window: #{z[:window_alive] ? "alive (#{z[:window_id]})" : "DEAD (#{z[:window_id]})"}"
        end
      end

      # Removes zombie projects from state.
      #
      # @param zombies [Array<Hash>] array of zombie info hashes
      # @return [void]
      def remove_zombies(zombies)
        zombies.each do |z|
          @state.delete(z[:project])
        end
      end
    end
  end
end
