module Workspace
  module Commands
    # Detects and removes zombie sessions from state.
    # A zombie session is one where the state file has an entry but the
    # corresponding tmux session or iTerm window no longer exists. A window
    # whose state could not be read is never counted as gone.
    class Cleanup
      # @param state [Workspace::State] state persistence
      # @param window_liveness [#call] answers true, false or nil (headless, or
      #   the window list could not be read) for each state entry
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(state:, window_liveness:, tmux:, output: $stdout, input: $stdin)
        @state = state
        @window_liveness = window_liveness
        @tmux = tmux
        @output = output
        @input = input
      end

      # Detects zombie sessions, lists them, asks for confirmation, and removes them.
      #
      # @param force [Boolean] skip confirmation and remove zombies immediately
      # @param dry_run [Boolean] list the zombies and return them without prompting or removing anything
      # @param tmux_dead_only [Boolean] count only entries whose tmux session is gone
      # @return [Array<Hash>] the zombies listed (dry run) or removed, each
      #   `{project:, tmux_alive:, window_alive:, window_id:, headless:}`; empty
      #   when there are none or the prompt was declined. `window_alive` is nil
      #   for a headless entry or when the window list could not be read.
      def call(force: false, dry_run: false, tmux_dead_only: false)
        @state.load

        if @state.empty?
          @output.puts "No tracked sessions. State is clean."
          return []
        end

        zombies = detect_zombies(tmux_dead_only: tmux_dead_only)

        if zombies.empty?
          @output.puts "No zombie sessions detected. State is clean."
          return []
        end

        list_zombies(zombies)

        if dry_run
          @output.puts "\nDry run: nothing was removed."
          return zombies
        end

        unless force
          answer = Prompt.ask(@input, @output, "\nRemove these #{zombies.size} zombie session(s) from state? [y/N] ", retry_flags: ["--force"], destructive: true)&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return []
          end
        end

        remove_zombies(zombies)
        @state.save

        @output.puts "\nCleaned up #{zombies.size} zombie session(s)."
        zombies
      end

      private

      # Detects zombie sessions by checking if tmux sessions and iTerm windows
      # exist. A headless project has no window, so only its tmux session is
      # checked, and iTerm2 isn't asked at all when every project is headless.
      # When the window list can't be read, a window is unknown rather than
      # gone: it never makes an entry a zombie, so only a missing tmux session
      # does.
      #
      # @param tmux_dead_only [Boolean] ignore the window; only a missing tmux session counts
      # @return [Array<Hash>] array of zombie info hashes
      def detect_zombies(tmux_dead_only:)
        active_sessions = @tmux.sessions
        window_states = @window_liveness.call(@state.to_h)

        zombies = []
        @state.each do |project, info|
          tmux_alive = active_sessions.include?(@tmux.session_name_for(project))
          window_alive = window_states[project]
          window_gone = window_alive == false

          next if tmux_alive && (tmux_dead_only || !window_gone)

          zombies << {
            project: project,
            tmux_alive: tmux_alive,
            window_alive: window_alive,
            window_id: info["iterm_window_id"],
            headless: info["headless"] ? true : false
          }
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
          @output.puts "    iTerm window: #{window_text(z)}"
        end
      end

      # @param zombie [Hash]
      # @return [String]
      def window_text(zombie)
        if zombie[:headless]
          "none (headless)"
        elsif zombie[:window_alive].nil?
          "unknown (could not list iTerm windows)"
        elsif zombie[:window_alive]
          "alive (#{zombie[:window_id]})"
        else
          "DEAD (#{zombie[:window_id]})"
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
