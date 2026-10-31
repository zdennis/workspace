require "time"

module Workspace
  # Gives a Claude Code or Codex agent in one pane a fresh conversation: waits for
  # the pane to go quiet, types the agent's clear command (`/clear` for both), waits for a status-line reading from
  # the new conversation (or a SessionStart hook event with source `clear`), then types the prompt. The daemon runs it on a
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
  #
  # A background sub-agent or shell can keep the screen moving long after the
  # main turn ended. A moving screen is accepted only on proof the turn is over
  # (`turn_over:` and `screen_ready:`, both held for {TURN_OVER_FOR}), and the
  # reply warns that background work may be lost. Nothing then proves Enter
  # took, so the prompt must be confirmed by a `user_prompt` hook.
  #
  # A still screen with a running sub-agent in a Claude Code pane gets the same
  # warning (`subagents_running:`), since /clear can end it. The monitor can't
  # see a background shell, so nothing is said of one. It is only a warning.
  #
  # Whichever way the wait ended, a Claude Code pane is checked again under the
  # delivery lock right before /clear: a still screen can hold a draft or a turn
  # just started. Other agents skip it. A refused check goes back through the
  # wait, up to its own deadline, so every attempt earns its hold.
  class AgentRestart
    # Text that clears a conversation when the pane's agent is not known.
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
    # How long the proof must hold before a moving screen is accepted, longer
    # than {QUIET_FOR} to let hook events arrive.
    TURN_OVER_FOR = 5.0
    # Longest wait for the hook that confirms a prompt typed on a moving screen.
    PROMPT_CONFIRM_TIMEOUT = 15
    # Seconds kept in hand, so the reply reaches a caller waiting for it.
    REPLY_MARGIN = 2
    # Least time given to that hook, however late the reply would be: a shorter
    # wait would report a prompt that went in as not delivered.
    MIN_PROMPT_CONFIRM = 3

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
    # @param pane_kind [#call] returns the session monitor's agent kind for a pane id ("claude",
    #   "codex", ...) or nil; it picks the clear command and how the context is read
    # @param agent_pid [#call] returns the pid of the coding agent in a pane
    #   id, or nil; a reading recorded without $TMUX_PANE is found by it
    # @param delivery_facts [#call] returns the session monitor's delivery facts for a
    #   pane id (see {Workspace::SessionMonitor#delivery_facts}) or nil. A SessionStart
    #   with source "clear" in them also confirms the /clear, which a fresh session
    #   needs because its status-line reading does not change; a pane whose hooks
    #   reach the daemon is restarted even when its reading could not confirm one
    # @param turn_over [#call] given a pane id, answers nil when the main turn is
    #   proven over, else what is missing, by name (`details.proof_missing`)
    # @param screen_ready [#call] given a pane id, answers
    #   {Workspace::IdlePromptCheck#refusal} for its screen as it is now
    # @param subagents_running [#call] given a pane id, how many sub-agents of its
    #   agent the session monitor sees running (nil or 0 for none); asked as
    #   /clear is typed on a Claude Code pane, to warn that they may be lost
    # @param run_bound [#call] given a pane id and a run id, says whether the pane
    #   is still bound to that run
    # @param clock [#call] monotonic seconds, for the bounded waits
    # @param wall_clock [#call] the current Time, compared with when a reading
    #   was recorded and with the monitor's hook times; the session monitor's clock
    #   is Time, so the two agree
    # @param sleeper [#call] sleeps the given seconds
    # @param quiet_timeout [Numeric] see {QUIET_TIMEOUT}
    # @param quiet_for [Numeric] see {QUIET_FOR}
    # @param poll_interval [Numeric] see {POLL_INTERVAL}
    # @param turn_over_for [Numeric] see {TURN_OVER_FOR}
    # @param prompt_confirm_timeout [Numeric] see {PROMPT_CONFIRM_TIMEOUT}
    # @param reply_timeout [Numeric] how long a waiting caller listens for the reply;
    #   it bounds the prompt's confirmation only when {#call} is told one is waiting
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, context_reader:, session_name:, delivery_lock:, pipeline_ref:,
      pane_state: ->(_pane_id) {},
      agent_pid: ->(_pane_id) {},
      pane_kind: ->(_pane_id) {},
      delivery_facts: ->(_pane_id) {},
      turn_over: ->(_pane_id) { "no_proof" },
      screen_ready: ->(_pane_id) {},
      subagents_running: ->(_pane_id) {},
      run_bound: ->(_pane_id, _run_id) { false },
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      wall_clock: -> { Time.now },
      sleeper: ->(seconds) { sleep(seconds) },
      quiet_timeout: QUIET_TIMEOUT, quiet_for: QUIET_FOR, poll_interval: POLL_INTERVAL,
      turn_over_for: TURN_OVER_FOR, prompt_confirm_timeout: PROMPT_CONFIRM_TIMEOUT, reply_timeout: WorkflowPanes::REPLY_TIMEOUT,
      logger: Workspace::Logger.new)
      @tmux = tmux
      @context_reader = context_reader
      @session_name = session_name
      @delivery_lock = delivery_lock
      @pipeline_ref = pipeline_ref
      @pane_state = pane_state
      @agent_pid = agent_pid
      @pane_kind = pane_kind
      @delivery_facts = delivery_facts
      @turn_over = turn_over
      @screen_ready = screen_ready
      @subagents_running = subagents_running
      @run_bound = run_bound
      @clock = clock
      @wall_clock = wall_clock
      @sleeper = sleeper
      @quiet_timeout = quiet_timeout
      @quiet_for = quiet_for
      @poll_interval = poll_interval
      @turn_over_for = turn_over_for
      @prompt_confirm_timeout = prompt_confirm_timeout
      @reply_timeout = reply_timeout
      @logger = logger
      @cleared = false
      @clear_command = CLEAR_COMMAND
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
    # @param run_id [String, nil] the workflow run this restart is for; once the
    #   pane is no longer bound to it, nothing more is typed (`run_unbound`)
    # @param waiting [Boolean] whether a caller is listening for this reply
    # @return [Hash] the reply: "ok", then "status" or "error" and "message".
    #   "warning" when background work may have been lost (a moving screen, or a
    #   running sub-agent at the moment of /clear), joined with any
    #   warning from the prompt's delivery; a failed wait has
    #   "details" => {"proof_missing" => name}
    def call(pane_id:, prompt:, force: false, confirm_timeout: CONFIRM_TIMEOUT, run_id: nil, waiting: false)
      reply = {"pane_id" => pane_id}
      started_at = @clock.call
      deadline = started_at + @quiet_timeout

      quiet = wait_until_quiet(pane_id, deadline)
      return reply.merge(quiet) unless quiet["ok"]

      moving = quiet["moving"] == true

      kind = @pane_kind.call(pane_id)
      @clear_command = AgentProvider.find(kind.to_s)&.clear_command || CLEAR_COMMAND
      before = read_context(pane_id)
      unless self.class.confirmable?(before) || self.class.hooks?(@delivery_facts.call(pane_id))
        return reply.merge(failure("context_unknown",
          "can't read context usage for pane #{pane_id} (#{before[:error]}), so a /clear couldn't be confirmed; " \
          "nothing was typed. #{ContextReasons.fix_hint(kind)}"))
      end
      reply["context_before"] = before[:pct]

      cleared_at = nil
      subagents = false
      clear = deliver_clear(pane_id, force: force, moving: moving, run_id: run_id, deadline: deadline) do |moving_at_clear|
        moving = moving_at_clear
        cleared_at = @wall_clock.call
        subagents = kind == "claude" && @subagents_running.call(pane_id).to_i > 0
        @cleared = true
      end
      return reply.merge(clear) if clear.key?("error")

      if subagents
        reply["warning"] = "a sub-agent was still running in pane #{pane_id} when #{@clear_command} was typed and may be lost"
      elsif moving
        reply["warning"] = "background work in pane #{pane_id} was still running when #{@clear_command} was typed and may be lost"
      end

      after = wait_for_clear(pane_id, before, cleared_at, confirm_timeout)
      unless after
        last = read_context(pane_id)
        return reply.merge(failure("clear_not_confirmed",
          "typed /clear into pane #{pane_id}, but no status-line reading from a new conversation and no SessionStart with source clear arrived " \
          "within #{confirm_timeout}s (before: #{describe(before)}; last reading: #{describe(last)}); the prompt was not sent"))
      end
      reply["context_after"] = after[:pct]

      typed_at = nil
      sent = deliver(pane_id, prompt, check_pipeline: !force, before_typing: -> { unbound_failure(pane_id, run_id, "the prompt") }) do
        typed_at = @wall_clock.call
      end
      return reply.merge(sent) if sent.key?("error")

      if moving && !prompt_confirmed?(pane_id, typed_at, started_at, waiting)
        return reply.merge(failure("not_delivered", "typed the prompt into pane #{pane_id}, but the agent never reported it, " \
          "so it may still be in the input box").merge("reason" => "prompt_unconfirmed"))
      end

      warning = [reply["warning"], sent["warning"]].compact.join("; ")
      reply.merge("ok" => true, "status" => "restarted").merge(sent).merge(warning.empty? ? {} : {"warning" => warning})
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

    # Whether a pane's delivery facts say its agent's hooks reach the daemon, so
    # a SessionStart with source `clear` can confirm a /clear. Shared by the
    # pre-check in Commands::Agent#restart_agent and {#call}.
    #
    # @param facts [Hash, nil] {Workspace::SessionMonitor#delivery_facts}
    # @return [Boolean]
    def self.hooks?(facts)
      facts&.dig(:hooks) == true
    end

    private

    # Looks the reading up by pane id, then by the agent's pid, as the
    # session monitor does for `sessions` and `handoff check`.
    def read_context(pane_id)
      @context_reader.read(pane_id: pane_id, agent_pid: @agent_pid.call(pane_id), kind: @pane_kind.call(pane_id))
    end

    def failure(error, message)
      {"ok" => false, "error" => error, "message" => message}
    end

    def busy_failure(reason, message)
      failure("pane_busy", message).merge("reason" => reason)
    end

    # Waits until the pane has stopped changing for QUIET_FOR and the agent
    # is neither working nor waiting on a person: /clear typed into a
    # permission prompt would answer it, and one typed mid-turn would land in
    # the middle of the work. With no monitor state, the screen alone decides.
    # A screen that won't stop moving is accepted once the proof has held for
    # {TURN_OVER_FOR}, with "moving" in the answer.
    def wait_until_quiet(pane_id, deadline)
      screen = nil
      quiet_since = nil
      proven_since = nil
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

        missing = proof_missing(pane_id, state)
        proven_since = missing ? nil : (proven_since || now)
        return {"ok" => true, "moving" => true} if proven_since && now - proven_since >= @turn_over_for

        return never_quiet(pane_id, state, missing || "proof_too_recent") if now >= deadline
        @sleeper.call(@poll_interval)
      end
    end

    # The first thing that keeps a moving screen from being accepted, by name;
    # nil once the proof stands.
    def proof_missing(pane_id, state)
      return "not_claude" unless @pane_kind.call(pane_id) == "claude"
      return state if BUSY_STATES.include?(state)

      @turn_over.call(pane_id) || @screen_ready.call(pane_id)&.fetch(:reason)
    end

    def never_quiet(pane_id, state, missing)
      failed = case state
      when "waiting"
        busy_failure("waiting", "pane #{pane_id} is waiting on a person within #{@quiet_timeout}s; /clear was not typed")
      when "working"
        busy_failure("working", "pane #{pane_id} was still working within #{@quiet_timeout}s; /clear was not typed")
      when "idle"
        busy_failure("background_activity", "the agent in pane #{pane_id} reads as idle, but the screen kept changing for #{@quiet_timeout}s, " \
          "possibly a background sub-agent or shell, or a turn still running; /clear was not typed")
      else
        busy_failure("unknown_state", "pane #{pane_id} kept changing for #{@quiet_timeout}s and the agent's state isn't known; /clear was not typed")
      end
      with_proof(failed, missing)
    end

    def with_proof(failed, missing)
      failed.merge("message" => "#{failed["message"]} (the turn isn't proven over: #{missing})", "details" => {"proof_missing" => missing})
    end

    # Types the clear command once the last check passes, yielding whether the
    # screen was accepted moving. A refused check gives up the delivery lock and
    # goes back through {#wait_until_quiet} until +deadline+, since a spinner can
    # be a redraw behind the last Stop, and a pass right after a refusal proves
    # nothing about a person at the keyboard. At the deadline the last check's
    # refusal is the answer: it names what was on screen.
    def deliver_clear(pane_id, force:, moving:, run_id:, deadline:)
      loop do
        clear = deliver(pane_id, @clear_command, check_pipeline: !force,
          before_typing: -> { clear_refusal(pane_id, moving, run_id) }) { yield moving }
        return clear unless clear["error"] == "pane_busy" && @clock.call < deadline

        quiet = wait_until_quiet(pane_id, deadline)
        return (quiet["error"] == "pane_busy") ? clear : quiet unless quiet["ok"]

        moving = quiet["moving"] == true
      end
    end

    # The check made under the delivery lock right before the clear command.
    #
    # @return [Hash, nil] a failure, or nil to go ahead
    def clear_refusal(pane_id, moving, run_id)
      unbound = unbound_failure(pane_id, run_id, @clear_command)
      return unbound if unbound
      return nil unless @pane_kind.call(pane_id) == "claude"

      reason, detail = screen_or_turn_refusal(pane_id, moving)
      return nil unless reason

      failed = busy_failure(reason, "#{detail} in pane #{pane_id}; #{@clear_command} was not typed")
      moving ? with_proof(failed, reason) : failed
    end

    def screen_or_turn_refusal(pane_id, moving)
      state = @pane_state.call(pane_id)
      return ["turn_started", "a turn has started"] if state == "working"
      return ["waiting", "the agent is waiting on a person"] if state == "waiting"

      refused = @screen_ready.call(pane_id)
      return [refused[:reason], refused[:message]] if refused

      ["turn_started", "a turn has started"] if moving && @turn_over.call(pane_id)
    end

    def unbound_failure(pane_id, run_id, what)
      return nil if run_id.nil? || @run_bound.call(pane_id, run_id)
      failure("run_unbound", "pane #{pane_id} is no longer bound to run #{run_id}; #{what} was not typed")
    end

    # Whether a `user_prompt` hook stamped after the typing has come, within the
    # time left to answer a caller that is waiting.
    def prompt_confirmed?(pane_id, typed_at, started_at, waiting)
      limit = @prompt_confirm_timeout
      if waiting
        left = started_at + @reply_timeout - REPLY_MARGIN - @clock.call
        limit = [limit, left.clamp(MIN_PROMPT_CONFIRM..)].min
      end
      deadline = @clock.call + limit
      loop do
        at = @delivery_facts.call(pane_id)&.dig(:last_user_prompt_at)
        return true if at && at > typed_at
        return false if @clock.call >= deadline
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
        # The old conversation's reading says nothing of the new one's usage.
        return {pct: nil} if session_cleared?(pane_id, cleared_at)
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

    # Whether the pane's agent reported a SessionStart with source `clear` after
    # /clear was typed (see {ClearConfirmation}).
    def session_cleared?(pane_id, cleared_at)
      ClearConfirmation.check(@delivery_facts.call(pane_id), cleared_at).first == :confirmed
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
    # middle of it. +before_typing+, under the lock, can answer a failure that
    # stops the typing. Yields, under the lock, just before typing.
    #
    # @return [Hash] "delivery" (and "warning") on success, or a failure
    def deliver(pane_id, text, check_pipeline: false, before_typing: nil)
      @delivery_lock.synchronize do
        detail = @tmux.pane_details(@session_name, window: nil).find { |d| d[:id] == pane_id }
        next failure("pane_gone", "pane #{pane_id} closed during the restart; #{describe_text(text)} was not typed") unless detail

        if check_pipeline && detail[:window] == 0 && (ref = @pipeline_ref.call(detail[:index]))
          next failure("pane_in_pipeline",
            "#{ref} started a pipeline stage on pane #{pane_id} during the restart; #{describe_text(text)} was not typed (pass --force to type it anyway)")
        end

        refused = before_typing&.call
        next refused if refused

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
      (text == @clear_command) ? text : "the prompt"
    end
  end
end
