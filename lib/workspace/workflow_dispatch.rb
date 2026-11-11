require "securerandom"
require "time"

module Workspace
  # Starts a run's current step and types its line: {#dispatch} takes the step's resources, writes its
  # instructions, binds the pane and stores the attempt as `delivering` inside the run's lock; {#deliver}
  # types the line after the lock is given up and records the answer, parking a released resume again when
  # the pane was only busy. A run whose token budget is used up is held before the attempt. {#check_pane}
  # says whether another run holds a pane, through the store's occupancy queries.
  class WorkflowDispatch
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = "Read %s and follow it."

    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = %w[no_such_pane pane_gone no_session wrong_session].freeze

    # How many times a released resume that could not be typed is parked again.
    # Each failed delivery is an attempt, and attempts count against `max_attempts`.
    PARK_RETRIES = 3

    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = %w[pane_busy restart_in_progress].freeze

    # @param change [Workspace::WorkflowRunChange] changes a run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] answers which run holds a pane, and gets the delivery's history line
    # @param resources [Workspace::RunResources] holds each step's `uses:` for the run
    # @param panes [Workspace::WorkflowPanes] binds, finds and types into the run's pane
    # @param prompt [Workspace::WorkflowPrompt] writes a step's instructions
    # @param attempt_record [Workspace::WorkflowAttemptRecord] records what each attempt started from
    # @param guard [Workspace::WorkflowGuard] reads the remote a `remote_unchanged` proof compares with
    # @param env_stopper [#call, nil] stops the dev environment a run left running under a lock it gave up
    #   (`run_id:`, `worktree:`)
    # @param event_log [Workspace::EventLog, nil] gets the run's lock events
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, resources:, panes:, prompt:, attempt_record:, guard:, env_stopper: nil, event_log: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @resources = resources
      @panes = panes
      @prompt = prompt
      @attempt_record = attempt_record
      @guard = guard
      @env_stopper = env_stopper
      @event_log = event_log
      @clock = clock
    end

    # Starts the run's current step: takes its resources, writes its instructions, binds the pane and stores
    # the attempt as running and `delivering`, and registers the line to type on +ctx+. The line is typed by
    # {#deliver} after the run's lock is given up, so a process that dies while the daemon answers leaves an
    # attempt a turn's end can decide. A step that can't start leaves the run waiting with the reason why.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the step to start; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context, which gets the line to type
    # @param context [String, nil] the step's `context` for this attempt (`fresh` starts a new conversation)
    # @param budgeted [Boolean] false starts the attempt even when the token budget is used up
    # @param retry_of [Hash{String=>Object}, nil] the retry's "pane", "identity" and "text", kept by a budget hold
    # @return [WorkflowRun] the run afterwards
    def dispatch(run, ctx:, context: nil, budgeted: true, retry_of: nil)
      work = WorkflowRun.from_h(run).to_mutable_h
      start_attempt(work, ctx: ctx, context: context, budgeted: budgeted, retry_of: retry_of)
      WorkflowRun.from_h(work)
    end

    # Types the line of an attempt {#dispatch} stored, then records the daemon's answer under the run's lock,
    # if the run is still on that attempt and nothing else (a turn's end, a cancel, a resume) has settled it
    # meanwhile. A line that could not be typed makes the run wait as before; a late answer for an attempt
    # already settled changes nothing.
    #
    # @param run_id [String]
    # @param delivery [Hash{String=>Object}] the line {#dispatch} registered
    # @return [WorkflowRun] the run afterwards; as stored when it was cancelled while the line was on its way
    # @raise [Workspace::Error] code `unknown_run`
    def deliver(run_id, delivery)
      record_remote(run_id, delivery) if delivery["remote_baseline"]
      kick = begin
        @panes.kick(workspace: delivery["workspace"], pane: delivery["pane"], text: delivery["text"], fresh: delivery["fresh"], run_id: run_id)
      rescue => e
        # Whatever went wrong, the mark is settled here: left set, it would hold off `resume` for nothing.
        {ok: false, code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.scrub.strip}
      end
      @store.record_event(run_id, "step_dispatched", "step" => delivery["step"], "attempt" => delivery["attempt"],
        "pane" => delivery["pane"], "delivered" => kick[:ok], **kick.slice(:warning, :proof_missing).transform_keys(&:to_s))
      WorkflowRun.from_h(@change.call(run_id) { |stored| stored.replace(settle(WorkflowRun.from_h(stored), delivery, kick).to_mutable_h) })
    rescue Workspace::Error => e
      # Cancelled while the line was on its way: the cancel stands.
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # Refuses a pane another run holds: one bound to a run still going, one a parked run waits for (a run
    # parked by `workflow run` has no binding yet), or one an `on_fail` retry or a token budget hold waits for.
    #
    # @param pane [String, nil] the pane id; nil is never refused
    # @param run_id [String, nil] the run asking, which a park or wait of its own can't refuse
    # @return [void]
    # @raise [Workspace::Error] code `pane_has_run`
    def check_pane(pane, run_id: nil)
      return unless pane
      bound = @panes.run_on(pane)
      other = (bound && @store.going?(bound)) ? bound : (parked_on(pane, run_id) || backoff_on(pane, run_id))
      return unless other
      raise Workspace::Error.new("Pane #{pane} is already running workflow run #{other}. Cancel it, or pass --pane for another agent pane.",
        code: "pane_has_run", details: {"pane" => pane, "run_id" => other})
    end

    # Gives up everything the run holds, writing `lock_released` for each. A checkout that is gone can't name
    # its lock store; the store drops a finished run's holds by itself.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @return [void]
    def release(run)
      hash = WorkflowRun.from_h(run).to_h
      @resources.release(run_id: hash["id"], worktree: hash["worktree"]).each { |name| lock_event(hash, "lock_released", name) }
    rescue Workspace::Error, SystemCallError
      nil
    end

    # Takes a park off the run however it ended (its note moves to the pending context, see
    # {WorkflowRun#drop_park}) and writes `resume_parked_ended` when there was one.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param how [String] how the park ended
    # @param extra [Hash{String=>Object}] added to the event
    # @return [WorkflowRun] the run afterwards
    def drop_park(run, how, extra = {})
      run = WorkflowRun.from_h(run)
      return run unless run.to_h.key?("parked")
      dropped = run.drop_park
      @change.event(dropped, "resume_parked_ended", {"step" => dropped.current, "how" => how}.merge(extra)) if run.parked
      dropped
    end

    private

    # The body of {#dispatch}, over a working copy of the run.
    def start_attempt(run, ctx:, context:, budgeted:, retry_of:)
      run.replace(drop_park(run, "moved_on").to_mutable_h) if run.key?("parked")
      step = step_def(run)
      state = step_state(run)
      return hold_for_budget(run, context, retry_of) if budgeted && budget_holds?(run)
      # A rejected gate stays marked for the first run of the step again, and no longer.
      gate = state["gate"]
      state.delete("gate") unless gate && gate["state"] == "rejected" && gate["attempt"] == state["attempts"].last&.fetch("n", nil)
      run["artifacts_dir"] ||= @prompt.artifacts_dir(run["worktree"], run["id"])
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
      pending = state.delete("redelivery_pending")
      attempt["redelivery"] = pending if pending
      run["pending_context"] = []
      attempt["prompt_file"], composed = @prompt.write(run, step, attempt["n"], attempt["context"])
      started = @attempt_record.start(run: run, attempt: attempt, composed: composed)
      run.replace(WorkflowRun.from_h(run).with_attempt(step["id"], started).to_mutable_h)
      state = step_state(run)
      attempt = state["attempts"].last
      @panes.bind(workspace: run["workspace"], pane: pane, run_id: run["id"], step: step["id"], attempt: attempt["n"],
        instructions: attempt["prompt_file"], artifacts: run["artifacts_dir"])
      run["pane"] = pane
      state["state"] = "running"
      run["state"] = "running"
      run["reason"] = nil
      @change.event(run, "step_dispatching", "step" => step["id"], "attempt" => attempt["n"], "pane" => pane)
      ctx.deliver({"step" => step["id"], "attempt" => attempt["n"], "workspace" => run["workspace"], "pane" => pane,
                   "text" => format(KICK, attempt["prompt_file"]), "fresh" => (context || step["context"]) == "fresh",
                   "remote_baseline" => WorkflowRequire.remote_baseline?(step), "worktree" => run["worktree"]})
    rescue Workspace::Error, SystemCallError, EncodingError => e
      # The step could not be started (no pane, an unreadable pack, a checkout that is gone, text that can't be written as UTF-8).
      not_delivered(run, state, attempt, {code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.strip})
    end

    # The daemon's answer to a typed line, applied to the stored run.
    def settle(run, delivery, kick)
      work = run.to_mutable_h
      state = work["steps"].fetch(delivery["step"])
      attempt = state["attempts"].last
      after = (attempt["n"] == delivery["attempt"]) ? attempt.delete("after_park") : nil
      return WorkflowRun.from_h(work) unless work["current"] == delivery["step"] && attempt["n"] == delivery["attempt"] && attempt["delivery"] == "delivering"
      attempt.delete("delivery")
      return WorkflowRun.from_h(work) if kick[:ok]
      not_delivered(work, state, attempt, kick)
      park_again(WorkflowRun.from_h(work), after, kick)
    end

    # The reading `remote_unchanged` compares with. It is taken here, the one place every attempt passes with the
    # lock given up and the agent not yet told: `dispatch` runs inside a transition, from many callers. It may take
    # {WorkflowGuard::REMOTE_READ_LIMIT} seconds, which {WorkflowTransitions::DELIVERY_WINDOW} has room for. A process
    # that dies here leaves an attempt with no reading, which that proof fails as unproven.
    def record_remote(run_id, delivery)
      reading = @guard.remote_head(delivery["worktree"])
      @change.call(run_id) do |stored|
        run = WorkflowRun.from_h(stored)
        attempt = run.step(delivery["step"]).last_attempt
        next unless run.current == delivery["step"] && attempt.n == delivery["attempt"]
        stored.replace(run.with_attempt(delivery["step"], WorkflowRun::Attempt.from_h(attempt.to_h.merge("remote" => reading))).to_mutable_h)
      end
    rescue Workspace::Error => e
      # Only a cancel stops the line; otherwise the attempt goes on with no reading, which that proof fails as unproven.
      raise if e.code == "run_not_active"
    end

    # After a release's line could not be typed: the failure stands unless a later try can help. The first
    # pass already moved the step and the pane, and {#not_delivered} put the note back, so the new park only waits.
    def park_again(run, after, kick)
      return run unless after && PARK_AGAIN_CODES.include?(kick[:code].to_s) && after["retries"] < PARK_RETRIES
      return run unless WorkflowTransitions.parked({"parked" => after}, @clock.call) == :waiting
      parked = run.with_park({"from" => nil, "note" => nil, "pane" => nil, "turn_over" => nil}, id: SecureRandom.hex(8),
        requested_at: now_iso, expires_at: after["expires_at"], retries: after["retries"] + 1)
      @change.event(parked, "resume_parked", "step" => parked.current, "pane" => after["pane"], "from" => nil, "has_note" => false, "retry" => true)
      parked
    end

    def not_delivered(run, state, attempt, kick)
      attempt&.delete("delivery")
      attempt&.merge!("ended_at" => now_iso, "outcome" => "not_delivered")
      attempt["code"] = kick[:code].to_s if attempt && kick[:code]
      # The next attempt is told what this one would have been.
      run["pending_context"] = attempt["context"] + run["pending_context"] if attempt
      release(run)
      state["state"] = "waiting"
      run["state"] = "waiting"
      gone = PANE_GONE_CODES.include?(kick[:code].to_s)
      run["reason"] = reason(gone ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => run["pane"], "workspace" => run["workspace"],
         "error" => kick[:code].to_s, "message" => kick[:message]&.to_s&.scrub, "reason" => kick[:reason]&.to_s,
         "proof_missing" => kick[:proof_missing]&.to_s}.compact)
    end

    # Whether the attempt about to start is held: the budget is used up. Not for a lock wait that ends (the attempt
    # was allowed when the step was reached). A run none of whose attempts could be counted has a total of 0, which is
    # under any budget, so it is never held.
    def budget_holds?(run)
      return false if run.dig("reason", "code") == "waiting_lock"
      reading = WorkflowBudget.reading(run, live: false)
      !!(reading && reading["spent"])
    end

    # Stops the run before the attempt: nothing is held, the step is left as it was, and the run waits for a
    # person. The resume that ends it starts the attempt, with the context the stop kept.
    def hold_for_budget(run, context, retry_of = nil)
      reading = WorkflowBudget.reading(run, live: false)
      release(run)
      pane = retry_of&.fetch("pane", nil) || bound_pane(run)
      identity = retry_of&.fetch("identity", nil) || @panes.identity(run["id"])
      run["budget_hold"] = {"context" => context, "pane" => pane, "identity" => identity, "text" => retry_of&.fetch("text", nil)}.compact
      run["state"] = "waiting"
      run["reason"] = reason("budget_spent", WorkflowTransitions.budget_details(run, reading).merge("kind" => "budget"))
      @change.event(run, "budget_spent", reading.slice("used", "allowance", "counted", "uncounted").merge("step" => run["current"]))
      true
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

    # Another run waiting to start in +pane+ (a run parked by `workflow run` has no binding yet).
    def parked_on(pane, run_id) = @store.parked_on(pane, except: run_id, now: @clock.call)&.id

    # Another run whose `on_fail` retry or token budget hold waits for +pane+ (a dead or reused id holds nothing).
    def backoff_on(pane, run_id) = @store.backoff_on(pane, except: run_id, same_pane: ->(each, identity) { @panes.same_pane?(each, identity) })&.id

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    def step_def(run)
      run["definition"]["steps"].find { |step| step["id"] == run["current"] }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
