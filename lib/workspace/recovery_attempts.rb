module Workspace
  # One recovery attempt from its claim to its end, on the attempt's own
  # thread: {#start} claims the pane, opens the attempt (step 1), has
  # {RecoveryAttemptRunner}, or the runner {AgentRecoverySteps} picks, run
  # steps 2 to 5, and hands the outcome to {RecoveryOutcomes#finish} (step 6).
  # {#resume_line} is the resume command an attempt types, which
  # {AgentRecoveryDesk#check} answers with its `:go`.
  #
  # Step 1 reads the entry and a quiet screen, then under the delivery lock
  # checks the pane again ({AgentRecoveryDesk#check}, given to {#start}),
  # confirms the failure still stands, writes `attempting` and, for a restart,
  # sends the one SIGINT. A refusal costs no attempt and writes no line.
  class RecoveryAttempts
    # What the agent is told at its live prompt.
    TYPED_MESSAGE = "An API error stopped your last turn (%<error>s). Continue where you left off."

    # What the agent is told once it has been resumed. Neither message may hold
    # anything a shell expands: one that lands at a shell must do nothing.
    RESUMED_MESSAGE = "An API error stopped your last turn (%<error>s), so workspace restarted Claude Code and resumed this " \
      "conversation. Locks your old process held were released, so take them again before you use them. A dev server " \
      "started with workspace dev up is still running and keeps its lock. Continue where you left off."

    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param facts [Workspace::RecoveryFacts] reads the pane, the screen, the transcript, the ledger and the monitor's prompts
    # @param outcomes [Workspace::RecoveryOutcomes] acts on a refusal, takes back an attempt with no signal, ends an attempt
    # @param attempt_runner [Workspace::RecoveryAttemptRunner] runs steps 2 to 5 unless +steps+ picks another runner
    # @param steps [Workspace::AgentRecoverySteps] picks the runner of steps 2 to 5 for each kind of attempt
    # @param stopper [Workspace::AgentStopper] sends the SIGINT
    # @param marker [Workspace::RecoveryStopMarker] says a stop is ours
    # @param resume_command [#call] given +cwd:+, +session_id:+ and +flags:+, the workspace's resume line
    #   ({AgentResumeCommand#call} with the workspace given)
    # @param delivery_lock [Mutex] held while step 1 checks and writes, shared with the daemon's other deliveries
    # @param claim_restart [#call] given a pane id, claims it; returns a token, or nil when it is held.
    #   Called on the attempt's own thread, so it can register +Thread.current+ for shutdown
    # @param release_restart [#call] given a pane id and a token, releases that claim
    # @param spawn [#call] runs the given block on its own thread
    # @param clock [#now] time source
    # @param logger [Workspace::Logger] debug logger
    def initialize(store:, facts:, outcomes:, attempt_runner:, stopper:, marker:, resume_command:, delivery_lock:,
      steps: AgentRecoverySteps.new, claim_restart: ->(_pane_id) { Object.new }, release_restart: ->(_pane_id, _token) {},
      spawn: ->(&block) { Thread.new(&block) }, clock: Time, logger: Workspace::Logger.new)
      @store = store
      @facts = facts
      @outcomes = outcomes
      @attempt_runner = attempt_runner
      @steps = steps
      @stopper = stopper
      @marker = marker
      @resume_command = resume_command
      @delivery_lock = delivery_lock
      @claim_restart = claim_restart
      @release_restart = release_restart
      @spawn = spawn
      @clock = clock
      @logger = logger
    end

    # Starts an attempt on its own thread: the typed one for `attempts` 0, else
    # stop, resume, wait, type.
    #
    # @param pane_id [String]
    # @param mode [Symbol] the `:go`'s mode, +:typed+, +:restart+ or +:resume_only+
    # @param check [#call] given the pane id, the entry and +screen:+, answers an {AgentRecoveryDesk::Verdict};
    #   it never raises
    # @return [void]
    def start(pane_id, mode, check:)
      if mode == :typed
        @spawn.call { run_claimed(pane_id, ->(*read) { begin_typed(*read, check) }, @steps.typed_runner(@attempt_runner.method(:typed))) }
      else
        @spawn.call { run_claimed(pane_id, ->(*read) { begin_restart(*read, check) }, @steps.restart_runner(@attempt_runner.method(:restart))) }
      end
    end

    # The flags are the pane's own agent's, stored with its pid. The config's
    # first `claude` pane says nothing about this one, so with none stored there
    # is no line, and {AgentRecoveryDesk#check} defers.
    #
    # @param entry [Hash] the pane's entry
    # @return [String, nil] the line that resumes the entry's session
    def resume_line(entry)
      return nil unless entry["cwd"].is_a?(String)
      @resume_command.call(cwd: entry["cwd"], session_id: entry["session_id"], flags: entry["agent_flags"])
    end

    private

    # The attempt thread's own logging: a logger that raises must not skip
    # the claim's release.
    def quiet_debug(&block)
      @logger.debug(&block)
    rescue
      nil
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
        @outcomes.finish(attempt, outcome, agent: agent)
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
    # @return [RecoveryAttemptRunner::Attempt, nil] the attempt under way; nil when none began
    def open_attempt(pane_id, opening)
      seen = @store.get(pane_id)
      return nil unless seen && seen["phase"] == "waiting"

      quiet = @facts.still_screen(pane_id)
      return @outcomes.refuse(pane_id, seen, :defer) unless quiet

      opened = @delivery_lock.synchronize { opening.call(pane_id, seen, quiet) }
      return opened if opened.is_a?(RecoveryAttemptRunner::Attempt)
      @outcomes.refuse(pane_id, seen, opened) if opened
      nil
    end

    # @return [RecoveryAttemptRunner::Attempt, Symbol, nil] the attempt under way; the answer to act
    #   on; or nil when a hook changed the entry and there is nothing to do
    def begin_restart(pane_id, seen, quiet, check)
      answer = check.call(pane_id, seen, screen: quiet)
      return answer.answer unless answer.answer == :go
      return nil if answer.mode == :typed
      return mark_attempting(pane_id, seen, answer) if answer.mode == :resume_only

      refused = failure_refusal(pane_id, seen)
      return refused if refused
      detail = @facts.pane_detail(pane_id)
      return :defer unless detail.is_a?(Hash)

      attempt = mark_attempting(pane_id, seen, answer, "stopped" => true, "last_signal_at" => AgentRecoveryStore.stamp(@clock.now))
      attempt && signal_agent(attempt, seen, detail)
    end

    # @return [RecoveryAttemptRunner::Attempt, Symbol, nil] as {#begin_restart}
    def begin_typed(pane_id, seen, quiet, check)
      answer = check.call(pane_id, seen, screen: quiet)
      return answer.answer unless answer.answer == :go
      return nil unless answer.mode == :typed

      failure_refusal(pane_id, seen) || mark_attempting(pane_id, seen, answer)
    end

    # @return [Symbol, nil] the answer to act on, unless the stored failure
    #   still stands. The prompt comes last: the transcript and ledger reads
    #   gave one time to arrive.
    def failure_refusal(pane_id, seen)
      unconfirmed = confirmed_error(pane_id, seen)
      return unconfirmed if unconfirmed
      :defer if @facts.prompt_since_failure?(pane_id, seen)
    end

    # @return [Symbol, nil] +:defer+ or +:clear+ unless the transcript and the
    #   ledger both still show the stored failure of the stored session
    def confirmed_error(pane_id, entry)
      answer = RecoveryVerdicts.transcript_verdict(@facts.transcript_error(entry), entry)
      return answer if answer
      RecoveryVerdicts.session_verdict(@facts.ledger_session(pane_id), entry)
    end

    # Writes `attempting`. `defer_since` goes here and nowhere earlier, so a
    # scan's `:go` and step 1's `:defer` can't repeat without bound. A typed
    # attempt's text is on the entry from here on, so a paste that renders late,
    # or a kill between the paste and Enter, leaves text {AgentRecoveryDesk#check} recognises.
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

      RecoveryAttemptRunner::Attempt.new(pane_id: pane_id, session_id: seen["session_id"], number: number,
        mode: typed ? "typed" : "restart", pid: seen["agent_pid"], started: seen["agent_started"], command: answer.command,
        message: message, resume_only: answer.mode == :resume_only, opened_at: @clock.now)
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

    # With `:not_running` the earlier signal's SessionEnd may be in flight, so
    # its marker is left to expire.
    def take_back(attempt, seen, answer, keep_marker: false)
      @marker.clear(attempt.session_id) unless keep_marker
      @outcomes.take_back(attempt, seen, answer)
    end
  end
end
