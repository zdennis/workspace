require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::HeldLocks do
  let(:tmpdir) { Dir.mktmpdir("ws-held-locks") }
  let(:liveness) { FakeLockLiveness.new }
  let(:store) { Workspace::LockStore.new(dir: tmpdir, liveness: liveness) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "k", display: "app", dir: tmpdir}) }
  let(:lock_holder) { instance_double(Workspace::LockHolder, current: current) }
  let(:bound_run) { instance_double(Workspace::BoundRun, run_id: run_id) }
  let(:me) { agent(100, pane: "%1") }
  let(:current) { me }
  let(:run_id) { nil }
  let(:env) { {"TMUX_PANE" => "%1"} }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  subject(:held) do
    described_class.new(lock_namespace: lock_namespace, lock_holder: lock_holder, bound_run: bound_run,
      store_factory: ->(_dir) { store }, env: env)
  end

  def agent(pid, pane:)
    {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "/src/app"}
  end

  def process(pid, pane:)
    {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, pane: pane, worktree: "/src/app", branch: "main"}
  end

  def take(name, identity)
    store.acquire(name, identity: identity, waiter_pid: identity[:pid], waiter_started: identity[:started])
  end

  before do
    take("mine", me)
    take("theirs", agent(200, pane: "%2"))
    take("devenv", process(300, pane: "%1"))
    take("their-dev", process(400, pane: "%2"))
    store.acquire_run(["test-db"], run: {run_id: "wr_1", step: "verify", workflow: "rpiv", workspace: "app", worktree: "/src/app", pane: "%5"})
  end

  it "lists only the caller's agent lock and the process lock started from its pane" do
    expect(held.call("/src/app")).to eq(names: %w[devenv mine], own: true)
  end

  context "when the caller's pane is bound to a run" do
    let(:run_id) { "wr_1" }

    it "lists the run's locks too" do
      expect(held.call("/src/app")).to eq(names: %w[devenv mine test-db], own: true)
    end
  end

  it "leaves out a lock whose holder is gone" do
    liveness.kill(100)

    expect(held.call("/src/app")).to eq(names: %w[devenv], own: true)
  end

  context "when the caller cannot be told" do
    let(:current) { nil }
    let(:env) { {} }

    it "lists every live lock and says they may not be the caller's" do
      expect(held.call("/src/app")).to eq(names: %w[devenv mine test-db their-dev theirs], own: false)
    end
  end

  it "lists every live lock, as maybe not the caller's, when the process table cannot be read and only the pane is known" do
    allow(lock_holder).to receive(:current).and_raise(Workspace::Error, "ps failed")

    expect(held.call("/src/app")).to eq(names: %w[devenv mine test-db their-dev theirs], own: false)
  end

  context "when the caller is in no pane" do
    let(:env) { {} }

    it "leaves out every process lock" do
      expect(held.call("/src/app")).to eq(names: %w[mine], own: true)
    end
  end

  context "when the caller's pane is bound to another run" do
    let(:run_id) { "wr_2" }

    it "leaves out the first run's locks" do
      expect(held.call("/src/app")).to eq(names: %w[devenv mine], own: true)
    end
  end

  context "when only a bound run identifies the caller" do
    let(:current) { nil }
    let(:run_id) { "wr_1" }

    it "lists the run's locks and the process lock from its pane" do
      expect(held.call("/src/app")).to eq(names: %w[devenv test-db], own: true)
    end
  end

  it "is empty when the repository has no lock directory" do
    allow(lock_namespace).to receive(:resolve).and_return({dir: File.join(tmpdir, "none")})

    expect(held.call("/src/app")).to eq(names: [], own: true)
  end
end
