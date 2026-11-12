module Workspace
  # The agent daemon's side of recovering a Claude Code agent whose turn ended
  # on an API error. It keeps one {AgentRecoveryStore} entry per pane, schedules
  # attempts, and gives up with one inbox item.
  #
  # {#session_event} hands the hook event to {RecoveryIntake}, which queues it
  # for its one worker and applies it to the pane's entry there.
  #
  # {#scan}, on the monitor's scan thread, has {RecoveryConfirmer} confirm a
  # failure against the transcript once {SETTLE} seconds have passed, runs
  # {#check} on the entries that are due, and has the confirmer pick up an
  # attempt the daemon lost when it restarted.
  #
  # {#check} answers one of four things, and only `:go` starts an attempt:
  #
  # * `:go` — every condition holds. `mode` says which attempt: `:typed` with
  #   `attempts` 0, `:restart` after that, `:resume_only` when the agent is
  #   already gone.
  # * `:defer` — something may clear. It costs no attempt, and {DEFER_LIMIT}
  #   seconds of unbroken deferring gives up with reason `deferred`.
  # * `:clear` — the failure can't be confirmed any more. With `attempts` 0 the
  #   entry is deleted; above 0 it gives up with reason `unconfirmed`, so a
  #   count never vanishes without a word.
  # * `:never` — this pane can't be restarted: give up with reason
  #   `cannot_restart`.
  #
  # Whatever can't be read leaves the agent alone. That includes an agent in a
  # pane outside window 0, which always defers, because the monitor scans
  # window 0 only and so has no facts for it.
  #
  # An agent whose process group doesn't hold the pane's terminal gets nothing:
  # a shell that took the terminal back runs whatever is typed, even while a
  # continued agent redraws its prompt. {#check} defers, and every typing try
  # and Enter press reads the groups again and refuses.
  #
  # An attempt runs on its own thread, inside a claim on the pane, and one
  # {AgentRecoveryStore#update} ends it. The first of an outage is typed: the
  # message goes to the live prompt, with no signal and no marker, and a turn
  # that fails again or a message no `user_prompt` hook answers leads to a
  # restart. A restart stops the agent, types the resume command, waits for the
  # agent and types a message, which a `user_prompt` hook must answer here too.
  # A failed attempt counts toward {AgentRecoveryStore::MAX_ATTEMPTS}, so nothing
  # repeats without bound, and there is no second typed attempt, because
  # `attempts` is then above 0. The only signal is one SIGINT per restart,
  # through {AgentStopper#stop}. There is no escalation: any other signal starts
  # a new, empty conversation in a `claude ... || claude` pane.
  #
  # `stopped` means our SIGINT went out and no new agent has come back, and it
  # is the only thing that lets a resume line reach a pane, read again just
  # before the keystroke. Only
  # {AgentStopper#stop} answering `:signalled` keeps it set; a SessionEnd in
  # `waiting` after a `not_stopped` sets it too, because that signal did go out
  # and the late exit can't be told from a person's. A same-id SessionStart or
  # any agent found clears it. An empty pane never sets it, so an agent that
  # came up and vanished, or left with no signal of ours, is not resumed: the
  # attempt gives up `unconfirmed` there and then, with nothing typed, whatever
  # failed turn it reported. After an attempt no entry waits with no agent and
  # `stopped` false, where a late hook could silence it, but for the
  # {AgentRecoveryStore::SIGNAL_HOLD} seconds a take-back leaves for an earlier
  # signal's SessionEnd.
  class AgentRecoveryDesk
    # The `error` kinds that go on the attempt schedule; any other gives up at once.
    RETRYABLE_ERRORS = RecoveryIntake::RETRYABLE_ERRORS

    # Seconds after the failure before the transcript is read: Claude Code may
    # still recover by itself, and the error line may follow the hook.
    SETTLE = RecoveryConfirmer::SETTLE

    # Seconds of unbroken deferring before giving up.
    DEFER_LIMIT = 1800

    # Seconds with no sub-agent event after which a sub-agent still recorded as
    # running stops holding off an attempt: an outage can kill one before it
    # sends SubagentStop.
    SUBAGENT_QUIET = RecoveryVerdicts::SUBAGENT_QUIET

    # What Claude Code shows while it is retrying by itself, or still working.
    BUSY_SCREEN = RecoveryVerdicts::BUSY_SCREEN

    # Seconds a stopped agent has to leave the pane, read once a second.
    STOP_WAIT = RecoveryAttemptRunner::STOP_WAIT

    # Reads in a row that must find the pane clear.
    CLEAR_READS = RecoveryAttemptRunner::CLEAR_READS

    # Seconds to wait for the SessionStart that names an agent's session.
    SESSION_WAIT = RecoveryAttemptRunner::SESSION_WAIT

    # Seconds a resumed agent has to show its prompt.
    READY_WAIT = RecoveryAttemptRunner::READY_WAIT

    # How many times the message is tried while the pane's state is unknown.
    TYPE_TRIES = RecoveryAttemptRunner::TYPE_TRIES

    # Seconds between polls and between typing tries.
    POLL_INTERVAL = RecoveryAttemptRunner::POLL_INTERVAL

    # Seconds a message, typed or resumed, has to bring a `user_prompt` hook.
    PROMPT_WAIT = RecoveryAttemptRunner::PROMPT_WAIT

    # What the agent is told at its live prompt.
    TYPED_MESSAGE = "An API error stopped your last turn (%<error>s). Continue where you left off."

    # What the agent is told once it has been resumed. Neither message may hold
    # anything a shell expands: one that lands at a shell must do nothing.
    RESUMED_MESSAGE = "An API error stopped your last turn (%<error>s), so workspace restarted Claude Code and resumed this " \
      "conversation. Locks your old process held were released, so take them again before you use them. A dev server " \
      "started with workspace dev up is still running and keeps its lock. Continue where you left off."

    # Event log line for a finished attempt.
    ATTEMPT_EVENT = RecoveryConfirmer::ATTEMPT_EVENT

    # Event log line for a give-up.
    GAVE_UP_EVENT = "agent_recovery_gave_up"

    # What {#check} answers.
    #
    # * +answer+ — +:go+, +:defer+, +:clear+ or +:never+
    # * +mode+ — with +:go+, +:typed+, +:restart+ or +:resume_only+
    # * +command+ — with +:go+ and a restart, the resume line to type
    Verdict = Struct.new(:answer, :mode, :command, keyword_init: true)

    # One attempt under way.
    Attempt = RecoveryAttemptRunner::Attempt
    private_constant :Attempt

    # Outcomes that may leave our text in the agent's input line.
    DRAFT_OUTCOMES = %w[not_submitted no_response].freeze
    private_constant :DRAFT_OUTCOMES

    # What hooks and step 3 leave on an entry for the end of an attempt.
    ATTEMPT_FIELDS = %w[turn_completed failed_during_attempt resumed_elsewhere attempt_session_id prompt_seen].freeze
    private_constant :ATTEMPT_FIELDS

    GIVE_UP_BODIES = {
      "attempts_exhausted" => "The API kept failing (%<error>s) through %<attempts>d recovery attempts, so workspace stopped trying.",
      "not_retryable" => "The turn failed with %<error>s, which trying again won't fix, so workspace won't try again.",
      "cannot_restart" => "The turn failed with %<error>s and workspace can't restart this pane: it has its own start command, " \
        "something other than a shell runs the agent, or the transcript is gone.",
      "fresh_conversation" => "A new conversation started in the pane in place of the one that failed (%<error>s). " \
        "Nothing was typed into it.",
      "deferred" => "The turn failed with %<error>s, and the pane stayed busy or unreadable for 30 minutes, so workspace " \
        "stopped trying. Nothing was stopped or typed in those 30 minutes.",
      "unconfirmed" => "After %<attempts>d recovery attempts workspace can no longer confirm the turn ended on the error " \
        "(%<error>s), so it stopped trying.",
      "unconfirmed_no_attempts" => "A turn failed with %<cause>s, then with %<error>s, and workspace can no longer confirm that " \
        "last failure, so it stopped watching. No recovery attempt was made."
    }.freeze
    private_constant :GIVE_UP_BODIES

    # @param panes [Workspace::PaneFactory] builds the pane to read, press a key in and type into; the pane list
    #   is read only to look a pane up ({RecoveryFacts#pane_detail})
    # @param workspace [String] the workspace the daemon serves; events and items go under it
    # @param session_name [String] the workspace's tmux session
    # @param session_monitor [Workspace::SessionMonitor] pane facts
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param transcript [Workspace::TranscriptSummary] reads the last turn record
    # @param stopper [Workspace::AgentStopper] finds the agent's process and sends the SIGINT
    # @param detector [Workspace::AgentDetector] the workspace's way to name the agent
    # @param process_tree [Workspace::ProcessTree] reads the fresh snapshots the process checks use
    # @param ledger [Workspace::SessionLedger] the session open in a pane, and its directory
    # @param resume_command [Workspace::AgentResumeCommand] builds the resume line
    # @param prompt_typer [Workspace::PromptTyper] the input line check, and the message's typing
    # @param readiness [Workspace::AgentReadiness] waits for a resumed agent
    # @param marker [Workspace::RecoveryStopMarker] says a stop is ours
    # @param inbox [#call] answers the workspace's {InboxStore}
    # @param event_log [Workspace::EventLog, nil] where attempts and give-ups are recorded
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param restarting [#call] given a pane id, whether a restart holds the pane. Claims are released
    #   by token and refused while held, so during an attempt a true answer is the attempt's own claim.
    #   That holds while every write to the claim is guarded by `key?` or replaces its own `:starting`
    # @param claim_restart [#call] given a pane id, claims it; returns a token, or nil when it is held.
    #   Called on the attempt's own thread, so it can register +Thread.current+ for shutdown
    # @param release_restart [#call] given a pane id and a token, releases that claim
    # @param rebind_queue [#call] given a pane id and the monitor's agent pid, moves the pane's
    #   queued prompts to that agent
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    # @param spawn [#call] runs the given block on its own thread
    # @param steps [Workspace::AgentRecoverySteps] picks the runner of steps 2 to 5 for each kind of attempt
    # @param max_attempts [Integer] attempts after which the desk gives up
    # @param logger [Workspace::Logger] debug logger
    # @param facts [Workspace::RecoveryFacts] makes each read {#check} and the attempts make; until T37.5 the
    #   default is built here over +panes+, +process_tree+, +stopper+, +detector+, +ledger+, +transcript+,
    #   +session_monitor+, +prompt_typer+, +clock+, +sleeper+ and +logger+
    # @param intake [Workspace::RecoveryIntake] queues the hook events and applies them to the entries; until
    #   T37.5 the default is built here over +store+, +session_monitor+, +facts+, +rebind_queue+,
    #   +max_attempts+, +clock+, +spawn+, +logger+ and the desk's own give-up report and inbox resolve
    # @param confirmer [Workspace::RecoveryConfirmer] marks the failed panes, settles a waiting entry and picks
    #   up a lost attempt; until T37.5 the default is built here over +workspace+, +store+, +facts+,
    #   +session_monitor+, +marker+, +event_log+, +max_attempts+, +clock+ and the desk's own clear, give-up
    #   report and inbox resolve
    # @param runner [Workspace::RecoveryAttemptRunner] runs steps 2 to 5 of each attempt and moves a pane's
    #   queued prompts to a new agent; until T37.5 the default is built here over +panes+, +session_name+,
    #   +store+, +facts+, +session_monitor+, +readiness+, +detector+, +marker+, +prompt_typer+,
    #   +delivery_lock+, +restarting+, +rebind_queue+, +clock+ and +sleeper+
    def initialize(panes:, workspace:, session_name:, session_monitor:, store:, transcript:, stopper:, detector:,
      process_tree:, ledger:, resume_command:, prompt_typer:, readiness:, marker:, inbox:, delivery_lock:, event_log: nil,
      restarting: ->(_pane_id) { false }, claim_restart: ->(_pane_id) { Object.new },
      release_restart: ->(_pane_id, _token) {}, rebind_queue: ->(_pane_id, _agent_pid) {}, clock: Time,
      sleeper: ->(seconds) { sleep(seconds) }, spawn: ->(&block) { Thread.new(&block) }, steps: AgentRecoverySteps.new, max_attempts: AgentRecoveryStore::MAX_ATTEMPTS,
      logger: Workspace::Logger.new,
      facts: RecoveryFacts.new(panes: panes, process_tree: process_tree, stopper: stopper, detector: detector, ledger: ledger,
        transcript: transcript, session_monitor: session_monitor, prompt_typer: prompt_typer, clock: clock, sleeper: sleeper,
        logger: logger),
      intake: RecoveryIntake.new(store: store, session_monitor: session_monitor, facts: facts, rebind_queue: rebind_queue,
        report_give_up: method(:report_give_up), resolve: method(:resolve), max_attempts: max_attempts, clock: clock,
        spawn: spawn, logger: logger),
      confirmer: RecoveryConfirmer.new(workspace: workspace, store: store, facts: facts, session_monitor: session_monitor,
        marker: marker, clear: method(:clear), report_give_up: method(:report_give_up), resolve: method(:resolve),
        event_log: event_log, max_attempts: max_attempts, clock: clock),
      runner: RecoveryAttemptRunner.new(panes: panes, session_name: session_name, store: store, facts: facts,
        session_monitor: session_monitor, readiness: readiness, detector: detector, marker: marker, prompt_typer: prompt_typer,
        delivery_lock: delivery_lock, restarting: restarting, rebind_queue: rebind_queue, clock: clock, sleeper: sleeper))
      @workspace = workspace
      @store = store
      @stopper = stopper
      @resume_command = resume_command
      @marker = marker
      @inbox = inbox
      @event_log = event_log
      @delivery_lock = delivery_lock
      @restarting = restarting
      @claim_restart = claim_restart
      @release_restart = release_restart
      @clock = clock
      @spawn = spawn
      @steps = steps
      @max_attempts = max_attempts
      @logger = logger
      @facts = facts
      @intake = intake
      @confirmer = confirmer
      @runner = runner
    end

    # Takes in a hook event the daemon received. Only queues it; the work runs
    # on a worker thread, so the hook is answered at once.
    #
    # @param message [Hash] a "session_event" payload
    # @return [void]
    def session_event(message)
      @intake.session_event(message)
    end

    # Runs from the monitor's scan: marks the failed panes once, then for each
    # entry confirms a settled failure, checks one that is due, and picks up an
    # attempt no claim holds any more.
    #
    # @return [void]
    def scan
      entries = @store.entries
      @confirmer.mark_failed_panes(entries)
      entries.each_key do |pane_id|
        scan_pane(pane_id)
      rescue => e
        @logger.debug { "agent recovery: scan of #{pane_id} failed (#{e.class}: #{e.message})" }
      end
    rescue Workspace::Error => e
      @logger.debug { "agent recovery: #{e.message}" }
    end

    # @param pane_id [String]
    # @return [Boolean] whether the pane's queued prompts must wait for the recovery
    def holding?(pane_id)
      @store.holding?(pane_id)
    end

    # Reads the pane as it is now and answers what may happen to the entry. It
    # costs no attempt, and it changes nothing but a missing pid or missing flags.
    #
    # @param pane_id [String]
    # @param entry [Hash] the pane's stored entry
    # @param screen [String, nil] the screen a quiet wait already gave, compared
    #   with one capture so the delivery lock isn't held across that wait
    # @return [Verdict]
    def check(pane_id, entry, screen: nil)
      detail = @facts.pane_detail(pane_id)
      return verdict(:defer) unless detail.is_a?(Hash)
      reading = @facts.agent(detail)
      return verdict(:defer) unless reading

      agent = reading.found
      agent ? check_live(pane_id, entry, detail, reading.tree, agent, screen) : check_gone(pane_id, entry, detail, reading.tree, screen)
    end

    private

    # The attempt thread's own logging: a logger that raises must not skip
    # the claim's release.
    def quiet_debug(&block)
      @logger.debug(&block)
    rescue
      nil
    end

    def scan_pane(pane_id)
      entry = @store.get(pane_id)
      return unless entry

      case entry["phase"]
      when "waiting"
        entry = @confirmer.settle(pane_id, entry) unless entry["stopped"] == true
        attempt_if_due(pane_id, entry) if entry
      when "attempting"
        @confirmer.reconcile(pane_id) unless @restarting.call(pane_id)
      end
    end

    def attempt_if_due(pane_id, entry)
      return unless entry["phase"] == "waiting"
      due = RecoveryVerdicts.time_of(entry["next_attempt_at"])
      return unless due && @clock.now >= due && !@restarting.call(pane_id)

      answer = safe_check(pane_id, entry)
      return refuse(pane_id, entry, answer) unless answer.answer == :go

      # The screen wait gave a hook time to change the entry.
      current = @store.get(pane_id)
      start_attempt(pane_id, answer) if current && RecoveryEntry.same_wait?(current, entry)
    end

    # Acts on any {#check} answer but `:go`.
    def refuse(pane_id, entry, answer)
      case answer.answer
      when :defer then defer(pane_id, entry)
      when :clear then clear(pane_id, entry)
      when :never then give_up(pane_id, entry, "cannot_restart")
      end
    end

    # A check that raises has read nothing, so it defers like any other unread
    # condition and the defer limit ends it.
    def safe_check(pane_id, entry, **options)
      check(pane_id, entry, **options)
    rescue => e
      @logger.debug { "agent recovery: check of #{pane_id} failed (#{e.class}: #{e.message})" }
      verdict(:defer)
    end

    def start_attempt(pane_id, answer)
      (answer.mode == :typed) ? typed_attempt(pane_id) : restart_attempt(pane_id)
    end

    # The attempt for `attempts` 0: the message typed at the live prompt.
    def typed_attempt(pane_id)
      @spawn.call { run_claimed(pane_id, method(:begin_typed), @steps.typed_runner(@runner.method(:typed))) }
    end

    # The attempt for `attempts` above 0: stop, resume, wait, type.
    def restart_attempt(pane_id)
      @spawn.call { run_claimed(pane_id, method(:begin_restart), @steps.restart_runner(@runner.method(:restart))) }
    end

    # Runs one attempt inside a claim on the pane. An attempt that raises or is
    # killed stays `attempting` with no claim, for {RecoveryConfirmer#reconcile} to pick up, and
    # keeps its marker until then: the agent may be exiting right now. A typed
    # attempt has no marker of its own, so it leaves alone one an earlier
    # `not_stopped` left to expire.
    #
    # @param opening [#call] {#open_attempt}'s step, under the delivery lock
    # @param steps [#call] given the attempt, answers an outcome and any agent that outcome names
    def run_claimed(pane_id, opening, steps)
      token = @claim_restart.call(pane_id)
      return unless token

      attempt = outcome = nil
      begin
        attempt = open_attempt(pane_id, opening)
        return unless attempt
        outcome, agent = steps.call(attempt)
        finish(attempt, outcome, agent: agent)
      rescue => e
        quiet_debug { "agent recovery: attempt in #{pane_id} failed (#{e.class}: #{e.message})" }
      ensure
        @marker.clear(attempt.session_id) if outcome && outcome != "not_stopped" && attempt.mode == "restart"
        @release_restart.call(pane_id, token)
      end
    end

    # Step 1. A refusal costs no attempt and writes no line.
    #
    # @param opening [#call] given the pane id, the entry and the quiet screen,
    #   answers what {#begin_restart} does
    # @return [Attempt, nil] the attempt under way; nil when none began
    def open_attempt(pane_id, opening)
      seen = @store.get(pane_id)
      return nil unless seen && seen["phase"] == "waiting"

      quiet = @facts.still_screen(pane_id)
      return refuse(pane_id, seen, verdict(:defer)) unless quiet

      opened = @delivery_lock.synchronize { opening.call(pane_id, seen, quiet) }
      return opened if opened.is_a?(Attempt)
      refuse(pane_id, seen, opened) if opened
      nil
    end

    # @return [Attempt, Verdict, nil] the attempt under way; the answer to act
    #   on; or nil when a hook changed the entry and there is nothing to do
    def begin_restart(pane_id, seen, quiet)
      answer = safe_check(pane_id, seen, screen: quiet)
      return answer unless answer.answer == :go
      return nil if answer.mode == :typed
      return mark_attempting(pane_id, seen, answer) if answer.mode == :resume_only

      refused = failure_refusal(pane_id, seen)
      return refused if refused
      detail = @facts.pane_detail(pane_id)
      return verdict(:defer) unless detail.is_a?(Hash)

      attempt = mark_attempting(pane_id, seen, answer, "stopped" => true, "last_signal_at" => stamp)
      attempt && signal_agent(attempt, seen, detail)
    end

    # @return [Attempt, Verdict, nil] as {#begin_restart}
    def begin_typed(pane_id, seen, quiet)
      answer = safe_check(pane_id, seen, screen: quiet)
      return answer unless answer.answer == :go
      return nil unless answer.mode == :typed

      failure_refusal(pane_id, seen) || mark_attempting(pane_id, seen, answer)
    end

    # @return [Verdict, nil] the answer to act on, unless the stored failure
    #   still stands. The prompt comes last: the transcript and ledger reads
    #   gave one time to arrive.
    def failure_refusal(pane_id, seen)
      unconfirmed = confirmed_error(pane_id, seen)
      return verdict(unconfirmed) if unconfirmed
      verdict(:defer) if @facts.prompt_since_failure?(pane_id, seen)
    end

    # Writes `attempting`. `defer_since` goes here and nowhere earlier, so a
    # scan's `:go` and step 1's `:defer` can't repeat without bound. A typed
    # attempt's text is on the entry from here on, so a paste that renders late,
    # or a kill between the paste and Enter, leaves text {#check} recognises.
    def mark_attempting(pane_id, seen, answer, fields = {})
      number = seen["attempts"].to_i + 1
      typed = answer.mode == :typed
      message = format(typed ? TYPED_MESSAGE : RESUMED_MESSAGE, error: seen["error"])
      fields = fields.merge("draft_text" => message) if typed
      opened = false
      @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen) && entry["attempts"] == seen["attempts"]
        entry.merge!(fields, "attempts" => number, "phase" => "attempting", "attempt_session_id" => nil, "defer_since" => nil,
          "prompt_seen" => false)
        opened = true
      end
      return nil unless opened

      Attempt.new(pane_id: pane_id, session_id: seen["session_id"], number: number, mode: typed ? "typed" : "restart",
        pid: seen["agent_pid"], started: seen["agent_started"], command: answer.command, message: message,
        resume_only: answer.mode == :resume_only, opened_at: @clock.now)
    end

    # The marker and `stopped` are written before the signal, because the
    # SessionEnd it causes can arrive at once, and with no marker it would stop
    # the dev server. Any answer but `:signalled` sent nothing, so `stopped` is
    # taken back: an agent gone by now left on someone's word, not ours.
    def signal_agent(attempt, seen, detail)
      return take_back(attempt, seen, :defer) unless @marker.mark(attempt.session_id)

      result = begin
        @stopper.stop(pid: attempt.pid, started: attempt.started, pane_pid: detail[:pid])
      rescue => e
        @logger.debug { "agent recovery: no signal for #{attempt.pane_id} (#{e.class}: #{e.message})" }
        :unread
      end
      case result
      when :signalled then attempt
      when :stale then take_back(attempt, seen, :clear)
      when :not_running then take_back(attempt, seen, :defer, keep_marker: true)
      else take_back(attempt, seen, :defer)
      end
    end

    # No signal went out, so the attempt never happened: the entry goes back to
    # how step 1 found it, `defer_since` included, so the defer limit still
    # runs. What a hook wrote meanwhile is honoured as step 6 would.
    #
    # An empty pane answers `:clear`, so no entry waits with no agent, unless an
    # earlier signal may explain it. With `:not_running` that signal's SessionEnd
    # may be in flight, so its marker is left to expire.
    #
    # @return [Verdict] the answer to act on; it finds a changed entry and does nothing
    def take_back(attempt, seen, answer, keep_marker: false)
      @marker.clear(attempt.session_id) unless keep_marker
      live = last_read(attempt.pane_id)
      row = nil
      restored = %w[phase attempts stopped last_signal_at defer_since].to_h { |key| [key, seen[key]] }
      stored = @store.update(attempt.pane_id) do |entry|
        next unless attempt.current?(entry)
        entry.merge!(restored)
        row = hook_row(entry, live)
      end
      close_row(attempt, row, stored)
      verdict((RecoveryEntry.agent_gone?(seen, live) && !signalled_lately?(seen)) ? :clear : answer)
    end

    # Step 6: one update, so it can't overwrite a hook's write, then the line.
    # The queue moves before the update ends the hold, so no prune sees the old
    # pid. An entry that isn't this attempt's any more was picked up by
    # {RecoveryConfirmer#reconcile}, which wrote the line. A kill waits for the end of the span,
    # so a `gave_up` entry always gets its line and inbox item.
    #
    # @param attempt [Attempt]
    # @param outcome [String]
    # @param agent [Hash, nil] with `person_resumed`, the agent found
    # @return [void]
    def finish(attempt, outcome, agent: nil)
      pane_id = attempt.pane_id
      live = agent || ((outcome == "fresh_agent") ? :unread : last_read(pane_id))
      @runner.rebind(pane_id) if live.is_a?(Hash) && !attempt.ours?(live)

      Thread.handle_interrupt(Object => :never) do
        seen = row = nil
        stored = @store.update(pane_id) do |entry|
          next unless attempt.current?(entry)
          seen = entry.dup
          row = hook_row(entry, live)
          next if row

          outcome = "agent_left" if live.nil? && %w[resumed typed].include?(outcome)
          row = close_attempt(entry, attempt, outcome, live)
        end
        next unless seen

        record(ATTEMPT_EVENT, "attempt" => attempt.number, "session_id" => attempt.session_id, "pane_id" => pane_id,
          "error" => seen["error"], "mode" => attempt.mode, "outcome" => outcome)
        close_row(attempt, row, stored)
      end
    end

    # @return [Symbol, nil] +:resolved+, +:gave_up+, or nil when there is nothing to report
    def close_attempt(entry, attempt, outcome, live)
      case outcome
      when "resumed" then entry.merge!("phase" => "watching", "last_signal_at" => nil, "draft_text" => nil)
      when "typed"
        entry["phase"] = "watching"
        entry["draft_text"] = nil
      when "person_resumed"
        entry.merge!("phase" => "watching", "stopped" => false, "last_signal_at" => nil, "draft_text" => nil)
        RecoveryEntry.store_agent(entry, live)
      when "fresh_agent"
        RecoveryEntry.give_up(entry, "fresh_conversation")
        return :gave_up
      else
        RecoveryEntry.apply_read(entry, live)
        entry["draft_text"] = attempt.message if DRAFT_OUTCOMES.include?(outcome)
        if RecoveryEntry.agent_gone?(entry, live)
          RecoveryEntry.give_up(entry, "unconfirmed")
          return :gave_up
        end
        return :gave_up if schedule_next(entry)
      end
      nil
    end

    # What hooks left for the end of the attempt, ahead of its outcome. Clears
    # the attempt's fields either way.
    #
    # @return [Symbol, nil] +:resolved+, +:gave_up+, +:rescheduled+, or nil when no hook decides
    def hook_row(entry, live)
      finished = entry["turn_completed"] == true || entry["resumed_elsewhere"] == true
      failed = entry["failed_during_attempt"] == true
      opened = entry["attempt_session_id"]
      ATTEMPT_FIELDS.each { |key| entry.delete(key) }
      if finished
        entry.clear
        return :resolved
      end
      if opened && opened != entry["session_id"]
        RecoveryEntry.give_up(entry, "fresh_conversation")
        return :gave_up
      end
      return nil unless failed

      RecoveryEntry.apply_read(entry, live)
      entry["phase"] = "watching"
      known = (live == :unread) ? {pid: entry["agent_pid"], started: entry["agent_started"], flags: entry["agent_flags"]} : live
      return :gave_up if @intake.apply_failure(entry, entry["session_id"], entry["error"], entry["transcript_path"], known)
      return :rescheduled unless RecoveryEntry.agent_gone?(entry, live)

      RecoveryEntry.give_up(entry, "unconfirmed")
      :gave_up
    end

    def close_row(attempt, row, stored)
      resolve(attempt.session_id) if row == :resolved
      report_give_up(attempt.pane_id, stored) if row == :gave_up
    end

    # @return [Hash, nil, Symbol] the agent in the pane, nil when there is none
    #   or the pane is gone, or :unread when tmux or the process table can't be read
    def last_read(pane_id)
      detail = @facts.pane_detail(pane_id)
      return (@facts.tree.nil? || detail == :unknown) ? :unread : nil unless detail.is_a?(Hash)
      reading = @facts.agent(detail)
      reading ? reading.found : :unread
    end

    def defer(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        since = RecoveryVerdicts.time_of(entry["defer_since"])
        if since.nil?
          entry["defer_since"] = stamp
        elsif @clock.now - since >= DEFER_LIMIT
          RecoveryEntry.give_up(entry, "deferred")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # `:clear`, with one meaning everywhere: the entry goes while no attempt
    # was made, and after attempts the count is reported, never dropped.
    def clear(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        if RecoveryEntry.unreported?(entry)
          entry.clear
        else
          RecoveryEntry.give_up(entry, "unconfirmed")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    def give_up(pane_id, seen, reason)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        RecoveryEntry.give_up(entry, reason)
        gave_up = true
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # An inbox that can't be written must not end the worker or the scan: the
    # entry is `gave_up` by now and the event line says so.
    def report_give_up(pane_id, entry)
      record(GAVE_UP_EVENT, "pane_id" => pane_id, "session_id" => entry["session_id"], "attempts" => entry["attempts"],
        "error" => entry["error"], "reason" => entry["give_up_reason"])
      @inbox.call.upsert(inbox_item(pane_id, entry), reopen: true)
      # A Stop may have come between the record and the item.
      current = @store.get(pane_id)
      resolve(entry["session_id"]) unless current && current["session_id"] == entry["session_id"]
    rescue Workspace::Error, SystemCallError => e
      @logger.debug { "agent recovery: no inbox item for #{pane_id} (#{e.class}: #{e.message})" }
    end

    def inbox_item(pane_id, entry)
      attempts = entry["attempts"].to_i
      error = entry["error"] || "an unnamed error"
      reason = (entry["give_up_reason"] == "unconfirmed" && attempts.zero?) ? "unconfirmed_no_attempts" : entry["give_up_reason"]
      body = format(GIVE_UP_BODIES.fetch(reason), error: error, cause: entry["item_error"] || error, attempts: attempts)
      {
        "type" => "alert",
        "scope" => {"kind" => "workspace", "key" => @workspace, "name" => @workspace},
        "title" => "The agent in pane #{pane_id} needs you: workspace could not recover it from an API error",
        "body" => "#{body} Session #{entry["session_id"]}.",
        "source" => {"kind" => "session", "ref" => entry["session_id"], "url" => nil},
        "dedupe_key" => inbox_key(entry["session_id"]),
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"pane" => pane_id},
        "expires_at" => nil,
        "note" => nil
      }
    end

    def inbox_key(session_id)
      "agent-recovery:#{session_id}"
    end

    def resolve(session_id)
      @inbox.call.transition_by_key(inbox_key(session_id), to: "done", by: {"kind" => "agent_recovery"})
    rescue Workspace::Error, SystemCallError => e
      @logger.debug { "agent recovery: inbox item for #{session_id} not resolved (#{e.class}: #{e.message})" }
    end

    # @return [Boolean] whether this gave up, the attempts being used up
    def schedule_next(entry)
      RecoveryEntry.schedule_next(entry, max_attempts: @max_attempts, clock: @clock)
    end

    # No agent in the pane. With `stopped` the agent is already gone and
    # nothing can be killed, so the checks that read a live agent don't apply.
    def check_gone(pane_id, entry, detail, tree, screen)
      unless entry["stopped"] == true
        return verdict(signalled_lately?(entry) ? :defer : :clear)
      end
      return verdict(:clear) if started_since_signal?(entry)
      return verdict(:never) unless @facts.transcript_file?(entry)

      command = resume_line(entry)
      return verdict(:defer) unless RecoveryVerdicts.resumable?(command, entry)
      clear = @facts.pane_clear?(detail, tree)
      return verdict(:defer) if !clear || @stopper.session_held?(session_id: entry["session_id"], tree: tree)
      return verdict(:defer) unless @facts.still_screen(pane_id, screen)
      verdict(:go, mode: :resume_only, command: command)
    end

    # A ledger that can't be read raises, which {#safe_check} answers with `:defer`.
    def started_since_signal?(entry)
      RecoveryVerdicts.started_since_signal?(entry, @facts.ledger_start(entry))
    end

    # What may clear comes first, so an agent at work is deferred and never
    # read as a transcript that moved on.
    def check_live(pane_id, entry, detail, tree, agent, screen)
      return verdict(:defer) if entry["stopped"] == true
      return verdict(:defer) unless @facts.foreground?(agent, detail)
      return verdict(:defer) if @facts.held_off?(pane_id, entry, screen)

      unless entry["agent_pid"]
        @store.update(pane_id) { |current| RecoveryEntry.store_agent(current, agent) if RecoveryEntry.same_wait?(current, entry) }
        return verdict(:defer)
      end
      return verdict(:clear) unless RecoveryVerdicts.same_process?(entry, agent)

      entry = fill_flags(pane_id, entry, agent)
      confirmed = confirmed_error(pane_id, entry)
      return verdict(confirmed) if confirmed
      return verdict(:go, mode: :typed) if RecoveryVerdicts.first_attempt?(entry)

      restart_verdict(pane_id, entry, detail, tree, agent)
    end

    # Flags an earlier read couldn't give, from a read of the same process.
    #
    # @return [Hash] the entry to go on with
    def fill_flags(pane_id, entry, agent)
      return entry unless entry["agent_flags"].nil? && agent[:flags]

      @store.update(pane_id) { |current| RecoveryEntry.store_agent(current, agent) if RecoveryEntry.same_wait?(current, entry) && RecoveryVerdicts.same_process?(current, agent) }
      entry.merge("agent_flags" => agent[:flags])
    end

    # @return [Symbol, nil] +:defer+ or +:clear+ unless the transcript and the
    #   ledger both still show the stored failure of the stored session
    def confirmed_error(pane_id, entry)
      answer = RecoveryVerdicts.transcript_verdict(@facts.transcript_error(entry), entry)
      return answer if answer
      RecoveryVerdicts.session_verdict(@facts.ledger_session(pane_id), entry)
    end

    def restart_verdict(pane_id, entry, detail, tree, agent)
      answer = RecoveryVerdicts.start_command_verdict(@facts.start_command(pane_id))
      return verdict(answer) if answer
      return verdict(:never) unless @stopper.restartable?(pid: agent[:pid], pane_pid: detail[:pid], tree: tree)

      command = resume_line(entry)
      command ? verdict(:go, mode: :restart, command: command) : verdict(:defer)
    end

    # The flags are the pane's own agent's, stored with its pid. The config's
    # first `claude` pane says nothing about this one, so with none stored there
    # is no line, and {#check} defers.
    def resume_line(entry)
      return nil unless entry["cwd"].is_a?(String)
      @resume_command.call(workspace: @workspace, cwd: entry["cwd"], session_id: entry["session_id"], flags: entry["agent_flags"])
    end

    def signalled_lately?(entry)
      RecoveryEntry.signalled_lately?(entry, @clock)
    end

    def verdict(answer, mode: nil, command: nil)
      Verdict.new(answer: answer, mode: mode, command: command)
    end

    def stamp
      AgentRecoveryStore.stamp(@clock.now)
    end

    def record(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end
  end
end
