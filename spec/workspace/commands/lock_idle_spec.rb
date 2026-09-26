require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Lock, "idle takeover and instructions" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-idle-command") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:lock_config) { instance_double(Workspace::LockConfig, idle_grace_for: 300) }
  let(:now) { [1_000_000] }
  let(:holder_identity) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app.worktree-a") }
  let(:waiter_identity) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.worktree-b") }
  # One timeline for both clocks, advanced by the sleeper, so --max-wait expires.
  let(:monotonic) do
    times = now
    Object.new.tap { |clock| clock.define_singleton_method(:now) { times[0].to_f } }
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  def command_for(identity, lock_config: self.lock_config)
    described_class.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, sleeper: ->(_) { now[0] += 5 },
      clock: monotonic, pid_provider: -> { identity.current[:pid] },
      trap: ->(signal, handler) {}, lock_config: lock_config, wall_clock: -> { now[0] })
  end

  def mark_holder_idle
    Workspace::LockStore.new(dir: tmpdir, liveness: holder_identity, clock: -> { now[0] })
      .mark_idle(holder_identity.current, idle: true)
  end

  def take_over
    command_for(holder_identity).acquire("edit", task: "PROJ-1")
    mark_holder_idle
    now[0] += 300
    command_for(waiter_identity).acquire("edit", task: "PROJ-2", wait: true)
  end

  it "lets a waiter take over an idle holder and says so on stderr" do
    result = take_over

    expect(result).to eq(exit_code: 0)
    expect(output.string).to include("Acquired edit lock.")
    expect(error_output.string).to include("Took over edit lock from %1 \"PROJ-1\" in app.worktree-a, idle since 1970-01-12T13:46:40Z.")
  end

  it "uses the project's configured idle grace" do
    allow(lock_config).to receive(:idle_grace_for).with("app").and_return(900)
    command_for(holder_identity).acquire("edit")
    mark_holder_idle
    now[0] += 300
    command = described_class.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: waiter_identity,
      output: output, error_output: error_output, sleeper: ->(_) { now[0] += 5 }, clock: monotonic,
      pid_provider: -> { 200 }, trap: ->(signal, handler) {}, lock_config: lock_config, wall_clock: -> { now[0] })

    expect(command.acquire("edit", wait: true, max_wait: 1)).to eq(exit_code: 75)
  end

  it "tells the displaced holder on its next acquire, exiting 3 without queueing" do
    take_over
    error_output.truncate(0)
    error_output.rewind

    result = command_for(holder_identity).acquire("edit", wait: true)

    expect(result).to eq(exit_code: described_class::EXIT_DISPLACED)
    expect(result[:exit_code]).to eq(3)
    expect(error_output.string).to include("Your edit lock was taken over by %2 \"PROJ-2\" in app.worktree-b")
    expect(error_output.string).to include("idle for 300s")
    expect(error_output.string).to include("workspace lock acquire edit --wait")
    status = Workspace::LockStore.new(dir: tmpdir, liveness: holder_identity).status("edit")["edit"]
    expect(status["queue"]).to be_empty

    expect(command_for(holder_identity).acquire("edit", wait: false)).to eq(exit_code: 1)
  end

  it "tells the displaced holder on its next release, exiting 3 once" do
    take_over

    expect(command_for(holder_identity).release("edit")).to eq(exit_code: 3)
    expect(error_output.string).to include("Your edit lock was taken over by %2")
    expect(output.string).not_to include("not held by this agent")

    expect(command_for(holder_identity).release("edit")).to eq(exit_code: 0)
  end

  it "reports a displacement on release --all" do
    take_over

    expect(command_for(holder_identity).release(nil, all: true)).to eq(exit_code: 3)
    expect(error_output.string).to include("Your edit lock was taken over")
  end

  it "shows an idle holder in status" do
    command_for(holder_identity).acquire("edit")
    mark_holder_idle

    command_for(holder_identity).status("edit")

    expect(output.string).to include("IDLE since 1970-01-12T13:46:40Z")
  end

  it "falls back to the default grace without a lock_config" do
    command_for(holder_identity, lock_config: nil).acquire("edit")
    mark_holder_idle
    now[0] += Workspace::LockStore::DEFAULT_IDLE_GRACE

    expect(command_for(waiter_identity, lock_config: nil).acquire("edit", wait: true)).to eq(exit_code: 0)
  end

  describe "#instructions" do
    it "prints the agent prompt block for the edit lock by default" do
      expect(command_for(holder_identity).instructions).to eq(exit_code: 0)

      expect(output.string).to eq(
        "Before editing files, run `workspace lock acquire edit --wait --task \"<your task>\"` using Bash with " \
        "run_in_background. Do not edit anything until it reports \"Acquired\". When your edits are complete, " \
        "run `workspace lock release edit`. Never run `workspace lock clear`.\n"
      )
    end

    it "substitutes the lock name into every command" do
      command_for(holder_identity).instructions("test")

      expect(output.string).to include("workspace lock acquire test --wait", "workspace lock release test")
      expect(output.string).not_to include("acquire edit")
      expect(output.string).not_to include("release edit")
    end

    it "rejects an empty name" do
      expect { command_for(holder_identity).instructions("") }.to raise_error(Workspace::UsageError)
    end
  end
end
