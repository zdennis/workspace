require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Lock, "recording lock waits in the event log" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-activity") }
  let(:store_dir) { File.join(tmpdir, "store").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:log_config) do
    Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
      allow(c).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
    end
  end
  let(:log_errors) { StringIO.new }
  let(:event_log) { Workspace::EventLog.new(config: log_config, error_output: log_errors) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:now) { [1_000_000] }
  let(:monotonic) do
    times = now
    Object.new.tap { |clock| clock.define_singleton_method(:now) { times[0].to_f } }
  end
  let(:holder_identity) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app.worktree-a") }
  let(:waiter_identity) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.worktree-b") }
  let(:on_sleep) { [] }
  let(:traps) { {} }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: store_dir)
  end

  def command_for(identity)
    described_class.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output,
      sleeper: ->(_) {
        now[0] += 5
        on_sleep.shift&.call
      },
      clock: monotonic, pid_provider: -> { identity.current[:pid] },
      trap: ->(signal, handler) { traps[signal] = handler },
      lock_config: instance_double(Workspace::LockConfig, idle_grace_for: 300),
      wall_clock: -> { now[0] }, event_log: event_log)
  end

  def logged
    event_log.events.map { |e| [e["project"], e["type"], e["data"]] }
  end

  it "records nothing for an uncontended acquire" do
    command_for(holder_identity).acquire("edit", working_dir: tmpdir)

    expect(logged).to be_empty
  end

  it "records the wait's start and how long it took to acquire" do
    command_for(holder_identity).acquire("edit", task: "PROJ-1", working_dir: tmpdir)
    on_sleep << -> { command_for(holder_identity).release("edit", working_dir: tmpdir) }

    result = command_for(waiter_identity).acquire("edit", task: "PROJ-2", wait: true, poll: 0.25, working_dir: tmpdir)

    expect(result).to eq(exit_code: 0)
    expect(logged.map { |project, type, _| [project, type] }).to eq([["app", "lock_wait_started"], ["app", "lock_acquired"]])
    expect(logged[0][2]).to include("lock" => "edit", "pid" => 200, "task" => "PROJ-2", "position" => 1,
      "holder" => include("pane" => "%1", "pid" => 100, "task" => "PROJ-1"))
    expect(logged[1][2]).to include("lock" => "edit", "pid" => 200, "waited_seconds" => 5.0)
  end

  it "records giving up after --max-wait" do
    command_for(holder_identity).acquire("edit", working_dir: tmpdir)

    result = command_for(waiter_identity).acquire("edit", wait: true, poll: 0.25, max_wait: 9, working_dir: tmpdir)

    expect(result).to eq(exit_code: 75)
    expect(logged.last[1..]).to eq(["lock_wait_gave_up", {"lock" => "edit", "pid" => 200, "waited_seconds" => 10.0}])
  end

  it "records a wait ended by clear" do
    command_for(holder_identity).acquire("edit", working_dir: tmpdir)
    on_sleep << -> { command_for(holder_identity).clear("edit", working_dir: tmpdir) }

    result = command_for(waiter_identity).acquire("edit", wait: true, poll: 0.25, working_dir: tmpdir)

    expect(result).to eq(exit_code: 4)
    expect(logged.last[1]).to eq("lock_wait_cleared")
  end

  it "records a wait abandoned on a signal, with the exit code" do
    command_for(holder_identity).acquire("edit", working_dir: tmpdir)
    on_sleep << -> { traps["TERM"].call }

    result = command_for(waiter_identity).acquire("edit", wait: true, poll: 0.25, working_dir: tmpdir)

    expect(result).to eq(exit_code: 143)
    expect(logged.last[1..]).to eq(["lock_wait_abandoned", {"lock" => "edit", "pid" => 200, "waited_seconds" => 5.0, "exit_code" => 143}])
  end

  it "records an idle takeover with the holder it displaced" do
    command_for(holder_identity).acquire("edit", task: "PROJ-1", working_dir: tmpdir)
    Workspace::LockStore.new(dir: store_dir, liveness: holder_identity, clock: -> { now[0] })
      .mark_idle(holder_identity.current, idle: true)
    now[0] += 300

    command_for(waiter_identity).acquire("edit", wait: true, working_dir: tmpdir)

    event = logged.last
    expect(event[1]).to eq("lock_takeover")
    expect(event[2]).to include("from" => include("pid" => 100, "task" => "PROJ-1"), "idle_since" => 1_000_000)
  end

  it "keeps its exit code and stdout when the log can't be written" do
    allow(log_config).to receive(:event_log_file).and_return(File.join(tmpdir, "gone", "events.jsonl"))
    command_for(holder_identity).acquire("edit", working_dir: tmpdir)
    on_sleep << -> { command_for(holder_identity).release("edit", working_dir: tmpdir) }

    result = command_for(waiter_identity).acquire("edit", wait: true, poll: 0.25, working_dir: tmpdir)

    expect(result).to eq(exit_code: 0)
    expect(output.string).not_to include("event log")
    expect(log_errors.string.lines.size).to eq(1)
  end
end
