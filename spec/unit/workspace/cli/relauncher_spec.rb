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
end
