module Workspace
  module Commands
    # Sends a shell command to a specific pane in a running project's tmux session.
    class Run
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param state [Workspace::State] state persistence (used for --focus)
      # @param window_manager [Workspace::WindowManager] iTerm window operations (used for --focus)
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings and errors
      def initialize(tmux:, state:, window_manager:, output: $stdout, error_output: $stderr)
        @tmux = tmux
        @state = state
        @window_manager = window_manager
        @output = output
        @error_output = error_output
      end

      # Sends a command to a pane in the project's tmux session.
      #
      # @param project [String] project/config name
      # @param command [String] shell command text to send
      # @param pane [:bottom, Integer] :bottom for last pane (default), or zero-based pane index
      # @param split [Boolean] create a new pane below the bottommost and run there
      # @param vertical [Boolean] with split: true, create side-by-side pane (-h) instead of below (-v)
      # @param enter [Boolean] press Enter after sending text (default: true)
      # @param focus [Boolean] bring the project's iTerm window to front after sending
      # @param dry_run [Boolean] print what would be executed without running it
      # @param close [Boolean] send 'exit' to the pane after the command (closes the shell/pane)
      # @return [void]
      # @raise [Workspace::Error] if no active tmux session exists for the project
      # @raise [Workspace::Error] if the session's window has no panes
      # @raise [Workspace::Error] if pane index is out of range
      # @raise [Workspace::Error] if tmux fails to split the window (with split: true)
      # @raise [Workspace::Error] if tmux fails to send the command to the target pane
      def call(project, command, pane: :bottom, split: false, vertical: false,
        enter: true, focus: false, dry_run: false, close: false)
        session_name = @tmux.session_name_for(project)
        unless @tmux.sessions.include?(session_name)
          raise Workspace::Error,
            "No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it."
        end

        if split
          split_and_run(session_name, command, vertical: vertical, enter: enter,
            dry_run: dry_run, close: close)
        else
          pane_spec = TmuxPane.new(pane, tmux: @tmux).target(session_name)

          if dry_run
            print_dry_run_delivery(session_name, pane_spec, command, enter: enter)
            print_dry_run_delivery(session_name, pane_spec, "exit", enter: true) if close
          else
            send_text(session_name, pane_spec, command, enter: enter,
              failure: "Failed to send command to pane #{pane_spec} of '#{project}'")
            if close
              send_text(session_name, pane_spec, "exit", enter: true,
                failure: "Failed to send exit to pane #{pane_spec} of '#{project}'")
            end
          end
        end

        focus_window(project) if focus
      end

      private

      def split_and_run(session_name, command, vertical:, enter:, dry_run:, close:)
        pane_list = @tmux.panes(session_name, window: "0")
        raise Workspace::Error, "No panes found for session '#{session_name}'" if pane_list.empty?

        last_pane = pane_list.last

        if dry_run
          flag = vertical ? "-h" : "-v"
          @output.puts "tmux split-window #{flag} -t #{session_name}:0.#{last_pane}"
          print_dry_run_delivery(session_name, "0.<new_pane>", command, enter: enter)
          print_dry_run_delivery(session_name, "0.<new_pane>", "exit", enter: true) if close
          return
        end

        # split_window reports the new pane's index directly (tmux split-window -P -F).
        # Re-querying panes() and taking .last would race with concurrent pane changes
        # and can be defeated by tmux reusing a freed pane index.
        new_pane_index = @tmux.split_window(session_name, pane: last_pane, vertical: vertical)
        unless new_pane_index
          raise Workspace::Error, "Failed to split window for '#{session_name}'"
        end

        pane_spec = "0.#{new_pane_index}"

        send_text(session_name, pane_spec, command, enter: enter,
          failure: "Failed to send command to new split pane of '#{session_name}'")

        if close
          send_text(session_name, pane_spec, "exit", enter: true,
            failure: "Failed to send exit to new split pane of '#{session_name}'")
        end
      end

      # Prints the load-buffer + paste-buffer sequence that {Workspace::Tmux#deliver}
      # actually issues, so --dry-run output matches what a real run would do.
      def print_dry_run_delivery(session_name, pane_spec, text, enter:)
        target = "#{session_name}:#{pane_spec}"
        @output.puts "tmux load-buffer -b <buffer> -"
        @output.puts "tmux paste-buffer -p -b <buffer> -t #{target}"
        @output.puts "tmux delete-buffer -b <buffer>"
        @output.puts "tmux send-keys -t #{target} Enter" if enter
      end

      # Sends text and raises, with tmux's reason, unless it landed and (with
      # +enter+) was submitted.
      def send_text(session_name, pane_spec, text, enter:, failure:)
        delivery = @tmux.deliver(session_name, pane_spec, text, enter: enter)
        return if delivery.ok?

        hint = delivery.landed? ? " Do not run it again -- it is already in the pane; press Enter there instead." : ""
        raise Workspace::Error, "#{failure}: #{delivery.message}.#{hint}"
      end

      def focus_window(project)
        @state.load
        window_id = @state.dig(project, "iterm_window_id")
        return unless window_id && window_id != 0
        @window_manager.focus_by_id(window_id, highlight: nil)
      end
    end
  end
end
