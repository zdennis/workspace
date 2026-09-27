require "spec_helper"
require "tmpdir"

# Adversarial probes for `lock clear`'s "keep the devenv lock when its
# process group can't be stopped" behavior (commit 7e201d4). Each `it` is a
# confirmed defect, not a speculative one.
RSpec.describe "workspace lock clear (adversarial)" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-adversarial") }
  let(:config) { Workspace::Config.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  def hold_devenv(pid: 4242)
    store = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new)
    store.acquire("devenv", identity: {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, worktree: "/w/login", branch: "login"},
      waiter_pid: pid, waiter_started: "start-#{pid}")
  end

  def not_permitted(pid = 4242)
    Workspace::Error.new("process group #{pid} has running processes this user is not permitted to signal (owned by alice: ...)")
  end

  def clear_command(terminator:)
    Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: FakeLockIdentity.new(pid: 999),
      output: output, error_output: error_output, terminator: terminator, trap: ->(*) {})
  end

  it "CL1: reports the holder as cleared even when finish_clear could not remove it" do
    hold_devenv
    terminator = instance_double(Workspace::ProcessGroupTerminator)
    allow(terminator).to receive(:stop_holder) do
      # Simulate a concurrent re-acquire of "devenv" landing between the
      # group being stopped and finish_clear running (the store is
      # unlocked while the group is stopped, by design).
      raw = JSON.parse(File.read(File.join(tmpdir, "locks.json")))
      raw["devenv"]["holder"] = {"kind" => "process", "pid" => 5555, "started" => "start-5555", "pgid" => 5555}
      File.write(File.join(tmpdir, "locks.json"), JSON.generate(raw))
      :gone
    end
    allow(terminator).to receive_messages(running?: false, orphan_running?: false)

    result = clear_command(terminator: terminator).clear("devenv")

    current_holder = JSON.parse(File.read(File.join(tmpdir, "locks.json"))).dig("devenv", "holder", "pid")

    # A racing re-acquire landed while the group was being stopped (the
    # store is unlocked for that step, by design), so LockStore#finish_clear
    # correctly refused to remove the new holder. The lock is genuinely
    # still held (by pid 5555) -- `clear` must not report this as success,
    # and must not tell the caller "Cleared devenv".
    expect(current_holder).to eq(5555)
    expect(result).to eq(exit_code: 1)
    expect(output.string).not_to include("Cleared devenv")
  end
end
