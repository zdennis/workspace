require "tmpdir"
require "json"

# Adversarial CLI/UX coverage for `workspace event-log` (T7). Each `it` is a
# confirmed defect, proven with a failing spec. See cli_spec.rb for
# `build_test_cli` and the happy-path event-log show specs this extends.
RSpec.describe "workspace event-log (adversarial CLI/UX)" do
  # Minimal copy of cli_spec.rb's build_test_cli (not shared across files) —
  # only what event-log show needs; everything else uses the same fakes.
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
      capture_command: capture_command, wait_until_content_command: CLITestHelpers::FakeWaitUntilContentCommand.new,
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      agent_command: agent_command,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: overrides[:config_command] || CLITestHelpers::FakeConfigCommand.new,
      statusline_command: CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: ask_command,
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: overrides[:exit_handler] || FakeExitHandler,
      input: input,
      working_dir: working_dir,
      clock: overrides[:clock] || -> { Time.now }
    )
    [cli, output, error_output, hook_runner]
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
      allow(c).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
      allow(c).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
    end
  end
  let(:event_log) { Workspace::EventLog.new(config: config, error_output: StringIO.new) }
  let(:state) { Workspace::State.new(config: config, event_log: event_log) }

  after { FileUtils.remove_entry(tmpdir) }

  # EU1: --json before the subcommand word makes `--json` itself be parsed
  # as the subcommand, so the "Unknown event-log subcommand" error is raised
  # as plain text on stderr instead of the promised
  # {"schema_version":1,"error":...} on stdout, breaking the project's
  # documented "--json works no matter where the flag appears" contract
  # (lib/workspace/cli.rb:2452-2457, docs/README.event-log.md:27).
  it "EU1: keeps stdout JSON-only when --json precedes the subcommand word" do
    cli, output, error_output = build_test_cli(state: state, config: config)

    # A leading --json makes "show" dispatch correctly (not an "Unknown
    # event-log subcommand" error), so this succeeds without exiting.
    cli.run(["event-log", "--json", "show"])

    expect(output.string).not_to be_empty
    expect { JSON.parse(output.string) }.not_to raise_error
    expect(error_output.string).to eq("")
  end

  it "EU1: still returns a JSON usage error on stdout when --json precedes an unknown subcommand" do
    cli, output, error_output = build_test_cli(state: state, config: config)

    expect { cli.run(["event-log", "--json", "bogus"]) }.to raise_error(FakeSystemExit)

    expect(output.string).not_to be_empty
    expect { JSON.parse(output.string) }.not_to raise_error
    expect(error_output.string).to eq("")
  end

  # EU2: format_event used to join "key=value" pairs with two raw spaces and
  # no escaping. A value containing a space or "=" was indistinguishable
  # from a key/value boundary, so the documented "key=value ..." line format
  # (docs/README.event-log.md:27) could not be parsed back out reliably even
  # though the log records exactly this kind of free-text data (e.g.
  # stage_completed's `summary`, dispatch_failed's `message`).
  #
  # Fix: such values are quoted with String#inspect. A quote-aware reader
  # (one that treats a `"`-delimited run as a single token, as any reader of
  # a quoted format must) recovers the value exactly; a blind split on "  "
  # still cannot, which is why the format docs point scripts at --json
  # instead.
  it "EU2: a value containing a double space is quoted and recoverable by a quote-aware reader" do
    event_log.record(type: "stage_completed", project: "proj1",
      data: {"summary" => "line one  line two", "next_stage" => "review"})
    cli, output, = build_test_cli(state: state, config: config)

    cli.run(["event-log", "show"])

    line = output.string.lines.first.chomp
    fields = line.scan(/(?:"(?:\\.|[^"\\])*"|\S)+/)
    parsed = fields.each_with_object({}) do |field, acc|
      key, value = field.split("=", 2)
      next unless value
      acc[key] = value.start_with?('"') ? eval(value) : value # standard:disable Security/Eval
    end
    expect(parsed["summary"]).to eq("line one  line two")
  end

  # EU3: lock events are recorded under the lock namespace's project name
  # (the parent/main workspace), not the worktree's own workspace name
  # (lib/workspace/commands/lock.rb:369-378). A user filtering
  # `event-log show --project <worktree-name>` to see that worktree's lock
  # waits gets nothing back, with no indication the events exist under a
  # different name.
  it "EU3: --project <worktree workspace name> misses that worktree's lock events" do
    event_log.record(type: "lock_wait_started", project: "main-repo",
      data: {"lock" => "devenv", "pid" => 111, "workspace" => "main-repo-feature-branch"})
    cli, output, = build_test_cli(state: state, config: config)

    # The waiter ran `workspace lock acquire` from the worktree workspace
    # "main-repo-feature-branch"; that is the name it knows itself by and
    # the name it would naturally pass to --project. The event log recorded
    # the wait under the lock namespace's project ("main-repo") instead, so
    # this lookup silently returns nothing.
    cli.run(["event-log", "show", "--project", "main-repo-feature-branch"])

    expect(output.string).not_to eq("")
  end

  # EU4: an unreadable (e.g. permission-denied) event log file raises an
  # uncaught Errno::EACCES from EventLog#events (only per-line JSON parse
  # errors are rescued there; File.readlines itself is not), crashing the
  # whole process with a Ruby backtrace instead of a clean error message
  # (or, under --json, a clean stdout-only JSON error).
  it "EU4: a permission-denied event log file crashes instead of reporting an error" do
    File.write(config.event_log_file, JSON.generate({"type" => "launched", "project" => "p", "data" => {}}) + "\n")
    File.chmod(0o000, config.event_log_file)
    cli, output, = build_test_cli(state: state, config: config)

    begin
      expect { cli.run(["event-log", "show", "--json"]) }.not_to raise_error
      expect(output.string).not_to be_empty
      expect { JSON.parse(output.string) }.not_to raise_error
    ensure
      File.chmod(0o600, config.event_log_file)
    end
  end
end
