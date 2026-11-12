require "time"

module Workspace
  # Decides a step whose agent's turn ended ({#turn_ended}, {#evaluate}): an agent's `fail` report, the step's
  # `guard:` (and the repository config warning), its `produces` files, then its `require:` proofs and `status:`
  # check, a proof or check that needs time run with the run's lock given up ({#finish_check}). Also records what
  # the agent says about its attempt ({#report}). A passed or failed step goes on through {WorkflowProgress}.
  # Each method that takes a run leaves it as it is and returns the run afterwards.
  class WorkflowEvaluation
    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = (WorkflowGuard::CODES + [WorkflowGuard::CONFIG_CHANGED] + WorkflowRequire::PROOFS.map { |name| "require_#{name}" } + %w[require_remote_unreachable require_unknown check_failed check_timed_out check_error reported step_timed_out]).freeze

    # The most of a failed check's log the `report_code` reading looks at.
    CHECK_CODE_TAIL_BYTES = 4096

    # What {#report} recorded: the run, its step and attempt, and the stored report ("status", "summary", "code", "at").
    Reported = Data.define(:run_id, :step, :attempt, :reported)

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] reads the run while a check runs outside its lock
    # @param progress [Workspace::WorkflowProgress] passes or fails the step once it is decided
    # @param panes [Workspace::WorkflowPanes] names the pane the run is bound to
    # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
    # @param require_check [Workspace::WorkflowRequire] checks a step's `require:` proofs
    # @param guard [Workspace::WorkflowGuard] checks a guarded step against the run's base and reads config changes
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param inbox_for [#call, nil] given a workspace name, its inbox store, for a guard's warning (default: no item)
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, progress:, panes:, checker:, require_check:, guard:, commands_config:, inbox_for: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @progress = progress
      @panes = panes
      @checker = checker
      @require_check = require_check
      @guard = guard
      @commands_config = commands_config
      @inbox_for = inbox_for
      @clock = clock
    end

    # The agent's turn ended in the run's pane: decides whether the current step is done. A step with a
    # `status:` check has it run here, outside the run's lock, so a long check never blocks a `cancel`.
    #
    # @param run_id [String]
    # @param pane [String, nil] the pane the turn ended in; an event from a pane the run is not bound to changes nothing
    # @param turn_started [Time, nil] when the turn that ended began; one that began before the step's attempt did decides nothing
    # @param stopped_at [Time, nil] when the turn's end was seen; one from before the attempt began decides nothing
    # @param background [Array<Hash>] the background tasks the agent still listed when its turn ended
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil, stopped_at: nil, background: [])
      check = nil
      run = @change.call(run_id) do |read, ctx|
        stored = read.to_h
        next if stored["parked"]
        state = step_state(stored)
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        next if stopped_at && stopped_at < Time.iso8601(state["attempts"].last["started_at"])
        judged = evaluate(read, ctx: ctx, turn_started: turn_started, background: background)
        check = ctx.check
        judged
      end
      check ? finish_check(run_id, check) : run
    end

    # Records what the agent says about its current attempt. Nothing moves until the turn ends.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @return [Reported]
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil, code: nil)
      result = nil
      @change.call(run_id) do |read|
        stored = read.thawed
        state = step_state(stored)
        unless %w[running checking].include?(state["state"])
          raise Workspace::Error.new("Step #{stored["current"]} of run #{run_id} is #{state["state"]}, so there is nothing to report on.",
            code: "step_not_running", details: {"run_id" => run_id, "step" => stored["current"], "state" => state["state"]})
        end
        attempt = state["attempts"].last
        attempt["reported"] = {"status" => status, "summary" => summary, "code" => code, "at" => now_iso}.reject { |key, value| key == "code" && value.nil? }
        event(stored, "step_reported", "step" => stored["current"], "attempt" => attempt["n"], "status" => status)
        result = Reported.new(run_id: run_id, step: stored["current"], attempt: attempt["n"], reported: attempt["reported"])
        WorkflowRun.from_h(stored)
      end
      result
    end

    # Decides a step whose turn ended. Registers the proof or check to run outside the lock on +ctx+, when the
    # step has one and nothing else already decided it. A stop seen again (the same code, step and attempt)
    # keeps its `since`, so a repeat raises no second notice; a turn that began after the stop was recorded is a
    # new stop. The stored `since` is whole seconds, so a turn that began in the same second is the same stop.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context
    # @param turn_started [Time, nil]
    # @param background [Array<Hash>] see {#turn_ended}
    # @return [WorkflowRun] the run afterwards
    def evaluate(run, ctx:, turn_started: nil, background: [])
      work = WorkflowRun.from_h(run).thawed
      judge(work, ctx, turn_started, background)
      WorkflowRun.from_h(work)
    end

    # Runs what {#evaluate} registered with the run's lock given up, and whatever comes after it: a proof can be
    # followed by another proof or the `status:` check.
    #
    # @param run_id [String]
    # @param check [Hash{String=>Object}] the proof or check {#evaluate} registered on its context
    # @return [WorkflowRun] the run afterwards; as stored when it was cancelled while the check ran
    def finish_check(run_id, check)
      run = nil
      run, check = apply_check(run_id, check, run_check(run_id, check)) while check
      run
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    private

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    def judge(run, ctx, turn_started, background)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      # A turn that ended on the attempt shows its line reached the agent.
      attempt.delete("delivery")
      attempt.delete("proofs")
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, {"cause" => "reported", "summary" => reported["summary"]}.merge(code_for("reported", reported["code"])), ctx)
        return
      end
      if step["guard"]
        found = guard_check(run, step)
        if found
          fail_step(run, found, ctx)
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
      require_and_status(run, step, state, attempt, ctx)
    end

    # What comes after the step's files: its `require:` entries from +from+ in order, then its `status:`
    # check. Registers the next thing to run outside the lock (a proof or the check) on +ctx+; none once the step is decided.
    def require_and_status(run, step, state, attempt, ctx, from: 0)
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
          fail_step(run, WorkflowTransitions.require_failure(unmet), ctx)
          return
        end
      end
      unless step["status"]
        adopt(run, @progress.pass_step(run, ctx: ctx))
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
      WorkflowCheck.env_for(@store.run(run_id))
    end

    # Whether the run still waits for this check: it is still on that step and
    # attempt, checking. A cancel, a kill or a `resume --from` ends that, and
    # the check is stopped instead of running on beside the lock's next holder.
    # So does a park: only a `--from` parks over a check, and that restarts the step. So does a proof run again.
    def wanted?(run_id, check)
      run = @store.run(run_id)
      step = run.steps.fetch(check["step"])
      attempt = step.last_attempt
      !run.parked && !WorkflowRunStore::TERMINAL_STATES.include?(run.state) && run.current == check["step"] &&
        step.state == "checking" && attempt.n == check["attempt"] &&
        (!check["proof"] || !open_proof(attempt.to_h, check).nil?)
    rescue Workspace::Error, SystemCallError
      true
    end

    # @return [Array] the run afterwards, and what to run next outside the lock, or nil
    def apply_check(run_id, check, result)
      following = nil
      run = @change.call(run_id) do |read, ctx|
        next if read.parked
        stored = read.thawed
        state = step_state(stored)
        attempt = state["attempts"].last
        # The run moved on while the check ran (a resume, a reject): its result decides nothing.
        next unless stored["current"] == check["step"] && state["state"] == "checking" && attempt["n"] == check["attempt"]
        if check["proof"]
          apply_proof(stored, attempt, check, result, ctx)
          following = ctx.check
          next WorkflowRun.from_h(stored)
        end
        attempt["check"].merge!("ended_at" => now_iso, "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
          "error" => result[:error]).compact!
        event(stored, "check_finished", "step" => check["step"], "attempt" => check["attempt"], "exit_code" => result[:exit_code])
        next @progress.pass_step(stored, ctx: ctx) if result[:exit_code] == 0
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
        @progress.fail_step(stored, failure, ctx: ctx)
      end
      [run, following]
    end

    # Records a proof's result; a passed one goes on to the next `require:` entry. A proof run again (a tick or a
    # resume took it for lost) has a new token, so a late result of the old run matches nothing and is dropped.
    def apply_proof(run, attempt, check, result, ctx)
      record = open_proof(attempt, check)
      return unless record
      record.merge!(result["record"].merge("ended_at" => now_iso))
      unmet = result["unmet"]
      event(run, "proof_finished", "step" => check["step"], "attempt" => check["attempt"], "proof" => record["proof"], "passed" => unmet.nil?)
      if unmet
        fail_step(run, WorkflowTransitions.require_failure(unmet), ctx)
        return
      end
      require_and_status(run, step_def(run), step_state(run), attempt, ctx, from: check["proof"]["index"] + 1)
    end

    def open_proof(attempt, check)
      Array(attempt["proofs"]).find { |each| each["token"] == check["proof"]["token"] && !each.key?("ended_at") }
    end

    def fail_step(run, failure, ctx)
      adopt(run, @progress.fail_step(run, failure, ctx: ctx))
    end

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
      "#{WorkflowTransitions::GUARD_TEXT.fetch(found["code"])}; the run went on"
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

    def stop_reason(stored, turn_started, code, details) = WorkflowTransitions.stop_reason(stored, turn_started, code, details, now_iso)

    def code_for(engine_code, agent_code) = WorkflowTransitions.code_for(engine_code, agent_code)

    def event(run, type, data = {}) = @change.event(run, type, data)

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    def step_def(run)
      run["definition"]["steps"].find { |step| step["id"] == run["current"] }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
