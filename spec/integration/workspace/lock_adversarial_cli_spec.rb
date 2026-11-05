require "spec_helper"
require "tmpdir"

# Adversarial coverage for `workspace lock`'s CLI contract, namespace
# resolution, and agent UX. Each example is prefixed with a finding id
# (U1, U2, ...) referenced in the review report; see RECOMMENDED-PLAN.md
# (PR1) for the intended contract.
RSpec.describe "workspace lock adversarial findings" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-adversarial") }
  let(:config) { Workspace::Config.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:sleeper) { instance_double("sleeper", call: nil) }
  let(:clock) { class_double(Time, now: base_time) }
  let(:base_time) { Time.utc(2026, 9, 26, 12, 0, 0) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  def command_for(identity, sleeper: self.sleeper)
    Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, sleeper: sleeper, clock: clock,
      pid_provider: -> { identity.current[:pid] },
      trap: ->(signal, handler) {})
  end

  describe "release/clear vs --all argument handling" do
    it "U1: silently ignores the given lock name and releases every lock when --all is also passed" do
      identity = FakeLockIdentity.new(pid: 100)
      cmd = command_for(identity)
      cmd.acquire("edit", task: "keep-this-one")

      # Caller asked to release "someother-lock-not-held" specifically, but
      # also passed --all by mistake (or a bug upstream). The command should
      # either refuse the ambiguous combination or release the named lock
      # only -- it should NOT silently release "edit", which the caller never
      # named.
      result = cmd.release("someother-lock-not-held", all: true)

      expect(result).to eq(exit_code: 0)
      expect(output.string).not_to include("Released edit lock.")
    end

    it "U2: silently ignores the given lock name and clears every lock when --all is also passed" do
      identity = FakeLockIdentity.new(pid: 100)
      cmd = command_for(identity)
      cmd.acquire("edit", task: "keep-this-one")

      result = cmd.clear("someother-lock-not-cleared", all: true)

      expect(result).to eq(exit_code: 0)
      expect(output.string).not_to include("Cleared edit:")
    end
  end

  describe "status STALE marking" do
    it "U3: marks an entry STALE when its holder is dead instead of silently reaping it away" do
      holder_identity = FakeLockIdentity.new(pid: 100)
      cmd = command_for(holder_identity)
      cmd.acquire("edit", task: "in-flight")
      holder_identity.kill(100)

      liveness = FakeLockLiveness.new(dead: [100])
      status_cmd = Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace,
        lock_holder: liveness, output: output, error_output: error_output, sleeper: sleeper, clock: clock)

      status_cmd.status("edit")

      expect(output.string).to match(/STALE/)
    end
  end

  describe "--poll and --max-wait input validation" do
    it "U4: a negative --poll crashes with an uncaught ArgumentError instead of a clean usage error" do
      holder = FakeLockIdentity.new(pid: 100)
      command_for(holder).acquire("edit")

      waiter = FakeLockIdentity.new(pid: 200)
      real_sleeper = ->(seconds) { sleep(seconds) }
      waiting_cmd = command_for(waiter, sleeper: real_sleeper)

      expect {
        waiting_cmd.acquire("edit", wait: true, poll: -1, max_wait: 0.05)
      }.not_to raise_error(ArgumentError)
    end

    it "U5: --poll 0 is rejected with a UsageError instead of busy-polling with a zero-second sleep" do
      holder = FakeLockIdentity.new(pid: 100)
      command_for(holder).acquire("edit")

      waiter = FakeLockIdentity.new(pid: 200)
      waiting_cmd = Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace,
        lock_holder: waiter, output: output, error_output: error_output, sleeper: sleeper, clock: Time,
        pid_provider: -> { waiter.current[:pid] }, trap: ->(signal, handler) {})

      expect {
        waiting_cmd.acquire("edit", wait: true, poll: 0, max_wait: 0.01)
      }.to raise_error(Workspace::UsageError)
      expect(sleeper).not_to have_received(:call).with(0)
    end
  end

  describe "namespace resolution when git is missing or fails" do
    it "U6: raises an uncaught Errno::ENOENT instead of falling back gracefully when git is not installed" do
      real_namespace = Workspace::LockNamespace.new(config: config)
      allow(Open3).to receive(:capture3).with("git", any_args).and_raise(Errno::ENOENT, "No such file or directory - git")

      expect {
        real_namespace.resolve(cwd: tmpdir)
      }.not_to raise_error
    end
  end

  describe "lock name validation" do
    it "U7: rejects an empty string lock name with a UsageError" do
      identity = FakeLockIdentity.new(pid: 100)
      cmd = command_for(identity)

      expect {
        cmd.acquire("", task: "oops")
      }.to raise_error(Workspace::UsageError)
    end
  end
end
