module Workspace
  # The work of `workflow recover`: after a reboot or the loss of the tmux server, brings back each workspace that has
  # a going run no person holds, and restarts the steps that were mid-turn, at most `workflows.recover.max_per_run`
  # times for each run ({WorkflowRun#reboot_recoveries}).
  #
  # Every going run is sorted first, oldest first, into one of three kinds:
  #
  # - left alone, with a row and no restore for its sake: its workspace is removed (`skipped/workspace_removed`), it
  #   waits for a person ({WorkflowTransitions.held_reason}: `skipped/<code>`), its session can't be told up or down
  #   (`skipped/unknown_liveness`), its session is up and its step is between turns (`skipped/nothing_to_restart`: the
  #   daemon and the sweep reach it there), its session is up and its bound pane is alive (`skipped/pane_alive`), an
  #   infra retry is claimed (`skipped/infra_retry_pending`: the claimant restarts it; an agent daemon outlives the tmux
  #   server), or in a live session waiting or due (the same row: the daemon carries it out), its step is mid-turn and
  #   it has used its recoveries (`refused/limit_reached`, with the commands to run by hand), the engine would refuse
  #   the restart ({WorkflowEngine#restart_refusal} with the pane `gone`: `refused/<code>`, such as `attempts_spent` or
  #   `budget_spent`), or the run can't be read as a run (`failed/unreadable_run`);
  # - restart: the step is `running` with an open attempt, and the session is down or the bound pane gone;
  # - wake: the step is between turns (reviewing, checking, a retry backoff, a redelivery due, or `running` with no
  #   open attempt) in a workspace with no session.
  #
  # Only restart and wake runs pick workspaces, handled one at a time in the order of each one's oldest such run. A
  # workspace is restored first; a raise, or a failed or unmatched row of the workspace itself (no config, a launch that
  # failed), makes each of its runs `failed/restore_failed`, and the pass goes on. A failed row of some other pane slot
  # does not: each run is judged on its own pane. Each restart run then has its pane read again (it must be bound and
  # alive), waits for the agent there to be ready, and is restarted through {WorkflowEngine#resume} (`restart_step`,
  # `bound: "idle"`, actor `person`, with `reboot_recovery` naming the attempt seen, which the engine checks under the
  # run's lock), which raises the run's count and records `reboot_recovered` in the same change. Each wake run, once
  # its session is up, gets one {WorkflowEngine#tick} (actor `sweep`) and raises no count. A failed or skipped row
  # changes no run.
  class WorkflowRecover
    # Seconds a restored pane's agent has to be ready.
    READY_SECONDS = 60

    # Seconds a restart refused as `step_still_working` (a line still being typed) is tried again for.
    STILL_WORKING_SECONDS = 30

    # Seconds between those tries, and before the one more try of a `restart_not_closed`.
    STILL_WORKING_POLL = 3

    # Where an infra retry stands when, in a live session, the daemon owns the restart.
    PENDING_INFRA = %i[waiting due claimed].freeze

    # @param store [WorkflowRunStore] the going runs, read again before each restart and wake
    # @param engine [WorkflowEngine] judges (`restart_refusal`), restarts (`resume`) and wakes (`tick`) runs
    # @param restore [#call] `call(workspaces, dry_run:, &launch)`, the `workspace restore` command object, answering
    #   `{results:}` rows with a "kind" and an "outcome"; raises {Workspace::Error} when tmux or its ledger can't be read
    # @param readiness [AgentReadiness] waits for a restored pane's agent
    # @param panes [WorkflowPanes] the run's bound pane and whether it is alive
    # @param liveness [Liveness] whether each workspace's tmux session is up (nil: can't tell)
    # @param project_config [ProjectConfig] a workspace whose project root is nil is removed
    # @param config [WorkflowConfig] `recover_max_per_run`
    # @param session_name [#call] given a workspace, its tmux session name, for the readiness wait
    # @param sleeper [#call] waits the given seconds between tries
    # @param clock [#call] returns the current Time
    def initialize(store:, engine:, restore:, readiness:, panes:, liveness:, project_config:, config:, session_name:,
      sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now })
      @store = store
      @engine = engine
      @restore = restore
      @readiness = readiness
      @panes = panes
      @liveness = liveness
      @project_config = project_config
      @config = config
      @session_name = session_name
      @sleeper = sleeper
      @clock = clock
    end

    # @param dry_run [Boolean] restore in its own dry run: rows `would_restart`, `would_restore`, or the row a run is
    #   left alone with; nothing is written, ticked or resumed
    # @yieldparam missing [Array<String>] workspaces with no tmux session, to launch (passed to the restore)
    # @yieldreturn [Hash{String=>String}] workspace => why it could not be launched
    # @return [Hash{Symbol=>Object}] `status` (`ok`, or `dry_run` for a dry run, unless rows are `failed` or `refused`:
    #   then `partial` when some are, `failed` when all are, as {JsonEnvelope.action_status}), `exit_code`
    #   ({JsonEnvelope::ACTION_EXIT_CODES} of the status: 0, 3 or 1), `results` (one row per going run, oldest first:
    #   "workspace", "outcome", "reason", "message", "run_id", "step", "attempt", and "next_actions" on rows a person
    #   can act on; a scheduled backoff's row also has "due"; then one `failed/unreadable_run` row for each run file
    #   the store can't read, as `workflow sweep` gives) and `extra` (`next_actions`, every row's together, and
    #   `unreadable_files`, the paths of those files)
    def call(dry_run: false, &launch)
      runs = @store.going
      alive = @liveness.call(runs.map(&:workspace).compact.uniq)
      max = @config.recover_max_per_run
      now = @clock.call
      done = {}
      picked = []
      runs.each do |run|
        kind = classify(run, alive, max, now, dry_run)
        kind.key?("outcome") ? done[run.id] = kind : picked << kind
      end
      picked.group_by { |entry| entry[:run].workspace }.each do |workspace, entries|
        found = dry_run ? preview(workspace, entries) : recover(workspace, entries, launch, max)
        found.each { |row| done[row["run_id"]] = row }
      end
      unreadable = @store.unreadable
      rows = runs.map { |run| done.fetch(run.id) } + unreadable_rows(unreadable)
      status = if rows.any? { |each| JsonEnvelope::FAILED_OUTCOMES.include?(each["outcome"]) } then JsonEnvelope.action_status(rows)
      elsif dry_run then "dry_run"
      else
        "ok"
      end
      {exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(status), results: rows, status: status, extra: {"next_actions" => next_actions(rows, dry_run), "unreadable_files" => unreadable}}
    end

    private

    # A row for a run left alone (a `failed/unreadable_run` row, built from its id and workspace alone, when the stored
    # run is not shaped as a run), or `{kind:, run:}` for a run to restart (with the open attempt's `n`, which the
    # restart names to the engine) or wake.
    def classify(run, alive, max, now, dry_run)
      classify_run(run, alive, max, now, dry_run)
    rescue KeyError, TypeError, NoMethodError => e
      unreadable_row(run, e)
    end

    def classify_run(run, alive, max, now, dry_run)
      facts = read_facts(run, now)
      workspace, held, open, infra, recoveries = facts.values_at(:workspace, :held, :open, :infra, :recoveries)
      unless workspace && @project_config.project_root_for(workspace)
        return row(run, "skipped", "workspace_removed", "workspace '#{workspace}' no longer exists; cancel the run (`workspace workflow cancel #{run.id}`)")
      end
      if held
        return pane_gone_row(run, held) if held != "paused" && WorkflowRun.slot_dig(run.to_h, run.current, "reason", "code") == "pane_gone"
        return row(run, "skipped", held, "the run waits for a person (#{held}); see `workspace workflow status #{run.id}`")
      end
      live = alive[workspace]
      return row(run, "skipped", "unknown_liveness", "can't tell whether workspace '#{workspace}' has a tmux session (a custom socket, or tmux did not answer); check `tmux ls`, then run `workspace workflow status #{run.id}`") if live.nil?
      if live
        return row(run, "skipped", "nothing_to_restart", "workspace '#{workspace}' is running and step #{run.current} is between turns; the agent daemon moves it on when the agent's turn ends") unless open
        return row(run, "skipped", "pane_alive", "workspace '#{workspace}' is running and the run's pane is there") if @panes.alive?(run.id)
      end
      if open && infra && (live ? PENDING_INFRA : [:claimed]).include?(infra[:state])
        return row(run, "skipped", "infra_retry_pending", "step #{run.current} has an automatic restart #{infra[:state]}; another process is already restarting it, or the workspace's daemon will")
      end
      return {kind: :wake, run: run} unless open
      return limit_row(run, max) if recoveries >= max
      refusal = restart_refusal(run)
      # A line still being typed may finish within the restart's own wait, which a dry run says.
      typing = refusal&.code == "step_still_working"
      return row(run, "refused", refusal.code || "error", first_line(refusal)) if refusal && !typing
      {kind: :restart, run: run, n: open.n, typing: typing}
    end

    # What sorting a run reads of it.
    def read_facts(run, now)
      {workspace: run.workspace, held: WorkflowTransitions.held_reason(run.to_h), open: open_attempt(run),
       infra: WorkflowTransitions.infra_retry(run.to_h, now), recoveries: run.reboot_recoveries}
    end

    def unreadable_row(run, error)
      {"workspace" => run.to_h["workspace"], "outcome" => "failed", "reason" => "unreadable_run", "run_id" => run.id, "step" => nil, "attempt" => nil,
       "message" => "the run could not be read as a run (#{error.class}: #{first_line(error)})"}
    end

    # A held run whose retry or dispatch found its pane gone: left alone, with the commands to run by hand.
    def pane_gone_row(run, held)
      row(run, "skipped", held, "the run is held because its pane is gone; restore the workspace (`workspace restore #{run.workspace}`), then resume the run (`workspace workflow resume #{run.id}`)",
        actions: manual_actions(run, held, restart: false) + [NextAction.build("workflow resume", run.id, why: held)])
    end

    # The engine's refusal of a restart with the pane gone, returned or raised alike.
    def restart_refusal(run)
      @engine.restart_refusal(run, bound: "gone")
    rescue Workspace::Error => e
      e
    end

    # One `failed/unreadable_run` row for each run file the store can't read, as `workflow sweep` gives.
    def unreadable_rows(paths)
      paths.map do |path|
        {"workspace" => nil, "outcome" => "failed", "reason" => "unreadable_run", "message" => "The run file #{path} can't be read, so its run is not looked at. Fix or delete the file.",
         "run_id" => File.basename(path, ".json"), "step" => nil, "attempt" => nil}
      end
    end

    # The current step's last attempt while the step is running and the attempt has not ended.
    def open_attempt(run)
      step = run.step(run.current)
      return nil unless step&.state == "running"
      last = step.last_attempt
      (last && last.ended_at.nil?) ? last : nil
    end

    def limit_row(run, max)
      row(run, "refused", "limit_reached",
        "the run has had #{run.reboot_recoveries} of its #{max} reboot recoveries (workflows.recover.max_per_run); restore and restart it by hand",
        actions: manual_actions(run, "limit_reached", restart: true))
    end

    # `restore WS`, and for a restart run `workflow resume RUN --restart-step`.
    def manual_actions(run, why, restart:)
      [NextAction.build("restore", run.workspace, why: why)] + (restart ? [NextAction.build("workflow resume", run.id, "--restart-step", why: why)] : [])
    end

    def recover(workspace, entries, launch, max)
      failure = restore_failure(workspace) { @restore.call([workspace], &launch) }
      if failure
        return entries.map do |entry|
          row(entry[:run], "failed", "restore_failed", "could not restore workspace '#{workspace}': #{failure}",
            actions: manual_actions(entry[:run], "restore_failed", restart: entry[:kind] == :restart))
        end
      end
      restarts, wakes = entries.partition { |entry| entry[:kind] == :restart }
      rows = restarts.map { |entry| restart(workspace, entry, max) }
      live = wakes.empty? || @liveness.call([workspace])[workspace] == true
      rows + wakes.map { |entry| live ? wake(workspace, entry[:run]) : no_session_row(workspace, entry[:run]) }
    end

    # Why the restore of +workspace+ failed as a whole, nil when it did not: a raise, or a failed or unmatched row of
    # the workspace itself (a pane slot's row says nothing of this run's pane).
    def restore_failure(workspace)
      result = yield
      failed = Array(result && result[:results]).find do |each|
        each["kind"] == "workspace" && %w[failed unmatched].include?(each["outcome"]) && [nil, workspace].include?(each["workspace"])
      end
      failed && (failed["message"] || failed["reason"] || "its restore failed").to_s.lines.first.to_s.strip
    rescue Workspace::Error, SystemCallError => e
      first_line(e)
    end

    def no_session_row(workspace, run)
      row(run, "failed", "restore_failed", "workspace '#{workspace}' still has no tmux session after its restore, so the run was not woken",
        actions: manual_actions(run, "restore_failed", restart: false))
    end

    def restart(workspace, entry, max)
      run = entry[:run]
      moved = moved_row(entry)
      return moved if moved
      pane = @panes.pane_of(run.id)
      unless pane && @panes.alive?(run.id)
        what = pane ? "pane #{pane}, bound to the run, is not there" : "no pane is bound to the run"
        return row(run, "failed", "no_pane", "#{what} after restoring workspace '#{workspace}'", actions: manual_actions(run, "no_pane", restart: true))
      end
      ready = @readiness.wait(@session_name.call(workspace), deadline: @readiness.deadline_in(READY_SECONDS), only_pane: pane)
      unless ready.ready?
        return row(run, "failed", "pane_not_ready", "the agent in pane #{pane} did not get ready: #{ready.reason}", actions: manual_actions(run, "pane_not_ready", restart: true))
      end
      resume(workspace, entry, pane, max)
    end

    # Restarts the step, trying a `step_still_working` refusal again until {STILL_WORKING_SECONDS} pass and a
    # `restart_not_closed` one once; the run is read again before every try.
    def resume(workspace, entry, pane, max)
      run = entry[:run]
      deadline = @clock.call + STILL_WORKING_SECONDS
      closed_tried = false
      loop do
        moved = moved_row(entry)
        return moved if moved
        begin
          after = @engine.resume(run.id, actor: "person", restart_step: true, bound: "idle", reboot_recovery: {"workspace" => workspace, "attempt" => entry[:n]})
          return restarted_row(run, after, pane, max)
        rescue Workspace::Error => e
          case e.code
          when "step_still_working"
            if @clock.call >= deadline
              return row(run, "failed", "step_still_working", "step #{run.current} still reads as working after #{STILL_WORKING_SECONDS} seconds: #{first_line(e)}",
                actions: [NextAction.build("workflow resume", run.id, "--restart-step", why: "step_still_working")])
            end
          when "restart_not_closed"
            return row(run, "refused", e.code, first_line(e)) if closed_tried
            closed_tried = true
          when "no_open_attempt" then return moved_on(run)
          when "infra_retry_not_claimed" then return claimed_row(run)
          else return row(run, "refused", e.code || "error", first_line(e))
          end
          @sleeper.call(STILL_WORKING_POLL)
        end
      end
    end

    # A row when the run is no longer on the attempt seen when it was sorted, or an infra retry claim stands on it; nil
    # to go on. The engine checks both again under the run's lock.
    def moved_row(entry)
      run = entry[:run]
      fresh = reread(run)
      return moved_on(run) unless fresh && fresh.current == run.current && open_attempt(fresh)&.n == entry[:n]
      return claimed_row(run) if WorkflowTransitions.infra_retry(fresh.to_h, @clock.call)&.dig(:state) == :claimed
      nil
    end

    # The run as stored now; nil when it is gone or has finished.
    def reread(run)
      fresh = @store.run(run.id)
      WorkflowRunStore::TERMINAL_STATES.include?(fresh.state) ? nil : fresh
    rescue Workspace::Error
      nil
    end

    def claimed_row(run)
      row(run, "skipped", "infra_retry_pending", "another process is already restarting step #{run.current}")
    end

    def moved_on(run) = row(run, "skipped", "moved_on", "the run moved on while it was being recovered; nothing was changed")

    def restarted_row(run, after, pane, max)
      attempt = after.dig("steps", run.current, "attempts")&.last&.dig("n")
      count = after["reboot_recoveries"]
      row(run, "restarted", nil, "restarted step #{run.current} (attempt #{attempt}) in pane #{pane}; reboot recovery #{count} of #{max}").merge("attempt" => attempt)
    end

    def wake(workspace, run)
      fresh = reread(run)
      return moved_on(run) unless fresh && step_mark(fresh) == step_mark(run)
      backoff = WorkflowTransitions.backoff(fresh.to_h, @clock.call)
      after = @engine.tick(run.id, actor: "sweep")
      return row(run, "restored", "woken", "restored workspace '#{workspace}' and woke the run (step #{run.current})") if after
      if backoff && backoff[:state] == :waiting
        return row(run, "restored", "backoff", "restored workspace '#{workspace}'; step #{backoff[:to]} starts again at #{backoff[:until]}",
          actions: [NextAction.build("workflow sweep", run.id, why: "backoff")]).merge("due" => backoff[:until])
      end
      row(run, "restored", "nothing_due", "restored workspace '#{workspace}'; nothing was due, so its daemon and the sweep take the run from here")
    rescue Workspace::Error => e
      row(run, "failed", e.code || "error", first_line(e))
    end

    def preview(workspace, entries)
      failure = restore_failure(workspace) { @restore.call([workspace], dry_run: true) }
      if failure
        return entries.map do |entry|
          row(entry[:run], "failed", "restore_failed", "workspace '#{workspace}' would not be restored: #{failure}",
            actions: manual_actions(entry[:run], "restore_failed", restart: entry[:kind] == :restart))
        end
      end
      now = @clock.call
      entries.map do |entry|
        run = entry[:run]
        next would_restore(workspace, run, now) if entry[:kind] == :wake
        typing = entry[:typing] ? "; its line is still being typed, which the restart waits up to #{STILL_WORKING_SECONDS} seconds for" : ""
        row(run, "would_restart", nil, "would restore workspace '#{workspace}' and restart step #{run.current}#{typing}")
      end
    end

    # Where a run stands, as far as waking it goes: its step, that step's state, and its last attempt's number and end.
    def step_mark(run)
      step = run.step(run.current)
      last = step&.last_attempt
      [run.current, step&.state, last&.n, last&.ended_at]
    end

    def would_restore(workspace, run, now)
      backoff = WorkflowTransitions.backoff(run.to_h, now)
      message = "would restore workspace '#{workspace}' and wake the run (step #{run.current})"
      found = row(run, "would_restore", nil, message)
      return found unless backoff && backoff[:state] == :waiting
      found.merge("due" => backoff[:until], "message" => "#{message}; step #{backoff[:to]} starts again at #{backoff[:until]}")
    end

    def next_actions(rows, dry_run)
      actions = rows.flat_map { |each| each["next_actions"] || [] }
      count = rows.count { |each| each["outcome"].start_with?("would_") }
      if dry_run && count.positive?
        actions << NextAction.build("workflow recover", why: "dry run: would recover #{count} #{(count == 1) ? "run" : "runs"}; run without --dry-run to do it")
      end
      actions
    end

    def first_line(error) = error.message.lines.first.to_s.strip

    def row(run, outcome, reason, message, actions: nil)
      found = {"workspace" => run.workspace, "outcome" => outcome, "reason" => reason, "message" => message, "run_id" => run.id,
               "step" => run.current, "attempt" => open_attempt(run)&.n || run.step(run.current)&.last_attempt&.n}
      actions ? found.merge("next_actions" => actions) : found
    end
  end
end
