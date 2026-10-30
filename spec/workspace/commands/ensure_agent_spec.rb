require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::EnsureAgent do
  let(:tmpdir) { Dir.mktmpdir }
  let(:lock_path) { File.join(tmpdir, "workspace-myapp.lock") }
  let(:log_path) { File.join(tmpdir, "workspace-myapp.log") }
  let(:error_output) { StringIO.new }
  let(:pipeline_config) { double("pipeline_config", stages_for: nil, literal_sentinel_warnings: []) }
  # Answers like a socket: false until a spawned daemon has "bound" it.
  let(:daemon_up) { [false] }
  let(:config) do
    instance_double(Workspace::Config, agent_lock_path: lock_path, agent_log_path: log_path).tap do |c|
      allow(c).to receive(:agent_running?) { daemon_up[0] }
    end
  end
  let(:spawns) { Queue.new }
  let(:spawner) do
    ->(name, wc_socket, path) {
      spawns << [name, wc_socket, path]
      daemon_up[0] = true
    }
  end
  let(:now) { [0.0] }
  let(:sleeper) { ->(seconds) { now[0] += seconds } }

  def build(**overrides)
    described_class.new(config: config, pipeline_config: pipeline_config, spawner: spawner, sleeper: sleeper,
      clock: -> { now[0] }, error_output: error_output, **overrides)
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "starts a daemon when none answers and reports it started" do
    result = build.call(name: "myapp")

    expect(result.status).to eq(:started)
    expect(result).to be_ok
    expect(spawns.size).to eq(1)
    expect(spawns.pop).to eq(["myapp", nil, log_path])
  end

  it "passes --wc-socket through to the spawner" do
    build.call(name: "myapp", wc_socket: "/tmp/wc.sock")

    expect(spawns.pop).to eq(["myapp", "/tmp/wc.sock", log_path])
  end

  it "does nothing when a daemon already answers" do
    daemon_up[0] = true

    result = build.call(name: "myapp")

    expect(result.status).to eq(:running)
    expect(spawns).to be_empty
  end

  it "treats a leftover socket file with nothing answering as not running" do
    File.write(File.join(tmpdir, "workspace-myapp.sock"), "")

    expect(build.call(name: "myapp").status).to eq(:started)
    expect(spawns.size).to eq(1)
  end

  it "reports failure when checking for the daemon raises" do
    allow(config).to receive(:agent_running?).and_raise(Workspace::Error, "socket dir is too deep")

    result = build.call(name: "myapp")

    expect(result.status).to eq(:failed)
    expect(result.detail).to eq("socket dir is too deep")
  end

  it "is a no-op when called again after starting" do
    ensurer = build
    ensurer.call(name: "myapp")
    second = ensurer.call(name: "myapp")

    expect(second.status).to eq(:running)
    expect(spawns.size).to eq(1)
  end

  it "starts one daemon when callers race" do
    slow_spawner = lambda do |name, wc_socket, path|
      sleep 0.05
      spawner.call(name, wc_socket, path)
    end
    ensurers = Array.new(4) { build(spawner: slow_spawner, sleeper: ->(_) { sleep 0.01 }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }) }

    results = ensurers.map { |e| Thread.new { e.call(name: "myapp") } }.map(&:value)

    expect(spawns.size).to eq(1)
    expect(results.map(&:status).sort).to eq(%i[running running running started])
  end

  it "reports failure when the daemon never answers" do
    never = ->(*) { spawns << :spawned }

    result = build(spawner: never, timeout: 2).call(name: "myapp")

    expect(result.status).to eq(:failed)
    expect(result.detail).to eq("it did not answer within 2s; see #{log_path}")
    expect(result).not_to be_ok
  end

  it "reports failure when the spawn raises" do
    broken = ->(*) { raise Errno::ENOENT, "workspace" }

    result = build(spawner: broken).call(name: "myapp")

    expect(result.status).to eq(:failed)
    expect(result.detail).to include("No such file or directory")
  end

  it "releases its lock after a failure so a later call can try again" do
    broken = ->(*) { raise Errno::ENOENT, "workspace" }
    build(spawner: broken).call(name: "myapp")

    expect(build.call(name: "myapp").status).to eq(:started)
  end

  it "reports failure when the lock file can't be opened" do
    allow(config).to receive(:agent_lock_path).and_return(File.join(tmpdir, "missing", "x.lock"))

    expect(build.call(name: "myapp").status).to eq(:failed)
    expect(spawns).to be_empty
  end

  it "warns and spawns nothing when the pipeline config is invalid" do
    allow(pipeline_config).to receive(:stages_for).and_raise(Workspace::Error, "must be greater than 0")

    result = build.call(name: "myapp")

    expect(result.status).to eq(:invalid_config)
    expect(spawns).to be_empty
    expect(error_output.string).to include("myapp's pipeline config is invalid (must be greater than 0)")
    expect(error_output.string).to include(log_path)
  end

  it "warns about a bare completion sentinel but still starts" do
    allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp").and_return(["names the bare WORKSPACE_DONE: marker"])

    expect(build.call(name: "myapp").status).to eq(:started)
    expect(error_output.string).to include("Warning: names the bare WORKSPACE_DONE: marker")
  end

  describe "renaming a mixed-case workspace" do
    let(:migrations) { [] }
    let(:migration_result) { Workspace::NameMigration::Result.new(name: "myapp", from: "MyApp", renamed: [], warnings: ["MyApp: state not renamed (taken)"]) }
    let(:name_migration) do
      double("name_migration").tap do |migration|
        allow(migration).to receive(:lock_path) { |name| config.agent_lock_path(name.downcase) }
        allow(migration).to receive(:call) do |name|
          lock_free = File.open(lock_path, File::RDWR) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
          migrations << [name, lock_free]
          migration_result
        end
      end
    end

    it "renames under the startup lock, then starts the daemon under the lowercase name" do
      result = build(name_migration: name_migration).call(name: "MyApp")

      expect(result.status).to eq(:started)
      expect(migrations).to eq([["MyApp", false]])
      expect(spawns.pop).to eq(["myapp", nil, log_path])
    end

    it "renames nothing while a daemon answers" do
      daemon_up[0] = true

      build(name_migration: name_migration).call(name: "MyApp")

      expect(migrations).to be_empty
    end

    it "keys the startup lock on the lowercase name, so every spelling shares it" do
      build(name_migration: name_migration).call(name: "MyApp")

      expect(config).to have_received(:agent_lock_path).with("myapp")
      expect(config).not_to have_received(:agent_lock_path).with("MyApp")
    end
  end

  describe "default spawner" do
    it "starts the CLI's agentd detached, appending its output to the log file" do
      ensurer = described_class.new(config: config, pipeline_config: pipeline_config, sleeper: sleeper, clock: -> { now[0] }, error_output: error_output)
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach) { daemon_up[0] = true }

      ensurer.call(name: "myapp", wc_socket: "/tmp/wc.sock")

      expect(Process).to have_received(:spawn).with($PROGRAM_NAME, "agentd", "--name", "myapp", "--wc-socket", "/tmp/wc.sock",
        out: [log_path, "a"], err: [log_path, "a"], in: File::NULL)
      expect(Process).to have_received(:detach).with(4242)
    end

    it "leaves out --wc-socket when no socket is given" do
      ensurer = described_class.new(config: config, pipeline_config: pipeline_config, sleeper: sleeper, clock: -> { now[0] }, error_output: error_output)
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach) { daemon_up[0] = true }

      ensurer.call(name: "myapp")

      expect(Process).to have_received(:spawn).with($PROGRAM_NAME, "agentd", "--name", "myapp",
        out: [log_path, "a"], err: [log_path, "a"], in: File::NULL)
    end
  end
end
