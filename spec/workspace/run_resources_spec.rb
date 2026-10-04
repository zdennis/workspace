require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::RunResources do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-run-resources")) }
  let(:store_dir) { File.join(tmpdir, "locks", "ns") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:liveness) { FakeLockLiveness.new }
  let(:now) { [5_000] }

  subject(:resources) { described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first }) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).with(cwd: "/src/app-a").and_return(key: "ns", display: "app", dir: store_dir)
  end

  def store
    Workspace::LockStore.new(dir: store_dir, liveness: liveness, clock: -> { now.first })
  end

  def holder(name)
    store.status(name).dig(name, "holder")
  end

  def acquire(uses, run_id: "wr_1", step: "verify", **rest)
    resources.acquire(run_id: run_id, step: step, uses: uses, worktree: "/src/app-a", **rest)
  end

  describe ".names" do
    it "sorts and de-duplicates a step's uses" do
      expect(described_class.names(%w[test-db devenv test-db])).to eq(%w[devenv test-db])
    end

    it "takes dev-env as the devenv lock, so a step and `dev up` stand in one queue" do
      expect(described_class.names(%w[dev-env])).to eq(%w[devenv])
      expect(described_class.names(%w[dev-env devenv])).to eq(%w[devenv])
    end

    it "takes one name as a list of one, and nothing as none" do
      expect(described_class.names("test-db")).to eq(%w[test-db])
      expect(described_class.names(nil)).to eq([])
      expect(described_class.names([])).to eq([])
    end

    it "refuses anything that is not a lock name" do
      [["bad name"], [""], [nil], [1], ["../x"], {"name" => "test-db"}, 7, [["a"]]].each do |uses|
        expect { described_class.names(uses) }.to raise_error(Workspace::UsageError, /uses/)
      end
    end

    it "refuses the edit lock, which only the agent that edits can hold" do
      expect { described_class.names(%w[test-db edit]) }
        .to raise_error(Workspace::UsageError, /uses: edit is not a resource a run can hold/)
    end
  end

  describe "#acquire" do
    it "holds a step's resources for the run, with what the run is for" do
      result = acquire(%w[test-db dev-env], workflow: "rpiv", workspace: "app.worktree-a", pane: "%4")

      expect(result).to include(status: :acquired, held: %w[devenv test-db], acquired: %w[devenv test-db])
      expect(holder("devenv")).to include("kind" => "run", "run_id" => "wr_1", "step" => "verify", "workflow" => "rpiv",
        "workspace" => "app.worktree-a", "worktree" => "/src/app-a", "pane" => "%4")
    end

    it "reports who it waits behind, without blocking" do
      acquire(%w[test-db], run_id: "wr_1", step: "implement", workspace: "app.worktree-a")

      result = acquire(%w[devenv test-db], run_id: "wr_2")

      expect(result).to include(status: :waiting, held: %w[devenv])
      expect(result[:waiting]).to include(name: "test-db", position: 1, total: 2, queued: true)
      expect(result[:waiting][:holder]).to include("run_id" => "wr_1", "step" => "implement", "workspace" => "app.worktree-a")
    end

    it "holds the lock once the run ahead releases it" do
      acquire(%w[test-db], run_id: "wr_1")
      acquire(%w[test-db], run_id: "wr_2")

      resources.release(run_id: "wr_1", worktree: "/src/app-a")

      expect(acquire(%w[test-db], run_id: "wr_2")).to include(status: :acquired, acquired: %w[test-db])
    end

    it "takes nothing for a run with no unfinished run file" do
      liveness.end_run("wr_1")

      expect(acquire(%w[test-db])).to include(status: :not_alive, held: [])
      expect(holder("test-db")).to be_nil
    end

    it "names a released resource the run's dev environment still holds, so the runner can stop it" do
      acquire(%w[devenv])
      store.delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 500, started: "start-500", pgid: 500})

      expect(acquire(nil)).to include(released: %w[devenv], handed_over: %w[devenv])
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "releases everything the run holds for a step that uses nothing" do
      acquire(%w[test-db])

      expect(acquire(nil)).to include(status: :acquired, held: [], released: %w[test-db])
      expect(holder("test-db")).to be_nil
    end

    it "uses the project's idle grace when it takes over from an idle agent" do
      lock_config = instance_double(Workspace::LockConfig)
      allow(lock_config).to receive(:idle_grace_for).with("app").and_return(30)
      with_config = described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, lock_config: lock_config,
        wall_clock: -> { now.first })
      agent = {kind: "agent", pid: 100, started: "start-100", pane: "%1", worktree: "app"}
      store.acquire("test-db", identity: agent, waiter_pid: 100, waiter_started: "start-100")
      store.mark_idle(agent, idle: true)
      with_config.acquire(run_id: "wr_1", step: "verify", uses: %w[test-db], worktree: "/src/app-a")
      now[0] += 31

      result = with_config.acquire(run_id: "wr_1", step: "verify", uses: %w[test-db], worktree: "/src/app-a")

      expect(result).to include(status: :acquired, took_over: include("test-db"))
    end

    it "refuses a run id or step that could not be a file name or one line" do
      expect { acquire(%w[test-db], run_id: "../x") }.to raise_error(Workspace::UsageError, /run id/)
      expect { acquire(%w[test-db], run_id: "") }.to raise_error(Workspace::UsageError, /run id/)
      expect { acquire(%w[test-db], step: "a\nb") }.to raise_error(Workspace::UsageError, /step/)
      expect(File.exist?(store_dir)).to be(false)
    end
  end

  describe "#release" do
    it "releases every lock the run holds and reports them" do
      acquire(%w[devenv test-db])

      expect(resources.release(run_id: "wr_1", worktree: "/src/app-a")).to eq(%w[devenv test-db])
      expect([holder("devenv"), holder("test-db")]).to eq([nil, nil])
    end

    it "releases only the named resources, by alias too" do
      acquire(%w[devenv test-db])

      expect(resources.release(run_id: "wr_1", worktree: "/src/app-a", names: %w[dev-env])).to eq(%w[devenv])
      expect(holder("test-db")).to include("run_id" => "wr_1")
    end

    it "does nothing, and creates nothing, for a repository with no lock store" do
      expect(resources.release(run_id: "wr_1", worktree: "/src/app-a")).to eq([])
      expect(File.exist?(store_dir)).to be(false)
    end
  end

  describe "in a real repository" do
    let(:main) { File.join(tmpdir, "app") }
    let(:worktree) { File.join(tmpdir, "app-login") }
    let(:config) { instance_double(Workspace::Config, lock_dir: File.join(tmpdir, "state", "locks")) }
    let(:real) do
      described_class.new(lock_namespace: Workspace::LockNamespace.new(config: config), lock_holder: liveness)
    end

    def git(*args)
      system("git", *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(" ")} failed"
    end

    before do
      git("init", "-q", "-b", "main", main)
      git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
      git("-C", main, "worktree", "add", "-q", "-b", "feat/login", worktree)
    end

    it "serializes two runs in different worktrees of one repository on a shared resource" do
      first = real.acquire(run_id: "wr_1", step: "verify", uses: %w[test-db], worktree: main)
      second = real.acquire(run_id: "wr_2", step: "verify", uses: %w[test-db], worktree: worktree)

      expect(first).to include(status: :acquired)
      expect(second).to include(status: :waiting)
      expect(second[:waiting]).to include(name: "test-db", holder: include("run_id" => "wr_1", "worktree" => main))
      expect(Dir.children(config.lock_dir).size).to eq(1)
    end

    it "keeps a run's locks through the SessionEnd and /clear release of the agent in its pane" do
      real.acquire(run_id: "wr_1", step: "implement", uses: %w[devenv test-db], worktree: worktree, pane: "%1")
      agent = FakeLockIdentity.new(pid: 100, pane: "%1", worktree: worktree)
      namespace = Workspace::LockNamespace.new(config: config)
      dir = namespace.resolve(cwd: worktree)[:dir]
      id = agent.current
      Workspace::LockStore.new(dir: dir, liveness: agent).acquire("edit", identity: id, waiter_pid: 100, waiter_started: id[:started])
      enforcer = Workspace::LockEnforcer.new(config: config, lock_namespace: namespace, lock_holder: agent)

      expect(enforcer.release_all(cwd: worktree)).to eq(%w[edit])

      status = Workspace::LockStore.new(dir: dir, liveness: agent).status
      expect(status["devenv"]["holder"]).to include("kind" => "run", "run_id" => "wr_1")
      expect(status["test-db"]["holder"]).to include("kind" => "run", "run_id" => "wr_1")
      expect(status["edit"]["holder"]).to be_nil
    end
  end
end
