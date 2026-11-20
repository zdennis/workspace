require "securerandom"
require "time"

module Workspace
  # Starts a run's current step and types its line: {#dispatch} takes the step's resources, writes its
  # instructions, binds the pane and stores the attempt as `delivering` inside the run's lock; {#deliver}
  # types the line after the lock is given up and records the answer, parking a released resume again when
  # the pane was only busy. A run whose token budget or timeout is used up is held before the attempt, or before a
  # review round ({#hold_round}). A paused run is held first, recording what was held as its `pause_hold`
  # ({#hold_paused}); a line registered before the pause and not yet typed is kept there too, untyped. {#check_pane}
  # says whether another run holds a pane, through the store's occupancy queries.
  class WorkflowDispatch
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = "Read %s and follow it."

    # The one line typed into the run pane for the subagent siblings of a fan_out group: each runs as a sub-agent of
    # the pane's agent, and the pane reports each one as it finishes. Always delivered fresh, as one line: the
    # per-sibling lines of the process-separation path would hit `pane_busy`, and one `/clear` per sibling would
    # queue several into the shared pane. The instructions themselves are in each sibling's prompt file.
    SUBAGENT_KICK = "Run each step below as its own sub-agent of yours: read its prompt file and follow it, then report the step with `workspace step done --step <step id>` as its instructions say. End your turn once every step is reported."

    # What a line refused as `pane_busy` leaves on the attempt, the run's reason and the events; text that may hold
    # pane content is escaped with {TerminalText}.
    #
    # @param kick [Hash] a kick's answer (:ok, :code, :message, :reason, :seen)
    # @return [Hash{String=>Object}, nil] `error`, `message`, `reason` and `seen` (those present); nil unless refused as `pane_busy`
    def self.refusal(kick)
      return nil if kick[:ok] || kick[:code].to_s != "pane_busy"
      seen = kick[:seen]&.transform_values { |value| value.is_a?(String) ? TerminalText.escape(value) : value }
      {"error" => "pane_busy", "message" => (TerminalText.escape(kick[:message]) if kick[:message]),
       "reason" => (TerminalText.escape(kick[:reason]) if kick[:reason]), "seen" => seen}.compact
    end

    # A refusal as flat event keys: `error`, `message`, `reason` and one `seen_*` key per thing seen.
    #
    # @param refusal [Hash, nil] from {.refusal}
    # @param except [Array<String>] keys left out, for an event that already carries them
    # @return [Hash{String=>Object}] empty when there is no refusal
    def self.refusal_event_keys(refusal, except: [])
      return {} unless refusal
      flat = refusal.except("seen").merge((refusal["seen"] || {}).transform_keys { |key| key.start_with?("seen_") ? key : "seen_#{key}" })
      flat.except(*except)
    end

    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = %w[no_such_pane pane_gone no_session wrong_session].freeze

    # Continue-line refusals that keep no `continue_pending`: a pane that is gone, or a run that ended or moved past
    # the marked attempt.
    CONTINUE_DROPPED = (PANE_GONE_CODES + %w[moved_on]).freeze

    # How many times a released resume that could not be typed is parked again.
    # Each failed delivery is an attempt row, but only the first release is held to `max_attempts`, so re-parks
    # can run up to PARK_RETRIES attempts past it.
    PARK_RETRIES = 3

    # Delivery failures that a later try can get past: a busy pane, a restart under way, a pane tmux still lists
    # that the daemon did not find, and a `/clear` that was typed but not confirmed. A pane tmux confirms gone
    # (reason `pane_gone`) is never parked again, whatever its code.
    PARK_AGAIN_CODES = %w[pane_busy restart_in_progress no_such_pane clear_not_confirmed].freeze

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
    # @param downtime [Workspace::WorkflowDowntime, nil] its spans are cut from the run's timeout clock (nil: none)
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, resources:, panes:, prompt:, attempt_record:, guard:, env_stopper: nil, event_log: nil, downtime: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @resources = resources
      @panes = panes
      @prompt = prompt
      @attempt_record = attempt_record
      @guard = guard
      @env_stopper = env_stopper
      @event_log = event_log
      @downtime = downtime
      @clock = clock
    end

    # Starts the run's current step: takes its resources, writes its instructions, binds the pane and stores
    # the attempt as running and `delivering`, and registers the line to type on +ctx+. The line is typed by
    # {#deliver} after the run's lock is given up, so a process that dies while the daemon answers leaves an
    # attempt a turn's end can decide. A step that can't start leaves the run waiting with the reason why.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the step to start; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context, which gets the line to type
    # @param cause [String] why the attempt starts, written on `step_dispatching` and `step_dispatched`: `first`, `next_step`,
    #   `loop`, `backoff_ended`, `review_rejected`, `resume`, `gate_rejected`, `redelivery`, or `lock_ended` when the
    #   wait for a lock ends and no earlier cause was kept
    # @param context [String, nil] the step's `context` for this attempt (`fresh` starts a new conversation)
    # @param budgeted [Boolean] false starts the attempt even when the token budget is used up
    # @param retry_of [Hash{String=>Object}, nil] the retry's "pane", "identity" and "text", kept by a budget hold, and
    #   "attempt": the attempt of the step a review rejected, recorded as the new attempt's `retry_of`
    # A step of a fan_out group none of whose siblings has started yet (each still `pending`, with no attempt) is not
    # started alone: the whole group is ({#fan_out}). This is the one place a group is entered, so the first step of a
    # run, a resume of a run that never started, and the step before the group passing all enter it the same way.
    #
    # @return [WorkflowRun] the run afterwards
    def dispatch(run, ctx:, cause:, context: nil, budgeted: true, retry_of: nil)
      work = WorkflowRun.from_h(run).thawed
      siblings = unstarted_group(work)
      if siblings
        fan_out(work, siblings, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: retry_of)
      else
        start_attempt(work, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: retry_of)
      end
      WorkflowRun.from_h(work)
    end

    # Types the line of an attempt {#dispatch} stored, then records the daemon's answer under the run's lock,
    # if the run is still on that attempt and nothing else (a turn's end, a cancel, a resume) has settled it
    # meanwhile. A line that could not be typed makes the run wait as before; a late answer for an attempt
    # already settled changes nothing. A run paused since the line was registered types nothing: the line is kept
    # as its `pause_hold` (kind `delivery`) and the attempt stays open and `running`, with no delivery mark. A pause
    # that lands after that read gets its line typed, as one just after the line went out would: it takes effect at
    # the next dispatch.
    #
    # @param run_id [String]
    # @param delivery [Hash{String=>Object}] the line {#dispatch} registered
    # @return [WorkflowRun] the run afterwards; as stored when it was cancelled while the line was on its way
    # @raise [Workspace::Error] code `unknown_run`
    def deliver(run_id, delivery)
      if @store.run(run_id).paused
        held = hold_delivery(run_id, delivery)
        return held if held
      end
      record_remote(run_id, delivery) if delivery["remote_baseline"]
      kick = begin
        @panes.kick(workspace: delivery["workspace"], pane: delivery["pane"], text: delivery["text"], fresh: delivery["fresh"], run_id: run_id)
      rescue => e
        # Whatever went wrong, the mark is settled here: left set, it would hold off `resume` for nothing.
        {ok: false, code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.scrub.strip}
      end
      # The daemon answers `no_such_pane` from one look at its pane list: tmux is asked again, here and not under the run lock.
      if %w[no_such_pane pane_gone].include?(kick[:code].to_s) && !@panes.pane_gone?(delivery["pane"], workspace: delivery["workspace"])
        kick = kick.merge(pane_listed: true)
      end
      event = {"step" => delivery["step"], "attempt" => delivery["attempt"], "pane" => delivery["pane"], "delivered" => kick[:ok],
               "actor" => "engine", "cause" => delivery["cause"], "from_state" => nil, "to_state" => nil,
               **kick.slice(:warning, :proof_missing).transform_keys(&:to_s),
               **self.class.refusal_event_keys(self.class.refusal(kick))}
      event["steps"] = delivery["steps"] if delivery["steps"].is_a?(Array)
      @store.record_event(run_id, "step_dispatched", event)
      @change.call(run_id, actor: "engine", cause: "delivery") { |run| settle(run, delivery, kick) }
    rescue Workspace::Error => e
      # Cancelled while the line was on its way: the cancel stands.
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # Types the continue line ({WorkflowTransitions::CONTINUE_LINE}) into a pane whose turn `pause --interrupt`
    # stopped, with the run's lock given up, and records `step_continued` (`delivered`; `code`, `message` and
    # `pending` when the line was not typed). The run is read first, as {#deliver} does: one paused again since its
    # caller's change types nothing (code `run_paused`), and so does one that has ended or moved past the marked
    # attempt since (code `moved_on`). A line not typed for any reason but those in {CONTINUE_DROPPED} puts the mark back as `continue_pending` under the run's lock (its `since` kept, so
    # {WorkflowTransitions.continue_state} still expires it), when the run is still on the marked attempt and holds no
    # other mark, and a later tick tries again. It adds no attempt and spends nothing, and never raises for a refusal.
    #
    # @param run_id [String]
    # @param mark [Hash{String=>Object}] the continue mark ("pane", "pid", "kind", "step", "attempt", "since")
    # @param workspace [String]
    # @param text [String] the line
    # @param actor [String] who made the change that let the line go, one of {WorkflowRunChange::ACTORS}
    # @param cause [String] that change's cause (`unpause` or `tick`)
    # @return [Hash] the kick's answer: :ok, and when false :code, :message and :pending (whether the mark was put back)
    def type_continue(run_id, mark, workspace:, text:, actor:, cause:)
      run = @store.run(run_id)
      # A fan_out sibling's mark is read on its own step, whichever sibling the cursor is on.
      kick = if WorkflowRunStore::TERMINAL_STATES.include?(run.state) || !WorkflowTransitions.continue_mark?(WorkflowTransitions.at_step(run.to_h, mark_step(mark)), mark)
        {ok: false, code: "moved_on", message: "the run has ended or moved past the attempt the line was for"}
      elsif run.paused
        {ok: false, code: "run_paused", message: "the run was paused again before the line was typed"}
      else
        begin
          @panes.kick(workspace: workspace, pane: mark["pane"], text: text, fresh: false, run_id: run_id)
        rescue => e
          {ok: false, code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.scrub.strip}
        end
      end
      kick = kick.merge(pending: !CONTINUE_DROPPED.include?(kick[:code].to_s) && keep_continue(run_id, mark, actor, cause, self.class.refusal(kick))) unless kick[:ok]
      line = {"step" => mark["step"], "attempt" => mark["attempt"], "pane" => mark["pane"], "delivered" => kick[:ok],
              "actor" => actor, "cause" => cause, "from_state" => nil, "to_state" => nil}
      @store.record_event(run_id, "step_continued", line.merge(kick.slice(:code, :message, :pending).transform_keys(&:to_s)).merge(self.class.refusal_event_keys(self.class.refusal(kick), except: %w[error message])))
      kick
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
      bound = @panes.bound_on(pane)&.fetch(:run_id)
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

    # Holds a review round before it starts when the run's token budget or timeout is used up, as {#dispatch} holds
    # an attempt, with the same exemption (a round leaving a lock wait was allowed when it was reached). The hold
    # (`budget_hold`, `timeout_hold`) records `{"review_round" => round}` and no pane, so its release starts that
    # round, never an author attempt; the reason is `budget_spent` or `run_timed_out`, its details naming the round.
    # The caller keeps the step `reviewing`. A redelivery of a round already started is not asked here. A paused run
    # holds the round first ({#hold_paused}, kind `round`), whatever its limits.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the step whose round would start; left as it is
    # @param round [Integer] the round about to start
    # @return [WorkflowRun, nil] the run held; nil when the round may start
    def hold_round(run, round:)
      paused = hold_paused(run, {"kind" => "round", "review_round" => round})
      return paused if paused
      work = WorkflowRun.from_h(run).thawed
      spent = budget_holds?(work)
      late = time_holds?(work)
      return nil unless spent || late
      hold(work, {"review_round" => round}, budget: spent, time: late)
      slot(work, "reason")["details"]["review_round"] = round
      WorkflowRun.from_h(work)
    end

    # Holds a dispatch of a paused run: +hold+ (its "kind", `attempt` or `round`, and what its replay needs) is stored
    # as the run's `pause_hold`, in the `budget_hold` shape, the run's locks are given up, and the run waits with
    # no stored reason (the pause is what it shows). Nothing is typed, and the step is left where it was. A run that
    # already holds a dispatch keeps that one and is left as it is: there is only ever one held dispatch.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run; left as it is
    # @param hold [Hash{String=>Object}] the record to store
    # @param release [Boolean] false keeps the run's locks (a rerun's `review.uses`, which its replay then needs not take)
    # @return [WorkflowRun, nil] the run held; nil when the run is not paused
    def hold_paused(run, hold, release: true)
      work = WorkflowRun.from_h(run).thawed
      return nil unless work["paused"]
      pause_hold(work, hold, release: release)
      WorkflowRun.from_h(work)
    end

    # Takes the `review.uses` of the step whose round is about to start, as {#dispatch} takes a step's `uses:`: the
    # run then holds exactly those, so the step's own are given up. A lock another holder has keeps the round from
    # starting: the run waits on `waiting_lock` (details naming the lock and `review_round`), the step stays as
    # +step_state+ says, and a later {WorkflowRecovery#tick} or a person's resume asks again. A lock store that can't
    # be read keeps it too, the run waiting for a person (`waiting_you`, kind `review`), with whatever locks the run
    # holds kept, as a budget or timeout hold ({#hold_round}) keeps them: nothing is given up that a resume would
    # have to queue for again. Runs under the run's lock.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the step whose round would start; left as it is
    # @param round [Integer] the round about to start
    # @param step_state [String] the state the step keeps while the run waits (the caller's `reviewing`)
    # @return [WorkflowRun, nil] the run waiting; nil when it holds what the round uses
    def hold_round_lock(run, round:, step_state:)
      work = WorkflowRun.from_h(run).thawed
      review = WorkflowDefinition.review(step_def(work)) || {}
      waiting = begin
        acquire(work, {"id" => work["current"], "uses" => review["uses"]}, nil)
      rescue Workspace::Error, SystemCallError => e
        work["state"] = "waiting"
        slots(work)["reason"] = reason("waiting_you", {"kind" => "review", "step" => work["current"], "review_round" => round,
          "error" => e.respond_to?(:code) ? e.code : "error", "message" => e.message.lines.first.to_s.scrub.strip})
        return WorkflowRun.from_h(work)
      end
      return nil unless waiting
      wait_for_lock(work, step_state(work), waiting, step_state: step_state)
      slot(work, "reason")["details"]["review_round"] = round
      WorkflowRun.from_h(work)
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

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    # Step states of a fan_out sibling at work: a sibling that can't start leaves the run running while another is in one.
    SIBLING_WORKING = %w[running checking reviewing].freeze

    # The ids of the current step's fan_out group, in step order, when the current step is a sibling and no sibling has
    # started (each `pending`, with no attempt); nil for any other step, and for a group already under way.
    def unstarted_group(run)
      ids = group_of(run, run["current"])
      return nil unless ids
      started = ids.any? do |id|
        state = run["steps"].is_a?(Hash) ? run["steps"][id] : nil
        !state.is_a?(Hash) || state["state"] != "pending" || Array(state["attempts"]).any?
      end
      started ? nil : ids
    end

    # The ids of +step_id+'s fan_out group, in step order; nil for a step in no group.
    def group_of(run, step_id)
      WorkflowDefinition.siblings_of(run["definition"], step_id)
    end

    # Starts every sibling of a group at once, each in its own author pane: the first in the run's pane, each after it
    # in a new pane split off the workspace's session ({WorkflowPanes#spawn_author}) — unless the group has a subagent
    # sibling, when the run pane is the group's and a `process_separation` first sibling takes a spawned pane too (see
    # {#first_pane}). Each sibling gets its own attempt, binding and line; a sibling whose pane can't be made or used
    # waits on its own, and the others start anyway. The cursor is left on the last sibling started. A paused run, or
    # one whose budget or timeout is used up, holds the first sibling only, as it would one step: the dispatch that
    # ends the hold finds the group still unstarted and fans it out then.
    #
    # A sibling whose resolved execution mode is `subagents` runs in the run's own pane instead: no author pane is
    # spawned, no binding or pane slot is written for it, and its line is not its own — every subagent sibling of the
    # group shares the one composed line (see {SUBAGENT_KICK}), typed into the run pane after the change.
    def fan_out(run, ids, ctx:, cause:, context:, budgeted:, retry_of:)
      run["current"] = ids.first
      held = run["paused"] || (budgeted && (budget_holds?(run) || time_holds?(run)))
      grouped = ids.any? { |id| WorkflowDefinition.subagent_sibling?(step_def_for(run, id)) }
      # The first sibling's spawned pane, when it takes one ({#first_pane}); +:failed+ when the spawn could not
      # be made, which leaves the first sibling on its refusal and starts the others anyway.
      made = first_pane(run, grouped, held)
      unless made == :failed
        start_attempt(run, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: retry_of,
          pane: made.is_a?(Hash) ? made[:pane] : nil, group_entry: true)
      end
      return if held
      # The run pane works on the group whole when any sibling runs as its sub-agent: one binding, written once at
      # group entry, so hook events and reports can resolve it. No sibling's attempt binds over it (the subagent
      # branch of {#start_attempt} skips the bind); the pane's next normal step binds it back to that step.
      if grouped
        @panes.bind_group(workspace: run["workspace"], pane: run_pane(run), run_id: run["id"],
          group: step_def_for(run, ids.first)["group"], artifacts: run["artifacts_dir"])
      end
      ids.drop(1).each do |id|
        run["current"] = id
        # A checkout that is gone fails the sibling before any pane is made for it.
        next start_attempt(run, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: nil, group_entry: true) unless File.directory?(run["worktree"])
        # The run's lock is held across each sibling's pane spawn, up to that sibling's readiness deadline, so a caller
        # that blocks on the lock (the nudger's advance, approve, cancel, resume) can wait that long. Spawning outside
        # the lock (a two-phase fan-out, as infra retry does) is deferred follow-up work.
        next start_attempt(run, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: nil, group_entry: true) if subagent_step?(run)
        made = @panes.spawn_author(run["workspace"])
        if made[:error]
          not_delivered(run, step_state(run), nil, {code: made[:error], message: made[:message]})
          slot(run, "reason")["details"]["pane"] = made[:pane] if made[:pane]
          next
        end
        start_attempt(run, ctx: ctx, cause: cause, context: context, budgeted: budgeted, retry_of: nil, pane: made[:pane], group_entry: true)
      end
      compose_group_line(run, ids, ctx, cause: cause)
    end

    # Whether the current step is a fan_out sibling that runs as a sub-agent of the run's own pane.
    def subagent_step?(run)
      step = step_def(run)
      step && WorkflowDefinition.subagent_sibling?(step)
    end

    # What the group's first sibling's attempt starts with: nil for a group of `process_separation` siblings
    # alone (today's path — the first runs in the run pane), nil for a subagent first sibling (it needs no pane),
    # and a freshly spawned author pane for a `process_separation` first sibling of a group that also has a
    # subagent one — the run pane is that group's, so it cannot take the first sibling too. A held first attempt
    # holds before any pane is made, so it spawns nothing, and a gone checkout fails the attempt as any step's
    # does, so no pane is made for it either. A spawn that could not be made records the sibling's reason and
    # answers +:failed+.
    def first_pane(run, grouped, held)
      return nil if held || !grouped || subagent_step?(run) || !File.directory?(run["worktree"])
      made = @panes.spawn_author(run["workspace"])
      return made unless made[:error]
      not_delivered(run, step_state(run), nil, {code: made[:error], message: made[:message]})
      slot(run, "reason")["details"]["pane"] = made[:pane] if made[:pane]
      :failed
    end

    # The one delivery line a `subagents` group's started siblings share, registered once after every sibling's
    # attempt is stored. A sibling whose attempt never started (its checkout was gone, its prompt could not be
    # written) is not named: it waits on its own reason. A re-attempt of a single subagent sibling delivers a line
    # naming only that sibling ({#start_attempt} with +group_entry: false+, from {#dispatch}).
    def compose_group_line(run, ids, ctx, cause:)
      started = ids.filter_map do |id|
        step = step_def_for(run, id)
        next unless WorkflowDefinition.subagent_sibling?(step)
        attempt = run.dig("steps", id, "attempts", -1)
        next unless attempt.is_a?(Hash) && attempt["prompt_file"] && attempt["outcome"] != "not_delivered"
        [id, attempt["prompt_file"], attempt["n"]]
      end
      ctx.add_delivery(subagent_line(run, started, cause: cause)) unless started.empty?
    end

    # The run's own pane — never a fan_out sibling's author pane, which the cursor's step may name. The run's
    # recorded pane is read before the live binding: a sibling bound a moment ago must not take the group's
    # own delivery, and the recorded pane is the one the run was launched in.
    def run_pane(run)
      run["pane"] || @panes.pane_of(run["id"])
    end

    def step_def_for(run, step_id)
      run["definition"]["steps"].find { |step| step["id"] == step_id }
    end

    # The body of {#dispatch}, over a working copy of the run. +pane+ is the pane to type into when the caller made it
    # (a fan_out sibling's new pane); nil uses the pane the step is bound to. +group_entry+ is true when the attempt
    # starts inside {#fan_out}: a `subagents` sibling then registers no line of its own, because the group's one
    # composed line is registered once after every sibling's attempt is stored ({#compose_group_line}). A subagent
    # sibling's attempt outside a group entry (its failure loop's re-attempt) delivers a composed line naming only it.
    def start_attempt(run, ctx:, cause:, context:, budgeted:, retry_of:, pane: nil, group_entry: false)
      return pause_attempt(run, cause, context, budgeted, retry_of) if run["paused"]
      adopt(run, drop_park(run, "moved_on")) if run.key?("parked")
      step = step_def(run)
      state = step_state(run)
      subagent = WorkflowDefinition.subagent_sibling?(step)
      if budgeted
        spent = budget_holds?(run)
        late = time_holds?(run)
        return hold_attempt(run, context, retry_of, budget: spent, time: late) if spent || late
      end
      # A rejected gate stays marked for the first run of the step again, and no longer.
      gate = state["gate"]
      state.delete("gate") unless gate && gate["state"] == "rejected" && gate["attempt"] == state["attempts"].last&.fetch("n", nil)
      run["artifacts_dir"] ||= @prompt.artifacts_dir(run["worktree"], run["id"])
      # Before anything is written: a removed checkout must not come back as a directory.
      raise Workspace::Error, "the checkout #{run["worktree"]} is gone" unless File.directory?(run["worktree"])
      pane ||= bound_pane(run)
      # A binding made for another pane (a tmux restart reuses pane ids) is not typed into.
      if stale_binding?(run, pane)
        return not_delivered(run, state, nil, {code: "pane_gone", message: "pane #{pane} is no longer the pane the run was bound in"})
      end
      pending_retry = retry_pending(run, retry_of, context)
      retry_n = pending_retry&.fetch("attempt")
      context ||= pending_retry&.fetch("context", nil)
      waiting = acquire(run, step, pane)
      if waiting
        # A review's retry waiting for a lock is still that retry when the wait ends (a tick or a resume dispatches it
        # again): its attempt, its context and its text (which a `--from` takes out of the pending context).
        pending_retry ? slots(run)["retry_of_pending"] = pending_retry : slots(run).delete("retry_of_pending")
        # The cause this dispatch had is kept for the one that ends the wait (a tick says `lock_ended`).
        slots(run)["dispatch_cause_pending"] = {"step" => run["current"], "cause" => kept_cause(run, cause)}
        return wait_for_lock(run, state, waiting)
      end
      slots(run).delete("retry_of_pending")
      cause = kept_cause(run, cause)
      slots(run).delete("dispatch_cause_pending")

      # To the millisecond: the end of a turn is matched to the attempt by when that turn began.
      attempt = {"n" => state["attempts"].size + 1, "started_at" => @clock.call.utc.iso8601(3), "context" => slot(run, "pending_context"),
                 "delivery" => "delivering"}
      pending = state.delete("redelivery_pending")
      attempt["redelivery"] = pending if pending
      attempt["retry_of"] = retry_n if retry_n
      slots(run)["pending_context"] = []
      attempt["prompt_file"], composed = @prompt.write(run, step, attempt["n"], attempt["context"])
      started = @attempt_record.start(run: run, attempt: attempt, composed: composed)
      adopt(run, WorkflowRun.from_h(run).with_attempt(step["id"], started))
      state = step_state(run)
      attempt = state["attempts"].last
      # A subagent sibling has no pane of its own: the run pane keeps its one binding (the group's, when one is
      # written) and the sibling records no pane slot, so every pane-keyed reader falls back to the run pane.
      unless subagent
        @panes.bind(workspace: run["workspace"], pane: pane, run_id: run["id"], step: step["id"], attempt: attempt["n"],
          instructions: attempt["prompt_file"], artifacts: run["artifacts_dir"])
        # A step of a group records its pane under its own hash; every other step, at the run's top level as always.
        WorkflowRun.slots(run, step["id"])["pane"] = pane
      end
      state["state"] = "running"
      run["state"] = "running"
      slots(run)["reason"] = nil
      @change.event(run, "step_dispatching", "step" => step["id"], "attempt" => attempt["n"], "pane" => pane, "cause" => cause, "retry_of" => attempt["retry_of"])
      if subagent
        # The group's composed line is registered once, after every sibling's attempt is stored; a re-attempt on its
        # own (the failure loop) delivers a composed line naming only this sibling. Its delivery is always fresh: the
        # run pane's one conversation is cleared before the line is typed, and the sub-agents it starts are new ones.
        return run if group_entry
        ctx.add_delivery(subagent_line(run, [[step["id"], attempt["prompt_file"], attempt["n"]]], cause: cause))
      else
        line = {"step" => step["id"], "attempt" => attempt["n"], "workspace" => run["workspace"], "pane" => pane,
                "text" => format(KICK, attempt["prompt_file"]), "fresh" => (context || step["context"]) == "fresh",
                "remote_baseline" => WorkflowRequire.remote_baseline?(step), "worktree" => run["worktree"], "cause" => cause}
        # A fan_out sibling's line is typed after its siblings'; any other step's is the change's one line.
        WorkflowRun.step_scoped?(run, step["id"]) ? ctx.add_delivery(line) : ctx.deliver(line)
      end
    rescue Workspace::Error, SystemCallError, EncodingError => e
      # The step could not be started (no pane, an unreadable pack, a checkout that is gone, text that can't be written as UTF-8).
      not_delivered(run, state, attempt, {code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.strip})
    end

    # The delivery line a `subagents` group's (or one re-attempted subagent sibling's) shared line is: the run pane's
    # agent is told to run each named sibling's prompt file as its own sub-agent and report each step as it finishes.
    def subagent_line(run, started, cause:)
      first = started.first
      {"step" => first[0], "steps" => started.map { |id, _file, _n| id }, "attempts" => started.to_h { |id, _file, n| [id, n] },
       "workspace" => run["workspace"], "pane" => run_pane(run),
       "text" => "#{SUBAGENT_KICK} " + started.map { |id, file, _n| "Step #{id}: #{format(KICK, file)}" }.join(" "),
       "fresh" => true, "remote_baseline" => started.any? { |id, _file, _n| WorkflowRequire.remote_baseline?(step_def_for(run, id)) },
       "worktree" => run["worktree"], "cause" => cause}
    end

    # The cause a dispatch that ends a lock wait is written with: the one the waiting dispatch had, for the same step.
    # A `lock_ended` dispatch with none kept (a run stored before it was kept) stays `lock_ended`.
    def kept_cause(run, cause)
      kept = slot(run, "dispatch_cause_pending")
      return cause unless cause == "lock_ended" && kept.is_a?(Hash) && kept["step"] == run["current"] && kept["cause"].is_a?(String)
      kept["cause"]
    end

    # The review retry this attempt is: given ("attempt", with its "text" and the +context+ it starts with), else the
    # one kept while the step waited for a lock (for the same step only); nil for any other attempt.
    def retry_pending(run, retry_of, context)
      if retry_of.is_a?(Hash) && retry_of["attempt"].is_a?(Integer)
        return {"step" => run["current"], "attempt" => retry_of["attempt"], "context" => context, "text" => retry_of["text"]}.compact
      end
      kept = slot(run, "retry_of_pending")
      (kept.is_a?(Hash) && kept["step"] == run["current"] && kept["attempt"].is_a?(Integer)) ? kept : nil
    end

    # The daemon's answer to a typed line, applied to the stored run.
    # A fan_out sibling's line is settled whichever sibling the cursor is on: the group's lines are typed one after another.
    # A `subagents` group's one composed line names every sibling it was typed for ("steps" with each one's attempt
    # number under "attempts"): a kick's answer settles them all — a failed one puts each named sibling on its own wait.
    def settle(run, delivery, kick)
      work = run.thawed
      ids, numbers = delivery_steps(delivery)
      after = nil
      settled = ids.filter_map do |id|
        state = work["steps"].fetch(id)
        attempt = state["attempts"].last
        next unless on_step?(work, id) && attempt.is_a?(Hash) && attempt["n"] == numbers[id] && attempt["delivery"] == "delivering"
        attempt.delete("delivery")
        after ||= attempt.delete("after_park")
        [state, attempt, id]
      end
      return WorkflowRun.from_h(work) if settled.empty?
      return WorkflowRun.from_h(work) if kick[:ok]
      settled.each { |state, attempt, id| not_delivered(work, state, attempt, kick, id) }
      return WorkflowRun.from_h(work) unless ids.include?(work["current"])
      park_again(WorkflowRun.from_h(work), after, kick)
    end

    # Whether the run is still on +step_id+: the cursor names it, or it is a fan_out sibling (the cursor names only one).
    def on_step?(run, step_id) = run["current"] == step_id || WorkflowRun.step_scoped?(run, step_id)

    # The steps a delivery line names, and each one's attempt number: a composed line's "steps" with each one's
    # number under "attempts", or the one step and attempt a plain line carries. The one reading of it, for
    # {#settle} and {#record_remote}.
    def delivery_steps(delivery)
      ids = (delivery["steps"].is_a?(Array) && delivery["steps"].any?) ? delivery["steps"] : [delivery["step"]]
      numbers = delivery["attempts"].is_a?(Hash) ? delivery["attempts"] : {delivery["step"] => delivery["attempt"]}
      [ids, numbers]
    end

    # The reading `remote_unchanged` compares with. It is taken here, the one place every attempt passes with the
    # lock given up and the agent not yet told: `dispatch` runs inside a transition, from many callers. It may take
    # {WorkflowGuard::REMOTE_READ_LIMIT} seconds, which {WorkflowTransitions::DELIVERY_WINDOW} has room for. A process
    # that dies here leaves an attempt with no reading, which that proof fails as unproven.
    def record_remote(run_id, delivery)
      reading = @guard.remote_head(delivery["worktree"])
      ids, numbers = delivery_steps(delivery)
      @change.call(run_id, actor: "engine", cause: "delivery") do |run|
        ids.each do |id|
          attempt = run.step(id).last_attempt
          next unless on_step?(run.to_h, id) && attempt.n == numbers[id]
          run = run.with_attempt(id, WorkflowRun::Attempt.from_h(attempt.to_h.merge("remote" => reading)))
        end
        run
      end
    rescue Workspace::Error => e
      # Only a cancel stops the line; otherwise the attempt goes on with no reading, which that proof fails as unproven.
      raise if e.code == "run_not_active"
    end

    # After a release's line could not be typed: the failure stands unless a later try can help. The first
    # pass already moved the step and the pane, and {#not_delivered} put the note back, so the new park only waits.
    def park_again(run, after, kick)
      # {#not_delivered} has already written the reason, so a pane tmux confirmed gone is read here.
      return run if run.reason_for(run.current).is_a?(Hash) && run.reason_for(run.current)["code"] == "pane_gone"
      return run unless after && PARK_AGAIN_CODES.include?(kick[:code].to_s) && after["retries"] < PARK_RETRIES
      return run unless WorkflowTransitions.parked({"parked" => after}, @clock.call) == :waiting
      parked = run.with_park({"from" => nil, "note" => nil, "pane" => nil, "turn_over" => nil}, id: SecureRandom.hex(8),
        requested_at: now_iso, expires_at: after["expires_at"], retries: after["retries"] + 1)
      @change.event(parked, "resume_parked", "step" => parked.current, "pane" => after["pane"], "from" => nil, "has_note" => false, "retry" => true)
      parked
    end

    # +step_id+ is the step that was not started: the cursor's, or a fan_out sibling's whose line was typed after another's.
    def not_delivered(run, state, attempt, kick, step_id = run["current"])
      attempt&.delete("delivery")
      attempt&.merge!("ended_at" => now_iso, "outcome" => "not_delivered")
      refusal = self.class.refusal(kick)
      attempt["refusal"] = refusal if attempt && refusal
      attempt["code"] = kick[:code].to_s if attempt && kick[:code]
      # The next attempt is told what this one would have been.
      slots = WorkflowRun.slots(run, step_id)
      slots["pending_context"] = attempt["context"] + WorkflowRun.slot(run, step_id, "pending_context") if attempt
      release(run)
      state["state"] = "waiting"
      wait_run(run, step_id)
      # A pane tmux still lists (`pane_listed`, set by {#deliver}) is not gone, whatever code the daemon answered.
      gone = PANE_GONE_CODES.include?(kick[:code].to_s) && !kick[:pane_listed]
      slots["reason"] = reason(gone ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => step_id, "pane" => WorkflowRun.slot(run, step_id, "pane"), "workspace" => run["workspace"],
         "error" => kick[:code].to_s, "message" => refusal&.fetch("message", nil) || kick[:message]&.to_s&.scrub, "reason" => refusal&.fetch("reason", nil) || kick[:reason]&.to_s,
         "proof_missing" => kick[:proof_missing]&.to_s, "seen" => refusal&.fetch("seen", nil)}.compact)
    end

    # Whether the attempt about to start is held: the budget is used up. Not for a lock wait that ends (the attempt
    # was allowed when the step was reached). A run none of whose attempts could be counted has a total of 0, which is
    # under any budget, so it is never held.
    #
    # The purse is the run's, shared by a fan_out group's siblings: one sibling held for it holds the others' attempts too.
    def budget_holds?(run)
      return false if slot_dig(run, "reason", "code") == "waiting_lock"
      reading = WorkflowBudget.reading(run, live: false)
      return false unless reading
      !!reading["spent"] || sibling_holds?(run, "budget_hold")
    end

    # Whether the attempt about to start is held: the run's `timeout:` is used up (machine time, see
    # {WorkflowDeadline}). Exempt as {#budget_holds?} is: a lock wait that ends was allowed when the step was reached.
    def time_holds?(run)
      return false if slot_dig(run, "reason", "code") == "waiting_lock"
      reading = WorkflowDeadline.reading(run, @clock.call, stops: downtime_stops)
      return false unless reading
      !!reading["spent"] || sibling_holds?(run, "timeout_hold")
    end

    # Whether a sibling of the current step's fan_out group holds +key+ (`budget_hold`, `timeout_hold`) under its own
    # step; false for a step in no group.
    def sibling_holds?(run, key)
      (group_of(run, run["current"]) || []).any? { |id| run["steps"].is_a?(Hash) && run["steps"][id].is_a?(Hash) && run["steps"][id][key].is_a?(Hash) }
    end

    # Sets the run waiting as a step that can't start leaves it, unless +step_id+ is a fan_out sibling with another
    # sibling still at work: the run is running while any of them is.
    def wait_run(run, step_id = run["current"])
      others = (group_of(run, step_id) || []) - [step_id]
      working = others.any? { |id| SIBLING_WORKING.include?(run.dig("steps", id, "state")) }
      run["state"] = working ? "running" : "waiting"
    end

    # Stops the run before the attempt: nothing is held, the step is left as it was, and the run waits for a
    # person. The resume that ends it starts the attempt, with the context the stop kept. Each limit that is spent
    # stores a hold of its own (`budget_hold`, `timeout_hold`); the reason is `budget_spent` when the token budget
    # is spent, else `run_timed_out`, and carries the other's details under `run_timed_out` when both are.
    def hold_attempt(run, context, retry_of, budget:, time:)
      pane = retry_of&.fetch("pane", nil) || bound_pane(run)
      identity = retry_of&.fetch("identity", nil) || pane_identity(run)
      hold(run, {"context" => context, "pane" => pane, "identity" => identity, "text" => retry_of&.fetch("text", nil),
                 "retry_of" => retry_of&.fetch("attempt", nil)}.compact, budget: budget, time: time)
    end

    # A paused run's attempt is held before anything is taken or written, with the pane and identity a budget hold
    # keeps, so its replay starts the attempt this dispatch would have.
    def pause_attempt(run, cause, context, budgeted, retry_of)
      pane = retry_of&.fetch("pane", nil) || bound_pane(run)
      identity = retry_of&.fetch("identity", nil) || pane_identity(run)
      pause_hold(run, {"kind" => "attempt", "cause" => cause, "context" => context, "budgeted" => budgeted, "pane" => pane, "identity" => identity,
                       "text" => retry_of&.fetch("text", nil), "retry_of" => retry_of&.fetch("attempt", nil)}.compact)
    end

    # There is only ever one held dispatch: a run that already holds one keeps it and is left as it is.
    def pause_hold(run, hold, release: true)
      return true if slot(run, "pause_hold")
      release(run) if release
      slots(run)["pause_hold"] = hold
      run["state"] = "waiting"
      slots(run)["reason"] = nil
      true
    end

    # The line {#deliver} was about to type for a run paused since {#dispatch} registered it. Under the lock, a run
    # still paused types nothing: when it is still on that attempt and `delivering`, the mark is taken off, the
    # attempt stays open and `running` (it was not refused, so it is not `not_delivered`), and `pause_hold` keeps the
    # line ("kind" `delivery`, "step", "attempt", "delivery") for the unpause to type. Nil when the pause has ended
    # meanwhile, so the line is typed.
    def hold_delivery(run_id, delivery)
      held = false
      paused = false
      run = @change.call(run_id, actor: "engine", cause: "delivery") do |stored|
        next unless (paused = !!stored.paused)
        attempt = stored.step(delivery["step"])&.last_attempt
        next unless on_step?(stored.to_h, delivery["step"]) && attempt&.n == delivery["attempt"] && attempt.to_h["delivery"] == "delivering"
        # The first hold is kept; this line's mark lapses, and the tick after the unpause sees to it.
        next if stored.pause_hold_for(delivery["step"])
        held = true
        work = stored.thawed
        work["steps"].fetch(delivery["step"])["attempts"].last.delete("delivery")
        WorkflowRun.slots(work, delivery["step"])["pause_hold"] = {"kind" => "delivery", "step" => delivery["step"], "attempt" => delivery["attempt"], "delivery" => delivery}
        WorkflowRun.from_h(work)
      end
      return nil unless paused
      if held
        @store.record_event(run_id, "step_dispatched", "step" => delivery["step"], "attempt" => delivery["attempt"], "pane" => delivery["pane"],
          "delivered" => false, "actor" => "engine", "cause" => "paused", "from_state" => nil, "to_state" => nil)
      end
      run
    end

    # The hold itself, for an attempt or a review round: +hold+ is the record each spent limit stores.
    def hold(run, hold, budget:, time:)
      reading = WorkflowBudget.reading(run, live: false) if budget
      deadline = WorkflowDeadline.reading(run, @clock.call, stops: downtime_stops) if time
      release(run)
      slots(run)["budget_hold"] = hold if budget
      slots(run)["timeout_hold"] = hold.dup if time
      wait_run(run)
      if budget
        details = WorkflowTransitions.budget_details(run, reading).merge("kind" => "budget")
        details["run_timed_out"] = WorkflowTransitions.deadline_details(run, deadline) if time
        slots(run)["reason"] = reason("budget_spent", details)
      else
        slots(run)["reason"] = reason("run_timed_out", WorkflowTransitions.deadline_details(run, deadline))
      end
      @change.event(run, "budget_spent", reading.slice("used", "allowance", "counted", "uncounted", "estimated").merge("step" => run["current"])) if budget
      @change.event(run, "run_timed_out", deadline.slice("used", "limit", "timeout", "extra_seconds").merge("step" => run["current"])) if time
      true
    end

    # @return [Hash, nil] the lock the run has to wait for; nil when it holds everything the step uses
    def acquire(run, step, pane)
      result = @resources.acquire(run_id: run["id"], step: step["id"], uses: step["uses"], worktree: run["worktree"],
        workflow: run["workflow"], workspace: run["workspace"], pane: pane)
      raise Workspace::Error, "run #{run["id"]} has no run file, so it can hold no lock" if result[:status] == :not_alive
      waited = (slot_dig(run, "reason", "code") == "waiting_lock") ? slot(run, "reason") : nil
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

    def wait_for_lock(run, state, waiting, step_state: "waiting")
      holder = waiting[:holder] || {}
      details = {"resource" => waiting[:name], "step" => run["current"], "position" => waiting[:position], "total" => waiting[:total],
                 "holder" => {"run_id" => holder["run_id"], "step" => holder["step"], "workspace" => holder["workspace"],
                              "worktree" => holder["worktree"], "pid" => holder["pid"], "kind" => holder["kind"]}.compact}
      since = (slot_dig(run, "reason", "code") == "waiting_lock" && slot_dig(run, "reason", "details", "resource") == waiting[:name]) ? slot(run, "reason")["since"] : now_iso
      state["state"] = step_state
      wait_run(run)
      slots(run)["reason"] = {"code" => "waiting_lock", "since" => since, "details" => details}
    end

    def lock_event(run, type, name, data = {})
      @event_log&.record(type: type, project: run["project"],
        data: {"lock" => name, "run_id" => run["id"], "step" => run["current"], "workspace" => run["workspace"]}.merge(data))
    end

    # Another run waiting to start in +pane+ (a run parked by `workflow run` has no binding yet).
    def parked_on(pane, run_id) = @store.parked_on(pane, except: run_id, now: @clock.call)&.id

    # Another run whose `on_fail` retry or token budget hold waits for +pane+ (a dead or reused id holds nothing).
    def backoff_on(pane, run_id) = @store.backoff_on(pane, except: run_id, same_pane: ->(each, identity) { @panes.same_pane?(each, identity) })&.id

    # The pane the current step's agent works in: for a fan_out sibling, its own binding, then the pane it recorded;
    # else (and for a sibling that has neither yet, the first of a group) the run's author pane.
    def bound_pane(run)
      step = run["current"]
      if WorkflowRun.step_scoped?(run, step)
        own = @panes.pane_of(run["id"], step: step) || run.dig("steps", step, "pane")
        return own if own
      end
      @panes.pane_of(run["id"]) || run["pane"]
    end

    # What identifies the pane {#bound_pane} names, for a hold to compare later: a fan_out sibling's own binding's,
    # else the run's.
    def pane_identity(run)
      step = run["current"]
      own = @panes.identity(run["id"], step: step) if WorkflowRun.step_scoped?(run, step) && @panes.pane_of(run["id"], step: step)
      own || @panes.identity(run["id"])
    end

    # Whether the binding of the pane the current step would be typed into was made for another pane. A fan_out
    # sibling's own binding is asked about alone, so one dead sibling pane stops only that sibling; a sibling with no
    # binding of its own yet is asked about through the run's when it is typed into the run's pane, and a pane just
    # made for it has none to ask about.
    def stale_binding?(run, pane)
      id = run["id"]
      step = run["current"]
      return !!(@panes.pane_of(id) && !@panes.alive?(id)) unless WorkflowRun.step_scoped?(run, step)
      return !@panes.alive?(id, step: step) if @panes.pane_of(id, step: step)
      pane == @panes.pane_of(id) && !@panes.alive?(id)
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

    # The Hash the current step's {WorkflowRun::PER_STEP_KEYS} slots are written into ({WorkflowRun.slots}).
    def slots(run) = WorkflowRun.slots(run, run["current"])

    # One of the current step's slots ({WorkflowRun.slot}).
    def slot(run, key) = WorkflowRun.slot(run, run["current"], key)

    # {#slot} dug into ({WorkflowRun.slot_dig}).
    def slot_dig(run, key, *path) = WorkflowRun.slot_dig(run, run["current"], key, *path)

    # Puts a continue mark back as `continue_pending`, so a later tick types the line; true when it did.
    # A refusal is written on the marked attempt every time, so a second refusal on the same mark replaces the first.
    def keep_continue(run_id, mark, actor, cause, refusal = nil)
      kept = false
      @change.call(run_id, actor: actor, cause: cause) do |read|
        stored = read.thawed
        next read unless WorkflowTransitions.continue_mark?(WorkflowTransitions.at_step(stored, mark_step(mark)), mark)
        attempt = stored.dig("steps", mark["step"], "attempts")&.find { |a| a["n"] == mark["attempt"] }
        attempt["refusal"] = refusal if attempt && refusal
        unless WorkflowRun.slot_key?(stored, mark["step"], "continue_pending")
          WorkflowRun.slots(stored, mark["step"])["continue_pending"] = mark.merge("since" => mark["since"] || now_iso)
          kept = true
        end
        WorkflowRun.from_h(stored)
      end
      kept
    rescue Workspace::Error => e
      raise unless %w[run_not_active unknown_run].include?(e.code)
      false
    end

    # The step a continue mark names, when it names one as a String.
    def mark_step(mark) = (mark.is_a?(Hash) && mark["step"].is_a?(String)) ? mark["step"] : nil

    def now_iso
      @clock.call.utc.iso8601
    end

    def downtime_stops
      @downtime&.spans(@clock.call) || []
    end
  end
end
