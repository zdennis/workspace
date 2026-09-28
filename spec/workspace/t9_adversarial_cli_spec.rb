require "spec_helper"
require "stringio"
require "tmpdir"

# Adversarial CLI/UX specs for T9 (commits 44ce6dc, 5a71390): the
# unknown-option-before-subcommand hint, and the `pipeline status --json`
# schema_version envelope. Each `it` is one confirmed defect, tagged with a
# UC id, and fails against the current code for the reason stated in its
# description.
RSpec.describe "T9 adversarial CLI specs" do
  # Minimal CLI builder, mirroring cli_spec.rb's build_test_cli, kept local so
  # this file has no dependency on that describe block's private helper.
  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)
    config = Workspace::Config.new
    state = CLITestHelpers::FakeState.new
    window_manager = CLITestHelpers::FakeWindowManager.new
    tmux = CLITestHelpers::FakeTmux.new
    project_config = CLITestHelpers::FakeProjectConfig.new
    doctor = CLITestHelpers::FakeDoctor.new
    project_settings = CLITestHelpers::FakeProjectSettings.new
    hook_runner = CLITestHelpers::FakeHookRunner.new
    iterm = CLITestHelpers::FakeITerm.new
    window_layout = CLITestHelpers::FakeWindowLayout.new
    git = Workspace::Git.new(output: output, input: input)
    project_detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)

    stop_command = Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
    start_command = Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
    kill_command = Workspace::Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: input)
    finish_command = Workspace::Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, error_output: error_output, input: input)
    focus_command = Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    sessions_command = Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output)
    session_event_command = Workspace::Commands::SessionEvent.new(config: config, tmux: tmux, input: input, env: {})
    hook_installer = Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: output), output: output, input: input)
    init_command = Workspace::Commands::Init.new(config: config, hook_installer: hook_installer, which: ->(_exe) { false }, output: output, error_output: error_output, input: input)
    repair_command = CLITestHelpers::FakeRepairCommand.new
    cleanup_command = Workspace::Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
    prune_command = Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command, output: output, input: input)
    claude_command = CLITestHelpers::FakeClaudeCommand.new
    lookup_command = Workspace::Commands::Lookup.new(project_config: project_config, output: output)
    update_pane_command = CLITestHelpers::FakeUpdatePaneCommand.new
    run_command = CLITestHelpers::FakeRunCommand.new
    run_result_store = CLITestHelpers::FakeRunResultStore.new
    run_and_report_command = CLITestHelpers::FakeRunAndReportCommand.new
    capture_command = CLITestHelpers::FakeCaptureCommand.new
    lock_command = CLITestHelpers::FakeLockCommand.new
    dev_command = CLITestHelpers::FakeDevCommand.new
    parent_command = CLITestHelpers::FakeParentCommand.new
    agent_command = CLITestHelpers::FakeAgentCommand.new
    ask_command = CLITestHelpers::FakeAskCommand.new

    Workspace::CLI.new(
      config: config, state: state, project_config: project_config, git: git,
      window_manager: window_manager, doctor: doctor, project_settings: project_settings,
      hook_runner: hook_runner, project_detector: project_detector,
      launch_command: launch_command, kill_command: kill_command, finish_command: finish_command,
      start_command: start_command, stop_command: stop_command, focus_command: focus_command,
      tile_command: tile_command, layout_command: layout_command, resize_command: resize_command,
      init_command: init_command, repair_command: repair_command, cleanup_command: cleanup_command,
      prune_command: prune_command, claude_command: claude_command, lookup_command: lookup_command,
      update_pane_command: update_pane_command, run_command: run_command, run_result_store: run_result_store,
      run_and_report_command: run_and_report_command, capture_command: capture_command, wait_until_content_command: CLITestHelpers::FakeWaitUntilContentCommand.new,
      lock_command: lock_command, dev_command: dev_command, parent_command: parent_command,
      agent_command: agent_command, sessions_command: sessions_command, session_event_command: session_event_command,
      config_command: CLITestHelpers::FakeConfigCommand.new, statusline_command: CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: ask_command, exit_handler: Kernel, output: output, error_output: error_output, input: input,
      working_dir: Dir.mktmpdir
    )
  end

  # UC1: `workspace --headless --json launch` has two leading options before
  # the real subcommand. The hint's "following" arg is picked with
  # `args.first`, which grabs the next *option* (`--json`) instead of the
  # actual subcommand (`launch`), producing a hint the user can't run.
  it "UC1: unknown-option hint names another leading option instead of the real subcommand" do
    output = StringIO.new
    error_output = StringIO.new
    cli = build_test_cli(output: output, error_output: error_output)
    allow(Kernel).to receive(:exit)

    cli.run(["--headless", "--json", "launch"])

    expect(error_output.string).to include("workspace launch --headless")
  end

  # UC2: with no subcommand at all (`workspace --json`, `workspace --`), the
  # hint falls back to the literal string "<subcommand>" and tells the user
  # to run that placeholder verbatim -- copy-pasting it fails.
  it "UC2: unknown-option hint prints an unusable literal placeholder when no subcommand follows" do
    output = StringIO.new
    error_output = StringIO.new
    cli = build_test_cli(output: output, error_output: error_output)
    allow(Kernel).to receive(:exit)

    cli.run(["--json"])

    expect(error_output.string).not_to include("<subcommand>")
  end

  # UC3: `workspace pipeline --json status <project>` puts --json before the
  # pipeline subcommand name. `cmd_pipeline` selects its subcommand with a
  # bare `args.shift` (no OptionParser), so "--json" itself is treated as an
  # unrecognized pipeline subcommand, raising UsageError with plain-text
  # pipeline_help -- cmd_pipeline_status (and its {schema_version, ...} JSON
  # error contract) is never reached, breaking stdout purity/envelope
  # guarantees for scripts that put --json first.
  it "UC3: pipeline --json before the subcommand name bypasses the JSON envelope entirely" do
    output = StringIO.new
    error_output = StringIO.new
    cli = build_test_cli(output: output, error_output: error_output)
    allow(Kernel).to receive(:exit)

    cli.run(["pipeline", "--json", "status", "some-project"])

    expect(output.string).not_to eq("")
    parsed = JSON.parse(output.string)
    expect(parsed["schema_version"]).to eq(1)
  end
end
