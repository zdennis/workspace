require "fileutils"
require "securerandom"
require "time"

module Workspace
  # Moves a workflow run from step to step. A run is a copy of its
  # definition plus where it stands, kept by {WorkflowRunStore}; every
  # method here makes one transition under the run's lock and returns.
  #
  # A step is done when the agent's turn ends in the bound pane
  # ({#turn_ended}), every file the step `produces:` exists, and its
  # `status:` check passes. `workspace step done` only adds the agent's own
  # report ({#report}); a report of `fail` fails the step at the turn's end.
  # A failed step follows its `on_fail: {goto, max}` while loops and the
  # run's `max_attempts` last; after that the run waits for a person.
  #
  # A run that is not moving has a `reason` that says why, one of
  # `waiting_lock`, `waiting_you`, `turn_ended_incomplete`,
  # `turn_ended_background` (a turn that ended with background tasks listed;
  # {WorkflowStatus} hides it) and `failed_check`. {WorkflowStatus} adds
  # `pane_gone`, which is read from tmux rather than stored. The one case
  # with no reason is a turn that ended without the daemon seeing it (an
  # interrupted turn, a daemon that was down): the step still reads
  # `running`, {WorkflowStatus} flags it `idle`, and {#resume} looks at it.
  #
  # Resources a step `uses:` are held by the run, taken before the step's
  # prompt is typed and given up at a gate, on a failure that stops the run,
  # and at the end.
  #
  # A resume that can't be carried out yet is parked ({#park}): a request
  # stored on the run as `parked`, not an attempt. No attempt is made and no
  # new resource taken until {#release_park}. Until then a turn's end, a tick
  # and a check's result decide nothing.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = WorkflowDispatch::KICK

    # The run id {#preflight} and {#render} compose a first step under, for a run that does not exist.
    PREVIEW_RUN_ID = WorkflowStarter::PREVIEW_RUN_ID

    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = WorkflowEvaluation::ENGINE_CODES

    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = WorkflowDispatch::PANE_GONE_CODES

    DELIVERY_WINDOW = WorkflowTransitions::DELIVERY_WINDOW

    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = 3600

    # How many times a released resume that could not be typed is parked again.
    # Each failed delivery is an attempt, and attempts count against `max_attempts`.
    PARK_RETRIES = WorkflowDispatch::PARK_RETRIES

    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = WorkflowDispatch::PARK_AGAIN_CODES

    REDELIVER_BACKOFF = WorkflowTransitions::REDELIVER_BACKOFF

    REDELIVER_CODES = WorkflowTransitions::REDELIVER_CODES

    REDELIVER_NEVER_REASONS = WorkflowTransitions::REDELIVER_NEVER_REASONS

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

    def self.wakeable?(run, now) = WorkflowTransitions.wakeable?(run, now)

    def self.lost_check?(run, now) = WorkflowTransitions.lost_check?(run, now)

    # @param store [Workspace::WorkflowRunStore]
    # @param resources [Workspace::RunResources] holds each step's `uses:` for the run
    # @param composer [Workspace::InstructionComposer] builds a step's instructions
    # @param panes [Workspace::WorkflowPanes] binds, finds and types into the run's pane
    # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param lineage [Workspace::WorkspaceLineage] names a checkout's parent project
    # @param git [Workspace::Git] reads the checkout's branch
    # @param guard [Workspace::WorkflowGuard] records a run's base commit and checks a guarded step against it
    # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
    # @param env_stopper [#call, nil] stops the dev environment a run left running under a lock it
    #   gave up (`run_id:`, `worktree:`), so nobody queues behind an environment no step uses
    # @param event_log [Workspace::EventLog, nil] gets `workflow_changed` and the run's lock events
    # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
    # @param task_store [Workspace::TaskStore, nil] names the workspace's task in the run
    # @param attempt_record [Workspace::WorkflowAttemptRecord, nil] records what each attempt started from and ended with
    #   (default: one reading HEAD through `guard`)
    # @param require_check [Workspace::WorkflowRequire, nil] checks a step's `require:` proofs
    #   (default: one over `guard` and `gate_note`)
    # @param log_tail [Workspace::WorkflowLogTail, nil] reads the end of a failed check's log for `on_fail`'s `log_tail`
    #   (default: a new one)
    # @param alerts [Workspace::WorkflowAlerts, nil] tells a person of a gate, a failure, a stall or a finish through `alerts.notify`
    #   (default: none)
    # @param inbox_for [#call, nil] given a workspace name, its inbox store, for a guard's warning (default: no item)
    # @param workspace_known [#call, nil] given a project name, true when a workspace of that name exists (for `workflow check`'s `--name` hint); nil means none does
    # @param clock [#call] returns the current Time
    # @param prompt_writer [#call] writes a step's instructions file, given the path, the text and an +encoding:+, as +File.write+ does
    def initialize(store:, resources:, composer:, panes:, checker:, commands_config:, lineage:, git:, guard:, excludes:, gate_note:,
      env_stopper: nil, workspace_known: nil, event_log: nil, task_store: nil, attempt_record: nil, require_check: nil, log_tail: nil, alerts: nil, inbox_for: nil, clock: -> { Time.now }, prompt_writer: File.method(:write))
      @store = store
      @panes = panes
      attempt_record ||= WorkflowAttemptRecord.new(guard: guard, clock: clock)
      require_check ||= WorkflowRequire.new(guard: guard, notes_dir_of: ->(workspace) { gate_note.notes_dir_of(workspace) },
        commands_config: commands_config, checker: checker)
      prompt = WorkflowPrompt.new(composer: composer, git: git, excludes: excludes, prompt_writer: prompt_writer)
      @clock = clock
      # The change types a step's line through Dispatch, which is built after it.
      @change = WorkflowRunChange.new(store: store, attempt_record: attempt_record, deliver: ->(run_id, delivery) { @dispatch.deliver(run_id, delivery)&.to_mutable_h },
        alerts: alerts, event_log: event_log)
      @dispatch = WorkflowDispatch.new(change: @change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, env_stopper: env_stopper, event_log: event_log, clock: clock)
      @progress = WorkflowProgress.new(change: @change, store: store, dispatch: @dispatch, attempt_record: attempt_record, panes: panes,
        log_tail: log_tail || WorkflowLogTail.new, clock: clock)
      @evaluation = WorkflowEvaluation.new(change: @change, store: store, progress: @progress, panes: panes, checker: checker, require_check: require_check,
        guard: guard, commands_config: commands_config, inbox_for: inbox_for, clock: clock)
      @starter = WorkflowStarter.new(change: @change, store: store, prompt: prompt, dispatch: @dispatch,
        lineage: lineage, commands_config: commands_config, guard: guard, gate_note: gate_note, task_store: task_store, workspace_known: workspace_known, clock: clock)
      @decisions = WorkflowDecisions.new(change: @change, store: store, progress: @progress, dispatch: @dispatch, evaluation: @evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: clock)
    end

    BACKGROUND_HOLD = WorkflowTransitions::BACKGROUND_HOLD

    # Checks everything `start` would refuse, and changes nothing. See {WorkflowStarter#preflight}.
    #
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step", "pane", "inputs" and "packs"
    # @raise [Workspace::Error] see {WorkflowStarter#preflight}
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      @starter.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, tree: tree, checkout: checkout)
    end

    # The instructions a step's agent would be sent for its first attempt. Writes nothing. See {WorkflowStarter#render}.
    #
    # @return [Hash{String=>Object}]
    # @raise [Workspace::Error, Workspace::UsageError] see {WorkflowStarter#render}
    def render(definition:, step:, workspace:, worktree:, inputs:)
      @starter.render(definition: definition, step: step, workspace: workspace, worktree: worktree, inputs: inputs)
    end

    # What `workflow check` runs for a step. Writes nothing. See {WorkflowStarter#check_plan}.
    #
    # @return [Hash{String=>Object}]
    # @raise [Workspace::Error] see {WorkflowStarter#check_plan}
    def check_plan(definition:, step:, worktree:)
      @starter.check_plan(definition: definition, step: step, worktree: worktree)
    end

    # Creates a run and starts its first step. See {WorkflowStarter#start}.
    #
    # @return [Hash{String=>Object}] the run after its first transition, or as created
    # @raise [Workspace::Error] see {WorkflowStarter#preflight}
    def start(definition:, workspace:, worktree:, inputs:, pane:, note: nil, dispatch: true)
      @starter.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, note: note, dispatch: dispatch).to_h
    end

    # The agent's turn ended in the run's pane: decides whether the current
    # step is done. A step with a `status:` check has it run here, outside
    # the run's lock, so a long check never blocks a `cancel`.
    #
    # @param run_id [String]
    # @param pane [String, nil] the pane the turn ended in; an event from a pane the
    #   run is not bound to changes nothing
    # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows.
    #   A turn that began before the step's attempt did was already under way when the
    #   step's line was typed (a person talking to the agent at a gate), and its end
    #   decides nothing. Without it every end of a turn in the pane counts
    # @param background [Array<Hash>] the background tasks (`"id"`, `"type"`) the agent still listed when
    #   its turn ended. A step the files do not yet complete is then held (`turn_ended_background`) and
    #   not reported as stopped, since each task that ends starts another turn
    # @param stopped_at [Time, nil] when the turn's end was seen. One from before the attempt
    #   began can't be that attempt's own, even with no +turn_started+
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil, stopped_at: nil, background: [])
      @evaluation.turn_ended(run_id, pane: pane, turn_started: turn_started, stopped_at: stopped_at, background: background).to_h
    end

    # Records what the agent says about its current attempt. See {WorkflowEvaluation#report}.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported" (the stored
    #   report: "status", "summary", "code", "at")
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil, code: nil)
      reported = @evaluation.report(run_id, status: status, summary: summary, code: code)
      {"run_id" => reported.run_id, "step" => reported.step, "attempt" => reported.attempt, "reported" => reported.reported}
    end

    # Passes a gate: the run goes on to the step after the gated one. When the
    # gated step's first file names a note (`note: <file>`), the note's sha256
    # is recorded with the approval and named in the next step's instructions.
    # Every check runs under the run's lock, in this order: the gate is
    # waiting (at +step+ and +attempt+ when given), +guard+, then the note.
    # A refusal leaves the run file as it was.
    #
    # @param run_id [String]
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting` when the run is not at a gate (or not at
    #   +step+ and +attempt+), `stale_revision` when the note's sha256 is not +note_sha256+,
    #   `gate_note_unreadable` when the named note can't be read, or when +note_sha256+ is given
    #   and the gate names no note; and what +guard+ raises
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @decisions.approve(run_id, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard).to_h
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note.
    #
    # @param run_id [String]
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`; `attempts_spent` when the run has made all its
    #   attempts and +extra_attempts+ is not given; `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it; `usage` when `to` is not the gated step or
    #   one before it; and what +guard+ raises
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil)
      @decisions.reject(run_id, note: note, to: to, step: step, attempt: attempt, guard: guard, extra_attempts: extra_attempts, extra_tokens: extra_tokens).to_h
    end

    # Gets a run that is not moving going again: asks for its lock again,
    # runs a failed or undelivered step again, looks again at a step whose
    # turn ended without its files or without the daemon seeing it, and
    # moves the run to another pane when its own is gone. A step an agent is
    # working on, and a check that is still running, are left alone. A resume
    # that acts takes over from a parked one; one that does nothing leaves it.
    #
    # @param run_id [String]
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was
    #   seen to have ended its turn on that attempt, so the step, if the run is still on that
    #   attempt and it reads `running`, is decided now
    # @param extra_attempts [Integer, nil] raises the run's attempt allowance by this much, kept in the run
    #   (`extra_attempts`) and recorded as `attempts_extended`; applied only when the resume starts an attempt,
    #   whether or not the allowance was spent
    # @param extra_tokens [Integer, nil] raises the run's token budget by this much, kept in the run (`extra_tokens`)
    #   and recorded as `budget_extended`; applied only when the resume starts an attempt, whether or not the budget was spent
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was done
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` when the resume would start
    #   an attempt the run has none left for and +extra_attempts+ is not given; `budget_spent` likewise for the token budget and +extra_tokens+
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      resumed = @decisions.resume(run_id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
      resumed.unchanged ? resumed.run.to_h.merge("unchanged" => resumed.unchanged) : resumed.run.to_h
    end

    # Stores a resume for later, with the same arguments as {#resume}: no
    # attempt, no binding, no new lock. What the run already has stays, and
    # {#release_park} carries it out. A live park stays as it is, so repeating
    # the call can't extend the wait; one past its limit is replaced.
    #
    # @param run_id [String]
    # @param from [String, nil] see {#resume}
    # @param note [String, nil] see {#resume}; stored in the run, never in an event
    # @param pane [String, nil] see {#resume}
    # @param turn_over [Hash{String=>Object}, nil] see {#resume}
    # @param extra_attempts [Integer, nil] see {#resume}; applied when the park is released
    # @param extra_tokens [Integer, nil] see {#resume}; applied when the park is released
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was stored
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent` as {#resume}
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      unchanged = nil
      run = @change.call(run_id) do |stored|
        @decisions.refuse_resume(stored, from: from)
        if self.class.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id: run_id) if pane && @panes.run_on(pane) != run_id
        if starts_attempt?(stored, from: from, pane: pane)
          @decisions.refuse_budget(stored, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        end
        drop_park(stored, "expired")
        store_park(stored, {"from" => from, "note" => note, "pane" => pane, "turn_over" => turn_over}.merge(extra_attempts ? {"extra_attempts" => extra_attempts} : {}).merge(extra_tokens ? {"extra_tokens" => extra_tokens} : {}),
          expires_at: (@clock.call + PARK_SECONDS).utc.iso8601)
      end
      unchanged ? run.merge("unchanged" => unchanged) : run
    end

    # Carries out a parked resume, in one change with taking it off the run.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when the resume did nothing, its note kept for the next attempt
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id)
      check = nil
      unchanged = nil
      run = @change.call(run_id) do |stored, ctx|
        parked = stored["parked"]
        next unless parked && parked["id"] == id
        stored.delete("parked")
        resumed = @decisions.apply_resume(stored, ctx: ctx, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"],
          extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"], budget: parked["retries"].to_i.zero?)
        stored.replace(resumed.run.to_mutable_h)
        unchanged = resumed.unchanged
        check = ctx.check
        add_resume_note(stored, parked["note"]) if unchanged
        event(stored, "resume_parked_ended", {"step" => stored["current"], "how" => unchanged ? "unchanged" : "released"}
          .merge(unchanged ? {"detail" => unchanged} : {}))
        next unless ctx.delivery
        step_state(stored)["attempts"].last["after_park"] = {"expires_at" => parked["expires_at"], "pane" => ctx.delivery["pane"], "retries" => parked["retries"]}
      end
      run = finish_check(run_id, check) if check
      unchanged ? run.merge("unchanged" => unchanged) : run
    end

    # Ends a park that can't be released, and leaves the run waiting for a
    # person. The step and what it holds stay, so a `running` step keeps its
    # attempt and a later resume decides it. A lock the run queued for is given
    # up, since the run would no longer use it. A run waiting at a gate keeps
    # its gate reason, so approve and reject stay open; the failure is in the
    # `resume_parked_ended` event.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`
    # @param message [String]
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:)
      @change.call(run_id) do |stored|
        next unless stored.dig("parked", "id") == id
        if step_state(stored).dig("gate", "state") == "waiting"
          drop_park(stored, "failed", "error" => code, "message" => message)
          next
        end
        target = park_target(stored)
        case stored.dig("reason", "code")
        when "waiting_lock" then release(stored)
        when "failed_check" then stored["pending_context"].unshift(last_failure(stored))
        end
        drop_park(stored, "failed")
        stored["state"] = "waiting"
        stored["reason"] = reason(PANE_GONE_CODES.include?(code) ? "pane_gone" : "waiting_you",
          "kind" => "dispatch", "step" => stored["current"], "pane" => target, "workspace" => stored["workspace"], "error" => code, "message" => message)
      end
    end

    # What {#resume} refuses, checked without changing anything, so a caller
    # can refuse before it starts a daemon or picks a pane.
    #
    # @param run [Hash{String=>Object}] a stored run that has not finished
    # @param from [String, nil] the step a resume would start again at
    # @return [void]
    # @raise [Workspace::Error] code `gate_waiting` for a run at a gate when no step is
    #   named (approve or reject it); `usage` for a step the workflow doesn't have
    def refuse_resume(run, from: nil)
      @decisions.refuse_resume(run, from: from)
    end

    # Ends a run: gives up its resources and frees its pane.
    #
    # @param run_id [String]
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      @decisions.cancel(run_id, cause: cause).to_h
    end

    # Ends every run of a workspace that was killed. See {WorkflowDecisions#workspace_killed}.
    #
    # @param workspace [String]
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and
    #   "failed", the ids of the runs that could not be
    def workspace_killed(workspace)
      @decisions.workspace_killed(workspace)
    end

    # The periodic look at a run nothing else will wake: one whose `on_fail`
    # backoff is over starts its retry, one waiting for a
    # lock asks for it again, a hold for background tasks that passed
    # {BACKGROUND_HOLD} becomes a `turn_ended_incomplete` stop, and a check
    # that never reported back (its process died) is run again. Does nothing
    # while another process is changing the run.
    #
    # @param run_id [String]
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      check = nil
      acted = false
      run = @change.call(run_id, nonblocking: true) do |stored, ctx|
        case self.class.wakeable?(stored, @clock.call)
        when :backoff
          acted = true
          start_retry(stored, ctx: ctx)
        when :lock
          acted = true
          dispatch(stored, ctx: ctx)
        when :background
          acted = true
          expire_background(stored)
        when :check
          acted = true
          evaluate(stored, ctx: ctx)
        end
        check = ctx.check
      end
      return nil unless run && acted
      check ? finish_check(run_id, check) : run
    end

    # Seconds a pending interrupt claim holds before another sweep may take it over: the process that took it
    # died between the claim and the press.
    INTERRUPT_CLAIM_SECONDS = 60

    # The marks the sweep left on the run's current attempt; see {WorkflowTransitions.sweep_marks}.
    def self.sweep_marks(run) = WorkflowTransitions.sweep_marks(run)

    # Records that the step stands in a stall the sweep found, once for each attempt and cause, and changes
    # nothing else. Does not wait for another process that is changing the run.
    #
    # @param run_id [String]
    # @param step [String] the step the sweep saw the run on
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param cause [String] `pane_gone`, `agent_gone` or `daemon_down`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @return [Symbol] :recorded, :repeat (this cause was recorded for the attempt already), :moved_on (the run
    #   is elsewhere now) or :busy (another process is changing the run)
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def note_stall(run_id, step:, attempt:, cause:, data: {})
      sweep_change(run_id, step: step, attempt: attempt, running: false) { |stored| mark_stall(stored, cause, data) ? :recorded : :repeat }
    end

    # Records that the sweep put right a stall it noted, once for each attempt and cause, and only for a cause
    # that was noted. Waits for the run's lock, so the record is not dropped for a busy run.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param cause [String] the cause given to {#note_stall}
    # @param action [String] e.g. `daemon_respawned`
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, step:, attempt:, cause:, action:)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        next :repeat unless self.class.sweep_marks(stored).dig("stalled", cause)
        mark_recovery(stored, cause, action) ? :recorded : :repeat
      end
    end

    # Decides a step whose agent has ended its turn without anyone seeing it, as {#resume} does when it is given
    # the same proof (+turn_over+). Does nothing unless the run is still on that step and attempt, `running`, with
    # no reason and no park, so a resume that got there first stands.
    #
    # @param run_id [String]
    # @param turn_over [Hash{String=>Object}] "step" and "attempt": the pane's agent was seen to have ended its turn on that attempt
    # @param cause [String] why the sweep acts, e.g. `idle_turn_over`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @param fail_if_incomplete [Hash, nil] "elapsed" and "timeout" of a step past its `timeout:` with `on_timeout: fail`:
    #   when the decision is a `turn_ended_incomplete` stop, the step is failed with `step_timed_out` instead
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      sweep_change(run_id, step: turn_over["step"], attempt: turn_over["attempt"], running: true) do |stored, ctx|
        mark_stall(stored, cause, data)
        mark_recovery(stored, cause, "evaluated")
        evaluate(stored, ctx: ctx)
        next :evaluated unless fail_if_incomplete && stored.dig("reason", "code") == "turn_ended_incomplete"
        fail_timed_out(stored, fail_if_incomplete["elapsed"], fail_if_incomplete["timeout"], ctx: ctx)
        :timed_out
      end
    end

    # Fails a step that ran past its `timeout:`, by the road a failed check takes (`on_fail`, then a stop for a
    # person), with `details.code` `step_timed_out`. A step held on `turn_ended_incomplete` is failed too. Waits
    # for the run's lock: it follows {#claim_interrupt} and {#interrupt_sent} when keys were pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, step:, attempt:, elapsed:, timeout:)
      sweep_change(run_id, step: step, attempt: attempt, running: :or_incomplete, blocking: true) do |stored, ctx|
        fail_timed_out(stored, elapsed, timeout, ctx: ctx)
        :timed_out
      end
    end

    # Types a step's line again after a delivery that failed, as the sweep's retry. Does nothing unless the run is
    # still on that step and attempt and {.redelivery} says a retry is due, so a resume, a park or a cancel that got
    # there first stands. The failed attempt is marked `redelivered` (it no longer counts against `max_attempts`),
    # the cause `undelivered` is recorded once for it, and a new attempt starts exactly as a resume starts one; the
    # typing itself goes through {WorkflowPanes#kick}, which refuses a pane that is not idle.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the failed attempt the sweep saw
    # @return [Symbol] :redelivered, :moved_on or :busy
    def redeliver(run_id, step:, attempt:)
      outcome = :moved_on
      info = nil
      run = @change.call(run_id, nonblocking: true) do |stored, ctx|
        next unless sweep_target?(stored, step, attempt, false)
        info = self.class.redelivery(stored, @clock.call)
        next unless info && info[:state] == :due
        mark_stall(stored, "undelivered", {"code" => info[:code], "retry" => info[:retries] + 1, "of" => info[:limit]})
        step_state(stored)["attempts"].last["redelivered"] = true
        # Stamped on the next attempt by {#dispatch}, which may be one `tick` starts after a lock wait.
        step_state(stored)["redelivery_pending"] = info[:retries] + 1
        dispatch(stored, ctx: ctx, budgeted: false)
        outcome = :started
      end
      return :busy unless run
      return outcome unless outcome == :started
      # The line has been typed (or refused) by now: say what became of it.
      state = run.dig("steps", step)
      last = state["attempts"].last
      return :waiting_lock if run.dig("reason", "code") == "waiting_lock"
      return :not_delivered if last["outcome"] == "not_delivered"
      @store.record_event(run_id, "step_recovered", "step" => step, "attempt" => attempt, "action" => "redelivered")
      :redelivered
    end

    # Starts an `on_fail` retry whose backoff is over, as the sweep's act. Does nothing unless the run is still on
    # that step and attempt and {.backoff} says the wait is over, so a resume, a cancel or a tick that got there
    # first stands.
    #
    # @param run_id [String]
    # @param step [String] the failed step the sweep saw
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @return [Symbol] :retried, :blocked (the pane is no longer the run's; the run waits for a person, nothing is spent), :held (the token budget is used; the run waits for a person), :moved_on or :busy
    def retry_backoff(run_id, step:, attempt:)
      outcome = :moved_on
      run = @change.call(run_id, nonblocking: true) do |stored, ctx|
        next unless sweep_target?(stored, step, attempt, false)
        next unless self.class.backoff(stored, @clock.call)&.fetch(:state) == :due
        start_retry(stored, ctx: ctx)
        outcome = if stored.dig("backoff", "blocked") then :blocked
        elsif stored["budget_hold"] then :held
        else :retried
        end
      end
      run ? outcome : :busy
    end

    # Takes the right to interrupt a step past its `timeout:`, as a pending mark, so two sweeps at once press the
    # keys once. A pending mark older than {INTERRUPT_CLAIM_SECONDS} can be taken over. Follow it with
    # {#interrupt_sent}, with the lock given up while the keys are pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#interrupt_sent}; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:)
      at = nil
      outcome = sweep_change(run_id, step: step, attempt: attempt, running: true) do |stored|
        marks = sweep_marks_for(stored)
        next :repeat if interrupt_held?(marks["interrupt"])
        at = now_iso
        marks["interrupt"] = {"state" => "pending", "at" => at}
        mark_stall(stored, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
        :claimed
      end
      (outcome == :claimed) ? [:claimed, at] : outcome
    end

    # Ends a {#claim_interrupt}. Sent: the mark becomes `sent`, and with +record+ the recovery is written. Not
    # sent: the claim is given back, so a later sweep tries again. Waits for the run's lock, so neither is dropped.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claim_at [String] the `at` {#claim_interrupt} gave; a claim another process took over since is left as it is
    # @param sent [Boolean] whether the keys were pressed
    # @param record [Boolean] write `step_recovered` (false when a {#time_out} follows and writes its own)
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        marks = sweep_marks_for(stored)
        next :taken_over unless marks.dig("interrupt", "at") == claim_at
        unless sent
          marks.delete("interrupt")
          next :released
        end
        marks["interrupt"] = {"state" => "sent", "at" => now_iso}
        mark_recovery(stored, "timed_out", "interrupted") if record
        :recorded
      end
    end

    # The active run on a checkout, matched by realpath. A run with no worktree, or one whose
    # path is gone or can't be resolved, is not that checkout; a finished run is not among the
    # active ones. Reads the store and takes no lock.
    #
    # @param path [String] the checkout's path
    # @return [Hash{String=>Object}, nil] the stored run, or nil
    def run_on_checkout(path)
      @store.on_checkout(path)&.to_h
    end

    private

    # One change the sweep makes under the run's lock. The block returns the outcome (a check it registers on its
    # context is run after the lock is given up), and is run only for
    # the step and attempt the sweep saw (and, with +running+, only while that step reads `running` with no
    # park and no line still on its way, and no reason: +running+ `:or_incomplete` allows a
    # `turn_ended_incomplete` stop). Without +blocking+ a run another process is changing is :busy.
    def sweep_change(run_id, step:, attempt:, running:, blocking: false)
      outcome = :moved_on
      check = nil
      run = @change.call(run_id, nonblocking: !blocking) do |stored, ctx|
        next unless sweep_target?(stored, step, attempt, running)
        outcome = yield stored, ctx
        check = ctx.check
      end
      return :busy unless run
      finish_check(run_id, check) if check
      outcome
    end

    def sweep_target?(run, step, attempt, running) = WorkflowTransitions.sweep_target?(run, step, attempt, running, @clock.call)

    def sweep_marks_for(run)
      marks = self.class.sweep_marks(run)
      return marks unless marks.empty?
      run["sweep"] = {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil), "stalled" => {}, "recovered" => {}}
    end

    def interrupt_held?(claim)
      return false unless claim
      return true if claim["state"] == "sent"
      @clock.call - Time.iso8601(claim["at"].to_s) < INTERRUPT_CLAIM_SECONDS
    rescue ArgumentError
      false
    end

    # Writes the cause once for each attempt; false when this attempt has it already.
    def mark_stall(run, cause, data)
      stalled = (sweep_marks_for(run)["stalled"] ||= {})
      return false if stalled.key?(cause)
      stalled[cause] = now_iso
      event(run, "step_stalled", sweep_event(run, {"cause" => cause}.merge(data)))
      true
    end

    def mark_recovery(run, cause, action)
      recovered = (sweep_marks_for(run)["recovered"] ||= {})
      return false if recovered.key?(cause)
      recovered[cause] = now_iso
      event(run, "step_recovered", sweep_event(run, "action" => action))
      true
    end

    def fail_timed_out(run, elapsed, timeout, ctx:)
      mark_stall(run, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
      mark_recovery(run, "timed_out", "failed")
      fail_step(run, {"cause" => "timeout", "timeout" => timeout, "elapsed" => elapsed.round}.merge(code_for("step_timed_out", nil)), ctx: ctx)
    end

    def sweep_event(run, data)
      {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)}.merge(data)
    end

    def starts_attempt?(run, from:, pane:) = self.class.starts_attempt?(run, from: from, pane: pane)

    def add_resume_note(run, note)
      run["pending_context"] << WorkflowRun.resume_note(note) if note
    end

    def last_failure(run)
      "The last attempt of this step failed: #{failure_text(run["reason"]["details"])}."
    end

    def park_target(run)
      run["parked"]["pane"] || bound_pane(run)
    end

    # +request+ is what a resume would be given: "from", "note", "pane", "turn_over".
    def store_park(run, request, expires_at:)
      run.replace(WorkflowRun.from_h(run).with_park(request, id: SecureRandom.hex(8), requested_at: now_iso, expires_at: expires_at, retries: 0).to_mutable_h)
      event(run, "resume_parked", {"step" => run["current"], "pane" => request["pane"] || bound_pane(run), "from" => request["from"],
                                   "has_note" => !request["note"].nil?})
    end

    # Takes a park off the run however it ended; see {WorkflowDispatch#drop_park}.
    def drop_park(run, how, extra = {})
      run.replace(@dispatch.drop_park(run, how, extra).to_mutable_h) if run.key?("parked")
    end

    def event(run, type, data = {}) = @change.event(run, type, data)

    def now_iso
      @clock.call.utc.iso8601
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    # +run_id+ is the run asking, which a park of its own can't refuse; see {WorkflowDispatch#check_pane}.
    def check_pane(pane, run_id: nil) = @dispatch.check_pane(pane, run_id: run_id)

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over) = WorkflowTransitions.left_alone(run, state, pane, turn_over, @clock.call, -> { bound_pane(run) })

    # Ends an `on_fail` retry's wait; see {WorkflowProgress#start_retry}.
    def start_retry(run, waiting = nil, ctx:, **options)
      run.replace(@progress.start_retry(run, waiting, ctx: ctx, **options).to_mutable_h)
    end

    # Starts the current step in the stored run; see {WorkflowDispatch#dispatch}.
    def dispatch(run, ctx:, **options)
      run.replace(@dispatch.dispatch(run, ctx: ctx, **options).to_mutable_h)
    end

    # Gives up everything the run holds; see {WorkflowDispatch#release}.
    def release(run) = @dispatch.release(run)

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end

    # No turn ended, so the step is neither passed nor checked: the hold only
    # becomes the stop it was hiding, with a `since` of its own.
    def expire_background(run)
      held = run["reason"]["details"]
      run["reason"] = reason("turn_ended_incomplete", held.slice("step", "attempt", "missing", "stale", "invalid").merge("background_tasks" => held["tasks"]))
    end

    # Decides the stored run's step whose turn ended; see {WorkflowEvaluation#evaluate}.
    def evaluate(run, ctx:) = run.replace(@evaluation.evaluate(run, ctx: ctx).to_mutable_h)

    # Runs a registered proof or check outside the lock; see {WorkflowEvaluation#finish_check}.
    def finish_check(run_id, check) = @evaluation.finish_check(run_id, check).to_h

    def fail_step(run, failure, ctx:) = run.replace(@progress.fail_step(run, failure, ctx: ctx).to_mutable_h)

    def code_for(engine_code, agent_code) = WorkflowTransitions.code_for(engine_code, agent_code)

    GUARD_TEXT = WorkflowTransitions::GUARD_TEXT

    def failure_text(failure) = WorkflowTransitions.failure_text(failure)
  end
end
