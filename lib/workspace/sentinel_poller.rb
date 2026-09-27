module Workspace
  # Polls a tmux pane for the WORKSPACE_DONE sentinel and invokes a callback
  # with the summary text that follows it.
  #
  # Each stage dispatch gets its own token, and only a sentinel carrying that
  # token ends the stage. Panes outlive the work items that run in them, so a
  # pane's scrollback often already holds sentinels from earlier stages or
  # earlier work items; the token is what tells this stage's sentinel apart
  # from those, and from a test or script that happens to print the prefix.
  # Because a match needs nothing but the token, it still works once the
  # pane's history is full, and after the agent restarts mid-stage.
  #
  # A poller without a token is the legacy mode for work dispatched before
  # tokens existed: it records how many lines the pane held when it started
  # and accepts any sentinel written after that point.
  class SentinelPoller
    SENTINEL = "WORKSPACE_DONE:".freeze

    # The placeholder the instruction text shows where the summary goes. A
    # line carrying it is the instruction itself, wrapped onto a line of its
    # own by the pane's width, not the stage reporting back.
    SUMMARY_PLACEHOLDER = "<one-line summary>".freeze

    # @param token [String, nil] the dispatch token, or nil for a tokenless sentinel
    # @return [String] the text a stage prints to start its completion line
    def self.marker(token)
      token ? "#{SENTINEL}#{token}" : SENTINEL
    end

    # @param token [String, nil] the dispatch token the stage must print
    # @return [String] the instruction telling a stage how to report it is done
    def self.instruction(token)
      "When you are done, print a single line: #{marker(token)} #{SUMMARY_PLACEHOLDER}"
    end

    # @param tmux [Workspace::Tmux] tmux session operations
    # @param session_name [String] tmux session to capture from
    # @param pane [Integer] zero-based pane index within window 0
    # @param token [String, nil] the dispatch token to wait for; nil accepts any
    #   sentinel written after the poller started
    # @param poll_interval [Numeric] seconds to wait between captures
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] stream for reporting an unexpected poller death
    def initialize(tmux:, session_name:, pane:, token: nil, poll_interval: 2,
      logger: Workspace::Logger.new, error_output: $stderr)
      @tmux = tmux
      @session_name = session_name
      @pane = pane
      @pattern = /^\s*#{Regexp.escape(self.class.marker(token))}(?:\s+(.*))?$/
      @token = token
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
        @baseline = @token ? 0 : capture.to_s.lines.size
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

    # @return [String, nil] the summary from the newest matching sentinel
    def scan
      output = capture
      return nil unless output

      lines = output.lines
      return nil if lines.size <= @baseline

      lines.drop(@baseline).reverse_each do |line|
        match = @pattern.match(line)
        next unless match
        summary = match[1].to_s.strip
        return summary unless summary == SUMMARY_PLACEHOLDER
      end
      nil
    end
  end
end
