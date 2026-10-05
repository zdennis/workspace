require "rbconfig"
require "time"

module Workspace
  # The agent daemon's part in a workflow: when a turn ends in a pane bound
  # to a run, and every so often for a run nothing else would wake, it
  # starts `workspace workflow advance` as its own process and goes back to
  # serving hooks. The run's transitions (a check that takes twenty minutes,
  # a `/clear` and a typed line) happen there, never on the daemon's threads.
  #
  # Nothing here raises: a run that can't be woken shows as stuck in
  # `workflow status`, and the daemon keeps running.
  class WorkflowNudger
    # @param store [Workspace::WorkflowRunStore]
    # @param panes [Workspace::WorkflowPanes] names the run a pane is bound to
    # @param executable [String] path to `bin/workspace`
    # @param log_path [#call] the file a workspace's advance processes write to
    # @param spawner [#call] starts a detached process: `(argv, log)`
    # @param clock [#call] returns the current Time
    # @param logger [Workspace::Logger]
    # @param error_output [IO] the daemon's log, for a run that can't be looked at
    def initialize(store:, panes:, executable:, log_path:, spawner: nil, clock: -> { Time.now }, logger: Workspace::Logger.new, error_output: $stderr)
      @error_output = error_output
      @store = store
      @panes = panes
      @executable = executable
      @log_path = log_path
      @spawner = spawner || method(:spawn_detached)
      @clock = clock
      @logger = logger
    end

    # @param workspace [String] the daemon's workspace
    # @param pane_id [String] the pane the main agent's turn ended in
    # @param turn_started [Time, nil] when that turn began, when it is known; lets the
    #   run tell its step's own turn from one that was under way before the step started
    # @return [String, nil] the run that was woken; nil for a pane bound to none
    def turn_ended(workspace, pane_id, turn_started: nil)
      run_id = @panes.run_on(pane_id)
      return nil unless run_id
      started = turn_started ? ["--turn-started", turn_started.utc.iso8601(3)] : []
      advance(workspace, run_id, "--turn-ended", "--pane", pane_id, *started)
      run_id
    rescue => e
      @logger.debug { "workflow: could not wake the run on #{pane_id} (#{e.class}: #{e.message})" }
      nil
    end

    # Wakes each of the workspace's runs that waits for a lock, or whose
    # check never reported back.
    #
    # @param workspace [String] the daemon's workspace
    # @return [Array<String>] the runs that were woken
    def tick(workspace)
      now = @clock.call
      @store.active.select { |run| run["workspace"] == workspace }.filter_map do |run|
        next unless WorkflowEngine.wakeable?(run, now)
        advance(workspace, run["id"])
        run["id"]
      rescue => e
        # One malformed run file must not stop the others from being woken.
        @error_output.puts "workflow: could not look at run #{run["id"]} (#{e.class}: #{e.message}); its run file may be malformed"
        nil
      end
    rescue => e
      @logger.debug { "workflow: tick failed (#{e.class}: #{e.message})" }
      []
    end

    private

    def advance(workspace, run_id, *flags)
      @spawner.call([RbConfig.ruby, @executable, "workflow", "advance", run_id, *flags], @log_path.call(workspace))
    end

    def spawn_detached(argv, log)
      Process.detach(Process.spawn(*argv, in: File::NULL, out: [log, "a"], err: [log, "a"]))
    end
  end
end
