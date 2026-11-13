require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Relauncher do
  let(:out) { StringIO.new }
  let(:calls) { [] }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_runner) { CLITestHelpers::FakeHookRunner.new }
  let(:launch_exit_codes) { {} }

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
    described_class.new(stop_command: stop_command, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: ->(s) { log << [:sleep, s] })
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
end
