require "spec_helper"
require "stringio"

RSpec.describe "CLITestHelpers.build_cli" do
  let(:out) { StringIO.new }

  it "builds Workspace::CLI.new from the keywords given, with the parts build_cli makes, when one of them is the CLI's own" do
    keywords = {lineage: LineageSupport.lineage, output: out, error_output: StringIO.new, working_dir: "/src/app"}
    given = nil
    expect(Workspace::CLI).to receive(:new) { |**kw| given = kw }.and_return(:cli)

    expect(CLITestHelpers.build_cli(**keywords)).to eq(:cli)
    expect(given.slice(:output, :error_output, :working_dir)).to eq(keywords.slice(:output, :error_output, :working_dir))
    expect(given).not_to have_key(:lineage)
    expect([given[:common], given[:names], given[:launcher], given[:families][:workflow]].map(&:class))
      .to eq([Workspace::CLI::Common, Workspace::CLI::Names, Workspace::CLI::Launcher, Workspace::CLI::Workflow])
  end

  it "builds through Workspace.build_cli, forwarding osascript:, ui_osascript: and workflow_source_runner:, given only its keywords" do
    osascript = ->(_script) {}
    ui_osascript = ->(_script) {}
    runner = ->(_argv, chdir:, timeout:) {}
    keywords = {output: out, error_output: StringIO.new, input: StringIO.new, env: {}, exit_handler: FakeExitHandler,
                osascript: osascript, ui_osascript: ui_osascript, workflow_source_runner: runner}
    expect(Workspace).to receive(:build_cli).with(**keywords).and_return(:cli)

    expect(CLITestHelpers.build_cli(**keywords)).to eq(:cli)
  end

  it "refuses a Workspace.build_cli override beside a Workspace::CLI.new keyword" do
    expect { CLITestHelpers.build_cli(lineage: LineageSupport.lineage, workflow_source_runner: ->(*) {}) }
      .to raise_error(ArgumentError, "Workspace::CLI.new does not take workflow_source_runner")
  end

  it "builds a CLI that runs" do
    cli = CLITestHelpers.build_cli(lineage: LineageSupport.lineage, output: out, error_output: StringIO.new, exit_handler: FakeExitHandler,
      config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, project_config: CLITestHelpers::FakeProjectConfig.new, git: FakeGit.new,
      window_manager: CLITestHelpers::FakeWindowManager.new, doctor: CLITestHelpers::FakeDoctor.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      hook_runner: CLITestHelpers::FakeHookRunner.new, project_detector: nil, launch_command: nil, kill_command: nil, finish_command: nil, start_command: nil,
      stop_command: nil, focus_command: nil, tile_command: nil, layout_command: nil, resize_command: nil, init_command: nil, repair_command: nil,
      cleanup_command: nil, prune_command: nil, claude_command: nil, lookup_command: nil, update_pane_command: nil, run_command: nil, run_result_store: nil,
      run_and_report_command: nil, capture_command: nil, wait_until_content_command: nil, lock_command: nil, dev_command: nil, parent_command: nil,
      agent_command: nil, sessions_command: nil, session_event_command: nil, config_command: nil, statusline_command: nil, ask_command: nil,
      launch_mode: CLITestHelpers.launch_mode(headless: false))
    cli.run(["version"])

    expect(out.string).to eq("workspace #{Workspace::VERSION}\n")
  end
end
