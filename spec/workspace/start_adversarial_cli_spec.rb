require "spec_helper"
require "stringio"
require "tmpdir"

# Adversarial CLI/UX specs for `workspace start` non-interactive support
# (--base, --yes, --json; commits 6ee4577, 3b30742). Each `it` is one
# confirmed defect, tagged with an SU id, and fails against the current code
# for the reason stated in its description.
RSpec.describe "workspace start adversarial CLI specs" do
  # Minimal CLI builder, mirroring cli_spec.rb's build_test_cli, kept local so
  # this file has no dependency on that describe block's private helper.
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

    stop_command = Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
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
    stop_command_for_prune = instance_double(Workspace::Commands::Stop)
    prune_command = Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command_for_prune, output: output, input: input)
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
      config_command: CLITestHelpers::FakeConfigCommand.new,
      statusline_command: CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: CLITestHelpers::FakeAskCommand.new,
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

  # SU1: `--json`'s promise ("on an error, prints
  # {"schema_version":1,"error":...} to stdout and returns exit 1") only
  # holds when --json happens to be parsed before the flag that errors.
  # cmd_start sets a local `json` flag from inside the OptionParser block, so
  # an OptionParser::ParseError raised while processing an *earlier* flag
  # (e.g. an unknown flag) fires before --json's block ever runs. The error
  # then falls through to CLI#run's plain-text rescue (stderr, no JSON),
  # even though the user did pass --json.
  it "SU1 | high | --json's JSON-on-error contract is order-dependent on flag position | lib/workspace/cli.rb:386-389 | parse args into a struct first (or re-scan for \"--json\" before raising) so any parse error is JSON-formatted regardless of flag order" do
    cli, output, error_output = build_test_cli

    exit_status = nil
    begin
      cli.run(["start", "--bogus-flag", "--json", "PROJ-1"])
    rescue FakeSystemExit => e
      exit_status = e.status
    end

    expect(exit_status).to eq(1)
    parsed = begin
      JSON.parse(output.string)
    rescue
      nil
    end
    expect(parsed).not_to be_nil, "expected stdout to contain the documented JSON error payload, got stdout=#{output.string.inspect} stderr=#{error_output.string.inspect}"
    expect(parsed["schema_version"]).to eq(1) if parsed
  end

  # SU2: when the requested branch already exists, start! returns early
  # (start.rb:170-171) before --base is ever consulted. No warning is logged
  # even though the caller explicitly asked for a specific base — the flag is
  # silently dropped, and the JSON payload's "base" field comes back nil with
  # no indication --base was ignored.
  it "SU2 | medium | --base is silently ignored (no warning) when the target branch already exists | lib/workspace/commands/start.rb:170 | log a warning (plain text) / add an \"base_ignored\" style note (--json) when --base is given but the branch already exists" do
    tmpdir = Dir.mktmpdir
    begin
      output = StringIO.new
      error_output = StringIO.new
      git = double("git")
      project_config = double("project_config")
      project_settings = CLITestHelpers::FakeProjectSettings.new
      launch_command = double("launch_command", call: {exit_code: 0})

      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).with("PROJ-1").and_return({type: :jira_key, value: "PROJ-1"})
      allow(git).to receive(:sanitize_for_filesystem).with("PROJ-1").and_return("PROJ-1")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("PROJ-1").and_return(true)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-1")

      command = Workspace::Commands::Start.new(
        git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, output: output, input: StringIO.new, error_output: error_output
      )

      command.call("PROJ-1", base: "develop", yes: true)

      # Human mode: the note goes to stderr, not stdout (stdout stays the
      # documented progress output; --json mode carries it in a "warnings" array).
      expect(error_output.string).to match(/ignor|--base/i), "expected a warning that --base was ignored, got: #{error_output.string.inspect}"
    ensure
      FileUtils.remove_entry(tmpdir)
    end
  end

  # SU3: resolving a PR branch shells out to `gh` via Open3.capture3 with no
  # rescue for it being missing (Errno::ENOENT). Start#call_json only rescues
  # Workspace::Error, so a missing `gh` propagates as a raw Ruby exception
  # instead of the documented JSON error payload -- "gh missing must not
  # break --json" is violated.
  it "SU3 | high | missing `gh` crashes the --json path instead of emitting the documented JSON error | lib/workspace/commands/start.rb:63-69 | rescue Errno::ENOENT (and similar) around gh invocation and re-raise as Workspace::Error" do
    tmpdir = Dir.mktmpdir
    begin
      output = StringIO.new
      git = double("git")
      project_config = double("project_config")
      project_settings = CLITestHelpers::FakeProjectSettings.new
      launch_command = double("launch_command")

      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).and_return({type: :pr_url, value: "https://github.com/org/repo/pull/1"})
      allow(git).to receive(:resolve_branch_from_pr).and_raise(Errno::ENOENT, "No such file or directory - gh")

      command = Workspace::Commands::Start.new(
        git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, output: output, input: StringIO.new
      )

      result = nil
      expect {
        result = command.call("https://github.com/org/repo/pull/1", json: true)
      }.not_to raise_error

      expect(result[:exit_code]).to eq(1)
      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(1)
    ensure
      FileUtils.remove_entry(tmpdir)
    end
  end
end
