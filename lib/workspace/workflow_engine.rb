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
    ENGINE_CODES = (WorkflowGuard::CODES + [WorkflowGuard::CONFIG_CHANGED] + WorkflowRequire::PROOFS.map { |name| "require_#{name}" } + %w[require_remote_unreachable require_unknown check_failed check_timed_out check_error reported step_timed_out]).freeze

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
      @checker = checker
      @commands_config = commands_config
      @guard = guard
      @gate_note = gate_note
      @attempt_record = attempt_record || WorkflowAttemptRecord.new(guard: guard, clock: clock)
      @require_check = require_check || WorkflowRequire.new(guard: guard, notes_dir_of: ->(workspace) { gate_note.notes_dir_of(workspace) },
        commands_config: commands_config, checker: checker)
      @log_tail = log_tail || WorkflowLogTail.new
      @inbox_for = inbox_for
      prompt = WorkflowPrompt.new(composer: composer, git: git, excludes: excludes, prompt_writer: prompt_writer)
      @clock = clock
      # The change types a step's line through Dispatch, which is built after it.
      @change = WorkflowRunChange.new(store: store, attempt_record: @attempt_record, deliver: ->(run_id, delivery) { @dispatch.deliver(run_id, delivery)&.to_mutable_h },
        alerts: alerts, event_log: event_log)
      @dispatch = WorkflowDispatch.new(change: @change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: @attempt_record,
        guard: guard, env_stopper: env_stopper, event_log: event_log, clock: clock)
      @starter = WorkflowStarter.new(change: @change, store: store, prompt: prompt, dispatch: @dispatch,
        lineage: lineage, commands_config: commands_config, guard: guard, gate_note: gate_note, task_store: task_store, workspace_known: workspace_known, clock: clock)
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
      check = nil
      run = @change.call(run_id) do |stored, ctx|
        next if stored["parked"]
        state = step_state(stored)
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        next if stopped_at && stopped_at < Time.iso8601(state["attempts"].last["started_at"])
        evaluate(stored, ctx: ctx, turn_started: turn_started, background: background)
        check = ctx.check
      end
      check ? finish_check(run_id, check) : run
    end

    # Records what the agent says about its current attempt. Nothing moves
    # until the turn ends.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported" (the stored
    #   report: "status", "summary", "code", "at")
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil, code: nil)
      result = nil
      @change.call(run_id) do |stored|
        state = step_state(stored)
        unless %w[running checking].include?(state["state"])
          raise Workspace::Error.new("Step #{stored["current"]} of run #{run_id} is #{state["state"]}, so there is nothing to report on.",
            code: "step_not_running", details: {"run_id" => run_id, "step" => stored["current"], "state" => state["state"]})
        end
        attempt = state["attempts"].last
        attempt["reported"] = {"status" => status, "summary" => summary, "code" => code, "at" => now_iso}.reject { |key, value| key == "code" && value.nil? }
        event(stored, "step_reported", "step" => stored["current"], "attempt" => attempt["n"], "status" => status)
        result = {"run_id" => run_id, "step" => stored["current"], "attempt" => attempt["n"], "reported" => attempt["reported"]}
      end
      result
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
      @change.call(run_id) do |stored, ctx|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        file = gate_file(stored, note_sha256)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        gate["file"] = file if file
        event(stored, "gate_approved", with_note({"step" => stored["current"]}, note).merge(file ? {"sha256" => file["sha256"]} : {}))
        stored["pending_context"] << "The #{stored["current"]} step was approved with this note: #{note}" if note
        stored["pending_context"] << "The approved note is #{file["path"]}, sha256 #{file["sha256"]}." if file
        advance(stored, ctx: ctx)
      end
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
      @change.call(run_id) do |stored, ctx|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        # The step runs again, which is a new attempt.
        spend_attempts(stored, extra_attempts)
        spend_tokens(stored, extra_tokens)
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil))
        event(stored, "gate_rejected", with_note({"step" => stored["current"], "to" => target}, note))
        stored["pending_context"] << "The #{stored["current"]} step was rejected at its gate: #{note}"
        stored["current"] = target
        dispatch(stored, ctx: ctx)
      end
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
      check = nil
      unchanged = nil
      run = @change.call(run_id) do |stored, ctx|
        unchanged = resume_step(stored, ctx: ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        check = ctx.check
      end
      run = finish_check(run_id, check) if check
      unchanged ? run.merge("unchanged" => unchanged) : run
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
        refuse_resume(stored, from: from)
        if self.class.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id: run_id) if pane && @panes.run_on(pane) != run_id
        if starts_attempt?(stored, from: from, pane: pane)
          refuse_spent(stored, extra_attempts)
          refuse_over_budget(stored, extra_tokens)
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
        unchanged = resume_step(stored, ctx: ctx, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"], extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"],
          budget: parked["retries"].to_i.zero?)
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
      if from
        return if step_ids(run).include?(from)
        raise UsageError, "No step #{from.to_s[0, 60].inspect} in workflow #{run["workflow"]} (#{step_ids(run).join(", ")})."
      end
      return unless step_state(run).dig("gate", "state") == "waiting"
      raise Workspace::Error.new("Run #{run["id"]} is waiting at the #{run["current"]} gate. Approve or reject it, or pass --from STEP.",
        code: "gate_waiting", details: {"run_id" => run["id"], "step" => run["current"]})
    end

    # Ends a run: gives up its resources and frees its pane.
    #
    # @param run_id [String]
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      @change.call(run_id) do |stored|
        stored.replace(@attempt_record.abandon(stored).to_mutable_h)
        finish(stored, "cancelled")
        stored["cancelled_by"] = cause
        event(stored, "run_cancelled", "cause" => cause)
      end
    end

    # Ends every run of a workspace that was killed, so none of them goes on
    # holding a lock for a checkout that is gone. Never raises: a run whose
    # file is malformed is reported, and the others are still ended.
    #
    # @param workspace [String]
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and
    #   "failed", the ids of the runs that could not be
    def workspace_killed(workspace)
      result = {"cancelled" => [], "failed" => []}
      @store.active.select { |run| run["workspace"] == workspace }.each do |run|
        cancel(run["id"], cause: "kill")
        result["cancelled"] << run["id"]
      rescue
        result["failed"] << run["id"]
      end
      result
    rescue
      result
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

    # The body of {#resume}, inside a transition.
    #
    # @return [String, nil] why nothing was done, or nil; a check to run is registered on +ctx+
    def resume_step(stored, ctx:, from:, note:, pane:, turn_over:, extra_attempts: nil, extra_tokens: nil, budget: true)
      # Refusals come first, so a refused resume leaves the run and its pane as they were.
      refuse_resume(stored, from: from)
      state = step_state(stored)
      # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
      unchanged = (from || stored["budget_hold"]) ? nil : left_alone(stored, state, pane, turn_over)
      return unchanged if unchanged
      # A wait whose pane would not take the retry is held before anything is written: no rebind, note, event or reset.
      held = held_by_pane(stored, pane, from)
      return held if held
      # A pane another run has is refused first, so a refusal after this point logs nothing.
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      # Only a resume that starts an attempt is held to the budget (not a parked one typed again after a
      # busy pane: its attempt was counted then); decided before anything is written.
      starting = budget && starts_attempt?(stored, from: from, pane: pane)
      spend_attempts(stored, extra_attempts, needed: starting)
      spend_tokens(stored, extra_tokens, needed: starting)
      # A person's resume starts the sweep's retry count again, also for a retry waiting on a lock.
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      # Dropping a park replaces the run's nested Hashes.
      state = step_state(stored)
      add_resume_note(stored, note)
      held = stored.delete("budget_hold")
      drop_retry_text(stored, held) if held && from
      if held && !from
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released")
        stored["reason"] = nil
        dispatch(stored, ctx: ctx, context: held["context"], budgeted: budget)
        return nil
      end
      # A resume skips the wait of a retry; `--from` goes elsewhere and drops it.
      waiting_retry = stored.delete("backoff")
      # A stored wait that names no step to go back to is dropped; the failed step is resumed as it stands.
      waiting_retry = nil unless waiting_retry.is_a?(Hash) && waiting_retry["to"].is_a?(String)
      if waiting_retry && !from
        event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"], "backoff" => "skipped")
        start_retry(stored, waiting_retry, ctx: ctx, proven: !pane.nil?, budgeted: budget)
        return held_retry_sentence(stored)
      end
      if from
        event(stored, "run_resumed", "from" => from)
        stored["current"] = from
        dispatch(stored, ctx: ctx, budgeted: budget)
        return nil
      end
      event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"])
      stored["pending_context"].unshift(last_failure(stored)) if state["state"] == "failed" && stored.dig("reason", "code") == "failed_check"
      case state["state"]
      when "running"
        if pane
          dispatch(stored, ctx: ctx, budgeted: budget)
        else
          stored["reason"] = nil
          evaluate(stored, ctx: ctx)
        end
      when "checking" then evaluate(stored, ctx: ctx)
      when "passed" then advance(stored, ctx: ctx)
      else dispatch(stored, ctx: ctx, budgeted: budget)
      end
      nil
    end

    # `--from` goes elsewhere: the text that told the held step why it was sent back is not for the step named.
    def drop_retry_text(run, hold)
      index = hold["text"].is_a?(String) ? run["pending_context"].index(hold["text"]) : nil
      run["pending_context"].delete_at(index) if index
    end

    def starts_attempt?(run, from:, pane:) = self.class.starts_attempt?(run, from: from, pane: pane)

    # Attempts that count against the allowance: every one except those the sweep typed again.
    def attempts_made(run) = self.class.attempts_made(run)

    # The definition's `max_attempts` plus what people added with `--extra-attempts`.
    def attempt_allowance(run) = self.class.attempt_allowance(run)

    # Refuses with `attempts_spent` when the allowance is used up and +extra+ does not cover the overrun: the
    # attempt about to start must fit, so +extra+ must be at least made minus allowed plus one.
    def refuse_spent(run, extra)
      made = attempts_made(run)
      allowed = attempt_allowance(run)
      needed = self.class.extra_attempts_needed(run)
      return if made < allowed || (extra && extra >= needed)
      raise Workspace::Error.new("Run #{run["id"]} has spent max_attempts (#{made} of #{allowed}). Pass --extra-attempts #{needed} to continue.",
        code: "attempts_spent", details: {"run_id" => run["id"], "attempts" => made, "max_attempts" => allowed, "step" => run["current"], "needed" => needed})
    end

    # The budget step of a person's resume or reject: refused before anything changes; +extra+ is added to the
    # run and recorded when the action goes on.
    def spend_attempts(run, extra, needed: true)
      return unless needed
      refuse_spent(run, extra)
      return unless extra
      run["extra_attempts"] = run["extra_attempts"].to_i + extra
      event(run, "attempts_extended", "extra" => extra, "extra_attempts" => run["extra_attempts"], "max_attempts" => attempt_allowance(run))
    end

    # Refuses with `budget_spent` when the token budget is used up and +extra+ does not cover the overrun (the least
    # is used minus the allowance plus one). A run without a budget is never refused.
    def refuse_over_budget(run, extra)
      reading = WorkflowBudget.reading(run, live: false)
      return unless reading && reading["spent"]
      return if extra && extra >= reading["needed"]
      raise Workspace::Error.new("Run #{run["id"]} has used its token budget (#{reading["used"]} of #{reading["allowance"]} tokens#{" at least" if reading["uncounted"].positive?}). Pass --extra-tokens #{reading["suggested"]} to continue (#{reading["needed"]} is the least).",
        code: "budget_spent", details: WorkflowTransitions.budget_details(run, reading))
    end

    # The token step of a person's resume or reject, as {#spend_attempts} is for attempts.
    def spend_tokens(run, extra, needed: true)
      return unless needed
      refuse_over_budget(run, extra)
      return unless extra && WorkflowBudget.reading(run)
      run["extra_tokens"] = run["extra_tokens"].to_i + extra
      event(run, "budget_extended", "extra" => extra, "extra_tokens" => run["extra_tokens"], "allowance" => WorkflowBudget.reading(run, live: false)["allowance"])
    end

    # A run held by its budget types into the pane it had when the attempt would have started. As for a retry's wait,
    # that pane must still be the run's (a person's +pane+ is the proof); nothing is written, so a refusal costs nothing.
    def held_budget_pane(stored, pane)
      hold = stored["budget_hold"]
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = retry_pane_problem(stored, hold, pane: pane || @panes.pane_of(stored["id"]) || hold["pane"], proven: !pane.nil?)
      problem && problem[:message].sub(/\.\z/, "")
    end

    # The read-only decision of a resume over a retry's wait: the sentence saying why the retry can't start in the
    # pane it would use (an explicit +pane+ counts as proven), after recording the hold once; nil when it can start
    # or the run waits out no (readable) backoff.
    def held_by_pane(stored, pane, from)
      return held_budget_pane(stored, pane) if stored["budget_hold"].is_a?(Hash)
      waiting = stored["backoff"]
      return nil if from || !(waiting.is_a?(Hash) && waiting["to"].is_a?(String))
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = retry_pane_problem(stored, waiting, pane: pane, proven: !pane.nil?)
      return nil unless problem
      hold_retry(stored, waiting, problem, pane: pane || bound_pane(stored))
      held_retry_sentence(stored)
    end

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

    # A gate event carries the person's note only when one was given.
    def with_note(data, note)
      note.to_s.strip.empty? ? data : data.merge("note" => note)
    end

    def now_iso
      @clock.call.utc.iso8601
    end

    def step_ids(run)
      run["definition"]["steps"].map { |step| step["id"] }
    end

    def step_def(run, id = run["current"])
      run["definition"]["steps"].find { |step| step["id"] == id }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    # +run_id+ is the run asking, which a park of its own can't refuse; see {WorkflowDispatch#check_pane}.
    def check_pane(pane, run_id: nil) = @dispatch.check_pane(pane, run_id: run_id)

    def active?(run_id) = @store.going?(run_id)

    # The waiting gate of the run's step; with +step+ (and +attempt+), only when the
    # run is at that step (and attempt), so a stale button can't pass a later gate.
    def waiting_gate(run, step: nil, attempt: nil)
      state = step_state(run)
      gate = state["gate"]
      current = state["attempts"].last&.fetch("n", nil)
      waiting = gate && gate["state"] == "waiting"
      return gate if waiting && (step.nil? || step == run["current"]) && (attempt.nil? || attempt == current)
      message = if step
        "Run #{run["id"]} is not waiting at the gate of step #{step.to_s[0, 60]}#{", attempt #{attempt}," if attempt} " \
          "(step #{run["current"]}, attempt #{current.inspect}, is #{state["state"]}#{" and waits at its gate" if waiting}). " \
          "Read `workspace workflow status #{run["id"]}` again."
      else
        "Run #{run["id"]} is not waiting at a gate (step #{run["current"]} is #{state["state"]})."
      end
      raise Workspace::Error.new(message,
        code: "gate_not_waiting",
        details: {"run_id" => run["id"], "step" => run["current"], "attempt" => current, "state" => state["state"],
                  "expected_step" => step, "expected_attempt" => attempt})
    end

    # The note the approval is of, as {"path", "sha256"}: hashed once here, compared with
    # what the caller read when it says, and recorded as read.
    def gate_file(run, note_sha256)
      found = @gate_note.find(run)
      if note_sha256
        raise @gate_note.missing(run) unless found
        unless found["sha256"] == note_sha256
          raise Workspace::Error.new("The note #{found["path"]} changed since that revision: its sha256 is now #{found["sha256"]}. " \
            "Read it again before you approve.",
            code: "stale_revision",
            details: {"revision" => found["sha256"], "path" => found["path"], "run_id" => run["id"], "step" => run["current"],
                      "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)})
        end
      end
      found&.slice("path", "sha256")
    end

    def rebind(run, pane)
      check_pane(pane, run_id: run["id"]) unless @panes.run_on(pane) == run["id"]
      @panes.unbind(run["id"])
      run["pane"] = pane
    end

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over) = WorkflowTransitions.left_alone(run, state, pane, turn_over, @clock.call, -> { bound_pane(run) })

    # Ends an `on_fail` retry's wait: tells the target step what failed (the text kept when the step failed) and
    # starts it, as the loop would have without a backoff.
    # +proven+ is a pane the person named: that is their proof it is the right pane, so its identity is not compared
    # (it must still exist and not belong to another run).
    def start_retry(run, stored = run.delete("backoff"), ctx:, proven: false, budgeted: true)
      problem = retry_pane_problem(run, stored, proven: proven)
      return hold_retry(run, stored, problem) if problem
      to = stored["to"]
      run["pending_context"] << stored["text"] if stored["text"].is_a?(String)
      event(run, "step_retry_started", "from" => run["current"], "to" => to)
      run["current"] = to
      run["reason"] = nil
      dispatch(run, ctx: ctx, context: stored["context"], budgeted: budgeted, retry_of: stored.slice("pane", "identity", "text"))
    end

    # Why the pane a waiting retry would type into is no longer the run's: another run took it, or tmux no longer has it.
    def retry_pane_problem(run, stored, proven: false, pane: nil)
      pane ||= bound_pane(run)
      return nil unless pane
      other = @panes.run_on(pane)
      if other && other != run["id"] && active?(other)
        return {code: "pane_has_run", message: "pane #{pane} is now running workflow run #{other}. Name another agent pane with `workflow resume --pane PANE`"}
      end
      return {code: "pane_gone", message: "pane #{pane} is gone. Name another agent pane with `workflow resume --pane PANE`"} if @panes.pane_gone?(pane)
      # A pane a person named for the resume was checked then; the wait's facts are about the pane it began in.
      return nil if proven || (stored["pane"] && stored["pane"] != pane)
      return nil if @panes.same_pane?(pane, stored["identity"])
      reason = stored["identity"] ? "does not look like the pane the run was in (a tmux restart reuses pane ids, and closing a pane beside it renumbers it; it may be fine)" : "can't be shown to be the pane the run was in (it may be fine)"
      {code: "pane_changed", message: "pane #{pane} #{reason}. Name it with `--pane #{pane}` to resume in it"}
    end

    # The retry is not started and not spent: the wait is kept, marked `blocked` so a tick or the sweep leaves it,
    # and the run waits for a person. A resume (with `--pane` for another pane) starts the retry.
    def hold_retry(run, stored, problem, pane: bound_pane(run))
      # The same hold again (same code, same pane) changes nothing: no new reason, no event.
      held = run["backoff"]
      same = held.is_a?(Hash) && held["blocked"] == problem[:code] && run.dig("reason", "details", "pane") == pane &&
        run.dig("reason", "details", "error") == problem[:code]
      return if same
      run["backoff"] = stored.merge("blocked" => problem[:code])
      run["reason"] = reason((problem[:code] == "pane_gone") ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"], "error" => problem[:code],
         "message" => "the retry of step #{stored["to"]} was not started: #{problem[:message]}. Or cancel the run."})
      event(run, "step_retry_blocked", "from" => run["current"], "to" => stored["to"], "code" => problem[:code])
    end

    # Why a resume that skipped the wait still started nothing; nil when the retry started.
    def held_retry_sentence(run)
      return nil unless run.dig("backoff", "blocked")
      run.dig("reason", "details", "message").to_s.sub(/\.\z/, "")
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

    def stop_reason(stored, turn_started, code, details) = WorkflowTransitions.stop_reason(stored, turn_started, code, details, now_iso)

    # Decides a step whose turn ended. Registers the check to run on +ctx+, when the
    # step has one and nothing else already decided it.
    # A stop the daemon sees again (the same code, step and attempt) keeps its `since`, so a
    # repeat raises no second notice; a turn that began after the stop was recorded is a new stop.
    # The stored `since` is whole seconds, so a turn that began in the same second is the same stop.
    def evaluate(run, ctx:, turn_started: nil, background: [])
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      # A turn that ended on the attempt shows its line reached the agent.
      attempt.delete("delivery")
      attempt.delete("proofs")
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, {"cause" => "reported", "summary" => reported["summary"]}.merge(code_for("reported", reported["code"])), ctx: ctx)
        return
      end
      if step["guard"]
        found = guard_check(run, step)
        if found
          fail_step(run, found, ctx: ctx)
          return
        end
      end
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      strict = WorkflowProduced.strict?(run["definition"])
      found = files.to_h { |file| [file, WorkflowProduced.inspect_file(file, strict: strict)] }
      missing = files.reject { |file| found[file].exists }
      invalid = files.select { |file| found[file].exists && found[file].rule }.map { |file| {"file" => file, "rule" => found[file].rule} }
      # A file an earlier attempt left does not count: the step has to write it again.
      started = Time.iso8601(attempt["started_at"])
      stale = files.select { |file| found[file].exists && found[file].rule.nil? && found[file].mtime < started }
      if missing.any? || invalid.any? || stale.any?
        state["state"] = "running"
        run["state"] = "waiting"
        details = {"step" => step["id"], "attempt" => attempt["n"], "missing" => missing, "stale" => stale}
        details["invalid"] = invalid if invalid.any?
        run["reason"] = if background.any?
          # Every notification starts a new turn and a hold is hidden, so its `since` stays.
          stop_reason(run["reason"], nil, "turn_ended_background", details.merge("tasks" => background)).merge("seen_at" => now_iso)
        else
          stop_reason(run["reason"], turn_started, "turn_ended_incomplete", details)
        end
        return
      end
      require_and_status(run, step, state, attempt, ctx: ctx)
    end

    # What comes after the step's files: its `require:` entries from +from+ in order, then its `status:`
    # check. Registers the next thing to run outside the lock (a proof or the check) on +ctx+; none once the step is decided.
    def require_and_status(run, step, state, attempt, ctx:, from: 0)
      if step["require"].to_a.any?
        unmet = @require_check.check(run: run, step: step, attempt: attempt, from: from)
        while unmet&.key?("skipped")
          skipped = unmet["skipped"]
          (attempt["proofs"] ||= []).reject! { |each| each["skipped"] && each["index"] == skipped["index"] }
          attempt["proofs"] << skipped.merge("started_at" => now_iso, "ended_at" => now_iso)
          unmet = @require_check.check(run: run, step: step, attempt: attempt, from: skipped["index"] + 1)
        end
        if unmet&.key?("outside")
          ctx.check(start_proof(run, step, state, attempt, unmet["outside"]))
          return
        end
        if unmet
          fail_step(run, require_failure(unmet), ctx: ctx)
          return
        end
      end
      unless step["status"]
        pass_step(run, ctx: ctx)
        return
      end

      command = step["status"]["run"] || @commands_config.for_project(run["project"])[step["status"]["command"].to_sym]
      log = File.join(run["artifacts_dir"], "steps", "#{step["id"]}.#{attempt["n"]}.check.log")
      attempt["check"] = {"started_at" => now_iso, "log" => log}
      attempt["check"]["command"] = command if command
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      ctx.check({"step" => step["id"], "attempt" => attempt["n"], "command" => command, "timeout" => step["status"]["timeout"], "log" => log,
                 "cwd" => run["worktree"], "role" => step["status"]["command"]})
    end

    # A proof takes the step to `checking` like a `status:` check, so a resume, a cancel, a tick and {#wanted?}
    # treat it as one. Its record stays open (no `ended_at`) until it is applied, or a next {#evaluate} starts over.
    # A proof's {WorkflowRequire::FACTS_KEY} (what an `exec` proof read of the run under the lock) goes to {WorkflowRequire#run_outside} only.
    def start_proof(run, step, state, attempt, pending)
      (attempt["proofs"] ||= []) << pending.except(WorkflowRequire::FACTS_KEY).merge("started_at" => now_iso)
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      {"step" => step["id"], "attempt" => attempt["n"], "cwd" => run["worktree"], "proof" => pending}
    end

    # Runs what {#evaluate} handed back with the run's lock given up, and whatever comes after it: a proof can be
    # followed by another proof or the `status:` check.
    def finish_check(run_id, check)
      run = nil
      run, check = apply_check(run_id, check, run_check(run_id, check)) while check
      run
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
    end

    def run_check(run_id, check)
      stop_when = -> { !wanted?(run_id, check) }
      return @require_check.run_outside(check["proof"], cwd: check["cwd"], env: check_env(run_id), stop_when: stop_when) if check["proof"]
      return {exit_code: nil, timed_out: false, error: "the project's #{check["role"]} command is not set"} unless check["command"]
      @checker.call(command: check["command"], cwd: check["cwd"], timeout: check["timeout"], log: check["log"], stop_when: stop_when, env: check_env(run_id))
    end

    # What a `status:` check is told about its run. `WORKSPACE_RUN_BASE_SHA` is
    # empty for a run with no recorded commit (an unborn branch, or a run made before it was kept).
    # Every inherited `GIT_*` variable is removed, so a caller's `GIT_DIR`, `GIT_INDEX_FILE` or
    # `GIT_CONFIG_*` can't steer the check.
    def check_env(run_id)
      WorkflowCheck.env_for(@store.find(run_id))
    end

    # Whether the run still waits for this check: it is still on that step and
    # attempt, checking. A cancel, a kill or a `resume --from` ends that, and
    # the check is stopped instead of running on beside the lock's next holder.
    # So does a park: only a `--from` parks over a check, and that restarts the step. So does a proof run again.
    def wanted?(run_id, check)
      run = @store.find(run_id)
      state = run["steps"].fetch(check["step"])
      !run["parked"] && !WorkflowRunStore::TERMINAL_STATES.include?(run["state"]) && run["current"] == check["step"] &&
        state["state"] == "checking" && state["attempts"].last["n"] == check["attempt"] &&
        (!check["proof"] || !open_proof(state["attempts"].last, check).nil?)
    rescue Workspace::Error, SystemCallError
      true
    end

    # @return [Array] the run afterwards, and what to run next outside the lock, or nil
    def apply_check(run_id, check, result)
      following = nil
      run = @change.call(run_id) do |stored, ctx|
        next if stored["parked"]
        state = step_state(stored)
        attempt = state["attempts"].last
        # The run moved on while the check ran (a resume, a reject): its result decides nothing.
        next unless stored["current"] == check["step"] && state["state"] == "checking" && attempt["n"] == check["attempt"]
        if check["proof"]
          apply_proof(stored, attempt, check, result, ctx: ctx)
          following = ctx.check
          next
        end
        attempt["check"].merge!("ended_at" => now_iso, "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
          "error" => result[:error]).compact!
        event(stored, "check_finished", "step" => check["step"], "attempt" => check["attempt"], "exit_code" => result[:exit_code])
        if result[:exit_code] == 0
          pass_step(stored, ctx: ctx)
        else
          code = if result[:timed_out]
            "check_timed_out"
          else
            result[:error] ? "check_error" : "check_failed"
          end
          failure = {"cause" => "check", "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
                     "error" => result[:error], "log" => check["log"]}.compact.merge(code_for(code, nil))
          if code == "check_failed"
            failure = failure.merge(reported_check_code(step_def(stored)["status"], check["log"]) || {})
          end
          fail_step(stored, failure, ctx: ctx)
        end
      end
      [run, following]
    end

    # Records a proof's result; a passed one goes on to the next `require:` entry. A proof run again (a tick or a
    # resume took it for lost) has a new token, so a late result of the old run matches nothing and is dropped.
    def apply_proof(run, attempt, check, result, ctx:)
      record = open_proof(attempt, check)
      return unless record
      record.merge!(result["record"].merge("ended_at" => now_iso))
      unmet = result["unmet"]
      event(run, "proof_finished", "step" => check["step"], "attempt" => check["attempt"], "proof" => record["proof"], "passed" => unmet.nil?)
      if unmet
        fail_step(run, require_failure(unmet), ctx: ctx)
        return
      end
      require_and_status(run, step_def(run), step_state(run), attempt, ctx: ctx, from: check["proof"]["index"] + 1)
    end

    def open_proof(attempt, check)
      Array(attempt["proofs"]).find { |each| each["token"] == check["proof"]["token"] && !each.key?("ended_at") }
    end

    def pass_step(run, ctx:)
      state = step_state(run)
      state["attempts"].last.merge!("ended_at" => now_iso, "outcome" => "passed")
      state["attempts"].last.replace(@attempt_record.finish(run: run, step: step_def(run), attempt: state["attempts"].last).to_mutable_h)
      state["state"] = "passed"
      event(run, "step_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      return advance(run, ctx: ctx) unless step_def(run)["gate"]

      release(run)
      state["gate"] = {"state" => "waiting", "since" => now_iso}
      run["state"] = "waiting"
      run["reason"] = reason("waiting_you", "kind" => "gate", "step" => run["current"],
        "artifacts" => step_def(run)["produces"].map { |file| File.join(run["artifacts_dir"], file) })
      event(run, "gate_waiting", "step" => run["current"])
      true
    end

    def advance(run, ctx:)
      ids = step_ids(run)
      following = ids[ids.index(run["current"]) + 1]
      return complete(run) unless following
      run["current"] = following
      dispatch(run, ctx: ctx)
      true
    end

    def complete(run)
      finish(run, "completed")
      event(run, "run_completed")
      true
    end

    def finish(run, state)
      drop_park(run, "ended")
      run.delete("backoff")
      run.delete("budget_hold")
      release(run)
      @panes.unbind(run["id"])
      run["state"] = state
      run["reason"] = nil
      run["ended_at"] = now_iso
    end

    # A failed step goes back along its `on_fail` while it has loops left and
    # the run has attempts left; otherwise the run stops and waits for a person.
    def fail_step(run, failure, ctx:)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      attempt["ended_at"] = now_iso
      attempt["outcome"] = "failed"
      attempt["code"] = failure["code"] if failure["code"].is_a?(String)
      attempt.replace(@attempt_record.finish(run: run, step: step, attempt: attempt).to_mutable_h)
      state["state"] = "failed"
      event(run, "step_failed", {"step" => step["id"], "attempt" => attempt["n"]}.merge(failure.slice("cause", "exit_code")))
      on_fail = step["on_fail"]
      edge = on_fail && "#{step["id"]}->#{on_fail["goto"]}"
      attempts = attempts_made(run)
      spent = attempts >= attempt_allowance(run)
      # An `on_fail` `except:` code or cause never loops: the failure falls through to the stop below,
      # so a run cannot be sent into a step that cannot pass against the same facts (a stale plan's
      # revision into `plan`, a guard failure into a step guarded the same way).
      except = Array(on_fail && on_fail["except"])
      excepted = except.any? { |name| name == failure["code"] || name == failure["cause"] }
      if on_fail && !excepted && run["loops"].fetch(edge, 0) < on_fail["max"] && !spent
        run["loops"][edge] = run["loops"].fetch(edge, 0) + 1
        text = loop_context(run, step, on_fail, failure, run["loops"][edge])
        wait = WorkflowDefinition.backoff(on_fail)
        event(run, "step_looped", {"from" => step["id"], "to" => on_fail["goto"], "count" => run["loops"][edge]}.merge(wait ? {"backoff" => wait} : {}))
        return wait_to_retry(run, step, on_fail, text, wait, attempt) if wait
        run["pending_context"] << text
        run["current"] = on_fail["goto"]
        return dispatch(run, ctx: ctx, context: on_fail["context"], retry_of: {"text" => text})
      end
      release(run)
      run["state"] = "waiting"
      run["reason"] = reason("failed_check", {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                                              "attempts" => attempts, "max_attempts" => attempt_allowance(run)}.merge(failure))
    end

    # No attempt, pane binding or lock is held while the retry waits: the run reads `waiting` with the reason
    # `retry_backoff`, and the step stays `failed` until {#start_retry}.
    def wait_to_retry(run, step, on_fail, text, wait, attempt)
      release(run)
      pane = bound_pane(run)
      identity = @panes.identity(run["id"])
      @panes.unbind(run["id"])
      time = (@clock.call + wait).utc.iso8601
      run["backoff"] = {"until" => time, "to" => on_fail["goto"], "context" => on_fail["context"], "text" => text, "pane" => pane, "identity" => identity}.compact
      run["state"] = "waiting"
      run["reason"] = reason("retry_backoff", {"step" => step["id"], "attempt" => attempt["n"], "to" => on_fail["goto"], "until" => time,
                                               "seconds" => wait, "loops" => run["loops"]})
    end

    def loop_context(run, step, on_fail, failure, count)
      text = "The #{step["id"]} step failed and sent the run back to this step (time #{count} of #{on_fail["max"]}): #{failure_text(failure)}. " \
        "Its files are in #{run["artifacts_dir"]}. Fix what it found."
      lines = WorkflowDefinition.log_tail(on_fail)
      tail = (lines && failure["log"].is_a?(String)) ? @log_tail.block(failure["log"], lines: lines) : nil
      tail ? "#{text}\n\n#{tail}" : text
    end

    def require_failure(unmet) = WorkflowTransitions.require_failure(unmet)

    def guard_check(run, step)
      found = @guard.check(run["worktree"], run, step["guard"])
      note_config_change(run, step)
      return nil unless found
      {"cause" => "guard", "guard" => found["code"], "paths" => found["paths"], "base_sha" => found["base_sha"], "head" => found["head"]}
        .compact.merge(code_for(found["code"], nil))
    rescue => e
      {"cause" => "check", "error" => "the guard could not run (#{e.class})"}.merge(code_for("check_error", nil))
    end

    # A changed repository config is a warning and the step goes on. `guard_config_seen` holds the reading last
    # warned of, so each distinct change warns once, on the attempt that first saw it, whatever steps follow; a
    # config back at the base's reading clears it. It is set only once the attempt holds the warning, so one that
    # could not be recorded is tried again at the next guarded step. A warning that can't be recorded must not stop the step.
    def note_config_change(run, step)
      found = @guard.config_change(run["worktree"], run, seen: run["guard_config_seen"])
      return unless found
      return run.delete("guard_config_seen") unless found["code"]
      attempt = step_state(run)["attempts"].last
      (attempt["warnings"] ||= []) << {"code" => found["code"], "at" => now_iso, "message" => config_warning(found)}
      run["guard_config_seen"] = found["reading"]
      event(run, "guard_warning", "step" => step["id"], "attempt" => attempt["n"], "code" => found["code"], "inbox" => post_config_warning(run, step, attempt, found))
    rescue
      nil
    end

    def config_warning(found)
      return "this run started before the config was read this way, so the difference may be no change at all; the run went on" if found["old_format"]
      "#{GUARD_TEXT.fetch(found["code"])}; the run went on"
    end

    # One item per run, whatever the number of changes; a later change opens it again if it was closed. Under the run's lock, as `inbox_item` reads.
    #
    # @return [Boolean] whether the item was written
    def post_config_warning(run, step, attempt, found)
      return false unless @inbox_for
      workspace = run["workspace"]
      @inbox_for.call(workspace).upsert({
        "type" => "alert", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
        "title" => "Workflow run #{run["id"]}: the repository's config changed",
        "body" => "At step #{step["id"]} (attempt #{attempt["n"]}): #{config_warning(found)}. Check `git -C #{run["worktree"]} config --list` if you did not expect it; `workspace workflow status #{run["id"]}` lists every warning.",
        "source" => {"kind" => "workflow", "ref" => run["id"], "url" => nil},
        "dedupe_key" => "workflow-guard:#{run["id"]}:#{found["code"]}",
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"run_id" => run["id"], "step" => step["id"], "attempt" => attempt["n"]}, "expires_at" => nil, "note" => nil
      }, reopen: true)
      true
    rescue Workspace::Error, SystemCallError
      false
    end

    def code_for(engine_code, agent_code) = WorkflowTransitions.code_for(engine_code, agent_code)

    # The most of a failed check's log the `report_code` reading looks at.
    CHECK_CODE_TAIL_BYTES = 4096

    # A step whose `status:` sets `report_code: true` may name its own failure code in the log's
    # last `code: <name>` line, so a check can tell one failure from another (a plan edited during
    # review from an ordinary rejected vote). A code the engine already hands out never comes from
    # a log, and a log whose tail names none leaves the plain `check_failed` standing. The tail is
    # read as a plain file, never through a link, and nothing here raises.
    def reported_check_code(status, log)
      return nil unless status.is_a?(Hash) && status["report_code"] == true
      line = check_log_last_line(log).to_s.strip
      match = line.match(/\Acode: (\S+)\z/)
      return nil if match.nil? || ENGINE_CODES.include?(match[1])
      {"code" => match[1], "code_source" => "check"}
    end

    def check_log_last_line(log)
      return nil unless log.is_a?(String)
      file = File.lstat(log)
      return nil unless file.file?
      opened = File.open(log, "rb")
      opened.seek([0, file.size - CHECK_CODE_TAIL_BYTES].max)
      opened.read.to_s.lines.reverse.find { |each| !each.strip.empty? }
    rescue SystemCallError, IOError
      nil
    ensure
      opened&.close
    end

    GUARD_TEXT = WorkflowTransitions::GUARD_TEXT

    def failure_text(failure) = WorkflowTransitions.failure_text(failure)
  end
end
