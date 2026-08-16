module Workspace
  # Polls a tmux pane for the WORKSPACE_DONE sentinel and invokes a callback
  # with the summary text that follows it.
  #
  # Panes outlive the work items that run in them, so a pane's scrollback often
  # already holds sentinels from earlier stages or earlier work items. The
  # poller records how many lines the pane held when it started and only ever
  # considers output written after that point.
  class SentinelPoller
    SENTINEL = "WORKSPACE_DONE:".freeze

    # A sentinel at the start of its own line, and everything after it. Anchoring
    # keeps an instruction or shell command that merely mentions the sentinel
    # from being read as the sentinel itself.
    SUMMARY_PATTERN = /^\s*#{Regexp.escape(SENTINEL)}\s*(.*)$/

    # @param tmux [Workspace::Tmux] tmux session operations
    # @param session_name [String] tmux session to capture from
    # @param pane [Integer] zero-based pane index within window 0
    # @param poll_interval [Numeric] seconds to wait between captures
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] stream for reporting an unexpected poller death
    def initialize(tmux:, session_name:, pane:, poll_interval: 2,
      logger: Workspace::Logger.new, error_output: $stderr)
      @tmux = tmux
      @session_name = session_name
      @pane = pane
      @poll_interval = poll_interval
      @logger = logger
      @error_output = error_output
      @running = false
    end

    # Polls the pane in a background thread until the sentinel appears.
    #
    # @param on_error [#call, nil] called with the message when polling dies
    # @yieldparam summary [String] the text following the sentinel
    # @return [Thread] the polling thread
    def start(on_error: nil, &on_complete)
      @running = true
      @thread = Thread.new do
        # Taken inside the thread so a failing capture is reported here rather
        # than raised into whoever started the poller.
        @baseline = capture.to_s.lines.size
        while @running
          summary = scan
          if summary
            on_complete.call(summary)
            break
          end
          sleep @poll_interval
        end
      rescue => e
        @error_output.puts "workspace agent: stopped watching #{@session_name} pane #{@pane}: #{e.message}"
        @logger.debug { "sentinel poller backtrace: #{e.backtrace&.first(5)&.join("\n")}" }
        on_error&.call(e.message)
      ensure
        @running = false
      end
    end

    # Stops polling. Safe to call more than once, and safe to call from within
    # the completion callback — a poller must never kill the thread it is
    # running on, or the work that triggered it dies half-finished.
    #
    # @return [void]
    def stop
      @running = false
      thread = @thread
      @thread = nil
      thread.kill if thread && !thread.equal?(Thread.current)
    end

    private

    def capture
      @tmux.capture_pane(@session_name, @pane, all: true)
    end

    # @return [String, nil] the summary from the newest sentinel written since start
    def scan
      output = capture
      return nil unless output

      lines = output.lines
      return nil if lines.size <= @baseline

      lines.drop(@baseline).reverse_each do |line|
        match = SUMMARY_PATTERN.match(line)
        return match[1].strip if match
      end
      nil
    end
  end
end
