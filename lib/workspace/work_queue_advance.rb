require "json"

module Workspace
  # One pass of a workspace's work queue: reads the current item's run and finishes or holds the item,
  # then starts the next queued item when nothing blocks. A start is claimed under the store's lock,
  # run outside it, and recorded under it again, so two passes never start the same item.
  class WorkQueueAdvance
    # The run reasons that mean a step failed: the item is held and the queue paused.
    FAILURE_REASONS = %w[failed_check budget_spent run_timed_out].freeze

    # @param store_factory [#call] workspace name to its {WorkQueueStore}
    # @param run_store [WorkflowRunStore]
    # @param starters [Hash{String=>#call}] kind to starter, as {WorkQueueStarters#to_h} gives
    # @param lock_holder [LockHolder] the claiming process's start time and a claim holder's liveness
    # @param status [WorkflowStatus] a parked run's actions
    # @param clock [#now]
    def initialize(store_factory:, run_store:, starters:, lock_holder:, status:, clock: Time)
      @store_factory = store_factory
      @run_store = run_store
      @starters = starters
      @lock_holder = lock_holder
      @status = status
      @clock = clock
    end

    # Runs one pass. The current item is reconciled whatever the toggle or pause; only a new start is refused.
    #
    # @param workspace [String] the queue's workspace
    # @param checkout [Workspace::Commands::WorkflowStart::Here] where its items start
    # @return [Array<Hash>] rows of `"outcome"`, `"id"`, `"kind"`, `"reason"`, `"run_id"` and `"next_actions"`
    # @raise [Workspace::Error] when the queue or a run file can't be read
    def call(workspace:, checkout:)
      store = @store_factory.call(workspace)
      rows = []
      claimed = store.transaction do |queue|
        reconcile(queue, workspace, rows)
        next nil if queue.current
        refusal = refusal(queue, workspace)
        if refusal
          rows << refusal
          next nil
        end
        claimed = queue.claim_next(claimed_by: {"pid" => Process.pid, "started" => own_start_time})
        claimed && JSON.parse(JSON.generate(claimed))
      end
      rows << start(store, claimed, workspace, checkout) if claimed
      rows.map { |each| parked_row?(each) ? each.merge("next_actions" => park_actions(each["run_id"])) : each }
    end

    private

    def reconcile(queue, workspace, rows)
      item = queue.current
      return unless item
      if item["state"] == "starting"
        return rows << starting_row(item, workspace) if holder_alive?(item["claimed_by"])
        run = claimed_run(item)
        return rows << interrupted(queue, item, workspace, "interrupted") unless run
        item = queue.adopt(item["id"], run_id: run.id)
      end
      rows << check_run(queue, item, workspace)
    end

    def check_run(queue, item, workspace)
      run = read_run(item.dig("result", "run_id"))
      return interrupted(queue, item, workspace, "unknown_run") unless run
      id = run.id
      case run.state
      when "completed"
        queue.finish(item["id"], outcome: "succeeded")
        return row("succeeded", item, run_id: id)
      when "failed", "cancelled"
        queue.finish(item["id"], outcome: run.state, reason: run.state)
        return row(run.state, item, reason: run.state, run_id: id) if item["on_fail"] == "continue"
        queue.pause(run.state)
        return row(run.state, item, reason: run.state, run_id: id, next_actions: [resume(workspace)])
      end
      if WorkflowEngine.parked(run.to_h, @clock.now) == :waiting
        hold(queue, item, "parked")
        return row("held", item, reason: "parked", run_id: id)
      end
      if run.current_step&.gate_waiting?
        hold(queue, item, "gate")
        return row("held", item, reason: "gate", run_id: id, next_actions: [NextAction.build("workflow approve", id)])
      end
      code = run.reason_for(run.current)&.dig("code")
      if FAILURE_REASONS.include?(code)
        queue.pause(code) if hold(queue, item, code)
        return row("held", item, reason: code, run_id: id,
          next_actions: [NextAction.build("workflow status", id), NextAction.build("work-queue skip", item["id"], "--name", workspace)])
      end
      queue.unhold(item["id"])
      row("active", item, run_id: id, next_actions: [NextAction.build("workflow status", id)])
    end

    def refusal(queue, workspace)
      return row("unchanged", nil, reason: "disabled", next_actions: [NextAction.build("work-queue enable", "--name", workspace)]) unless queue.enabled == true
      return row("unchanged", nil, reason: "paused", next_actions: [resume(workspace)]) if queue.paused
      return row("unchanged", nil, reason: "empty") if queue.items.empty?
      going = @run_store.going.find { |run| run.workspace == workspace }
      row("unchanged", nil, reason: "run_going", run_id: going.id, next_actions: [NextAction.build("workflow status", going.id)]) if going
    end

    def start(store, item, workspace, checkout)
      id = item["id"]
      claim = item["claim"]
      starter = @starters[item["kind"]]
      return launch_failed(store, item, workspace, "unknown_kind", "No starter for queue items of kind #{item["kind"].inspect}.") unless starter
      begin
        run_id = starter.call(item, workspace: workspace, checkout: checkout, note: "Started by work-queue item #{id} (claim #{claim})")
      rescue Workspace::Error => e
        return launch_failed(store, item, workspace, launch_reason(e), e.message, run: claimed_run(item))
      end
      store.transaction do |queue|
        next row("started", item, run_id: run_id, next_actions: [NextAction.build("workflow status", run_id)]) if queue.record_run(id, claim: claim, run_id: run_id) == :recorded
        claim_lost(queue, item, workspace, run_id)
      end
    end

    def launch_failed(store, item, workspace, reason, error, run: nil)
      store.transaction do |queue|
        next recorded_or_lost(queue, item, workspace, run.id) if run
        next claim_lost(queue, item, workspace, nil) if queue.finish(item["id"], outcome: "launch_failed", reason: reason, error: error, claim: item["claim"]) == :lost
        queue.pause("launch_failed")
        row("launch_failed", item, reason: reason, next_actions: [history_show(item, workspace), resume(workspace)])
      end
    end

    def recorded_or_lost(queue, item, workspace, run_id)
      return claim_lost(queue, item, workspace, run_id) if queue.record_run(item["id"], claim: item["claim"], run_id: run_id) == :lost
      check_run(queue, queue.items.find { |i| i["id"] == item["id"] }, workspace)
    end

    def claim_lost(queue, item, workspace, run_id)
      queue.pause("claim_lost")
      actions = run_id ? [NextAction.build("workflow status", run_id)] : []
      row("claim_lost", item, reason: "claim_lost", run_id: run_id, next_actions: actions + [resume(workspace)])
    end

    def interrupted(queue, item, workspace, reason)
      queue.finish(item["id"], outcome: "interrupted", reason: reason)
      queue.pause(reason)
      row("interrupted", item, reason: reason, run_id: item.dig("result", "run_id"), next_actions: [history_show(item, workspace), resume(workspace)])
    end

    def hold(queue, item, reason)
      return false if item["state"] == "held" && item["reason"] == reason
      queue.unhold(item["id"])
      !queue.hold(item["id"], reason: reason).nil?
    end

    def launch_reason(error)
      return "usage_error" if error.is_a?(UsageError) && error.code == "usage"
      return "start_failed" if error.code == "error"
      error.code
    end

    def holder_alive?(claimed_by)
      claimed_by = claimed_by.is_a?(Hash) ? claimed_by : {}
      @lock_holder.holder_alive?(pid: claimed_by["pid"], started: claimed_by["started"])
    rescue Workspace::Error
      true
    end

    def own_start_time
      @lock_holder.start_time(Process.pid)
    rescue Workspace::Error
      nil
    end

    def claimed_run(item)
      mark = "(claim #{item["claim"]})"
      since = begin
        Time.iso8601(item["claimed_at"].to_s)
      rescue ArgumentError
        Time.at(0)
      end
      (@run_store.unarchived + @run_store.finished_since(since)).find { |run| run.note.to_s.include?(mark) }
    end

    def read_run(id)
      return nil unless id
      @run_store.run(id)
    rescue Workspace::Error => e
      raise unless e.code == "unknown_run"
      nil
    end

    def park_actions(run_id)
      actions = @status.run(run_id).dig("runs", 0, "current", "reason", "actions")
      (actions.is_a?(Array) && !actions.empty?) ? actions : [NextAction.build("workflow status", run_id)]
    rescue Workspace::Error
      [NextAction.build("workflow status", run_id)]
    end

    def parked_row?(row)
      row["outcome"] == "held" && row["reason"] == "parked"
    end

    def starting_row(item, workspace)
      why = "Item #{item["id"]} is being started by another pass; run advance again once its start has landed."
      row("unchanged", item, reason: "starting", next_actions: [NextAction.build("work-queue status", "--name", workspace, why: why)])
    end

    def resume(workspace)
      NextAction.build("work-queue resume", "--name", workspace)
    end

    def history_show(item, workspace)
      NextAction.build("work-queue history show", item["id"], "--name", workspace)
    end

    def row(outcome, item, reason: nil, run_id: nil, next_actions: [])
      {"outcome" => outcome, "id" => item&.dig("id"), "kind" => item&.dig("kind"), "reason" => reason, "run_id" => run_id, "next_actions" => next_actions}
    end
  end
end
