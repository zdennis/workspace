module Workspace
  module Commands
    # Polls a tmux pane's scrollback until it contains a target string, then
    # execs a follow-up command so it replaces this process and owns the
    # terminal (direct Ctrl-C, untouched STDIN/STDOUT/STDERR).
    #
    # Port of the standalone wait-until-content script. By default it matches
    # against the last --lines lines of the pane's scrollback, so content that
    # was already present matches immediately. With since_start: true it takes
    # a baseline of the full scrollback when it starts and only matches content
    # written after that point, anchoring on the baseline content itself (see
    # #post_start_lines) rather than on a line offset, which churn at the
    # history limit or a mid-wait clear-history defeats.
    #
    # The pane spec is resolved once, at start, to the pane's tmux pane id,
    # and every poll re-resolves by that id: a :bottom/index/title selector
    # cannot silently switch to a renumbered pane when the target closes —
    # the id stops resolving and the wait errors out.
    class WaitUntilContent
      DEFAULT_LINES = 100
      DEFAULT_INTERVAL = 0.5

      # Color wrapper that degrades to plain text when the stream is not a TTY
      # or when NO_COLOR is set. Checks the injected stream, not $stdout, so
      # tests (StringIO) never see ANSI codes.
      module Color
        GREEN = "\e[32m"
        CYAN = "\e[36m"
        RED = "\e[31m"
        DIM = "\e[2m"
        BOLD = "\e[1m"
        RESET = "\e[0m"

        def self.wrap(io, code, text)
          return text unless io.tty? && !ENV.key?("NO_COLOR")
          "#{code}#{text}#{RESET}"
        end
      end

      # Flushes the status streams, then replaces this process with the command.
      # exec does NOT flush Ruby's IO buffers — without the flushes the banner
      # and status lines are lost when stdout is block-buffered (e.g. piped).
      DEFAULT_EXEC_HANDLER = lambda do |command, output, error_output|
        output.flush
        error_output.flush
        if command.is_a?(Array)
          Kernel.exec(*command)
        else
          Kernel.exec(command)
        end
      end

      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] stream for the banner and status lines
      # @param error_output [IO] stream for failure messages
      # @param sleeper [#call] test seam: seconds -> sleeps (default: Kernel.sleep)
      # @param exec_handler [#call] test seam: (command, output, error_output) ->
      #   flushes streams then execs; never returns on success
      # @param clock [#call] test seam: -> monotonic seconds
      # @param spinner_enabled [Boolean] start the spinner thread (disable in tests)
      def initialize(tmux:, output: $stdout, error_output: $stderr,
        sleeper: ->(seconds) { Kernel.sleep(seconds) },
        exec_handler: DEFAULT_EXEC_HANDLER,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        spinner_enabled: true)
        @tmux = tmux
        @output = output
        @error_output = error_output
        @sleeper = sleeper
        @exec_handler = exec_handler
        @clock = clock
        @spinner_enabled = spinner_enabled
      end

      # Polls the pane until its captured content includes content, then execs
      # exec_command.
      #
      # @param project [String] project/config name
      # @param content [String] target string (may be multi-line)
      # @param pane [nil, :bottom, Integer, String] pane selector (see TmuxPane)
      # @param lines [Integer] match window: last N lines of scrollback (default: 100)
      # @param interval [Numeric] seconds between polls (default: 0.5)
      # @param max_wait_time [nil, Numeric] give up after this many seconds
      #   (nil: wait forever)
      # @param since_start [Boolean] only match content written after this
      #   command starts (content-anchored baseline of the full scrollback).
      #   A target string spanning the anchor boundary (part pre-start,
      #   part post-start) never matches. Known limitation: a mid-wait
      #   reflow (e.g. a resize rewrapping the baseline lines) can lose
      #   the anchor, and the surviving==0 fallback then treats
      #   pre-start content as post-start — content alone cannot
      #   distinguish reflow from full history eviction.
      # @param exec_command [nil, Array, String] command to exec on match:
      #   an Array is passed straight to exec (no shell re-quoting), a String
      #   is a shell command; nil means report the match and return 0
      # @return [Integer] 0 on match (exec_command nil) or after handing off
      #   to exec; 1 on timeout or exec failure
      # @raise [Workspace::Error] if no active tmux session exists for the project
      # @raise [Workspace::Error] if the pane cannot be found, or disappears
      #   mid-poll (the pane is anchored to its tmux pane id at start, which
      #   stops resolving once the pane or session is gone)
      # @raise [Workspace::Error] if since_start is set and the baseline
      #   capture fails at start
      def call(project, content, pane: :bottom, lines: DEFAULT_LINES,
        interval: DEFAULT_INTERVAL, max_wait_time: nil, since_start: false,
        exec_command: nil)
        session_name = @tmux.session_name_for(project)
        unless @tmux.sessions.include?(session_name)
          raise Workspace::Error,
            "No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it."
        end

        pane_spec = TmuxPane.new(pane, tmux: @tmux)
        pane_index = pane_spec.resolve(session_name)
        # Anchor to the pane's tmux pane id, resolved once: re-resolving the
        # original spec each poll would let a :bottom/index/title selector
        # silently switch to a renumbered pane once the target closes.
        pane_id = pane_spec.resolve_id(session_name)
        anchored_pane = TmuxPane.new(pane_id, tmux: @tmux)

        baseline = nil
        if since_start
          baseline_capture = @tmux.capture_pane_by_id(pane_id, all: true)
          if baseline_capture.nil?
            raise Workspace::Error,
              "Could not capture the pane to take a --since-start baseline " \
              "(tmux capture failed for pane #{pane_id} of '#{session_name}'); " \
              "a silent zero-line baseline could match pre-existing content"
          end
          # A zero-line capture is a legitimate baseline: a pane with no
          # history yet baselines at 0, so everything captured later is
          # post-start content. Only a nil capture is an error.
          baseline = baseline_capture
        end

        print_banner(project, session_name, pane_index, content, lines, interval,
          max_wait_time, since_start, exec_command)

        start = @clock.call
        spinner = start_spinner(start)
        begin
          loop do
            # Re-resolve by the anchored pane id on every poll: if the target
            # pane closes, the id no longer resolves and this raises, so the
            # wait errors out instead of polling forever — or of silently
            # following whichever pane a :bottom/index/title selector would
            # pick up after a renumber.
            anchored_pane.resolve(session_name)

            if match?(capture(pane_id, lines, baseline), content)
              stop_spinner(spinner)
              elapsed = @clock.call - start
              @output.puts Color.wrap(@output, Color::GREEN, "  ✓ Matched after #{format_elapsed(elapsed)}")
              return execute(exec_command)
            end
            elapsed = @clock.call - start
            if max_wait_time && elapsed >= max_wait_time
              stop_spinner(spinner)
              @error_output.puts Color.wrap(@error_output, Color::RED,
                "  ✗ Timed out after #{format_elapsed(elapsed)} waiting for content in pane #{pane_index} of '#{project}'")
              return 1
            end
            # Sleep no longer than the time remaining, so a long --interval
            # cannot overshoot --max-wait-time.
            if max_wait_time
              @sleeper.call([interval, max_wait_time - elapsed].min)
            else
              @sleeper.call(interval)
            end
          end
        ensure
          stop_spinner(spinner)
        end
      end

      private

      # Returns the text to match: the last `lines` lines of the capture,
      # or with a baseline, the last `lines` lines of everything written since
      # this command started. The baseline uses the full scrollback because a
      # windowed baseline would slide as new content is written.
      #
      # A nil capture is a transient hiccup on a pane the anchored resolve
      # just confirmed exists: it reads as no-match and polling continues, in
      # both the bounded and the baseline path. A pane or session that no
      # longer exists raises from the anchored resolve instead.
      def capture(pane_id, lines, baseline)
        if baseline
          blob = @tmux.capture_pane_by_id(pane_id, all: true)
          return "" if blob.nil?
          post_start_lines(blob, baseline).last(lines).join
        else
          @tmux.capture_pane_by_id(pane_id, lines: lines).to_s
        end
      end

      # The lines of the current capture written after the baseline was
      # taken: everything after the surviving part of the baseline.
      #
      # Alignment: a pane appends new lines below the existing ones and,
      # once the history limit is reached, evicts the oldest from the top —
      # and clear-history keeps the visible screen, which holds the bottom
      # of the baseline. In every case the surviving baseline content is a
      # suffix of the baseline that appears as a prefix of the current
      # capture, so the anchor is the longest such suffix and the match
      # window is what follows it. A line offset cannot express this: a
      # scrollback already at the history limit stays the same size forever
      # (new content evicts the top, so the offset lands past the end and
      # post-start content can never match), and a clear-history keeps the
      # line count plausible while the pre-start content survives.
      #
      # When no suffix survives — the baseline fully evicted at the history
      # limit, or the pane cleared and rewritten — everything in the capture
      # is post-start content, so all of it is the match window.
      #
      # Limitation: a mid-wait reflow (a resize rewrapping the baseline
      # lines, or an alt-screen round-trip transforming them) breaks the
      # suffix anchor, and the surviving==0 fallback then admits
      # pre-start content. Content alone cannot distinguish reflow from
      # full history eviction, and full eviction must treat everything
      # as post-start (the history-limit case), so the trade-off is
      # inherent.
      #
      # Duplicate-tail absorption: post-start lines identical to the
      # evicted baseline tail can be absorbed into the anchor — a
      # bounded false negative that self-corrects once a distinguishing
      # line lands, and never a false positive.
      #
      # The baseline's trailing blank lines are stripped first: tmux pads
      # the visible screen with blank lines below the cursor, and new lines
      # are written into that region (the padding stays at the bottom), so
      # padded blanks never align as part of the surviving suffix. A
      # zero-line baseline strips to no lines, so everything matches — the
      # legitimate empty-pane baseline.
      #
      # The suffix scan tries the longest suffix first; line-array equality
      # short-circuits on the first differing line, so each rejected
      # candidate is cheap.
      #
      # @param blob [String] the full scrollback captured this poll
      # @param baseline [String] the full scrollback captured at start
      # @return [Array<String>] the post-start lines, padding included
      def post_start_lines(blob, baseline)
        current = blob.lines
        baseline_lines = strip_trailing_blanks(baseline.lines)
        max = [baseline_lines.size, current.size].min
        max.downto(0) do |surviving|
          if current.first(surviving) == baseline_lines.last(surviving)
            return current.drop(surviving)
          end
        end
      end

      # Removes the visible screen's blank padding below the cursor from
      # the end of the captured lines. The lines are mutated in place; the
      # caller passes a fresh Array from String#lines.
      def strip_trailing_blanks(lines)
        lines.pop while !lines.empty? && lines.last.strip.empty?
        lines
      end

      def match?(blob, content)
        blob.include?(content)
      end

      def execute(exec_command)
        return 0 if exec_command.nil?
        command_display = exec_command.is_a?(Array) ? exec_command.join(" ") : exec_command
        @output.puts Color.wrap(@output, Color::CYAN, "  ▶ Executing #{command_display}")
        @output.puts
        @exec_handler.call(exec_command, @output, @error_output)
        0
      rescue SystemCallError => e
        @error_output.puts Color.wrap(@error_output, Color::RED,
          "  ✗ Failed to execute #{command_display.inspect}: #{e.message}")
        1
      end

      def print_banner(project, session_name, pane_index, content, lines,
        interval, max_wait_time, since_start, exec_command)
        command_display = if exec_command.nil?
          "none"
        else
          exec_command.is_a?(Array) ? exec_command.join(" ") : exec_command
        end
        wait_for = max_wait_time ? "up to #{max_wait_time}s" : "as long as it takes"
        window = since_start ? "since start (last #{lines} lines)" : "last #{lines} lines"

        @output.puts Color.wrap(@output, Color::BOLD, "wait-until-content")
        @output.puts
        label_width = 12
        print_field = lambda do |label, value|
          @output.puts "  #{Color.wrap(@output, Color::DIM, label.ljust(label_width))}#{value}"
        end
        print_field.call("workspace", Color.wrap(@output, Color::BOLD, project))
        print_field.call("session", Color.wrap(@output, Color::DIM, session_name))
        print_field.call("pane", Color.wrap(@output, Color::BOLD, pane_index.to_s))
        print_field.call("window", Color.wrap(@output, Color::DIM, window))
        print_field.call("interval", Color.wrap(@output, Color::DIM, "#{interval}s"))
        print_field.call("wait for", Color.wrap(@output, Color::DIM, wait_for))
        @output.puts
        @output.puts "  #{Color.wrap(@output, Color::DIM, "content to match")}"
        content.each_line(chomp: true) { |l| @output.puts "    #{Color.wrap(@output, Color::BOLD, l)}" }
        @output.puts
        @output.puts "  #{Color.wrap(@output, Color::DIM, "command on match")}"
        @output.puts "    #{Color.wrap(@output, Color::CYAN, command_display)}"
        @output.puts
      end

      # Rewrites a single line with a spinner glyph and elapsed seconds, only
      # when the output is a TTY. Returns a stop lambda, or nil when there is
      # no spinner (piped output, or disabled in tests).
      def start_spinner(start)
        return nil unless @spinner_enabled && @output.tty?
        chars = %w[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]
        stop = [false]
        thread = Thread.new do
          i = 0
          until stop[0]
            elapsed = @clock.call - start
            @output.print "\r  #{chars[i % chars.length]} #{Color.wrap(@output, Color::DIM, "waiting... #{elapsed.to_i}s")}"
            i += 1
            Kernel.sleep 0.1
          end
          @output.print "\r#{" " * 40}\r"
        end
        # Join so the spinner finishes clearing its line before the status
        # line prints; it sleeps at most 0.1s between frames.
        -> do
          stop[0] = true
          thread.join(1)
        end
      end

      # Safe to call more than once; the ensure block in call relies on that.
      def stop_spinner(stop_lambda)
        stop_lambda&.call
      end

      def format_elapsed(elapsed)
        format("%.1f", elapsed)
      end
    end
  end
end
