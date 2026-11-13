require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Relauncher do
  let(:out) { StringIO.new }
  let(:calls) { [] }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_runner) { CLITestHelpers::FakeHookRunner.new }
  let(:launch_exit_codes) { {} }
  let(:tmux) { FakeTmux.new }

  let(:stop_command) do
    log = calls
    Class.new do
      define_method(:call) do |names|
        log << [:stop, names, names.object_id]
        names.reject { |n| n == "stuck" }
      end

      def warnings = ["stop warning"]
    end.new
  end

  let(:launcher) do
    log = calls
    codes = launch_exit_codes
    Class.new do
      define_method(:launch) do |_invocation, args, headless: nil|
        log << [:launch, args, headless]
        {exit_code: codes[headless ? :headless : :windowed] || 0, projects: args, result: {}}
      end

      define_method(:rows) do |projects, _result, ok_outcome:|
        projects.map { |p| {"workspace" => p, "outcome" => ok_outcome} }
      end
    end.new
  end

  let(:invocation) { Workspace::CLI::Invocation.new(output: out, error_output: StringIO.new, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {}) }
  let(:relauncher) do
    log = calls
    described_class.new(stop_command: stop_command, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: ->(s) { log << [:sleep, s] }, tmux: tmux)
  end

  before do
    state["app"] = {"headless" => false}
    state["bot"] = {"headless" => true}
    state["web"] = {"headless" => false}
    state["stuck"] = {"headless" => false}
  end

  it "stops, sleeps, then launches the windowed batch and the headless batch" do
    relauncher.call(invocation, %w[app bot web])

    expect(calls.map { |c| (c.first == :stop) ? c.first(2) : c }).to eq([
      [:stop, %w[app bot web]],
      [:sleep, 2],
      [:launch, %w[app web], nil],
      [:launch, %w[bot], true]
    ])
    expect(out.string).to include("Will relaunch: app, bot, web")
  end

  it "gives the stop command a copy of the names" do
    names = %w[app bot]
    relauncher.call(invocation, names)

    expect(calls.first.last).not_to eq(names.object_id)
  end

  it "answers one relaunched row per workspace, whatever json is" do
    result = relauncher.call(invocation, %w[app bot])

    expect(result).to eq(exit_code: 0, warnings: ["stop warning"], results: [
      {"workspace" => "app", "outcome" => "relaunched"},
      {"workspace" => "bot", "outcome" => "relaunched"}
    ])
    expect(relauncher.call(invocation, %w[app])[:results]).to eq([{"workspace" => "app", "outcome" => "relaunched"}])
  end

  it "runs post_stop for each workspace that stopped" do
    relauncher.call(invocation, %w[app stuck])

    expect(hook_runner.runs.map { |r| [r[:project], r[:event]] }).to eq([["app", "post_stop"]])
  end

  it "still launches a workspace that failed to stop" do
    relauncher.call(invocation, %w[app stuck])

    expect(calls).to include([:launch, %w[app stuck], nil])
  end

  it "attempts the headless batch after a windowed failure and exits 1" do
    launch_exit_codes[:windowed] = 1

    result = relauncher.call(invocation, %w[app bot])

    expect(calls.map(&:first)).to eq(%i[stop sleep launch launch])
    expect(result[:exit_code]).to eq(1)
  end

  it "launches nothing for an empty batch" do
    relauncher.call(invocation, %w[bot])

    expect(calls.select { |c| c.first == :launch }).to eq([[:launch, %w[bot], true]])
  end

  describe "only_stopped:" do
    let(:tmux) { FakeTmux.new(sessions: ["ws-web"], session_names: {"web" => "ws-web"}) }

    it "does not launch a workspace whose session survived the stop, answering relaunch_stop_failed" do
      result = relauncher.call(invocation, %w[app web bot], only_stopped: true)

      expect(calls.select { |c| c.first == :launch }).to eq([[:launch, %w[app], nil], [:launch, %w[bot], true]])
      expect(result[:results].last).to include("workspace" => "web", "outcome" => "failed", "reason" => "relaunch_stop_failed")
      expect(result[:exit_code]).to eq(1)
    end

    it "launches a workspace the stop command did not name once its session is gone" do
      relauncher.call(invocation, %w[app stuck], only_stopped: true)

      expect(calls).to include([:launch, %w[app stuck], nil])
    end

    it "runs no launch when no session went away" do
      result = relauncher.call(invocation, %w[web], only_stopped: true)

      expect(calls.map(&:first)).to eq(%i[stop sleep])
      expect(result[:results].map { |r| r["outcome"] }).to eq(%w[failed])
    end

    it "asks tmux nothing without the keyword" do
      relauncher.call(invocation, %w[web])

      expect(calls).to include([:launch, %w[web], nil])
    end

    it "reads headless from the state as it was before the stop removed the entries" do
      stop = Class.new do
        def initialize(state) = @state = state

        def call(names)
          names.each { |n| @state.delete(n) }
          names
        end

        def warnings = []
      end.new(state)
      described_class.new(stop_command: stop, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: ->(_) {}, tmux: FakeTmux.new)
        .call(invocation, %w[app bot], only_stopped: true)

      expect(calls).to eq([[:launch, %w[app], nil], [:launch, %w[bot], true]])
    end
  end

  describe "#active_name" do
    it "answers the state's key for a name in any case, nil for one it doesn't list" do
      expect(relauncher.active_name("WEB")).to eq("web")
      expect(relauncher.active_name("gone")).to be_nil
    end
  end

  describe "#pane_in_session?" do
    let(:tmux) { FakeTmux.new(session_names: {"web" => "ws-web", "js" => "foo.js"}, pane_sessions: {"%3" => "ws-web", "%4" => "foo_js"}) }

    it "says whether the pane is in the workspace's session, comparing names as tmux stores them" do
      expect(relauncher.pane_in_session?("%3", "web")).to be true
      expect(relauncher.pane_in_session?("%3", "js")).to be false
      expect(relauncher.pane_in_session?("%4", "js")).to be true
    end

    it "asks the tmux server of the workspace's own socket, and answers nil when tmux can't place the pane" do
      asked = []
      recording = Class.new(FakeTmux) do
        define_method(:session_name_for_pane) do |pane_id, project: nil|
          asked << [pane_id, project]
          super(pane_id, project: project)
        end
      end.new(session_names: {"web" => "ws-web"})
      on_socket = described_class.new(stop_command: stop_command, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: ->(_) {}, tmux: recording)

      expect(on_socket.pane_in_session?("%9", "web")).to be_nil
      expect(asked).to eq([["%9", "web"]])

      allow(tmux).to receive(:session_name_for_pane).and_raise(Errno::ENOENT)
      expect(relauncher.pane_in_session?("%3", "web")).to be_nil
    end
  end

  describe "#client_session and #session_of?" do
    let(:tmux) { FakeTmux.new(session_names: {"js" => "foo.js", "web" => "ws-web"}, client_sessions: {"/tmp/t,1,2" => "foo_js"}) }

    it "names the current client's session and matches it to a workspace as tmux stores names" do
      expect(relauncher.client_session("/tmp/t,1,2")).to eq("foo_js")
      expect(relauncher.client_session("/tmp/other,1,2")).to be_nil
      expect(relauncher.session_of?("foo_js", "js")).to be true
      expect(relauncher.session_of?("foo_js", "web")).to be false
    end
  end

  describe "when the config can't be read (SystemCallError)" do
    let(:tmux) { FakeTmux.new(pane_sessions: {"%3" => "web"}, client_sessions: {"/tmp/t,1,2" => "web"}) }

    before { allow(tmux).to receive(:session_name_for).and_raise(Errno::EACCES) }

    it "counts the session as up, and answers nil for the session matches" do
      expect(relauncher.running?("web")).to be true
      expect(relauncher.pane_in_session?("%3", "web")).to be_nil
      expect(relauncher.session_of?("web", "web")).to be_nil
    end

    it "answers nil for the client's session when tmux can't be run" do
      allow(tmux).to receive(:client_session_name).and_raise(Errno::ENOENT)

      expect(relauncher.client_session("/tmp/t,1,2")).to be_nil
    end
  end

  describe "#running?" do
    let(:tmux) { FakeTmux.new(sessions: ["ws-web", "foo_js"], session_names: {"web" => "ws-web", "js" => "foo.js"}) }

    it "asks tmux about the workspace's session under the name tmux stores, and counts an error as up" do
      expect(relauncher.running?("web")).to be true
      expect(relauncher.running?("app")).to be false
      expect(relauncher.running?("js")).to be true
      allow(tmux).to receive(:session_name_for).and_raise(Workspace::Error, "no config")
      expect(relauncher.running?("app")).to be true
    end
  end

  describe "#own_workspace" do
    let(:tmux) { FakeTmux.new(pane_sessions: {"%3" => "web"}, client_sessions: {"/tmp/t,1,2" => "app"}) }

    it "counts the working directory's workspace alone when neither $TMUX_PANE nor $TMUX is set" do
      own = relauncher.own_workspace({}, "app")

      expect(%w[app web].map { |n| own.call(n) }).to eq([true, false])
    end

    it "counts the workspace whose session holds $TMUX_PANE, and tallies the lookups tmux answered" do
      tally = {asked: 0, answered: 0}
      own = relauncher.own_workspace({"TMUX_PANE" => "%3"}, nil, tally)

      expect(%w[web app].map { |n| own.call(n) }).to eq([true, false])
      expect(tally).to eq(asked: 2, answered: 2)
    end

    it "falls back to the session $TMUX names, read once, where tmux can't place the pane" do
      reads = []
      allow(tmux).to receive(:client_session_name) { |env| reads << env and "app" }
      own = relauncher.own_workspace({"TMUX_PANE" => "%9", "TMUX" => "/tmp/t,1,2"}, nil)

      expect(%w[app web].map { |n| own.call(n) }).to eq([true, false])
      expect(reads).to eq(["/tmp/t,1,2"])
    end

    it "counts none when tmux can't say, and tallies no answer" do
      tally = {asked: 0, answered: 0}
      own = relauncher.own_workspace({"TMUX_PANE" => "%9", "TMUX" => "/tmp/other,1,2"}, nil, tally)

      expect(own.call("app")).to be false
      expect(tally).to eq(asked: 1, answered: 0)
    end
  end

  describe "#detach and the background run's records" do
    let(:program) { [RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace")] }
    let(:spawned) { [] }
    let(:live) { {} }
    let(:processes) do
      table = live
      Class.new do
        define_method(:start_time) { |pid| "start-#{pid}" }
        define_method(:alive?) { |pid:, started:| table[pid] == started }
      end.new
    end
    let(:detacher) do
      log = spawned
      ->(argv, log_path:, env:) {
        log << [argv, log_path, env]
        File.write(log_path, "")
        4321
      }
    end
    let(:wrapper) { 4321 }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = File.join(dir, ".relaunch")
        example.run
      end
    end

    def build(detacher: self.detacher, program: self.program, processes: self.processes, log_dir: @dir)
      own = wrapper
      described_class.new(stop_command: stop_command, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: ->(_) {}, tmux: tmux,
        detacher: detacher, program: program, log_dir: log_dir, processes: processes, clock: -> { Time.utc(2026, 11, 13, 9, 8, 7) }, pid: 55, wrapper_pid: -> { own })
    end

    def record(name) = JSON.parse(File.read(File.join(@dir, "#{name}.pid")))

    def write_record(name, pid, log = "/old.log")
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, "#{name}.pid"), JSON.generate("pid" => pid, "started" => "start-#{pid}", "log" => log))
    end

    def failure(&block)
      error = nil
      begin
        block.call
      rescue Workspace::Error => e
        error = e
      end
      error
    end

    it "starts relaunch -- NAMES with the marker set, records each workspace's run, and stops nothing" do
      log = File.join(@dir, "20261113T090807Z-55.log")

      expect(build.detach(%w[app Web])).to eq(pid: 4321, log: log)

      expect(spawned).to eq([[[*program, "relaunch", "--", "app", "Web"], log, {"WORKSPACE_RELAUNCH_DETACHED" => "1"}]])
      expect(record("app")).to eq("pid" => 4321, "started" => "start-4321", "log" => log)
      expect(record("web")["pid"]).to eq(4321)
      expect(File.stat(File.join(@dir, "app.pid")).mode & 0o777).to eq(0o600)
      expect(calls).to be_empty
    end

    it "keeps the newest #{described_class::LOGS_KEPT} logs" do
      FileUtils.mkdir_p(@dir)
      old = (1..25).map { |n| File.join(@dir, format("20250101T0000%02dZ-1.log", n)).tap { |f| File.write(f, "") } }

      build.detach(%w[app])

      logs = Dir.glob(File.join(@dir, "*.log")).sort
      expect(logs.size).to eq(described_class::LOGS_KEPT)
      expect(logs.last).to end_with("20261113T090807Z-55.log")
      expect(logs.first).to eq(old[6])
    end

    it "refuses relaunch_in_progress, starting nothing, while another background run of a workspace is live" do
      write_record("web", 99, "/state/.relaunch/earlier.log")
      live[99] = "start-99"

      error = failure { build.detach(%w[app web]) }

      expect(error.code).to eq("relaunch_in_progress")
      expect(error.details).to eq("names" => ["web"], "pid" => 99, "log" => "/state/.relaunch/earlier.log")
      expect(spawned).to be_empty
    end

    it "ignores a record whose process is gone or whose pid now belongs to another process" do
      write_record("web", 99)
      live[99] = "a later start"

      build.detach(%w[web])

      expect(record("web")["pid"]).to eq(4321)
    end

    it "counts a record as live when the process table can't be read" do
      write_record("web", 99)
      unreadable = Class.new { def alive?(**) = raise(Workspace::Error, "ps failed") }.new

      expect(failure { build(processes: unreadable).refuse_in_progress!(%w[web]) }.code).to eq("relaunch_in_progress")
    end

    it "counts a record with no start time as live while its pid exists, and dead once it is gone" do
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, "web.pid"), JSON.generate("pid" => Process.pid, "started" => nil, "log" => "/x.log"))
      expect(failure { build.refuse_in_progress!(%w[web]) }.code).to eq("relaunch_in_progress")

      File.write(File.join(@dir, "web.pid"), JSON.generate("pid" => 2_000_000_000, "started" => nil, "log" => "/x.log"))
      expect { build.refuse_in_progress!(%w[web]) }.not_to raise_error
    end

    it "lets the background run pass its own wrapper's record, and removes only that record when it is done" do
      write_record("app", wrapper)
      write_record("web", 77)
      live[wrapper] = "start-#{wrapper}"
      relauncher = build

      expect { relauncher.refuse_in_progress!(%w[app], except_own: true) }.not_to raise_error
      expect(failure { relauncher.refuse_in_progress!(%w[app]) }.code).to eq("relaunch_in_progress")

      relauncher.release(%w[app web])

      expect(File.exist?(File.join(@dir, "app.pid"))).to be false
      expect(File.exist?(File.join(@dir, "web.pid"))).to be true
    end

    it "raises relaunch_detach_failed, starting nothing, when a program file is missing" do
      gone = File.join(PROJECT_ROOT, "bin", "no-such-workspace")

      error = failure { build(program: [RbConfig.ruby, gone]).detach(%w[app]) }

      expect(error.code).to eq("relaunch_detach_failed")
      expect(error.details).to eq("log" => nil, "program" => [gone])
      expect(error.message).to include("nothing was stopped")
      expect(spawned).to be_empty
    end

    it "raises relaunch_detach_failed when a program file is not executable" do
      plain = File.join(PROJECT_ROOT, "Gemfile")

      expect(failure { build(program: [RbConfig.ruby, plain]).detach(%w[app]) }.details["program"]).to eq([plain])
      expect(spawned).to be_empty
    end

    it "raises relaunch_detach_failed, with the log path, when the run can't start" do
      failing = ->(*, **) { raise Errno::EACCES, "spawn" }

      error = failure { build(detacher: failing).detach(%w[app]) }

      expect(error.code).to eq("relaunch_detach_failed")
      expect(error.details).to eq("log" => File.join(@dir, "20261113T090807Z-55.log"))
      expect(error.message).to include("nothing was stopped", "workspace relaunch app")
      expect(File.exist?(File.join(@dir, "app.pid"))).to be false
    end

    it "raises relaunch_detach_failed when no detacher or log directory is set up" do
      expect(failure { build(detacher: nil).detach(%w[app]) }.code).to eq("relaunch_detach_failed")
      expect(failure { build(log_dir: nil).detach(%w[app]) }.code).to eq("relaunch_detach_failed")
    end
  end
end
