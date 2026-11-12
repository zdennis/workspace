require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::PlanSpine do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:plan_command) { instance_double(Workspace::Commands::Plan, status: nil) }
  let(:plan_dispatch_command) { instance_double(Workspace::Commands::PlanDispatch) }
  let(:spine_command) { instance_double(Workspace::Commands::Spine, show: nil) }
  let(:spine_start_command) { instance_double(Workspace::Commands::SpineStart) }
  let(:goal_command) { instance_double(Workspace::Commands::Goal, list: nil) }
  let(:status_scope) { instance_double(Workspace::StatusScope, resolve: Workspace::StatusScope::Scope.new(kind: :workspace, workspace: "app")) }
  let(:launched) { {projects: ["app"], result: :launched, plays: {}, packs: {}, skipped_packs: {}, prompts: {}} }
  let(:launcher) { instance_double(Workspace::CLI::Launcher, launch: launched, rows: [{"outcome" => "launched", "reason" => nil, "message" => nil, "pane" => "%3"}]) }

  def family
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: detector,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(plan_command: plan_command, plan_dispatch_command: plan_dispatch_command, plan_task_command: instance_double(Workspace::Commands::PlanTask),
      spine_command: spine_command, spine_init_command: nil, spine_start_command: spine_start_command, goal_command: goal_command,
      status_scope: status_scope, project_detector: detector, launcher: launcher, common: Workspace::CLI::Common.new, names: names, working_dir: "/src/app")
  end

  def invocation
    @invocation ||= Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def run(verb, *args)
    family.call(verb, args, invocation)
    nil
  rescue FakeSystemExit => e
    e.status
  end

  describe "#call" do
    it "reads plan status for the workspace the status scope resolves from the working directory" do
      run("plan", "status", "--json")

      expect(status_scope).to have_received(:resolve).with(name: nil, project: nil, all: nil, working_dir: "/src/app")
      expect(plan_command).to have_received(:status).with(names: ["app"], json: true)
    end

    it "launches a workspace with no session for plan start through the launcher, with the invocation it was given" do
      allow(plan_dispatch_command).to receive(:start) { |name:, launch:| launch.call(name).merge("outcome" => "started").transform_keys(&:to_s) }

      expect(run("plan", "start", "--json")).to be_nil

      expect(launcher).to have_received(:launch).with(invocation, ["app"], plays: [Workspace::Commands::PlanDispatch::PLAY],
        prompt: Workspace::Commands::PlanDispatch::CONTINUE_PROMPT, with_packs: true)
      expect(JSON.parse(out.string)).to include("action" => "plan start", "results" => [hash_including("workspace" => "app", "outcome" => "started", "pane" => "%3")])
    end

    it "says why a plan verb failed on the invocation's error output and exits 1 through its exit handler" do
      allow(plan_dispatch_command).to receive(:start).and_return("outcome" => "failed", "message" => "no agent pane")

      expect(run("plan", "start")).to eq(1)

      expect(err.string).to eq("Error: could not start the plan for app: no agent pane\n")
    end

    it "gives spine start a launcher over the invocation, and exits 1 with the message when the stage did not start" do
      allow(spine_start_command).to receive(:start) do |name:, play:, launch:, **|
        expect(launch.call(name, play, "brief")).to eq(ok: true, reason: nil, message: nil, pane: "%3")
        {"ok" => false, "path" => "verify", "message" => "not submitted"}
      end

      expect(run("spine", "start", "verify", "--play", "research")).to eq(1)

      expect(launcher).to have_received(:launch).with(invocation, ["app"], plays: ["research"], prompt: "brief", with_packs: true)
      expect(err.string).to eq("Error: could not start stage verify of app: not submitted\n")
    end

    it "answers journey as spine and hands goal list to the goal command" do
      run("journey", "show")
      run("goal", "list", "--all")

      expect(spine_command).to have_received(:show).with(name: "app", json: false, stage: nil, body: false, evaluate: false)
      expect(goal_command).to have_received(:list).with(all: true, json: false)
    end

    it "prints a verb's help through the invocation's output" do
      run("goal", "--help")

      expect(out.string).to include("workspace goal show")
    end
  end
end
