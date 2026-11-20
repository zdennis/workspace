require "fileutils"
require "time"

module Workspace
  # Moves a workflow run from step to step. A run is a copy of its definition plus where it
  # stands, kept by {WorkflowRunStore}; every method makes one transition under the run's lock.
  #
  # A step is done when the agent's turn ends in the bound pane ({#turn_ended}), every file it
  # `produces:` exists, and its `status:` check passes. A failed step follows its
  # `on_fail: {goto, max}` while loops and `max_attempts` last; then the run waits for a person.
  # A run that is not moving has a `reason` (`waiting_lock`, `waiting_you`,
  # `turn_ended_incomplete`, `turn_ended_background`, `failed_check`); {WorkflowStatus} adds
  # `pane_gone`. A resume that can't be carried out yet is parked ({#park}) until {#release_park}.
  #
  # This class is the facade: each method forwards to the phase that owns it and turns the
  # phase's {WorkflowRun} or result value into the Hash callers read today.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = WorkflowDispatch::KICK
    # The run id {#preflight} and {#render} compose a first step under.
    PREVIEW_RUN_ID = WorkflowStarter::PREVIEW_RUN_ID
    # The words in `details.code` the engine sets itself; `step done --code` refuses them.
    ENGINE_CODES = WorkflowEvaluation::ENGINE_CODES
    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = WorkflowDispatch::PANE_GONE_CODES
    DELIVERY_WINDOW = WorkflowTransitions::DELIVERY_WINDOW
    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = WorkflowDecisions::PARK_SECONDS
    # How many times a released resume that could not be typed is parked again.
    PARK_RETRIES = WorkflowDispatch::PARK_RETRIES
    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = WorkflowDispatch::PARK_AGAIN_CODES
    REDELIVER_BACKOFF = WorkflowTransitions::REDELIVER_BACKOFF
    REDELIVER_CODES = WorkflowTransitions::REDELIVER_CODES
    REDELIVER_NEVER_REASONS = WorkflowTransitions::REDELIVER_NEVER_REASONS
    BACKGROUND_HOLD = WorkflowTransitions::BACKGROUND_HOLD
    # Seconds a pending interrupt claim holds before another sweep may take it over.
    INTERRUPT_CLAIM_SECONDS = WorkflowRecovery::INTERRUPT_CLAIM_SECONDS
    # Seconds an infra retry's claim holds before another advance may take it over.
    INFRA_RETRY_CLAIM_WINDOW = WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW
    GUARD_TEXT = WorkflowTransitions::GUARD_TEXT

    # The class methods below forward to {WorkflowTransitions}, which holds the rules.
    def self.attempts_made(run) = WorkflowTransitions.attempts_made(run)
    def self.attempts_spent?(run) = WorkflowTransitions.attempts_spent?(run)
    def self.attempt_allowance(run) = WorkflowTransitions.attempt_allowance(run)
    def self.extra_attempts_needed(run) = WorkflowTransitions.extra_attempts_needed(run)
    def self.starts_attempt?(run, from:, pane:) = WorkflowTransitions.starts_attempt?(run, from: from, pane: pane)
    def self.delivery(attempt, now) = WorkflowTransitions.delivery(attempt, now)
    def self.redelivery(run, now) = WorkflowTransitions.redelivery(run, now)
    def self.backoff(run, now) = WorkflowTransitions.backoff(run, now)
    def self.parked(run, now) = WorkflowTransitions.parked(run, now)
    def self.park_timeout_message(pane, checking: false) = WorkflowTransitions.park_timeout_message(pane, checking: checking)
    def self.wakeable?(run, now, alive: nil, stops: []) = WorkflowTransitions.wakeable?(run, now, alive: alive, stops: stops)
    def self.lost_check?(run, now) = WorkflowTransitions.lost_check?(run, now)
    def self.lost_round?(run, now, stops: []) = WorkflowTransitions.lost_round?(run, now, stops: stops)
    def self.sweep_marks(run) = WorkflowTransitions.sweep_marks(run)
    def self.infra_retry(run, now) = WorkflowTransitions.infra_retry(run, now)
    def self.infra_retries(run, step) = WorkflowTransitions.infra_retries(run, step)

    # {Workspace.build_workflow_engine} builds the phases over one shared {WorkflowRunChange}.
    #
    # @param starter [Workspace::WorkflowStarter] preflight, render, check_plan and start
    # @param evaluation [Workspace::WorkflowEvaluation] a turn that ended, and the agent's report
    # @param decisions [Workspace::WorkflowDecisions] a person's commands on a run
    # @param recovery [Workspace::WorkflowRecovery] tick and the sweep's acts
    def initialize(starter:, evaluation:, decisions:, recovery:)
      @starter = starter
      @evaluation = evaluation
      @decisions = decisions
      @recovery = recovery
    end

    # Checks everything `start` would refuse, and changes nothing. See {WorkflowStarter#preflight}.
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step", "pane", "inputs" and "packs"
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      @starter.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, tree: tree, checkout: checkout)
    end

    # A step's first-attempt instructions; writes nothing. See {WorkflowStarter#render}.
    # @return [Hash{String=>Object}]
    def render(definition:, step:, workspace:, worktree:, inputs:)
      @starter.render(definition: definition, step: step, workspace: workspace, worktree: worktree, inputs: inputs)
    end

    # What `workflow check` runs for a step; writes nothing. See {WorkflowStarter#check_plan}.
    # @return [Hash{String=>Object}]
    def check_plan(definition:, step:, worktree:) = @starter.check_plan(definition: definition, step: step, worktree: worktree)

    # Creates a run and starts its first step. See {WorkflowStarter#start}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run after its first transition, or as created
    def start(definition:, workspace:, worktree:, inputs:, pane:, actor:, note: nil, dispatch: true)
      @starter.start(definition: definition, actor: actor, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, note: note, dispatch: dispatch).to_h
    end

    # The agent's turn ended in the run's pane: decides the current step. See {WorkflowEvaluation#turn_ended}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards
    def turn_ended(run_id, actor:, pane: nil, turn_started: nil, stopped_at: nil, background: [], transcript_path: nil, step: nil)
      @evaluation.turn_ended(run_id, actor: actor, pane: pane, step: step, turn_started: turn_started, stopped_at: stopped_at, background: background, transcript_path: transcript_path).to_h
    end

    # Records what the agent says about its current attempt. See {WorkflowEvaluation#report}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported"
    def report(run_id, actor:, status:, summary: nil, code: nil, step: nil)
      reported = @evaluation.report(run_id, actor: actor, status: status, summary: summary, code: code, step: step)
      {"run_id" => reported.run_id, "step" => reported.step, "attempt" => reported.attempt, "reported" => reported.reported}
    end

    # Passes a gate: the run goes on to the step after the gated one. See {WorkflowDecisions#approve}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards
    def approve(run_id, actor:, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @decisions.approve(run_id, actor: actor, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard).to_h
    end

    # Turns a gate down: the gated step, or an earlier one, runs again. See {WorkflowDecisions#reject}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards
    def reject(run_id, actor:, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil)
      @decisions.reject(run_id, actor: actor, note: note, to: to, step: step, attempt: attempt, guard: guard, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds).to_h
    end

    # Gets a run that is not moving going again, or with +restart_step+ starts its current step again: the open
    # attempt is closed as `interrupted` (a `step_interrupted` event: `step`, `attempt`, `pane`, `usage_counted`) and a
    # new one starts; with +infra_retry+ (the claimant of {#claim_infra_retry}) that restart is the step's infra retry.
    # See {WorkflowDecisions#resume}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @param step [String, nil] with +restart_step+, the fan_out sibling to restart instead of the cursor's step
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when nothing was done
    def resume(run_id, actor:, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil,
      extra_rounds: nil, accept_guard: false, guard_retry: false, caller_pane: nil, restart_step: false, bound: nil, infra_retry: nil, reboot_recovery: nil, step: nil)
      resumed_h(@decisions.resume(run_id, actor: actor, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, extra_rounds: extra_rounds,
        accept_guard: accept_guard, guard_retry: guard_retry, caller_pane: caller_pane, restart_step: restart_step, bound: bound, infra_retry: infra_retry, reboot_recovery: reboot_recovery, **(step ? {step: step} : {})))
    end

    # Why a restart of the run's current step would be refused, without changing anything. See {WorkflowDecisions#restart_refusal}.
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param bound [String] what the caller knows of the bound pane (`unknown` by default)
    # @return [Workspace::Error, nil]
    def restart_refusal(run, bound: "unknown") = @decisions.restart_refusal(run, bound: bound)

    # Stores a resume for later, with {#resume}'s arguments. See {WorkflowDecisions#park}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when nothing was stored
    def park(run_id, actor:, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil)
      resumed_h(@decisions.park(run_id, actor: actor, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, extra_rounds: extra_rounds))
    end

    # Carries out the parked resume +id+. See {WorkflowDecisions#release_park}.
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when the resume did nothing
    def release_park(run_id, id, actor:) = resumed_h(@decisions.release_park(run_id, id, actor: actor))

    # Ends a park that can't be released; the run waits for a person. See {WorkflowDecisions#park_failed}.
    # @return [Hash{String=>Object}] the run afterwards
    def park_failed(run_id, id, code:, message:, actor:, gone: PANE_GONE_CODES.include?(code)) = @decisions.park_failed(run_id, id, code: code, message: message, actor: actor, gone: gone).to_h

    # What {#resume} refuses, checked without changing anything. See {WorkflowDecisions#refuse_resume}.
    # @return [void]
    def refuse_resume(run, from: nil, note: nil, accept_guard: false, guard_retry: false)
      @decisions.refuse_resume(run, from: from, note: note, accept_guard: accept_guard, guard_retry: guard_retry)
    end

    # Stops a run from starting anything new until {#unpause}. See {WorkflowDecisions#pause}.
    # @param interrupt [Boolean] also press the agent's interrupt keys in the run's pane while it works
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards, with "interrupted": true when the keys were pressed, and
    #   "interrupt_warning" when a press was tried and failed
    def pause(run_id, actor:, text: nil, interrupt: false)
      paused = @decisions.pause(run_id, actor: actor, text: text, interrupt: interrupt)
      paused.run.to_h.merge("interrupted" => paused.interrupted).merge(paused.warning ? {"interrupt_warning" => paused.warning} : {})
    end

    # Ends a pause and does what it held. See {WorkflowDecisions#unpause}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Object}] the run afterwards, with "unpaused": {"action", "held"} (what the unpause did, as on
    #   `run_unpaused`), plus "continued" (true, false or "pending") and "warning" when a continue line applied
    def unpause(run_id, actor:)
      unpaused = @decisions.unpause(run_id, actor: actor)
      shown = {"action" => unpaused.action, "held" => unpaused.held}.merge({"continued" => unpaused.continued, "warning" => unpaused.warning}.compact)
      unpaused.run.to_h.merge("unpaused" => shown)
    end

    # Ends a run: gives up its resources and frees its pane. See {WorkflowDecisions#cancel}.
    # @return [Hash{String=>Object}] the run afterwards
    def cancel(run_id, actor:, cause: "cancel") = @decisions.cancel(run_id, actor: actor, cause: cause).to_h

    # Ends every run of a workspace that was killed. See {WorkflowDecisions#workspace_killed}.
    # @return [Hash{String=>Array<String>}] "cancelled" and "failed" run ids
    def workspace_killed(workspace, actor:) = @decisions.workspace_killed(workspace, actor: actor)

    # The periodic look at a run nothing else will wake. See {WorkflowRecovery#tick}.
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id, actor:) = @recovery.tick(run_id, actor: actor)&.to_h

    # Records a stall the sweep found, and with +infra_retry+ (`{max:}`) schedules the step's infra retry, or gives it up as spent, in the same
    # change. See {WorkflowRecovery#note_stall}.
    # @return [Symbol] :scheduled, :exhausted, :recorded, :repeat, :moved_on or :busy
    def note_stall(run_id, actor:, step:, attempt:, cause:, data: {}, infra_retry: nil)
      @recovery.note_stall(run_id, actor: actor, step: step, attempt: attempt, cause: cause, data: data, infra_retry: infra_retry)
    end

    # Records that a step's infra retry will not happen. See {WorkflowRecovery#give_up_infra_retry}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :repeat or :moved_on
    def give_up_infra_retry(run_id, actor:, step:, attempt:, cause:, reason:, max: nil)
      @recovery.give_up_infra_retry(run_id, actor: actor, step: step, attempt: attempt, cause: cause, reason: reason, max: max)
    end

    # Takes the right to restart a step whose infra retry is due, giving it up on any refusal the run can answer
    # ({#restart_refusal}). See {WorkflowRecovery#claim_infra_retry}.
    # @param claimant [Hash] "pid" and "started" of the claiming process; ArgumentError without both
    # @param alive [#call, nil] given a claim's `claimed_by`, whether that process still runs
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, Integer), Array(Symbol, String), Symbol] [:claimed, n], [:gave_up, reason] or :not_due
    def claim_infra_retry(run_id, actor:, step:, attempt:, claimant:, alive:)
      @recovery.claim_infra_retry(run_id, actor: actor, step: step, attempt: attempt, claimant: claimant, alive: alive,
        refusal: ->(run) { @decisions.restart_refusal(run) })
    end

    # Gives back a claimed infra retry whose restart met a working agent, once per mark. See {WorkflowRecovery#release_infra_retry}.
    # @param claimant [Hash] "pid" and "started" of the process that claimed the retry; ArgumentError without both
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol, Array(Symbol, String)] :released, [:gave_up, "still_working"], :not_claimant or :moved_on
    def release_infra_retry(run_id, actor:, step:, attempt:, claimant:)
      @recovery.release_infra_retry(run_id, actor: actor, step: step, attempt: attempt, claimant: claimant)
    end

    # Records that the sweep put right a stall it noted. See {WorkflowRecovery#note_recovery}.
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, actor:, step:, attempt:, cause:, action:) = @recovery.note_recovery(run_id, actor: actor, step: step, attempt: attempt, cause: cause, action: action)

    # Decides a step whose agent ended its turn unseen. See {WorkflowRecovery#recover}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, actor:, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      @recovery.recover(run_id, actor: actor, turn_over: turn_over, cause: cause, data: data, fail_if_incomplete: fail_if_incomplete)
    end

    # Acts on a review round the sweep found stalled in its review pane. See {WorkflowRecovery#review_stalled}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :evaluated, :stopped, :redelivered, :moved_on or :busy
    def review_stalled(run_id, actor:, step:, attempt:, round:, pane:, cause:, data: {})
      @recovery.review_stalled(run_id, actor: actor, step: step, attempt: attempt, round: round, pane: pane, cause: cause, data: data)
    end

    # Fails a step that ran past its `timeout:`. See {WorkflowRecovery#time_out}.
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, actor:, step:, attempt:, elapsed:, timeout:) = @recovery.time_out(run_id, actor: actor, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout)

    # Types a step's line again after a failed delivery. See {WorkflowRecovery#redeliver}.
    # @return [Symbol] :redelivered, :waiting_lock, :not_delivered, :moved_on or :busy
    def redeliver(run_id, actor:, step:, attempt:) = @recovery.redeliver(run_id, actor: actor, step: step, attempt: attempt)

    # Starts an `on_fail` retry whose backoff is over. See {WorkflowRecovery#retry_backoff}.
    # @return [Symbol] :retried, :blocked, :held, :moved_on or :busy
    def retry_backoff(run_id, actor:, step:, attempt:) = @recovery.retry_backoff(run_id, actor: actor, step: step, attempt: attempt)

    # Takes the right to interrupt a step past its `timeout:`. See {WorkflowRecovery#claim_interrupt}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`]; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, actor:, step:, attempt:, elapsed:, timeout:, cause: "timed_out", details: nil, budget: nil)
      @recovery.claim_interrupt(run_id, actor: actor, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout, cause: cause, details: details, budget: budget)
    end

    # Ends a {#claim_interrupt}. See {WorkflowRecovery#interrupt_sent}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, actor:, step:, attempt:, claim_at:, sent:, record: true, cause: "timed_out")
      @recovery.interrupt_sent(run_id, actor: actor, step: step, attempt: attempt, claim_at: claim_at, sent: sent, record: record, cause: cause)
    end

    # Takes the right to interrupt a review round's pane past a time limit. See {WorkflowRecovery#claim_round_interrupt}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`]; or :repeat, :moved_on or :busy
    def claim_round_interrupt(run_id, actor:, step:, attempt:, round:, pane:, elapsed:, timeout:, cause:)
      @recovery.claim_round_interrupt(run_id, actor: actor, step: step, attempt: attempt, round: round, pane: pane, elapsed: elapsed, timeout: timeout, cause: cause)
    end

    # Ends a {#claim_round_interrupt}. See {WorkflowRecovery#round_interrupt_sent}.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def round_interrupt_sent(run_id, actor:, step:, attempt:, round:, pane:, claim_at:, sent:, cause:)
      @recovery.round_interrupt_sent(run_id, actor: actor, step: step, attempt: attempt, round: round, pane: pane, claim_at: claim_at, sent: sent, cause: cause)
    end

    private

    # The Hash a resume, a park and a park's release answer: the run, with "unchanged" when nothing was done.
    def resumed_h(resumed)
      resumed.unchanged ? resumed.run.to_h.merge("unchanged" => resumed.unchanged) : resumed.run.to_h
    end
  end
end
