require "tmpdir"
require "socket"

# Adversarial probes for commit 15c1d9e ("show every lock a pane holds or
# waits on"). Each example is a confirmed defect, not a spec bug — see the ID
# prefix in the description for cross-reference with the review report.
RSpec.describe Workspace::Commands::Sessions do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }
  let(:socket_path) { File.join(tmpdir, "agent.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: lock_dir}) }
  let(:lock_holder) { FakeLockLiveness.new }
  let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: "/projects/proj") }

  let(:payload) do
    {
      "workspace" => "proj",
      "updated_at" => "2026-09-26T12:00:00Z",
      "panes" => [
        {"pane_id" => "%1", "index" => 0, "kind" => "claude", "label" => "Claude Code",
         "state" => "working", "idle_seconds" => 0, "agents" => []},
        {"pane_id" => "%2", "index" => 1, "kind" => "shell", "label" => "zsh",
         "state" => "idle", "idle_seconds" => 192, "agents" => []}
      ]
    }
  end

  subject(:command) do
    described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      project_config: project_config, output: output, error_output: error_output)
  end

  before { allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path) }

  after { FileUtils.remove_entry(tmpdir) }

  def with_daemon(reply: payload)
    server = UNIXServer.new(socket_path)
    listener = Thread.new do
      client = server.accept
      client.gets
      client.puts(JSON.generate(reply)) if reply
      client.close
    end
    yield
    listener.join(2)
  ensure
    server&.close
  end

  def acquire(name, pid:, pane:, wait: false)
    store = Workspace::LockStore.new(dir: lock_dir, liveness: lock_holder)
    identity = {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
    store.acquire(name, identity: identity, waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
  end

  # SX1: a pane that holds a lock while a *different* agent in the same pane
  # is also queued for it (two sub-agents sharing one pane, a normal
  # multi-agent scenario) is stamped with two entries for the same lock name
  # instead of being deduplicated the way the pre-multi-lock code did (it
  # used `||=` so only the first entry per pane ever won). The label now
  # reads "edit ✓ edit #1" for one pane, which is self-contradictory.
  it "SX1: does not show the same lock twice for one pane (held + queued)" do
    acquire("edit", pid: 100, pane: "%1")
    acquire("edit", pid: 200, pane: "%1", wait: true)

    with_daemon { command.call(name: "proj") }

    line = output.string.lines.find { |l| l.start_with?("0.0") }
    expect(line.scan("edit").size).to eq(1)
  end

  # SX2: the JSON "locks" array inherits the same duplication — a consumer
  # iterating `locks` for pane %1 sees the "edit" lock listed twice with
  # contradictory states ("held" and "queued").
  it "SX2: does not duplicate a lock name in the JSON locks array" do
    acquire("edit", pid: 100, pane: "%1")
    acquire("edit", pid: 200, pane: "%1", wait: true)

    with_daemon { command.call(name: "proj", json: true) }

    pane = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%1" }
    names = pane["locks"].map { |l| l["name"] }
    expect(names.tally["edit"]).to eq(1)
  end

  # SX3: two distinct agents queued in the same pane for the same lock (e.g.
  # two sub-agents both waiting on "edit") produce two queue entries for one
  # pane, again shown as duplicate "edit #N edit #M" labels rather than being
  # collapsed to the pane's best (lowest) position, as the pre-multi-lock
  # code did.
  it "SX3: does not show duplicate queue entries for one pane in one lock's queue" do
    acquire("edit", pid: 100, pane: "%9")
    acquire("edit", pid: 200, pane: "%1", wait: true)
    acquire("edit", pid: 201, pane: "%1", wait: true)

    with_daemon { command.call(name: "proj") }

    line = output.string.lines.find { |l| l.start_with?("0.0") }
    expect(line.scan("edit").size).to eq(1)
  end
end
