require "time"

module Workspace
  # Gives a coding agent in one pane a fresh conversation: waits for the pane
  # to go quiet, types `/clear`, waits for the pane's context usage to drop,
  # then types the prompt. The daemon runs it on a worker thread for a
  # `restart_agent` message.
  #
  # Every wait is bounded. The prompt is typed only after the drop is seen:
  # a prompt typed into a conversation that was never cleared would land on
  # top of the old context, which is what the restart exists to avoid.
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
    # Default longest wait for context usage to drop after /clear.
    CONFIRM_TIMEOUT = 30
    # Seconds between reads while waiting.
    POLL_INTERVAL = 0.5

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
      @clock = clock
      @wall_clock = wall_clock
      @sleeper = sleeper
      @quiet_timeout = quiet_timeout
      @quiet_for = quiet_for
      @poll_interval = poll_interval
      @logger = logger
    end

    # @param pane_id [String] tmux pane id (e.g. "%18")
    # @param prompt [String] text typed once the conversation is cleared
    # @param force [Boolean] type the prompt even when a pipeline stage has
    #   started on the pane
    # @param confirm_timeout [Numeric] longest wait for usage to drop
    # @return [Hash] the reply: "ok", then "status" or "error" and "message"
    def call(pane_id:, prompt:, force: false, confirm_timeout: CONFIRM_TIMEOUT)
      reply = {"pane_id" => pane_id}

      quiet = wait_until_quiet(pane_id)
      return reply.merge(quiet) unless quiet["ok"]

      before = @context_reader.read(pane_id: pane_id)
      if before[:pct].nil?
        return reply.merge(failure("context_unknown",
          "can't read context usage for pane #{pane_id} (#{before[:error]}), so a /clear couldn't be confirmed; " \
          "nothing was typed. #{ContextReasons::FIX_HINT}"))
      end
      reply["context_before"] = before[:pct]

      cleared_at = @wall_clock.call
      clear = deliver(pane_id, CLEAR_COMMAND)
      return reply.merge(clear) if clear.key?("error")

      after = wait_for_drop(pane_id, before[:pct], cleared_at, confirm_timeout)
      unless after
        last = @context_reader.read(pane_id: pane_id)
        return reply.merge(failure("clear_not_confirmed",
          "typed /clear into pane #{pane_id}, but its context usage did not drop below #{before[:pct]}% " \
          "within #{confirm_timeout}s (last reading: #{describe(last)}); the prompt was not sent"))
      end
      reply["context_after"] = after[:pct]

      sent = deliver(pane_id, prompt, check_pipeline: !force)
      return reply.merge(sent) if sent.key?("error")

      reply.merge("ok" => true, "status" => "restarted").merge(sent)
    end

    private

    def failure(error, message)
      {"ok" => false, "error" => error, "message" => message}
    end

    # Waits until the pane's screen has stopped changing for QUIET_FOR, and
    # the agent isn't waiting on a person: /clear typed into a permission
    # prompt would answer it instead.
    def wait_until_quiet(pane_id)
      deadline = @clock.call + @quiet_timeout
      screen = nil
      quiet_since = nil
      loop do
        current = @tmux.capture_screen(pane_id)
        return failure("pane_gone", "pane #{pane_id} is gone; nothing was typed") if current.nil?

        now = @clock.call
        if current != screen
          screen = current
          quiet_since = now
        elsif now - quiet_since >= @quiet_for && @pane_state.call(pane_id) != "waiting"
          return {"ok" => true}
        end

        if now >= deadline
          waiting = @pane_state.call(pane_id) == "waiting"
          why = waiting ? "is waiting on a person" : "never stopped changing"
          return failure("pane_busy", "pane #{pane_id} #{why} within #{@quiet_timeout}s; /clear was not typed")
        end
        @sleeper.call(@poll_interval)
      end
    end

    # Polls until a reading taken after /clear shows lower usage. A reading
    # recorded before the /clear can't confirm it, however low it is.
    #
    # @return [Hash, nil] the confirming reading, or nil at the deadline
    def wait_for_drop(pane_id, before_pct, cleared_at, timeout)
      deadline = @clock.call + timeout
      loop do
        reading = @context_reader.read(pane_id: pane_id)
        return reading if dropped?(reading, before_pct, cleared_at)
        return nil if @clock.call >= deadline
        @sleeper.call(@poll_interval)
      end
    end

    def dropped?(reading, before_pct, cleared_at)
      return false if reading[:pct].nil? || reading[:updated_at].nil?
      # Readings are stamped to the second, so one taken in the same second
      # as the /clear counts as after it.
      return false if Time.iso8601(reading[:updated_at]) < Time.at(cleared_at.to_i)
      reading[:pct] < before_pct || reading[:pct].zero?
    rescue ArgumentError
      false
    end

    def describe(reading)
      return "none (#{reading[:error]})" if reading[:pct].nil?
      "#{reading[:pct]}% at #{reading[:updated_at]}"
    end

    # Types +text+ into the pane under the delivery lock. With
    # +check_pipeline+, refuses when a pipeline stage started on the pane
    # while the restart was waiting, since the prompt would land in the
    # middle of it.
    #
    # @return [Hash] "delivery" (and "warning") on success, or a failure
    def deliver(pane_id, text, check_pipeline: false)
      @delivery_lock.synchronize do
        detail = @tmux.pane_details(@session_name, window: nil).find { |d| d[:id] == pane_id }
        next failure("pane_gone", "pane #{pane_id} closed during the restart; #{describe_text(text)} was not typed") unless detail

        if check_pipeline && detail[:window] == 0 && (ref = @pipeline_ref.call(detail[:index]))
          next failure("pane_in_pipeline",
            "#{ref} started a pipeline stage on pane #{pane_id} during the restart; the prompt was not typed (pass --force to type it anyway)")
        end

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
