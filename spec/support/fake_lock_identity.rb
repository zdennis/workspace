# A stand-in for LockHolder: identifies a fixed agent and treats every
# recorded pid as alive unless explicitly marked dead, so tests can drive
# multiple "agents" deterministically without a real process tree.
class FakeLockIdentity
  def initialize(pid:, pane: "%1", worktree: "app")
    @pid = pid
    @pane = pane
    @worktree = worktree
    @dead = []
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
end

# A fake liveness checker driven by an explicit set of dead pids, rather than
# the real ProcessTree, so LockStore reaping scenarios are deterministic.
class FakeLockLiveness
  def initialize(dead: [])
    @dead = dead
  end

  def alive?(pid:, started:)
    !@dead.include?(pid)
  end

  def kill(pid)
    @dead << pid
  end
end
