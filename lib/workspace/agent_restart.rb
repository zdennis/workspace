require "time"

module Workspace
  # Gives a Claude Code agent in one pane a fresh conversation: waits for the
  # pane to go quiet, types `/clear`, waits for a status-line reading from
  # the new conversation, then types the prompt. The daemon runs it on a
  # worker thread for a `restart_agent` message.
  #
  # Every wait is bounded. The prompt is typed only after the clear is
  # confirmed: a prompt typed into a conversation that was never cleared
  # would land on top of the old context, which is what the restart exists
  # to avoid.
  #
  # Claude re-renders its status line within a second of `/clear`, with a
  # new session id and no usage yet (a null percentage). So a reading
  # stamped after the moment `/clear` was typed that carries a different
  # session id confirms it. Without a session id to compare, the reading
  # must show no usage, or less than before. The pane's usage needn't be
  # known beforehand: a pane just started or cleared, or one with no reading
  # yet, is restarted all the same, and still confirmed this way.
  #
  # The pane is addressed by its tmux pane id, which stays with a pane for
  # its life. tmux can't paste to "session:%id", so the pane's current
  # "window.index" is looked up from the id before each delivery.
  class AgentRestart
    # Text that clears a Claude Code conversation.
    CLEAR_COMMAND = "/clear"
    # Longest wait for the pane to stop changing before /clear is typed.
    QUIET_TIMEOUT = 120
    # How long the pane's screen must stay unchanged to count as quiet.
    QUIET_FOR = 2.0
    # Default longest wait for a reading that confirms the /clear.
    CONFIRM_TIMEOUT = 30
    # Seconds between reads while waiting.
    POLL_INTERVAL = 0.5
    # Session monitor states in which /clear must not be typed.
    BUSY_STATES = ["working", "waiting"].freeze

    # @param tmux [Workspace::Tmux] pane reads and deliveries
    # @param context_reader [Workspace::ContextReader] reads the pane's usage
    # @param session_name [String] the tmux session the pane belongs to
    # @param delivery_lock [Mutex] held for each delivery, so a restart's
    #   typing takes turns with pipeline deliveries
    # @param pipeline_ref [#call] returns the work item mid-pipeline on a
    #   pane index (Integer) in window 0, or nil; called with the delivery
    #   lock held, just before the prompt is typed
    # @param pane_state [#call] returns the session monitor's state for a pane
    #   id ("working", "idle", "waiting") or nil when it has none
    # @param agent_pid [#call] returns the pid of the coding agent in a pane
    #   id, or nil; a reading recorded without $TMUX_PANE is found by it
    # @param clock [#call] monotonic seconds, for the bounded waits
    # @param wall_clock [#call] the current Time, compared with when a reading
    #   was recorded
    # @param sleeper [#call] sleeps the given seconds
    # @param quiet_timeout [Numeric] see {QUIET_TIMEOUT}
    # @param quiet_for [Numeric] see {QUIET_FOR}
    # @param poll_interval [Numeric] see {POLL_INTERVAL}
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, context_reader:, session_name:, delivery_lock:, pipeline_ref:,
      pane_state: ->(_pane_id) {},
      agent_pid: ->(_pane_id) {},
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      wall_clock: -> { Time.now },
      sleeper: ->(seconds) { sleep(seconds) },
      quiet_timeout: QUIET_TIMEOUT, quiet_for: QUIET_FOR, poll_interval: POLL_INTERVAL,
      logger: Workspace::Logger.new)
      @tmux = tmux
      @context_reader = context_reader
      @session_name = session_name
      @delivery_lock = delivery_lock
      @pipeline_ref = pipeline_ref
      @pane_state = pane_state
      @agent_pid = agent_pid
      @clock = clock
      @wall_clock = wall_clock
      @sleeper = sleeper
      @quiet_timeout = quiet_timeout
      @quiet_for = quiet_for
      @poll_interval = poll_interval
      @logger = logger
      @cleared = false
    end

    # @return [Boolean] whether /clear has been typed into the pane, so a
    #   restart stopped part way can say what it left behind
    def cleared?
      @cleared
    end

    # @param pane_id [String] tmux pane id (e.g. "%18")
    # @param prompt [String] text typed once the conversation is cleared
    # @param force [Boolean] type /clear and the prompt even when a pipeline stage has
    #   started on the pane
    # @param confirm_timeout [Numeric] longest wait for the clear to be confirmed
    # @return [Hash] the reply: "ok", then "status" or "error" and "message"
    def call(pane_id:, prompt:, force: false, confirm_timeout: CONFIRM_TIMEOUT)
      reply = {"pane_id" => pane_id}

      quiet = wait_until_quiet(pane_id)
      return reply.merge(quiet) unless quiet["ok"]

      before = read_context(pane_id)
      unless self.class.confirmable?(before)
        return reply.merge(failure("context_unknown",
          "can't read context usage for pane #{pane_id} (#{before[:error]}), so a /clear couldn't be confirmed; " \
          "nothing was typed. #{ContextReasons::FIX_HINT}"))
      end
      reply["context_before"] = before[:pct]

      cleared_at = nil
      clear = deliver(pane_id, CLEAR_COMMAND, check_pipeline: !force) do
        cleared_at = @wall_clock.call
        @cleared = true
      end
      return reply.merge(clear) if clear.key?("error")

      after = wait_for_clear(pane_id, before, cleared_at, confirm_timeout)
      unless after
        last = read_context(pane_id)
        return reply.merge(failure("clear_not_confirmed",
          "typed /clear into pane #{pane_id}, but no status-line reading from a new conversation arrived " \
          "within #{confirm_timeout}s (before: #{describe(before)}; last reading: #{describe(last)}); the prompt was not sent"))
      end
      reply["context_after"] = after[:pct]

      sent = deliver(pane_id, prompt, check_pipeline: !force)
      return reply.merge(sent) if sent.key?("error")

      reply.merge("ok" => true, "status" => "restarted").merge(sent)
    end

    # Whether a /clear could be confirmed from this pane's readings, judged
    # by the reading taken before it: one with a percentage or from a stored
    # status-line reading can be compared with what follows, and a pane with
    # no reading yet can be confirmed by the new conversation's first one.
    # Scrape mode with no pattern, or one that doesn't match, never could.
    #
    # Mirrors the pane-kind gate in Commands::Agent#restart_agent
    # (lib/workspace/commands/agent.rb) — keep both in sync if this changes.
    #
    # @param reading [Hash] a {Workspace::ContextReader#read} result
    # @return [Boolean]
    def self.confirmable?(reading)
      !reading[:pct].nil? || !reading[:updated_at].nil? || reading[:error] == ContextReasons::NO_READING
    end

    private

    # Looks the reading up by pane id, then by the agent's pid, as the
    # session monitor does for `sessions` and `handoff check`.
    def read_context(pane_id)
      @context_reader.read(pane_id: pane_id, agent_pid: @agent_pid.call(pane_id))
    end

    def failure(error, message)
      {"ok" => false, "error" => error, "message" => message}
    end

    # Waits until the pane has stopped changing for QUIET_FOR and the agent
    # is neither working nor waiting on a person: /clear typed into a
    # permission prompt would answer it, and one typed mid-turn would land in
    # the middle of the work. With no monitor state, the screen alone decides.
    def wait_until_quiet(pane_id)
      deadline = @clock.call + @quiet_timeout
      screen = nil
      quiet_since = nil
      loop do
        current = @tmux.capture_screen(pane_id)
        return failure("pane_gone", "pane #{pane_id} is gone; nothing was typed") if current.nil?

        now = @clock.call
        state = @pane_state.call(pane_id)
        if current != screen
          screen = current
          quiet_since = now
        elsif now - quiet_since >= @quiet_for && !BUSY_STATES.include?(state)
          return {"ok" => true}
        end

        if now >= deadline
          why = case state
          when "waiting" then "is waiting on a person"
          when "working" then "was still working"
          else "never stopped changing"
          end
          return failure("pane_busy", "pane #{pane_id} #{why} within #{@quiet_timeout}s; /clear was not typed")
        end
        @sleeper.call(@poll_interval)
      end
    end

    # Polls until a reading confirms the /clear took effect.
    #
    # @return [Hash, nil] the confirming reading, or nil at the deadline
    def wait_for_clear(pane_id, before, cleared_at, timeout)
      deadline = @clock.call + timeout
      loop do
        reading = read_context(pane_id)
        return reading if clear_confirmed?(reading, before, cleared_at)
        return nil if @clock.call >= deadline
        @sleeper.call(@poll_interval)
      end
    end

    # Only a reading stamped after the moment /clear was typed can confirm
    # it; the old conversation's last render never can. A reading stamped to
    # the whole second (recorded before sub-second stamps) is taken as the
    # start of its second, so one from the /clear's own second never counts.
    # A new session id is what shows the conversation changed; without one
    # to compare, the reading must show no usage, or less than before.
    def clear_confirmed?(reading, before, cleared_at)
      recorded_at = reading[:recorded_at] || (reading[:updated_at] && Time.iso8601(reading[:updated_at]))
      return false unless recorded_at && recorded_at > cleared_at

      if before[:session_id]
        !reading[:session_id].nil? && reading[:session_id] != before[:session_id]
      else
        reading[:pct].nil? || (!before[:pct].nil? && reading[:pct] < before[:pct])
      end
    rescue ArgumentError
      false
    end

    def describe(reading)
      return "none (#{reading[:error]})" if reading[:updated_at].nil?
      pct = reading[:pct].nil? ? "no usage yet" : "#{reading[:pct]}%"
      session = reading[:session_id] ? ", session #{reading[:session_id]}" : ""
      "#{pct} at #{reading[:updated_at]}#{session}"
    end

    # Types +text+ into the pane under the delivery lock. With
    # +check_pipeline+, refuses when a pipeline stage started on the pane
    # while the restart was waiting, since the text would land in the
    # middle of it. Yields, under the lock, just before typing.
    #
    # @return [Hash] "delivery" (and "warning") on success, or a failure
    def deliver(pane_id, text, check_pipeline: false)
      @delivery_lock.synchronize do
        detail = @tmux.pane_details(@session_name, window: nil).find { |d| d[:id] == pane_id }
        next failure("pane_gone", "pane #{pane_id} closed during the restart; #{describe_text(text)} was not typed") unless detail

        if check_pipeline && detail[:window] == 0 && (ref = @pipeline_ref.call(detail[:index]))
          next failure("pane_in_pipeline",
            "#{ref} started a pipeline stage on pane #{pane_id} during the restart; #{describe_text(text)} was not typed (pass --force to type it anyway)")
        end

        yield if block_given?

        target = "#{detail[:window]}.#{detail[:index]}"
        delivery = @tmux.deliver(@session_name, target, text)
        @logger.debug { "restart_agent: #{describe_text(text)} to #{@session_name}:#{target}: #{delivery.status}" }
        unless delivery.landed?
          next failure("not_delivered", "#{describe_text(text)} was not typed into pane #{pane_id}: #{delivery.message}")
        end

        result = {"delivery" => delivery.status.to_s}
        result["warning"] = delivery.message unless delivery.ok?
        result
      end
    end

    def describe_text(text)
      (text == CLEAR_COMMAND) ? "/clear" : "the prompt"
    end
  end
end
