module Workspace
  # Steps 2 to 5 of a recovery attempt, run on the attempt's own thread inside
  # the claim the {AgentRecoveryDesk} took: {#restart} waits for the stopped
  # agent to leave, types the resume command, waits for the agent and types the
  # message; {#typed} types the message at the live prompt and waits for the
  # `user_prompt` hook that answers it. Step 1, which opens the attempt, and
  # step 6, which ends it, stay the desk's; {AgentRecoverySteps} picks whether
  # these runners or fixed ones run between them.
  #
  # Nothing is typed unless the claim still holds and the pane still has the
  # attempt's agent holding the terminal, read again under the delivery lock
  # before each paste and before Enter. An agent the attempt didn't start ends
  # it `person_resumed` when it holds the attempt's session, else
  # `fresh_agent`.
  class RecoveryAttemptRunner
    # Seconds a stopped agent has to leave the pane, read once a second.
    STOP_WAIT = 15

    # Reads in a row that must find the pane clear: on one, the wrapper may
    # have only just exited, or the `||` branch may be about to start.
    CLEAR_READS = 2

    # Seconds to wait for the SessionStart that names an agent's session.
    SESSION_WAIT = 10

    # Seconds a resumed agent has to show its prompt.
    READY_WAIT = 60

    # How many times the message is tried while the pane's state is unknown.
    TYPE_TRIES = 20

    # Seconds between polls and between typing tries.
    POLL_INTERVAL = 1

    # Seconds a message, typed or resumed, has to bring a `user_prompt` hook.
    PROMPT_WAIT = 30

    # Outcomes that say what is in the pane, so {#typed} looks no further.
    SETTLED_OUTCOMES = %w[resumed typed person_resumed fresh_agent].freeze
    private_constant :SETTLED_OUTCOMES

    # One attempt under way.
    #
    # * +mode+ — the event line's mode, "typed" or "restart"
    # * +number+ — the entry's `attempts` once this one is counted
    # * +pid+, +started+ — the agent the attempt began with, nil when it is gone;
    #   step 4 sets them to the agent it resumed
    # * +command+ — the resume line {AgentRecoveryDesk#check} answered in step 1, flags included
    # * +message+ — the text typed to the agent
    # * +resume_only+ — no agent to stop, so no signal and no wait for an exit
    # * +opened_at+ — when step 1 wrote `attempting`; its checks cover any prompt before this
    Attempt = Struct.new(:pane_id, :session_id, :number, :mode, :pid, :started, :command, :message, :resume_only, :opened_at,
      keyword_init: true) do
      # @param agent [Hash] an agent found (+:pid+, +:started+)
      # @return [Boolean] whether it is the agent this attempt began with, or resumed
      def ours?(agent)
        agent[:pid] == pid && agent[:started] == started
      end

      # @param entry [Hash] the pane's entry as it stands now
      # @return [Boolean] whether the entry is still this attempt's
      def current?(entry)
        entry["phase"] == "attempting" && entry["session_id"] == session_id && entry["attempts"] == number
      end
    end

    # @param panes [Workspace::PaneFactory] builds the pane the resume command and Enter go to
    # @param session_name [String] the workspace's tmux session
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param facts [Workspace::RecoveryFacts] reads the pane, the agent, the process table and the monitor's prompts
    # @param session_monitor [Workspace::SessionMonitor] rescans a pane and names the agent pid the queue compares
    # @param readiness [Workspace::AgentReadiness] waits for a resumed agent
    # @param detector [Workspace::AgentDetector] the workspace's way to name the agent, for the readiness wait
    # @param marker [Workspace::RecoveryStopMarker] cleared once the resumed agent is up
    # @param prompt_typer [Workspace::PromptTyper] types the message and checks the input line
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param restarting [#call] given a pane id, whether the attempt's claim still holds it
    # @param rebind_queue [#call] given a pane id and the monitor's agent pid, moves the pane's queued prompts to that agent
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    def initialize(panes:, session_name:, store:, facts:, session_monitor:, readiness:, detector:, marker:, prompt_typer:,
      delivery_lock:, restarting:, rebind_queue: ->(_pane_id, _agent_pid) {}, clock: Time, sleeper: ->(seconds) { sleep(seconds) })
      @panes = panes
      @session_name = session_name
      @store = store
      @facts = facts
      @session_monitor = session_monitor
      @readiness = readiness
      @detector = detector
      @marker = marker
      @prompt_typer = prompt_typer
      @delivery_lock = delivery_lock
      @restarting = restarting
      @rebind_queue = rebind_queue
      @clock = clock
      @sleeper = sleeper
    end

    # Steps 2 to 5 of a restart. Each step answers nil to go on. A message no
    # hook answers is `no_response`: Enter can fall on an agent still starting,
    # whose screen changes all the same, and nothing else would ever end the
    # wait.
    #
    # @param attempt [Attempt]
    # @return [Array] the outcome, and with `person_resumed` the agent found
    def restart(attempt)
      ended = attempt.resume_only ? nil : await_exit(attempt)
      ended ||= resume_in_pane(attempt) || await_agent(attempt)
      return ended if ended

      expect_message(attempt)
      outcome, agent = typed(attempt)
      [(outcome == "typed") ? "resumed" : outcome, agent]
    end

    # Typing and the prompt wait, for a typed attempt and a restart's step 5. An
    # agent that came in after the last identity check is named here, because
    # step 6 would store any agent its last read finds as ours to stop.
    #
    # @param attempt [Attempt]
    # @return [Array] the outcome, and with `person_resumed` the agent found
    def typed(attempt)
      typed = type_message(attempt)
      typed = await_prompt(attempt) if typed == "submitted"
      ended = Array(typed)
      return ended if SETTLED_OUTCOMES.include?(ended.first)

      look, agent = pane_look(attempt)
      (look == :other) ? identify(attempt, agent) : ended
    end

    # The queue compares the monitor's pid, which in an unwrapped pane is the
    # pane's shell and not the agent's own process.
    #
    # @param pane_id [String]
    # @return [void]
    def rebind(pane_id)
      @session_monitor.rescan_pane(pane_id)
      agent_pid = @session_monitor.agent_pid(pane_id)
      @rebind_queue.call(pane_id, agent_pid) if agent_pid
    end

    private

    # The new agent's input line is empty, so its text is ours from here on, and
    # a kill during the typing or the prompt wait leaves text
    # {AgentRecoveryDesk#check} recognises. It isn't written at step 1: a
    # `not_stopped` agent still holds the text of the attempt before. Only a
    # hook from here on can answer the message, and a prompt the worker took
    # late can't: {#type_once} refuses any prompt the monitor saw after step 1.
    def expect_message(attempt)
      @store.update(attempt.pane_id) do |entry|
        entry.merge!("draft_text" => attempt.message, "prompt_seen" => false) if attempt.current?(entry)
      end
    end

    # The wait after Enter. A `stop` or `turn_failed` in it is taken by step 6.
    #
    # @return [String] "typed", or "no_response" with no `user_prompt` hook in {PROMPT_WAIT}
    def await_prompt(attempt)
      deadline = @clock.now + PROMPT_WAIT
      loop do
        return "typed" if @store.get(attempt.pane_id)&.fetch("prompt_seen", false) == true
        return "no_response" if @clock.now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # Step 2.
    def await_exit(attempt)
      deadline = @clock.now + STOP_WAIT
      clear_reads = 0
      loop do
        look, agent = pane_look(attempt)
        return identify(attempt, agent) if look == :other
        clear_reads = (look == :clear) ? clear_reads + 1 : 0
        return nil if clear_reads >= CLEAR_READS
        return ["not_stopped"] if @clock.now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # @return [Array] +:same+ with the agent and the pane's details (the agent
    #   we stopped), +:other+ with the agent, +:clear+ (a shell holding the
    #   terminal), or +:none+ when the pane is neither or can't be read
    def pane_look(attempt)
      detail = @facts.pane_detail(attempt.pane_id)
      reading = detail.is_a?(Hash) ? @facts.agent(detail) : nil
      return [:none] unless reading

      agent = reading.found
      return attempt.ours?(agent) ? [:same, agent, detail] : [:other, agent] if agent
      @facts.pane_clear?(detail, reading.tree) ? [:clear] : [:none]
    end

    # An agent we didn't start. The monitor keeps the old session id until a
    # new SessionStart, so only `attempt_session_id` can say a person resumed
    # this conversation.
    def identify(attempt, agent)
      (await_session(attempt) == attempt.session_id) ? ["person_resumed", agent] : ["fresh_agent"]
    end

    # @return [String, nil] the session a SessionStart reported since step 1
    def await_session(attempt)
      deadline = @clock.now + SESSION_WAIT
      loop do
        session = @store.get(attempt.pane_id)&.fetch("attempt_session_id", nil)
        return session if session || @clock.now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # Step 3. The wait in {#identify} runs outside the lock.
    def resume_in_pane(attempt)
      typed, agent = @delivery_lock.synchronize { type_resume(attempt) }
      (typed == :other) ? identify(attempt, agent) : typed && [typed]
    end

    # The shell's line is emptied first, in its own call: Enter would otherwise
    # run whatever already sits there, our own leftover or a person's half-typed
    # text. That text is lost, the accepted cost in a pane we stopped.
    #
    # @return [Array, nil] a refusal, or nil once the command landed. Through
    #   {Tmux#deliver}, because {PromptTyper} refuses a shell.
    def type_resume(attempt)
      pane_id = attempt.pane_id
      return ["resumed_elsewhere"] if @store.get(pane_id)&.fetch("resumed_elsewhere", false) == true
      return ["claim_lost"] unless @restarting.call(pane_id)

      # Read first, so the clear look is the last read before `C-u`, and acted
      # on after it, so a person's resume in this pane still reads as `:other`.
      held = @facts.session_held?(attempt.session_id)
      look, agent = pane_look(attempt)
      return [:other, agent] if look == :other
      return ["pane_not_clear"] unless look == :clear && !held && @store.get(pane_id)&.fetch("stopped", false) == true
      pane = @panes.for(pane_id)
      return ["not_delivered"] if pane.is_a?(Symbol) || !pane.send_key("C-u")

      pane.deliver(attempt.command).landed? ? nil : ["not_delivered"]
    end

    # Step 4. The agent's pid is stored as soon as it is seen, whatever happens
    # next, so {AgentRecoveryDesk#check} doesn't read our own agent as someone
    # else's. The agent we signalled has left by now, so the signal goes too:
    # this agent got none, and its SessionEnd must not read as that signal's.
    def await_agent(attempt)
      pane_id = attempt.pane_id
      @readiness.wait(@session_name, deadline: @readiness.deadline_in(READY_WAIT), only_pane: pane_id, detector: @detector)
      @session_monitor.rescan_pane(pane_id)
      @marker.clear(attempt.session_id)
      agent = @facts.live_agent(pane_id)
      return ["not_ready"] unless agent

      attempt.pid, attempt.started = agent.values_at(:pid, :started)
      @store.update(pane_id) do |entry|
        next unless attempt.current?(entry)
        RecoveryEntry.store_agent(entry, agent)
        RecoveryEntry.forget_signal(entry)
      end
      session = await_session(attempt)
      return ["fresh_agent"] if session && session != attempt.session_id
      rebind(pane_id)
      session ? nil : ["not_ready"]
    end

    # Step 5. The lock is held for one try, so the workspace's other deliveries
    # aren't held up. Text that may have landed is never typed again.
    #
    # @return [String, Array] "submitted", "not_submitted" or "not_typed"; or,
    #   when the pane isn't the attempt's any more, the outcome and any agent
    def type_message(attempt)
      TYPE_TRIES.times do |try|
        @sleeper.call(POLL_INTERVAL) unless try.zero?
        typed = @delivery_lock.synchronize { typing_refusal(attempt) || type_once(attempt) }
        return (typed.first == :other) ? identify(attempt, typed.last) : typed if typed.is_a?(Array)
        return typed unless typed == :retry
      end
      "not_typed"
    end

    # Each try's identity check, under the lock: nothing is typed unless the
    # claim holds and the pane still has the attempt's agent, holding the
    # terminal.
    #
    # @return [Array, nil] the refusal; +:other+ with an agent we didn't start
    def typing_refusal(attempt)
      return ["claim_lost"] unless @restarting.call(attempt.pane_id)

      look, agent, detail = pane_look(attempt)
      case look
      when :same then @facts.foreground?(agent, detail) ? nil : ["pane_not_clear"]
      when :other then [:other, agent]
      else ["pane_not_clear"]
      end
    end

    # A person's prompt in the retry window stops the paste: the +:aborted+ is
    # `not_typed`. It compares with the attempt's opening and not the failure,
    # because `resume_only` skips the prompt check on purpose: a late hook from
    # our own earlier message must not abort every resume until the 12 run out.
    def type_once(attempt)
      pane_id = attempt.pane_id
      typed = @prompt_typer.type(session_name: @session_name, target: pane_id, pane_id: pane_id, text: attempt.message,
        before_paste: -> { !@facts.prompt_after?(pane_id, attempt.opened_at) }, before_enter: -> { typing_refusal(attempt).nil? })
      case typed.outcome
      when :submitted then "submitted"
      when :not_submitted then press_enter(attempt) ? "submitted" : "not_submitted"
      when :refused then (typed.reason == "unknown") ? :retry : "not_typed"
      else "not_typed"
      end
    end

    # The paste took time, so the pane is read again before Enter.
    def press_enter(attempt)
      pane_id = attempt.pane_id
      typing_refusal(attempt).nil? && @prompt_typer.check(pane_id, pasted: attempt.message).nil? &&
        enter_pressed?(pane_id)
    end

    def enter_pressed?(pane_id)
      pane = @panes.for(pane_id)
      !pane.is_a?(Symbol) && pane.deliver("", enter: true).ok?
    end
  end
end
