require "rbconfig"
require "time"

module Workspace
  # The agent daemon's part in a workflow: when a turn ends in a pane bound
  # to a run, and every so often for a run nothing else would wake, it
  # starts `workspace workflow advance` as its own process and goes back to
  # serving hooks. The run's transitions (a check that takes twenty minutes,
  # a `/clear` and a typed line) happen there, never on the daemon's threads.
  # While the workspace has a going run, its tick also starts
  # `workspace workflow sweep --name WORKSPACE` the same way, at most once
  # every {SWEEP_INTERVAL} seconds, so stalled and timed-out steps are
  # recovered without the opt-in launchd sweep.
  #
  # Nothing here raises: a run that can't be woken shows as stuck in
  # `workflow status`, and the daemon keeps running.
  class WorkflowNudger
    # Seconds between two sweeps the tick starts for one workspace.
    SWEEP_INTERVAL = 300

    # @param store [Workspace::WorkflowRunStore]
    # @param panes [Workspace::WorkflowPanes] names the run a pane is bound to
    # @param executable [String] path to `bin/workspace`
    # @param log_path [#call] the file a workspace's advance processes write to
    # @param spawner [#call] starts a detached process: `(argv, log)`
    # @param holder_alive [#call, nil] given a review round's delivery `holder`, whether that process still runs, so
    #   a lapsed round is woken only once its holder is gone (nil takes every holder as alive)
    # @param clock [#call] returns the current Time
    # @param downtime [Workspace::WorkflowDowntime, nil] beaten first on every tick (its heartbeat)
    # @param logger [Workspace::Logger]
    # @param error_output [IO] the daemon's log, for a run that can't be looked at
    def initialize(store:, panes:, executable:, log_path:, spawner: nil, holder_alive: nil, clock: -> { Time.now }, downtime: nil, logger: Workspace::Logger.new, error_output: $stderr)
      @downtime = downtime
      @holder_alive = holder_alive
      @error_output = error_output
      @store = store
      @panes = panes
      @executable = executable
      @log_path = log_path
      @spawner = spawner || method(:spawn_detached)
      @clock = clock
      @logger = logger
      @last_sweep = {}
      @last_reasons = {}
      @lock = Mutex.new
    end

    # @param workspace [String] the daemon's workspace
    # @param pane_id [String] the pane the main agent's turn ended in
    # @param turn_started [Time, nil] when that turn began, when it is known; lets the
    #   run tell its step's own turn from one that was under way before the step started
    # @param background [Array<Hash>, nil] the tasks (`"id"`, `"type"`) the Stop listed as still going
    # @param hook_log [Workspace::HookEventLog, nil] the workspace's log, given by the caller that holds it; nil writes nothing
    # @return [String, nil] the run that was woken; nil for a pane bound to none
    def turn_ended(workspace, pane_id, turn_started: nil, background: nil, hook_log: nil)
      # A review pane's turn ends its round, so a pane bound in any role wakes its run.
      run_id = @panes.bound_on(pane_id)&.fetch(:run_id)
      return nil unless run_id
      started = turn_started ? ["--turn-started", turn_started.utc.iso8601(3)] : []
      tasks = Array(background).flat_map { |task| ["--background-task", "#{task["type"]}:#{task["id"]}"] }
      record(hook_log, "workflow_advance_started", pane_id, "run_id" => run_id, "cause" => "turn_ended")
      advance(workspace, run_id, "--turn-ended", "--pane", pane_id, *started, "--stopped-at", @clock.call.utc.iso8601(3), *tasks)
      run_id
    rescue => e
      @logger.debug { "workflow: could not wake the run on #{pane_id} (#{e.class}: #{e.message})" }
      nil
    end

    # Wakes each of the workspace's runs that has a parked resume, waits for
    # a lock (a review round's `review.uses` too), or whose check or review
    # round never reported back, or whose review round has to be delivered again
    # ({WorkflowEngine.wakeable?}). Then, when the workspace has a going run and
    # no sweep started in the last {SWEEP_INTERVAL} seconds (or none yet), starts
    # `workflow sweep` for it; a failure there never stops the advances.
    #
    # Each wake and sweep is a line in the hook log. A run that is not woken is logged
    # only when its reason differs from the last tick's, and the memory of reasons keeps
    # only the runs still going.
    #
    # @param workspace [String] the daemon's workspace
    # @param hook_log [Workspace::HookEventLog, nil] the workspace's log, given by the caller that holds it; nil writes nothing
    # @return [Array<String>] the runs that were woken
    def tick(workspace, hook_log: nil)
      beat
      now = @clock.call
      runs = @store.going.select { |run| run.workspace == workspace }
      stops = downtime_stops(now)
      note_reasons(workspace, runs.map(&:id))
      woken = runs.filter_map do |run|
        wake = WorkflowEngine.wakeable?(run.to_h, now, alive: @holder_alive, stops: stops)
        reason = (wake || skip_reason(run.to_h)).to_s
        changed = reason_changed?(workspace, run.id, reason)
        unless wake
          record(hook_log, "workflow_run_skipped", nil, "run_id" => run.id, "reason" => reason) if changed
          next
        end
        record(hook_log, "workflow_advance_started", nil, "run_id" => run.id, "cause" => "tick", "reason" => reason)
        advance(workspace, run.id)
        run.id
      rescue => e
        # One malformed run file must not stop the others from being woken.
        @error_output.puts "workflow: could not look at run #{run.id} (#{e.class}: #{e.message}); its run file may be malformed"
        nil
      end
      sweep(workspace, runs, now, hook_log)
      woken
    rescue => e
      @logger.debug { "workflow: tick failed (#{e.class}: #{e.message})" }
      []
    end

    private

    # The heartbeat is a side record: a failure to write it must not skip the tick.
    def beat
      @downtime&.beat
    rescue => e
      @logger.debug { "workflow: could not beat the heartbeat (#{e.class}: #{e.message})" }
    end

    # Read once a tick, so a wake after downtime starts no advance for a clock the downtime stopped.
    def downtime_stops(now)
      @downtime&.spans(now) || []
    rescue => e
      @logger.debug { "workflow: could not read the downtime (#{e.class}: #{e.message})" }
      []
    end

    def sweep(workspace, runs, now, hook_log)
      return if runs.empty?
      due = @lock.synchronize do
        last = @last_sweep[workspace]
        # Recorded before the spawn, so a spawn that raises is not retried on every tick.
        (@last_sweep[workspace] = now) unless last && now - last < SWEEP_INTERVAL
      end
      return unless due
      record(hook_log, "workflow_sweep_started", nil, "run_ids" => runs.map(&:id))
      @spawner.call([RbConfig.ruby, @executable, "workflow", "sweep", "--name", workspace], @log_path.call(workspace))
    rescue => e
      @logger.debug { "workflow: could not start the sweep for #{workspace} (#{e.class}: #{e.message})" }
    end

    # Why a run that nothing wakes is left alone, as far as its stored state says.
    def skip_reason(run)
      return "paused" if run["paused"]
      run.dig("reason", "code") || "not_due"
    end

    # Forgets this workspace's runs that are no longer going, so the memory does not grow with every run seen.
    def note_reasons(workspace, going_ids)
      @lock.synchronize { @last_reasons.delete_if { |(name, id), _| name == workspace && !going_ids.include?(id) } }
    end

    # Whether the run's reason differs from the last tick's; remembers it.
    def reason_changed?(workspace, run_id, reason)
      @lock.synchronize do
        changed = @last_reasons[[workspace, run_id]] != reason
        @last_reasons[[workspace, run_id]] = reason
        changed
      end
    end

    # A decision line is a side record: it never stops the decision it describes.
    def record(hook_log, type, pane_id, fields)
      hook_log&.append(type, pane_id, fields)
    rescue => e
      @logger.debug { "workflow: could not log #{type} (#{e.class}: #{e.message})" }
    end

    def advance(workspace, run_id, *flags)
      @spawner.call([RbConfig.ruby, @executable, "workflow", "advance", run_id, *flags], @log_path.call(workspace))
    end

    def spawn_detached(argv, log)
      # The daemon may have been started from a pane: that pane is not this process's caller.
      Process.detach(Process.spawn({"TMUX_PANE" => nil}, *argv, in: File::NULL, out: [log, "a"], err: [log, "a"]))
    end
  end
end
