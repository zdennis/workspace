require "fileutils"
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
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = "Read %s and follow it."

    # Restart errors that mean there is no pane to type into.
    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = (WorkflowGuard::CODES + %w[check_failed check_timed_out check_error reported]).freeze

    PANE_GONE_CODES = %w[no_such_pane pane_gone no_session wrong_session].freeze

    # Seconds after an attempt starts during which its line may still be on its
    # way: the daemon's answer to `restart_agent`, plus a minute to start it.
    DELIVERY_WINDOW = WorkflowPanes::REPLY_TIMEOUT + 60

    # Where the line that starts an attempt stands. An attempt is stored as
    # `delivering` before its line is typed, outside the run's lock, and the
    # mark is cleared once the daemon answers or a turn's end shows the agent
    # had it. A mark older than {DELIVERY_WINDOW} was left by a process that
    # died while it waited: the line may or may not have reached the agent.
    #
    # @param attempt [Hash{String=>Object}, nil] a step's last attempt
    # @param now [Time]
    # @return [Symbol, nil] :delivering, :unknown, or nil when the line was delivered or never sent
    def self.delivery(attempt, now)
      return nil unless attempt && attempt["delivery"] == "delivering"
      (now - Time.iso8601(attempt["started_at"]) > DELIVERY_WINDOW) ? :unknown : :delivering
    rescue ArgumentError, TypeError
      :unknown
    end

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
    # @param clock [#call] returns the current Time
    def initialize(store:, resources:, composer:, panes:, checker:, commands_config:, lineage:, git:, guard:, excludes:, gate_note:,
      env_stopper: nil, event_log: nil, task_store: nil, clock: -> { Time.now })
      @store = store
      @resources = resources
      @composer = composer
      @panes = panes
      @checker = checker
      @commands_config = commands_config
      @lineage = lineage
      @git = git
      @guard = guard
      @excludes = excludes
      @gate_note = gate_note
      @env_stopper = env_stopper
      @event_log = event_log
      @task_store = task_store
      @clock = clock
      @delivery = nil
    end

    # Whether a run is one only a timer will wake: it waits for a lock, or
    # its check was started and never reported back (the process running it
    # died), judged by the check's time limit plus a minute.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :lock, :check, or nil
    def self.wakeable?(run, now)
      return :lock if run.dig("reason", "code") == "waiting_lock"
      state = run["steps"].fetch(run["current"])
      return nil unless state["state"] == "checking"
      started = state["attempts"].last&.dig("check", "started_at")
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      timeout = step.dig("status", "timeout") || WorkflowDefinition::DEFAULT_CHECK_TIMEOUT
      :check if started.nil? || now - Time.iso8601(started) > timeout + 60
    end

    # Checks everything `start` would refuse, and changes nothing.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param workspace [String] the workspace the run would work in
    # @param worktree [String] that workspace's checkout
    # @param inputs [Hash{String=>String}] values for the definition's inputs
    # @param pane [String, nil] the pane id the steps would run in, when it is known
    # @param tree [String, nil] the checkout a `guard: unchanged` step would run in, which must
    #   be clean (no commit to start from, no git operation stopped, no change to a tracked
    #   file); nil skips the look
    # @param checkout [String, nil] the path of a checkout that does not exist yet (the worktree `workflow start`
    #   will have `start` make), checked for characters unsafe in shell commands like +worktree+ and +tree+
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step" (the first
    #   step), "pane", "inputs" and "packs" (the refs the first step's instructions use)
    # @raise [Workspace::Error] code `input_required` for a missing input, `usage` for an
    #   unknown one, `workflow_command_unset` when a step's check names a command the
    #   project has not set, `dirty_worktree` when +tree+ is not clean for a guarded step, `pane_has_run` when the pane already runs a workflow, and
    #   the composer's errors for a pack that can't be read
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      data = definition.to_h
      inputs = check_inputs(data, inputs)
      check_checkout_path(data, [worktree, tree, checkout].compact.uniq)
      check_notes_path(data, workspace)
      check_tree(data, tree)
      project = @lineage.resolve(cwd: worktree).name
      check_commands(data, project)
      check_pane(pane)
      first = data["steps"].first
      packs = compose({"definition" => data, "workspace" => workspace, "worktree" => worktree, "inputs" => inputs,
                       "id" => "wr_preview", "artifacts_dir" => artifacts_dir(worktree, "wr_preview")}, first, [])["packs"]
      {"workflow" => data["id"], "workspace" => workspace, "project" => project, "step" => first["id"], "pane" => pane,
       "inputs" => inputs, "packs" => packs.map { |pack| pack["ref"] }}
    end

    # Creates a run and starts its first step.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param workspace [String]
    # @param worktree [String]
    # @param inputs [Hash{String=>String}]
    # @param pane [String] the pane id the steps run in
    # @param note [String, nil] added to every step's instructions
    # @return [Hash{String=>Object}] the run after its first transition
    # @raise [Workspace::Error] see {#preflight}
    def start(definition:, workspace:, worktree:, inputs:, pane:, note: nil)
      checked = preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane)
      data = definition.to_h
      now = now_iso
      base = @guard.base(worktree)
      # Stored as waiting to be started: a `workflow run` that is interrupted before its
      # first step is under way leaves a run that says so, and that `resume` can start.
      attributes = {
        "schema_version" => 1, "workflow" => data["id"], "title" => data["title"],
        "definition" => data, "definition_source" => definition.source, "definition_path" => definition.path,
        "definition_sha256" => definition.sha256,
        "workspace" => workspace, "project" => checked["project"], "worktree" => worktree,
        "base_sha" => base["base_sha"], "base_guard" => base["base_guard"],
        "task" => task_id(workspace), "inputs" => checked["inputs"], "note" => note,
        "state" => "waiting", "created_at" => now, "started_at" => now, "ended_at" => nil,
        "current" => data["steps"].first["id"], "pane" => pane, "loops" => {}, "pending_context" => [],
        "reason" => reason("waiting_you", "kind" => "dispatch", "step" => data["steps"].first["id"], "pane" => pane, "workspace" => workspace,
          "error" => "not_started", "message" => "the run was created and its first step never started"),
        "steps" => data["steps"].to_h { |step| [step["id"], {"state" => "pending", "attempts" => []}] }
      }
      run = @store.create(attributes) { |created| created["artifacts_dir"] = artifacts_dir(worktree, created["id"]) }
      event(run, "run_started", "workflow" => data["id"], "workspace" => workspace)
      transition(run["id"]) { |stored| dispatch(stored) }
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
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil, background: [])
      check = nil
      run = transition(run_id) do |stored|
        state = step_state(stored)
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        check = evaluate(stored, turn_started: turn_started, background: background)
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
      transition(run_id) do |stored|
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
      transition(run_id) do |stored|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        file = gate_file(stored, note_sha256)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        gate["file"] = file if file
        event(stored, "gate_approved", with_note({"step" => stored["current"]}, note).merge(file ? {"sha256" => file["sha256"]} : {}))
        stored["pending_context"] << "The #{stored["current"]} step was approved with this note: #{note}" if note
        stored["pending_context"] << "The approved note is #{file["path"]}, sha256 #{file["sha256"]}." if file
        advance(stored)
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
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`; `usage` when `to` is not the gated step or
    #   one before it; and what +guard+ raises
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil)
      transition(run_id) do |stored|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil))
        event(stored, "gate_rejected", with_note({"step" => stored["current"], "to" => target}, note))
        stored["pending_context"] << "The #{stored["current"]} step was rejected at its gate: #{note}"
        stored["current"] = target
        dispatch(stored)
      end
    end

    # Gets a run that is not moving going again: asks for its lock again,
    # runs a failed or undelivered step again, looks again at a step whose
    # turn ended without its files or without the daemon seeing it, and
    # moves the run to another pane when its own is gone. A step an agent is
    # working on, and a check that is still running, are left alone.
    #
    # @param run_id [String]
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was
    #   seen to have ended its turn on that attempt, so the step, if the run is still on that
    #   attempt and it reads `running`, is decided now
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was done
    # @raise [Workspace::Error] see {#refuse_resume}
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil)
      check = nil
      unchanged = nil
      run = transition(run_id) do |stored|
        # Refusals come first, so a refused resume leaves the run and its pane as they were.
        refuse_resume(stored, from: from)
        state = step_state(stored)
        # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
        unchanged = from ? nil : left_alone(stored, state, pane, turn_over)
        next if unchanged
        rebind(stored, pane) if pane
        stored["pending_context"] << "Note from the person who resumed the run: #{note}" if note
        if from
          event(stored, "run_resumed", "from" => from)
          stored["current"] = from
          next dispatch(stored)
        end
        event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"])
        if state["state"] == "failed" && stored.dig("reason", "code") == "failed_check"
          stored["pending_context"].unshift("The last attempt of this step failed: #{failure_text(stored["reason"]["details"])}.")
        end
        case state["state"]
        when "running"
          if pane
            dispatch(stored)
          else
            stored["reason"] = nil
            check = evaluate(stored)
          end
        when "checking" then check = evaluate(stored)
        when "passed" then advance(stored)
        else dispatch(stored)
        end
      end
      run = finish_check(run_id, check) if check
      unchanged ? run.merge("unchanged" => unchanged) : run
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
      transition(run_id) do |stored|
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

    # The periodic look at a run nothing else will wake: one waiting for a
    # lock asks for it again, and a check that never reported back (its
    # process died) is run again. Does nothing while another process is
    # changing the run.
    #
    # @param run_id [String]
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      check = nil
      acted = false
      run = transition(run_id, nonblocking: true) do |stored|
        case self.class.wakeable?(stored, @clock.call)
        when :lock
          acted = true
          dispatch(stored)
        when :check
          acted = true
          check = evaluate(stored)
        end
      end
      return nil unless run && acted
      check ? finish_check(run_id, check) : run
    end

    private

    # Runs one change to a run under its lock and announces it, then types
    # the line of a step the change started, once the lock is given up.
    def transition(run_id, nonblocking: false)
      before = nil
      # The one step line this change started, if any; taken before {#deliver} runs a transition of its own.
      @delivery = nil
      run = @store.update(run_id, nonblocking: nonblocking) do |stored|
        before = fingerprint(stored)
        yield stored
        stored
      end
      delivery, @delivery = @delivery, nil
      return nil unless run
      changed(run) unless before == fingerprint(run)
      delivery ? deliver(run_id, delivery) : run
    end

    # What `workflow status` shows of a run's progress; a change in it is announced.
    def fingerprint(run)
      state = step_state(run)
      [run["state"], run["current"], run["reason"]&.except("seen_at"), state["state"], state["attempts"].size, state.dig("gate", "state")]
    end

    def changed(run)
      @event_log&.record(type: "workflow_changed", project: run["workspace"],
        data: {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "state" => run["state"],
               "step" => run["current"], "reason" => run.dig("reason", "code")})
    end

    def event(run, type, data = {})
      @store.record_event(run["id"], type, data)
    end

    # A gate event carries the person's note only when one was given.
    def with_note(data, note)
      note.to_s.strip.empty? ? data : data.merge("note" => note)
    end

    def now_iso
      @clock.call.utc.iso8601
    end

    def artifacts_dir(worktree, run_id)
      File.join(worktree, ".workflow", run_id)
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

    # A task store that can't be read costs the run its task's id, not its start.
    def task_id(workspace)
      @task_store&.active_for(workspace)&.fetch("id", nil)
    rescue Workspace::Error, EncodingError, ArgumentError
      nil
    end

    def check_inputs(data, inputs)
      inputs = (inputs || {}).transform_keys(&:to_s)
      unknown = inputs.keys - data["inputs"].keys
      if unknown.any?
        raise UsageError, "Workflow #{data["id"]} has no input #{unknown.first.to_s[0, 60].inspect} " \
          "(inputs: #{data["inputs"].keys.join(", ").then { |list| list.empty? ? "none" : list }})."
      end
      missing = data["inputs"].select { |name, spec| spec["required"] && inputs[name].to_s.strip.empty? }
      if missing.any?
        raise Workspace::Error.new("Workflow #{data["id"]} needs input #{missing.keys.join(", ")}. Pass --input #{missing.keys.first}=VALUE.",
          code: "input_required",
          details: {"workflow" => data["id"], "inputs" => missing.map { |name, spec| {"name" => name, "description" => spec["description"]} }})
      end
      check_input_patterns(data, inputs)
      data["inputs"].keys.to_h { |name| [name, inputs[name].to_s] }
    end

    INPUT_VALUE_LIMIT = 4096

    # Only a truly empty value is unset and passes; whitespace is checked like any other. A value too long, or one the pattern takes too long to judge, is a mismatch. The value is never echoed.
    def check_input_patterns(data, inputs)
      data["inputs"].each do |name, spec|
        pattern = spec["pattern"]
        value = inputs[name].to_s
        next if pattern.nil? || value.empty?
        next if value.length <= INPUT_VALUE_LIMIT && input_matches?(pattern, value)
        raise Workspace::Error.new("Input #{name} of workflow #{data["id"]} does not match its pattern #{pattern}.",
          code: "invalid_input", details: {"workflow" => data["id"], "input" => name, "pattern" => pattern})
      end
    end

    # Ruby 3.2 and later bound the match by time; older Rubies rely on the length cap alone.
    def input_matches?(pattern, value)
      source = "\\A(?:#{pattern})\\z"
      regexp = Regexp.respond_to?(:timeout) ? Regexp.new(source, timeout: 1) : Regexp.new(source)
      regexp.match?(value)
    rescue RegexpError
      false
    end

    def check_commands(data, project)
      roles = data["steps"].filter_map { |step| step.dig("status", "command") }.uniq
      return if roles.empty?
      set = @commands_config.for_project(project)
      unset = roles.reject { |role| set[role.to_sym] }
      return if unset.empty?
      raise Workspace::Error.new(
        "Workflow #{data["id"]} checks a step with the project's #{unset.join(" and ")} command, and #{project} has none. " \
        "Set it with: workspace config set commands.#{unset.first} \"COMMAND\" --name #{project}",
        code: "workflow_command_unset", details: {"workflow" => data["id"], "project" => project, "commands" => unset}
      )
    end

    def check_pane(pane)
      return unless pane
      other = @panes.run_on(pane)
      return unless other && active?(other)
      raise Workspace::Error.new("Pane #{pane} is already running workflow run #{other}. Cancel it, or pass --pane for another agent pane.",
        code: "pane_has_run", details: {"pane" => pane, "run_id" => other})
    end

    def active?(run_id)
      !WorkflowRunStore::TERMINAL_STATES.include?(@store.find(run_id)["state"])
    rescue Workspace::Error
      false
    end

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
      check_pane(pane) unless @panes.run_on(pane) == run["id"]
      @panes.unbind(run["id"])
      run["pane"] = pane
    end

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over)
      case state["state"]
      when "running"
        # Another process is still typing this attempt's line; typing it again would start the step twice.
        if !pane && self.class.delivery(state["attempts"].last, @clock.call) == :delivering
          return "step #{run["current"]}'s line is still being delivered to pane #{bound_pane(run)}"
        end
        # The turn's end counts only for the attempt it was seen on: the run may have moved on since.
        over = turn_over && turn_over["step"] == run["current"] && turn_over["attempt"] == state["attempts"].last&.fetch("n", nil)
        "an agent is working on step #{run["current"]}" unless pane || run["reason"] || over
      when "checking"
        "the check of step #{run["current"]} is still running" unless self.class.wakeable?(run, @clock.call) == :check
      end
    end

    # Starts the current step: takes its resources, writes its instructions,
    # binds the pane and stores the attempt as running and `delivering`. The
    # line that points the agent at the instructions is typed by {#deliver}
    # after the run's lock is given up, so a process that dies while the
    # daemon answers leaves an attempt a turn's end can decide.
    def dispatch(run, context: nil)
      step = step_def(run)
      state = step_state(run)
      # A rejected gate stays marked for the first run of the step again, and no longer.
      gate = state["gate"]
      state.delete("gate") unless gate && gate["state"] == "rejected" && gate["attempt"] == state["attempts"].last&.fetch("n", nil)
      run["artifacts_dir"] ||= artifacts_dir(run["worktree"], run["id"])
      # Before anything is written: a removed checkout must not come back as a directory.
      raise Workspace::Error, "the checkout #{run["worktree"]} is gone" unless File.directory?(run["worktree"])
      pane = bound_pane(run)
      # A binding made for another pane (a tmux restart reuses pane ids) is not typed into.
      if @panes.pane_of(run["id"]) && !@panes.alive?(run["id"])
        return not_delivered(run, state, nil, {code: "pane_gone", message: "pane #{pane} is no longer the pane the run was bound in"})
      end
      waiting = acquire(run, step, pane)
      return wait_for_lock(run, state, waiting) if waiting

      # To the millisecond: the end of a turn is matched to the attempt by when that turn began.
      attempt = {"n" => state["attempts"].size + 1, "started_at" => @clock.call.utc.iso8601(3), "context" => run["pending_context"],
                 "delivery" => "delivering"}
      run["pending_context"] = []
      attempt["prompt_file"] = write_prompt(run, step, attempt)
      state["attempts"] << attempt
      @panes.bind(workspace: run["workspace"], pane: pane, run_id: run["id"], step: step["id"], attempt: attempt["n"],
        instructions: attempt["prompt_file"], artifacts: run["artifacts_dir"])
      run["pane"] = pane
      state["state"] = "running"
      run["state"] = "running"
      run["reason"] = nil
      event(run, "step_dispatching", "step" => step["id"], "attempt" => attempt["n"], "pane" => pane)
      @delivery = {"step" => step["id"], "attempt" => attempt["n"], "workspace" => run["workspace"], "pane" => pane,
                   "text" => format(KICK, attempt["prompt_file"]), "fresh" => (context || step["context"]) == "fresh"}
    rescue Workspace::Error, SystemCallError, EncodingError => e
      # The step could not be started (no pane, an unreadable pack, a checkout that is gone, text that can't be written as UTF-8).
      not_delivered(run, state, attempt, {code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.strip})
    end

    # Types the line of an attempt {#dispatch} stored, then records the
    # daemon's answer under the run's lock, if the run is still on that
    # attempt and nothing else (a turn's end, a cancel, a resume) has
    # settled it meanwhile. A line that could not be typed makes the run wait
    # as before; a late answer for an attempt already settled changes nothing.
    def deliver(run_id, delivery)
      kick = begin
        @panes.kick(workspace: delivery["workspace"], pane: delivery["pane"], text: delivery["text"], fresh: delivery["fresh"])
      rescue => e
        # Whatever went wrong, the mark is settled here: left set, it would hold off `resume` for nothing.
        {ok: false, code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.scrub.strip}
      end
      @store.record_event(run_id, "step_dispatched", "step" => delivery["step"], "attempt" => delivery["attempt"],
        "pane" => delivery["pane"], "delivered" => kick[:ok])
      transition(run_id) do |stored|
        state = stored["steps"].fetch(delivery["step"])
        attempt = state["attempts"].last
        next unless stored["current"] == delivery["step"] && attempt["n"] == delivery["attempt"] && attempt["delivery"] == "delivering"
        attempt.delete("delivery")
        not_delivered(stored, state, attempt, kick) unless kick[:ok]
      end
    rescue Workspace::Error => e
      # Cancelled while the line was on its way: the cancel stands.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
    end

    def not_delivered(run, state, attempt, kick)
      attempt&.delete("delivery")
      attempt&.merge!("ended_at" => now_iso, "outcome" => "not_delivered")
      # The next attempt is told what this one would have been.
      run["pending_context"] = attempt["context"] + run["pending_context"] if attempt
      release(run)
      state["state"] = "waiting"
      run["state"] = "waiting"
      gone = PANE_GONE_CODES.include?(kick[:code].to_s)
      run["reason"] = reason(gone ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => run["pane"], "workspace" => run["workspace"],
         "error" => kick[:code].to_s, "message" => kick[:message]&.to_s&.scrub}.compact)
    end

    # @return [Hash, nil] the lock the run has to wait for; nil when it holds everything the step uses
    def acquire(run, step, pane)
      result = @resources.acquire(run_id: run["id"], step: step["id"], uses: step["uses"], worktree: run["worktree"],
        workflow: run["workflow"], workspace: run["workspace"], pane: pane)
      raise Workspace::Error, "run #{run["id"]} has no run file, so it can hold no lock" if result[:status] == :not_alive
      waited = (run.dig("reason", "code") == "waiting_lock") ? run["reason"] : nil
      result[:released].each { |name| lock_event(run, "lock_released", name) }
      result[:acquired].each do |name|
        was_waiting = waited && waited.dig("details", "resource") == name
        lock_event(run, "lock_acquired", name, was_waiting ? {"waited_seconds" => (@clock.call - Time.iso8601(waited["since"])).round} : {})
      end
      stop_environment(run) if result[:handed_over].include?(DevRunner::LOCK_NAME)
      waiting = result[:waiting]
      return nil unless waiting
      unless waited && waited.dig("details", "resource") == waiting[:name]
        lock_event(run, "lock_wait_started", waiting[:name], "position" => waiting[:position],
          "holder" => waiting[:holder]&.slice("pane", "pid", "worktree", "task", "run_id", "step")&.compact)
      end
      waiting
    end

    # An environment that can't be stopped keeps the lock, as `dev down`
    # leaves it; the step goes on with the locks it has.
    def stop_environment(run)
      @env_stopper&.call(run_id: run["id"], worktree: run["worktree"])
    rescue Workspace::Error, SystemCallError
      nil
    end

    def wait_for_lock(run, state, waiting)
      holder = waiting[:holder] || {}
      details = {"resource" => waiting[:name], "step" => run["current"], "position" => waiting[:position], "total" => waiting[:total],
                 "holder" => {"run_id" => holder["run_id"], "step" => holder["step"], "workspace" => holder["workspace"],
                              "worktree" => holder["worktree"], "pid" => holder["pid"], "kind" => holder["kind"]}.compact}
      since = (run.dig("reason", "code") == "waiting_lock" && run.dig("reason", "details", "resource") == waiting[:name]) ? run["reason"]["since"] : now_iso
      state["state"] = "waiting"
      run["state"] = "waiting"
      run["reason"] = {"code" => "waiting_lock", "since" => since, "details" => details}
    end

    def lock_event(run, type, name, data = {})
      @event_log&.record(type: type, project: run["project"],
        data: {"lock" => name, "run_id" => run["id"], "step" => run["current"], "workspace" => run["workspace"]}.merge(data))
    end

    # Gives up everything the run holds. A checkout that is gone can't name
    # its lock store; the store drops a finished run's holds by itself.
    def release(run)
      @resources.release(run_id: run["id"], worktree: run["worktree"]).each { |name| lock_event(run, "lock_released", name) }
    rescue Workspace::Error, SystemCallError
      nil
    end

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end

    def stop_reason(stored, turn_started, code, details)
      fresh = reason(code, details)
      return fresh unless stored && stored["code"] == code && stored["since"]
      return fresh unless %w[step attempt].all? { |key| stored.dig("details", key) == details[key] }
      return fresh if turn_started && turn_started.to_i > Time.iso8601(stored["since"]).to_i
      fresh.merge("since" => stored["since"])
    end

    def values(run)
      branch = begin
        @git.worktree_branch(run["worktree"])
      rescue Workspace::Error, SystemCallError
        nil
      end
      {"workspace" => run["workspace"], "branch" => branch.to_s, "artifacts" => run["artifacts_dir"], "run" => run["id"]}
        .merge(run["inputs"].transform_keys { |name| "inputs.#{name}" })
    end

    def compose(run, step, context, binding: nil)
      data = run["definition"]
      filled = values(run)
      context = context.dup
      context.unshift("Note for this run: #{run["note"]}") if run["note"]
      @composer.compose(
        packs: nil, cwd: run["worktree"], binding: binding, skip: step["uses"].to_a.include?("devenv") ? ["dev"] : [],
        workflow: {"name" => data["id"], "include" => data["include"],
                   "text" => data["instructions"] && WorkflowDefinition.render(data["instructions"], filled)},
        step: {"name" => step["id"], "include" => step["include"], "text" => step_text(run, step, filled)},
        attempt: context
      )
    rescue EncodingError, ArgumentError => e
      # Text that is not UTF-8 met text that is (a pack read with no UTF-8 locale, a checkout under
      # such a path): an encoding error, or the "invalid byte sequence" a string method raises.
      raise unless e.is_a?(EncodingError) || e.message.include?("invalid byte sequence")
      raise Workspace::Error, "the step's instructions could not be put together: a pack, a prompt or a path is not UTF-8 text (#{e.class})"
    end

    # The prompt, then what the runner looks at when the turn ends.
    def step_text(run, step, filled)
      text = WorkflowDefinition.render(step["prompt"], filled).strip
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      text += "\n\nThis step is finished when your turn ends and these files exist, written during this attempt: #{files.join(", ")}." if files.any?
      text += "\n\nWhen your turn ends, the runner checks the step with the project's own command; work until it would pass." if step["status"]
      text
    end

    def write_prompt(run, step, attempt)
      dir = File.join(run["artifacts_dir"], "steps")
      FileUtils.mkdir_p(dir)
      @excludes.add(run["worktree"], "/.workflow/")
      path = File.join(dir, "#{step["id"]}.#{attempt["n"]}.prompt.md")
      binding = {"kind" => "run", "id" => run["id"], "workspace" => run["workspace"], "step" => step["id"], "attempt" => attempt["n"],
                 "instructions" => path, "artifacts" => run["artifacts_dir"]}
      File.write(path, compose(run, step, attempt["context"], binding: binding)["text"], encoding: Encoding::UTF_8)
      path
    end

    # Decides a step whose turn ended. Returns the check to run, when the
    # step has one and nothing else already decided it.
    # A stop the daemon sees again (the same code, step and attempt) keeps its `since`, so a
    # repeat raises no second notice; a turn that began after the stop was recorded is a new stop.
    # The stored `since` is whole seconds, so a turn that began in the same second is the same stop.
    def evaluate(run, turn_started: nil, background: [])
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      # A turn that ended on the attempt shows its line reached the agent.
      attempt.delete("delivery")
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, {"cause" => "reported", "summary" => reported["summary"]}.merge(code_for("reported", reported["code"])))
        return nil
      end
      if step["guard"]
        found = guard_check(run, step)
        if found
          fail_step(run, found)
          return nil
        end
      end
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      missing = files.reject { |file| File.exist?(file) }
      # A file an earlier attempt left does not count: the step has to write it again.
      started = Time.iso8601(attempt["started_at"])
      stale = (files - missing).select { |file| File.mtime(file) < started }
      if missing.any? || stale.any?
        state["state"] = "running"
        run["state"] = "waiting"
        details = {"step" => step["id"], "attempt" => attempt["n"], "missing" => missing, "stale" => stale}
        run["reason"] = if background.any?
          # Every notification starts a new turn and a hold is hidden, so its `since` stays.
          stop_reason(run["reason"], nil, "turn_ended_background", details.merge("tasks" => background)).merge("seen_at" => now_iso)
        else
          stop_reason(run["reason"], turn_started, "turn_ended_incomplete", details)
        end
        return nil
      end
      unless step["status"]
        pass_step(run)
        return nil
      end

      command = step["status"]["run"] || @commands_config.for_project(run["project"])[step["status"]["command"].to_sym]
      log = File.join(run["artifacts_dir"], "steps", "#{step["id"]}.#{attempt["n"]}.check.log")
      attempt["check"] = {"started_at" => now_iso, "log" => log}
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      {"step" => step["id"], "attempt" => attempt["n"], "command" => command, "timeout" => step["status"]["timeout"], "log" => log,
       "cwd" => run["worktree"], "role" => step["status"]["command"]}
    end

    def finish_check(run_id, check)
      result = if check["command"]
        @checker.call(command: check["command"], cwd: check["cwd"], timeout: check["timeout"], log: check["log"],
          stop_when: -> { !wanted?(run_id, check) }, env: check_env(run_id))
      else
        {exit_code: nil, timed_out: false, error: "the project's #{check["role"]} command is not set"}
      end
      apply_check(run_id, check, result)
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
    end

    # What a `status:` check is told about its run. `WORKSPACE_RUN_BASE_SHA` is
    # empty for a run with no recorded commit (an unborn branch, or a run made before it was kept).
    # Every inherited `GIT_*` variable is removed, so a caller's `GIT_DIR`, `GIT_INDEX_FILE` or
    # `GIT_CONFIG_*` can't steer the check.
    def check_env(run_id)
      run = @store.find(run_id)
      ENV.keys.select { |name| name.start_with?("GIT_") }.to_h { |name| [name, nil] }.merge(
        "WORKSPACE_RUN_ID" => run["id"], "WORKSPACE_RUN_ARTIFACTS" => run["artifacts_dir"].to_s,
        "WORKSPACE_RUN_BASE_SHA" => run["base_sha"].to_s
      )
    end

    # The steps' prompts hand the agent shell commands that hold the run's artifacts path
    # (under the checkout) and the gate note's path (under the notes directory), so a path that
    # can end a quote or start a substitution is refused. Only the names of the characters are
    # reported, never the path. +what+ says which path it is.
    def check_checkout_path(data, paths, what: "checkout")
      paths.each do |path|
        found = ShellSafePath.unsafe_characters(path)
        next if found.empty?
        raise Workspace::Error.new(
          "Workflow #{data["id"]} can't run with a #{what} whose path holds #{found.join(", ")}: its instructions put the path in shell commands. " \
          "Use a #{what} whose path has none of them.",
          code: "unsafe_checkout_path", details: {"workflow" => data["id"], "characters" => found, "path_kind" => what}
        )
      end
    end

    # The notes directory is read only for a workflow with a gate, whose note the fix step is
    # handed the path of; one that can't be found yet (a worktree not made) is left to the gate.
    def check_notes_path(data, workspace)
      return unless data["steps"].any? { |step| step["gate"] }
      dir = @gate_note.notes_dir_of(workspace)
      check_checkout_path(data, [dir].compact, what: "notes directory")
    end

    # A definition with a `guard: unchanged` step starts from a clean checkout: a commit to
    # start from, no stopped git operation, no change to a tracked file.
    def check_tree(data, tree)
      return unless tree && data["steps"].any? { |step| step["guard"] == "unchanged" }
      found = @guard.check(tree, @guard.base(tree), "unchanged")
      return unless found
      raise Workspace::Error.new(
        "Workflow #{data["id"]} needs a clean checkout, and #{tree} is not (#{GUARD_TEXT[found["code"]] || "tracked files changed: #{found["paths"].join(", ")}"}). " \
        "Commit or stash the changes, or finish the git operation, first.",
        code: "dirty_worktree", details: {"path" => tree, "guard" => found["code"], "files" => found["paths"]}
      )
    end

    # Whether the run still waits for this check: it is still on that step and
    # attempt, checking. A cancel, a kill or a `resume --from` ends that, and
    # the check is stopped instead of running on beside the lock's next holder.
    def wanted?(run_id, check)
      run = @store.find(run_id)
      state = run["steps"].fetch(check["step"])
      !WorkflowRunStore::TERMINAL_STATES.include?(run["state"]) && run["current"] == check["step"] &&
        state["state"] == "checking" && state["attempts"].last["n"] == check["attempt"]
    rescue Workspace::Error, SystemCallError
      true
    end

    def apply_check(run_id, check, result)
      transition(run_id) do |stored|
        state = step_state(stored)
        attempt = state["attempts"].last
        # The run moved on while the check ran (a resume, a reject): its result decides nothing.
        next unless stored["current"] == check["step"] && state["state"] == "checking" && attempt["n"] == check["attempt"]
        attempt["check"].merge!("ended_at" => now_iso, "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
          "error" => result[:error]).compact!
        event(stored, "check_finished", "step" => check["step"], "attempt" => check["attempt"], "exit_code" => result[:exit_code])
        if result[:exit_code] == 0
          pass_step(stored)
        else
          code = if result[:timed_out]
            "check_timed_out"
          else
            result[:error] ? "check_error" : "check_failed"
          end
          fail_step(stored, {"cause" => "check", "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
                             "error" => result[:error], "log" => check["log"]}.compact.merge(code_for(code, nil)))
        end
      end
    end

    def pass_step(run)
      state = step_state(run)
      state["attempts"].last.merge!("ended_at" => now_iso, "outcome" => "passed")
      state["state"] = "passed"
      event(run, "step_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      return advance(run) unless step_def(run)["gate"]

      release(run)
      state["gate"] = {"state" => "waiting", "since" => now_iso}
      run["state"] = "waiting"
      run["reason"] = reason("waiting_you", "kind" => "gate", "step" => run["current"],
        "artifacts" => step_def(run)["produces"].map { |file| File.join(run["artifacts_dir"], file) })
      event(run, "gate_waiting", "step" => run["current"])
      true
    end

    def advance(run)
      ids = step_ids(run)
      following = ids[ids.index(run["current"]) + 1]
      return complete(run) unless following
      run["current"] = following
      dispatch(run)
      true
    end

    def complete(run)
      finish(run, "completed")
      event(run, "run_completed")
      true
    end

    def finish(run, state)
      release(run)
      @panes.unbind(run["id"])
      run["state"] = state
      run["reason"] = nil
      run["ended_at"] = now_iso
    end

    # A failed step goes back along its `on_fail` while it has loops left and
    # the run has attempts left; otherwise the run stops and waits for a person.
    def fail_step(run, failure)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      attempt["ended_at"] = now_iso
      attempt["outcome"] = "failed"
      state["state"] = "failed"
      event(run, "step_failed", {"step" => step["id"], "attempt" => attempt["n"]}.merge(failure.slice("cause", "exit_code")))
      on_fail = step["on_fail"]
      edge = on_fail && "#{step["id"]}->#{on_fail["goto"]}"
      attempts = run["steps"].values.sum { |each| each["attempts"].size }
      spent = attempts >= run["definition"]["max_attempts"]
      if on_fail && run["loops"].fetch(edge, 0) < on_fail["max"] && !spent
        run["loops"][edge] = run["loops"].fetch(edge, 0) + 1
        run["pending_context"] << loop_context(run, step, on_fail, failure, run["loops"][edge])
        event(run, "step_looped", "from" => step["id"], "to" => on_fail["goto"], "count" => run["loops"][edge])
        run["current"] = on_fail["goto"]
        return dispatch(run, context: on_fail["context"])
      end
      release(run)
      run["state"] = "waiting"
      run["reason"] = reason("failed_check", {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                                              "attempts" => attempts, "max_attempts" => run["definition"]["max_attempts"]}.merge(failure))
    end

    def loop_context(run, step, on_fail, failure, count)
      "The #{step["id"]} step failed and sent the run back to this step (time #{count} of #{on_fail["max"]}): #{failure_text(failure)}. " \
        "Its files are in #{run["artifacts_dir"]}. Fix what it found."
    end

    def guard_check(run, step)
      found = @guard.check(run["worktree"], run, step["guard"])
      return nil unless found
      {"cause" => "guard", "guard" => found["code"], "paths" => found["paths"], "base_sha" => found["base_sha"], "head" => found["head"]}
        .compact.merge(code_for(found["code"], nil))
    rescue => e
      {"cause" => "check", "error" => "the guard could not run (#{e.class})"}.merge(code_for("check_error", nil))
    end

    # The one code key of a failed step: an agent's word when it gave one, else the engine's.
    def code_for(engine_code, agent_code)
      agent_code ? {"code" => agent_code, "code_source" => "agent"} : {"code" => engine_code, "code_source" => "engine"}
    end

    GUARD_TEXT = {
      "no_commit" => "the checkout had no commit to start from",
      "operation_in_progress" => "a git operation (merge, rebase, cherry-pick, revert or bisect) is in progress",
      "config_changed" => "the repository's config or attributes changed since the run started",
      "hooks_changed" => "the repository's hooks changed since the run started",
      "hidden_changed" => "tracked files were hidden from git (assume-unchanged or skip-worktree) since the run started"
    }.freeze

    def failure_text(failure)
      if failure["cause"] == "guard"
        case failure["guard"]
        when "head_moved" then "HEAD moved from #{failure["base_sha"].to_s[0, 12]} to #{failure["head"].to_s[0, 12]} since the run started"
        when "tracked_changed" then "tracked files changed since the run started (#{Array(failure["paths"]).join(", ")})"
        else GUARD_TEXT.fetch(failure["guard"], "the guard failed (#{failure["guard"]})")
        end
      elsif failure["cause"] == "reported"
        "its agent reported failure#{": #{failure["summary"]}" if failure["summary"]}"
      elsif failure["timed_out"]
        "its check ran past its time limit (log: #{failure["log"]})"
      elsif failure["error"]
        "its check could not be run (#{failure["error"]})"
      else
        "its check exited #{failure["exit_code"].inspect} (log: #{failure["log"]})"
      end
    end
  end
end
