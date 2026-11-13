require "spec_helper"
require "json"
require "stringio"

RSpec.describe "workspace relaunch" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:state) { CLITestHelpers::FakeState.new.tap { |st| %w[api web].each { |n| st[n] = {"unique_id" => "uid-#{n}"} } } }
  let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/src/api", "web" => "/src/web") }
  let(:detected) { "api" }
  let(:env) { {} }
  let(:own) { ->(name) { name == detected } }
  let(:relauncher) do
    instance_double(Workspace::CLI::Relauncher, call: {exit_code: 0, results: [{"workspace" => "api", "outcome" => "relaunched"}], warnings: []},
      detach: {pid: 777, log: "/state/.relaunch/x.log"}, refuse_in_progress!: nil, release: nil).tap do |double|
      allow(double).to receive(:own_workspace) { own }
    end
  end

  def cli
    detector = instance_double(Workspace::ProjectDetector, detect: detected)
    unused = %i[launch_command kill_command finish_command start_command stop_command focus_command tile_command layout_command resize_command
      init_command repair_command cleanup_command prune_command claude_command lookup_command update_pane_command run_command run_result_store
      run_and_report_command capture_command wait_until_content_command lock_command dev_command parent_command session_event_command
      config_command statusline_command ask_command].to_h { |key| [key, nil] }
    CLITestHelpers.build_cli(config: Workspace::Config.new, state: state, project_config: project_config, git: FakeGit.new,
      window_manager: CLITestHelpers::FakeWindowManager.new, doctor: CLITestHelpers::FakeDoctor.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      hook_runner: CLITestHelpers::FakeHookRunner.new, project_detector: detector, lineage: CLITestHelpers::FakeLineage.new,
      logger: Workspace::Logger.new(output: error_output), output: Workspace::OutputGate.new(output), error_output: error_output, exit_handler: FakeExitHandler,
      input: StringIO.new, working_dir: "/src/api", sleeper: ->(_) {}, launch_mode: CLITestHelpers.launch_mode(headless: false),
      env: env, relauncher: relauncher, **unused)
  end

  it "hands the relaunch of its own workspace to the background and stops nothing itself" do
    cli.run(["relaunch"])

    expect(relauncher).to have_received(:own_workspace).with(env, nil)
    expect(relauncher).to have_received(:detach).with(%w[api])
    expect(relauncher).not_to have_received(:call)
    expect(output.string).to include("Relaunching api in the background", "closes this window and its tmux session", "Log: /state/.relaunch/x.log")
  end

  it "detaches every workspace of --all when one is the caller's own" do
    cli.run(["relaunch", "--all"])

    expect(relauncher).to have_received(:detach).with(%w[api web])
  end

  it "prints an ok action document with a relaunch_scheduled row per workspace and the log and pid under --json" do
    cli.run(["relaunch", "--json", "api", "web"])

    document = JSON.parse(output.string)
    expect(document).to include("ok" => true, "action" => "relaunch", "status" => "ok", "log" => "/state/.relaunch/x.log", "pid" => 777)
    expect(document["results"].map { |r| [r["workspace"], r["outcome"]] }).to eq([%w[api relaunch_scheduled], %w[web relaunch_scheduled]])
    expect(error_output.string).to include("Relaunching api, web in the background")
  end

  it "relaunches in the foreground when none of the workspaces is the caller's own" do
    cli.run(["relaunch", "web"])

    expect(relauncher).not_to have_received(:detach)
    expect(relauncher).to have_received(:call).with(anything, %w[web])
  end

  context "with a frozen env" do
    let(:env) { {Workspace::CLI::Relauncher::DETACHED_ENV => "1"}.freeze }

    it "reads the marker without mutating the hash" do
      expect { cli.run(["relaunch", "api"]) }.not_to raise_error
      expect(relauncher).not_to have_received(:detach)
      expect(relauncher).to have_received(:call).with(anything, %w[api])
    end
  end

  it "never detaches again, nor asks, in the run the background started, and removes its own records after" do
    env[Workspace::CLI::Relauncher::DETACHED_ENV] = "1"

    cli.run(["relaunch", "api"])

    expect(relauncher).not_to have_received(:own_workspace)
    expect(relauncher).not_to have_received(:detach)
    expect(relauncher).to have_received(:refuse_in_progress!).with(%w[api], except_own: true).ordered
    expect(relauncher).to have_received(:call).with(anything, %w[api]).ordered
    expect(relauncher).to have_received(:release).with(%w[api]).ordered
  end

  context "with the marker in the process environment" do
    around do |example|
      saved = ENV[Workspace::CLI::Relauncher::DETACHED_ENV]
      ENV[Workspace::CLI::Relauncher::DETACHED_ENV] = "1"
      example.run
    ensure
      ENV[Workspace::CLI::Relauncher::DETACHED_ENV] = saved
    end

    let(:env) { ENV }

    it "deletes it before the stop and launch run, so the sessions they start never inherit it" do
      seen = :unset
      allow(relauncher).to receive(:call) do
        seen = ENV[Workspace::CLI::Relauncher::DETACHED_ENV]
        {exit_code: 0, results: [], warnings: []}
      end

      cli.run(["relaunch", "api"])

      expect(seen).to be_nil
      expect(relauncher).not_to have_received(:detach)
    end
  end

  it "counts the marker only when it is exactly 1, and deletes it either way" do
    env[Workspace::CLI::Relauncher::DETACHED_ENV] = "yes"

    cli.run(["relaunch", "api"])

    expect(relauncher).to have_received(:detach).with(%w[api])
    expect(env).not_to have_key(Workspace::CLI::Relauncher::DETACHED_ENV)
  end

  it "refuses a workspace a background relaunch is still relaunching before anything stops" do
    allow(relauncher).to receive(:refuse_in_progress!).and_raise(Workspace::Error.new("still running", code: "relaunch_in_progress", details: {"names" => ["web"], "pid" => 5, "log" => "/l"}))

    expect { cli.run(["relaunch", "--json", "web"]) }.to raise_error(FakeSystemExit)

    expect(JSON.parse(output.string)).to include("ok" => false, "code" => "relaunch_in_progress")
    expect(relauncher).not_to have_received(:call)
  end

  it "runs in the foreground when only the working directory is in the workspace" do
    detected_own = ->(_name) { false }
    allow(relauncher).to receive(:own_workspace).and_return(detected_own)

    cli.run(["relaunch"])

    expect(relauncher).not_to have_received(:detach)
    expect(relauncher).to have_received(:call).with(anything, %w[api])
  end

  it "answers relaunch_detach_failed, with nothing stopped, when the background run can't start" do
    allow(relauncher).to receive(:detach).and_raise(Workspace::Error.new("Could not start", code: "relaunch_detach_failed", details: {"log" => "/l"}))

    expect { cli.run(["relaunch", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

    expect(JSON.parse(output.string)).to include("ok" => false, "code" => "relaunch_detach_failed")
    expect(relauncher).not_to have_received(:call)
  end
end
