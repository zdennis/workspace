require "stringio"
require "tmpdir"
require "json"

# Adversarial CLI/UX probes for `workspace handoff check|new` (H3). Each `it`
# is a confirmed defect, not a spec for desired behavior that already works;
# see the spec's PR description for the seeds that were probed and refuted.
RSpec.describe "workspace handoff adversarial CLI probes" do
  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    config = overrides[:config] || Workspace::Config.new
    logger = overrides[:logger] || Workspace::Logger.new(output: error_output)
    state = overrides[:state] || CLITestHelpers::FakeState.new
    window_manager = overrides[:window_manager] || CLITestHelpers::FakeWindowManager.new
    tmux = overrides[:tmux] || CLITestHelpers::FakeTmux.new
    project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
    doctor = overrides[:doctor] || CLITestHelpers::FakeDoctor.new
    project_settings = overrides[:project_settings] || CLITestHelpers::FakeProjectSettings.new
    hook_runner = overrides[:hook_runner] || CLITestHelpers::FakeHookRunner.new
    working_dir = overrides[:working_dir] || Dir.tmpdir

    iterm = overrides[:iterm] || CLITestHelpers::FakeITerm.new
    window_layout = overrides[:window_layout] || CLITestHelpers::FakeWindowLayout.new
    git = overrides[:git] || Workspace::Git.new(output: output, input: input)

    project_detector = overrides[:project_detector] || Workspace::ProjectDetector.new(state: state, project_config: project_config)

    stop_command = overrides[:stop_command] || Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = overrides[:launch_command] || Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
    kill_command = overrides[:kill_command] || Workspace::Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: input)
    finish_command = overrides[:finish_command] || Workspace::Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, error_output: error_output, input: input)
    focus_command = overrides[:focus_command] || Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = overrides[:tile_command] || Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = overrides[:layout_command] || Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = overrides[:resize_command] || Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    sessions_command = overrides[:sessions_command] || Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output)
    session_event_command = overrides[:session_event_command] || Workspace::Commands::SessionEvent.new(config: config, tmux: tmux, input: input, env: {})
    hook_installer = Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: output), output: output, input: input)
    init_command = overrides[:init_command] || Workspace::Commands::Init.new(config: config, hook_installer: hook_installer, which: ->(_exe) { false }, output: output, error_output: error_output, input: input)
    repair_command = overrides[:repair_command] || CLITestHelpers::FakeRepairCommand.new
    cleanup_command = overrides[:cleanup_command] || Workspace::Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
    stop_command_for_prune = instance_double(Workspace::Commands::Stop)
    prune_command = overrides[:prune_command] || Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command_for_prune, output: output, input: input)
    claude_command = overrides[:claude_command] || CLITestHelpers::FakeClaudeCommand.new
    lookup_command = overrides[:lookup_command] || Workspace::Commands::Lookup.new(project_config: project_config, output: output)
    update_pane_command = overrides[:update_pane_command] || CLITestHelpers::FakeUpdatePaneCommand.new
    run_command = overrides[:run_command] || CLITestHelpers::FakeRunCommand.new
    run_result_store = overrides[:run_result_store] || CLITestHelpers::FakeRunResultStore.new
    run_and_report_command = overrides[:run_and_report_command] || CLITestHelpers::FakeRunAndReportCommand.new
    capture_command = overrides[:capture_command] || CLITestHelpers::FakeCaptureCommand.new
    lock_command = overrides[:lock_command] || CLITestHelpers::FakeLockCommand.new
    dev_command = overrides[:dev_command] || CLITestHelpers::FakeDevCommand.new
    parent_command = overrides[:parent_command] || CLITestHelpers::FakeParentCommand.new
    agent_command = overrides[:agent_command] || CLITestHelpers::FakeAgentCommand.new
    ask_command = overrides[:ask_command] || CLITestHelpers::FakeAskCommand.new

    cli = Workspace::CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
      launch_command: launch_command,
      kill_command: kill_command,
      finish_command: finish_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      repair_command: repair_command,
      cleanup_command: cleanup_command,
      prune_command: prune_command,
      claude_command: claude_command,
      lookup_command: lookup_command,
      update_pane_command: update_pane_command,
      run_command: run_command,
      run_result_store: run_result_store,
      run_and_report_command: run_and_report_command,
      capture_command: capture_command,
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      agent_command: agent_command,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: overrides[:config_command] || CLITestHelpers::FakeConfigCommand.new,
      statusline_command: overrides[:statusline_command] || CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: ask_command,
      restart_agent_command: overrides[:restart_agent_command],
      handoff_command: overrides[:handoff_command],
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: overrides[:exit_handler] || FakeExitHandler,
      input: input,
      working_dir: working_dir,
      clock: overrides[:clock] || -> { Time.now }
    )
    [cli, output, error_output]
  end

  let(:handoff_command) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }

  # HC1: `--threshold` reaches Handoff#check with no range validation, unlike
  # `--context-pct` (lib/workspace/commands/handoff.rb:69-71 only checks
  # context_pct). A negative or >100 threshold is silently accepted and
  # changes trigger behavior instead of raising a usage error.
  it "HC1: rejects an out-of-range --threshold instead of silently accepting it" do
    cli, _output, error_output = build_test_cli(handoff_command: handoff_command)

    expect { cli.run(["handoff", "check", "myapp", "--threshold", "-5"]) }
      .to raise_error(FakeSystemExit)
    expect(error_output.string).to match(/threshold/i)
    expect(handoff_command).not_to have_received(:check)
  end

  # HC2: `workspace handoff` (missing subcommand) and `workspace handoff bogus`
  # raise UsageError from CLI#cmd_handoff (lib/workspace/cli.rb:1569-1577)
  # *before* cmd_handoff_check/cmd_handoff_new ever run, so the --json rescue
  # clause that guards those two never fires. --json is silently ignored and
  # the error is printed as plain text on stderr, breaking the documented
  # "--json errors on stdout" contract for these two entry points.
  it "HC2: honors --json for a missing handoff subcommand" do
    cli, output, error_output = build_test_cli(handoff_command: handoff_command)

    expect { cli.run(["handoff", "--json"]) }.to raise_error(FakeSystemExit)

    parsed = JSON.parse(output.string)
    expect(parsed["schema_version"]).to eq(Workspace::Commands::Handoff::JSON_SCHEMA_VERSION)
    expect(error_output.string).to eq("")
  end

  it "HC2: honors --json for an unknown handoff subcommand" do
    cli, output, error_output = build_test_cli(handoff_command: handoff_command)

    expect { cli.run(["handoff", "bogus", "--json"]) }.to raise_error(FakeSystemExit)

    parsed = JSON.parse(output.string)
    expect(parsed["schema_version"]).to eq(Workspace::Commands::Handoff::JSON_SCHEMA_VERSION)
    expect(error_output.string).to eq("")
  end
end
