module Workspace
  # The agent daemon's side of recovering a Claude Code agent whose turn ended
  # on an API error. It keeps one {AgentRecoveryStore} entry per pane, schedules
  # attempts, and gives up with one inbox item.
  #
  # {#session_event} hands the hook event to {RecoveryIntake}, which queues it
  # for its one worker and applies it to the pane's entry there.
  #
  # {#scan}, on the monitor's scan thread, has {RecoveryConfirmer} confirm a
  # failure against the transcript once {RecoveryConfirmer::SETTLE} seconds
  # have passed, runs {#check} on the entries that are due, and has the
  # confirmer pick up an attempt the daemon lost when it restarted. An answer
  # but `:go` goes to {RecoveryOutcomes#refuse}, and a `:go` to
  # {RecoveryAttempts#start}.
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
    # What {#check} answers.
    #
    # * +answer+ — +:go+, +:defer+, +:clear+ or +:never+
    # * +mode+ — with +:go+, +:typed+, +:restart+ or +:resume_only+
    # * +command+ — with +:go+ and a restart, the resume line to type
    Verdict = Struct.new(:answer, :mode, :command, keyword_init: true)

    # @param facts [Workspace::RecoveryFacts] makes each read {#check} makes
    # @param intake [Workspace::RecoveryIntake] queues the hook events and applies them to the entries
    # @param confirmer [Workspace::RecoveryConfirmer] marks the failed panes, settles a waiting entry and picks
    #   up a lost attempt
    # @param runner [Workspace::RecoveryAttempts] runs an attempt from its claim to its end, and gives the
    #   resume line
    # @param outcomes [Workspace::RecoveryOutcomes] acts on an answer but `:go`
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param restarting [#call] given a pane id, whether a restart holds the pane. Claims are released
    #   by token and refused while held, so during an attempt a true answer is the attempt's own claim.
    #   That holds while every write to the claim is guarded by `key?` or replaces its own `:starting`
    # @param clock [#now] time source
    # @param logger [Workspace::Logger] debug logger
    def initialize(facts:, intake:, confirmer:, runner:, outcomes:, store:, restarting: ->(_pane_id) { false }, clock: Time,
      logger: Workspace::Logger.new)
      @facts = facts
      @intake = intake
      @confirmer = confirmer
      @runner = runner
      @outcomes = outcomes
      @store = store
      @restarting = restarting
      @clock = clock
      @logger = logger
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
      return @outcomes.refuse(pane_id, entry, answer.answer) unless answer.answer == :go

      # The screen wait gave a hook time to change the entry.
      current = @store.get(pane_id)
      @runner.start(pane_id, answer.mode, check: method(:safe_check)) if current && RecoveryEntry.same_wait?(current, entry)
    end

    # A check that raises has read nothing, so it defers like any other unread
    # condition and the defer limit ends it.
    def safe_check(pane_id, entry, **options)
      check(pane_id, entry, **options)
    rescue => e
      @logger.debug { "agent recovery: check of #{pane_id} failed (#{e.class}: #{e.message})" }
      verdict(:defer)
    end

    # No agent in the pane. With `stopped` the agent is already gone and
    # nothing can be killed, so the checks that read a live agent don't apply.
    def check_gone(pane_id, entry, detail, tree, screen)
      unless entry["stopped"] == true
        return verdict(signalled_lately?(entry) ? :defer : :clear)
      end
      return verdict(:clear) if started_since_signal?(entry)
      return verdict(:never) unless @facts.transcript_file?(entry)

      command = @runner.resume_line(entry)
      return verdict(:defer) unless RecoveryVerdicts.resumable?(command, entry)
      clear = @facts.pane_clear?(detail, tree)
      return verdict(:defer) if !clear || @facts.session_held_in?(entry["session_id"], tree)
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
      return verdict(:never) unless @facts.restartable?(agent, detail, tree)

      command = @runner.resume_line(entry)
      command ? verdict(:go, mode: :restart, command: command) : verdict(:defer)
    end

    def signalled_lately?(entry)
      RecoveryEntry.signalled_lately?(entry, @clock)
    end

    def verdict(answer, mode: nil, command: nil)
      Verdict.new(answer: answer, mode: mode, command: command)
    end
  end
end
