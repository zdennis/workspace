# A stand-in for LockHolder: identifies a fixed agent and treats every
# recorded pid as alive unless explicitly marked dead, so tests can drive
# multiple "agents" deterministically without a real process tree.
class FakeLockIdentity
  def initialize(pid:, pane: "%1", worktree: "app")
    @pid = pid
    @pane = pane
    @worktree = worktree
    @dead = []
    @ended_runs = []
  end

  def current
    {kind: "agent", pid: @pid, started: "start-#{@pid}", pane: @pane, worktree: @worktree}
  end

  def start_time(pid = Process.pid)
    "start-#{pid}"
  end

  def alive?(pid:, started:)
    !@dead.include?(pid) && started == "start-#{pid}"
  end

  def kill(pid)
    @dead << pid
  end

  # A run counts as alive until the spec ends it, as a run does until its run
  # file is terminal or gone.
  def run_alive?(run_id)
    !@ended_runs.include?(run_id)
  end

  def end_run(run_id)
    @ended_runs << run_id
  end
end

# A fake liveness checker driven by an explicit set of dead pids, rather than
# the real ProcessTree, so LockStore reaping scenarios are deterministic.
class FakeLockLiveness
  def initialize(dead: [])
    @dead = dead
    @ended_runs = []
  end

  def alive?(pid:, started:)
    !@dead.include?(pid)
  end

  def start_time(pid = Process.pid)
    "start-#{pid}"
  end

  def kill(pid)
    @dead << pid
  end

  # A run counts as alive until the spec ends it, as a run does until its run
  # file is terminal or gone.
  def run_alive?(run_id)
    !@ended_runs.include?(run_id)
  end

  def end_run(run_id)
    @ended_runs << run_id
  end
end
