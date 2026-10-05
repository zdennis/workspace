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
  # `waiting_lock`, `waiting_you`, `turn_ended_incomplete` and
  # `failed_check`. {WorkflowStatus} adds `pane_gone`, which is read from
  # tmux rather than stored. The one case with no reason is a turn that
  # ended without the daemon seeing it (an interrupted turn, a daemon that
  # was down): the step still reads `running`, {WorkflowStatus} flags it
  # `idle`, and {#resume} looks at it.
  #
  # Resources a step `uses:` are held by the run, taken before the step's
  # prompt is typed and given up at a gate, on a failure that stops the run,
  # and at the end.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = "Read %s and follow it."

    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = %w[no_such_pane pane_gone no_session wrong_session].freeze

    # @param store [Workspace::WorkflowRunStore]
    # @param resources [Workspace::RunResources] holds each step's `uses:` for the run
    # @param composer [Workspace::InstructionComposer] builds a step's instructions
    # @param panes [Workspace::WorkflowPanes] binds, finds and types into the run's pane
    # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param lineage [Workspace::WorkspaceLineage] names a checkout's parent project
    # @param git [Workspace::Git] reads the checkout's branch
    # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
    # @param env_stopper [#call, nil] stops the dev environment a run left running under a lock it
    #   gave up (`run_id:`, `worktree:`), so nobody queues behind an environment no step uses
    # @param event_log [Workspace::EventLog, nil] gets `workflow_changed` and the run's lock events
    # @param task_store [Workspace::TaskStore, nil] names the workspace's task in the run
    # @param clock [#call] returns the current Time
    def initialize(store:, resources:, composer:, panes:, checker:, commands_config:, lineage:, git:, excludes:,
      env_stopper: nil, event_log: nil, task_store: nil, clock: -> { Time.now })
      @store = store
      @resources = resources
      @composer = composer
      @panes = panes
      @checker = checker
      @commands_config = commands_config
      @lineage = lineage
      @git = git
      @excludes = excludes
      @env_stopper = env_stopper
      @event_log = event_log
      @task_store = task_store
      @clock = clock
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
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step" (the first
    #   step), "pane", "inputs" and "packs" (the refs the first step's instructions use)
    # @raise [Workspace::Error] code `input_required` for a missing input, `usage` for an
    #   unknown one, `workflow_command_unset` when a step's check names a command the
    #   project has not set, `pane_has_run` when the pane already runs a workflow, and
    #   the composer's errors for a pack that can't be read
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil)
      data = definition.to_h
      inputs = check_inputs(data, inputs)
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
      # Stored as waiting to be started: a `workflow run` that is interrupted before its
      # first step is under way leaves a run that says so, and that `resume` can start.
      attributes = {
        "schema_version" => 1, "workflow" => data["id"], "title" => data["title"],
        "definition" => data, "definition_source" => definition.source, "definition_path" => definition.path,
        "definition_sha256" => definition.sha256,
        "workspace" => workspace, "project" => checked["project"], "worktree" => worktree,
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
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil)
      check = nil
      run = transition(run_id) do |stored|
        state = step_state(stored)
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        check = evaluate(stored)
      end
      check ? finish_check(run_id, check) : run
    end

    # Records what the agent says about its current attempt. Nothing moves
    # until the turn ends.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported" (the stored
    #   report: "status", "summary", "at")
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil)
      result = nil
      transition(run_id) do |stored|
        state = step_state(stored)
        unless %w[running checking].include?(state["state"])
          raise Workspace::Error.new("Step #{stored["current"]} of run #{run_id} is #{state["state"]}, so there is nothing to report on.",
            code: "step_not_running", details: {"run_id" => run_id, "step" => stored["current"], "state" => state["state"]})
        end
        attempt = state["attempts"].last
        attempt["reported"] = {"status" => status, "summary" => summary, "at" => now_iso}
        event(stored, "step_reported", "step" => stored["current"], "attempt" => attempt["n"], "status" => status)
        result = {"run_id" => run_id, "step" => stored["current"], "attempt" => attempt["n"], "reported" => attempt["reported"]}
      end
      result
    end

    # Passes a gate: the run goes on to the step after the gated one.
    #
    # @param run_id [String]
    # @param note [String, nil] added to the next step's instructions
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting` when the run is not at a gate
    def approve(run_id, note: nil)
      transition(run_id) do |stored|
        gate = waiting_gate(stored)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        event(stored, "gate_approved", "step" => stored["current"])
        stored["pending_context"] << "The #{stored["current"]} step was approved with this note: #{note}" if note
        advance(stored)
      end
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note.
    #
    # @param run_id [String]
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`; `usage` when `to` is not the gated step or one before it
    def reject(run_id, note:, to: nil)
      transition(run_id) do |stored|
        gate = waiting_gate(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note)
        event(stored, "gate_rejected", "step" => stored["current"], "to" => target)
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
        when "running" then pane ? dispatch(stored) : (check = evaluate(stored))
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

    # Runs one change to a run under its lock and announces it.
    def transition(run_id, nonblocking: false)
      before = nil
      run = @store.update(run_id, nonblocking: nonblocking) do |stored|
        before = fingerprint(stored)
        yield stored
        stored
      end
      return nil unless run
      changed(run) unless before == fingerprint(run)
      run
    end

    # What `workflow status` shows of a run's progress; a change in it is announced.
    def fingerprint(run)
      state = step_state(run)
      [run["state"], run["current"], run["reason"], state["state"], state["attempts"].size, state.dig("gate", "state")]
    end

    def changed(run)
      @event_log&.record(type: "workflow_changed", project: run["workspace"],
        data: {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "state" => run["state"],
               "step" => run["current"], "reason" => run.dig("reason", "code")})
    end

    def event(run, type, data = {})
      @store.record_event(run["id"], type, data)
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
      data["inputs"].keys.to_h { |name| [name, inputs[name].to_s] }
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

    def waiting_gate(run)
      gate = step_state(run)["gate"]
      return gate if gate && gate["state"] == "waiting"
      raise Workspace::Error.new("Run #{run["id"]} is not waiting at a gate (step #{run["current"]} is #{step_state(run)["state"]}).",
        code: "gate_not_waiting", details: {"run_id" => run["id"], "step" => run["current"], "state" => step_state(run)["state"]})
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
        # The turn's end counts only for the attempt it was seen on: the run may have moved on since.
        over = turn_over && turn_over["step"] == run["current"] && turn_over["attempt"] == state["attempts"].last&.fetch("n", nil)
        "an agent is working on step #{run["current"]}" unless pane || run["reason"] || over
      when "checking"
        "the check of step #{run["current"]} is still running" unless self.class.wakeable?(run, @clock.call) == :check
      end
    end

    # Starts the current step: takes its resources, writes its instructions,
    # binds the pane and types the one line that points the agent at them.
    def dispatch(run, context: nil)
      step = step_def(run)
      state = step_state(run)
      state.delete("gate")
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
      attempt = {"n" => state["attempts"].size + 1, "started_at" => @clock.call.utc.iso8601(3), "context" => run["pending_context"]}
      run["pending_context"] = []
      attempt["prompt_file"] = write_prompt(run, step, attempt)
      state["attempts"] << attempt
      @panes.bind(workspace: run["workspace"], pane: pane, run_id: run["id"], step: step["id"], attempt: attempt["n"],
        instructions: attempt["prompt_file"], artifacts: run["artifacts_dir"])
      run["pane"] = pane
      kick = @panes.kick(workspace: run["workspace"], pane: pane, text: format(KICK, attempt["prompt_file"]),
        fresh: (context || step["context"]) == "fresh")
      event(run, "step_dispatched", "step" => step["id"], "attempt" => attempt["n"], "pane" => pane, "delivered" => kick[:ok])
      return not_delivered(run, state, attempt, kick) unless kick[:ok]
      state["state"] = "running"
      run["state"] = "running"
      run["reason"] = nil
    rescue Workspace::Error, SystemCallError, EncodingError => e
      # The step could not be started (no pane, an unreadable pack, a checkout that is gone, text that can't be written as UTF-8).
      not_delivered(run, state, attempt, {code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.strip})
    end

    def not_delivered(run, state, attempt, kick)
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
        packs: nil, cwd: run["worktree"], binding: binding,
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
    def evaluate(run)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, "cause" => "reported", "summary" => reported["summary"])
        return nil
      end
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      missing = files.reject { |file| File.exist?(file) }
      # A file an earlier attempt left does not count: the step has to write it again.
      started = Time.iso8601(attempt["started_at"])
      stale = (files - missing).select { |file| File.mtime(file) < started }
      if missing.any? || stale.any?
        state["state"] = "running"
        run["state"] = "waiting"
        run["reason"] = reason("turn_ended_incomplete", "step" => step["id"], "attempt" => attempt["n"], "missing" => missing, "stale" => stale)
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
          stop_when: -> { !wanted?(run_id, check) })
      else
        {exit_code: nil, timed_out: false, error: "the project's #{check["role"]} command is not set"}
      end
      apply_check(run_id, check, result)
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
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
          fail_step(stored, {"cause" => "check", "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
                             "error" => result[:error], "log" => check["log"]}.compact)
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

    def failure_text(failure)
      if failure["cause"] == "reported"
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
