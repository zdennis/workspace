require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe "Lock idle takeover: adversarial concurrency review" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-idle-adv") }
  let(:now) { [1_000_000] }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:lock_config) { instance_double(Workspace::LockConfig, idle_grace_for: 300) }
  let(:holder_identity) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app.a") }
  let(:waiter_identity) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.b") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  def store(liveness: holder_identity)
    Workspace::LockStore.new(dir: tmpdir, liveness: liveness, clock: -> { now[0] }, idle_grace: 300)
  end

  def hold_as_a
    id = holder_identity.current
    store.acquire("edit", identity: id, waiter_pid: 100, waiter_started: "start-100", task: "A")
  end

  def queue_b
    store.acquire("edit", identity: waiter_identity.current, waiter_pid: 200, waiter_started: "start-200", task: "B", wait: true)
  end

  def command_for(identity, clock:, trap: ->(_signal, _handler) {})
    Workspace::Commands::Lock.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, sleeper: ->(_) { now[0] += 5 },
      clock: clock, pid_provider: -> { 200 }, trap: trap, lock_config: lock_config, wall_clock: -> { now[0] })
  end

  def rewrite_holder
    path = File.join(tmpdir, "locks.json")
    data = JSON.parse(File.read(path))
    yield data["edit"]["holder"]
    File.write(path, JSON.generate(data))
  end

  it "IC1: routes every PreToolUse (not just Task) to session-event, so a holder resumed without a prompt is marked active" do
    groups = Workspace::AgentProvider.find("claude").hook_settings("workspace session-event")["hooks"]["PreToolUse"]
    covers = ->(tool) { groups.any? { |g| g["matcher"].nil? || Regexp.new("\\A(?:#{g["matcher"]})\\z").match?(tool) } }

    expect(covers.call("Bash")).to be(true)
    expect(covers.call("Edit")).to be(true)
  end

  it "IC2: an idle holder that re-runs acquire (already_held) is active again and cannot be taken over" do
    hold_as_a
    queue_b
    store.mark_idle(holder_identity.current, idle: true)
    now[0] += 300

    expect(store.acquire("edit", identity: holder_identity.current, waiter_pid: 101, waiter_started: "start-101")).to eq(status: :already_held)
    expect(store(liveness: waiter_identity).poll("edit", 200)[:status]).to eq(:queued)
  end

  it "IC3: a SIGINT that lands during the takeover poll does not leave the idle holder displaced for nothing" do
    hold_as_a
    store.mark_idle(holder_identity.current, idle: true)
    now[0] += 300
    handlers = {}
    fired = [false]
    interrupting = FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.b")
    interrupting.define_singleton_method(:alive?) do |pid:, started:|
      if handlers["INT"] && !fired[0]
        fired[0] = true
        handlers["INT"].call
      end
      super(pid: pid, started: started)
    end
    monotonic = Object.new.tap { |c| c.define_singleton_method(:now) { 0.0 } }
    trap = ->(signal, handler) {
      handlers[signal] = handler
      nil
    }

    result = command_for(interrupting, clock: monotonic, trap: trap).acquire("edit", task: "B", wait: true)

    # Decision C7: a lock acquired in the same poll that saw the signal is
    # kept and reported, so the takeover is never undone.
    expect(result).to eq(exit_code: 0)
    expect(store.status("edit")["edit"]["holder"]["pid"]).to eq(200)
  end

  it "IC4: a head waiter whose holder's grace expires at the --max-wait deadline takes over instead of giving up" do
    hold_as_a
    store.mark_idle(holder_identity.current, idle: true)
    now[0] += 299
    calls = [0]
    wall = now
    monotonic = Object.new.tap do |c|
      c.define_singleton_method(:now) do
        calls[0] += 1
        next 0.0 if calls[0] == 1
        wall[0] = 1_000_300
        10.0
      end
    end

    result = command_for(waiter_identity, clock: monotonic).acquire("edit", task: "B", wait: true, max_wait: 1)

    expect(result).to eq(exit_code: 0)
  end

  it "IC5: a non-integer idle_since in locks.json never wedges the holder as permanently un-reclaimable" do
    hold_as_a
    queue_b
    rewrite_holder { |h| h["idle_since"] = "999999" }

    store.mark_idle(holder_identity.current, idle: true)
    now[0] += 86_400

    expect(store(liveness: waiter_identity).poll("edit", 200)[:status]).to eq(:acquired)
  end

  it "IC6: an idle_since in the future (wall clock stepped back) does not extend the grace by the skew" do
    hold_as_a
    queue_b
    now[0] += 86_400
    store.mark_idle(holder_identity.current, idle: true)
    now[0] -= 86_400

    store(liveness: waiter_identity).poll("edit", 200)
    now[0] += 301

    expect(store(liveness: waiter_identity).poll("edit", 200)[:status]).to eq(:acquired)
  end
end
