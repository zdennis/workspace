require "stringio"
require "tmpdir"

# Adversarial CLI/UX specs for headless launch (T8). Each `it` is one
# confirmed defect, tagged with an ID for the report. See
# spec/workspace/headless_launch_adversarial_concurrency_spec.rb for the
# concurrency-focused half of this review.
RSpec.describe "headless launch adversarial (CLI/UX)" do
  describe "HU1: relaunch aborts before launching headless projects" do
    # lib/workspace/cli.rb's cmd_relaunch launches windowed projects first,
    # then headless ones, by calling cmd_launch twice in sequence. cmd_launch
    # calls @exit_handler.exit(1) whenever Launch#call reports a nonzero
    # exit_code. In production, exit_handler is Kernel, so that exit raises
    # SystemExit and the process terminates -- the second cmd_launch call
    # (for the headless projects) never runs. A relaunch with a mix of
    # windowed and headless projects silently drops every headless project
    # whenever the windowed batch has any failure (a missing window, an
    # unsent prompt, etc).
    it "never attempts to relaunch headless projects when the windowed batch exits nonzero" do
      output = StringIO.new
      error_output = StringIO.new
      state = CLITestHelpers::FakeState.new
      state["windowed-proj"] = {"iterm_window_id" => 1}
      state["headless-proj"] = {"headless" => true}

      windowed_calls = []
      headless_calls = []
      launch_command = Object.new
      launch_command.define_singleton_method(:call) do |projects, **opts|
        if opts[:headless]
          headless_calls << projects
          {exit_code: 0, prompt_failures: {}}
        else
          windowed_calls << projects
          {exit_code: 1, prompt_failures: {"windowed-proj" => "window never appeared"}}
        end
      end

      cli, = build_relaunch_test_cli(state: state, launch_command: launch_command, output: output, error_output: error_output)

      begin
        cli.run(["relaunch"])
      rescue FakeSystemExit
        nil
      end

      expect(windowed_calls).to eq([["windowed-proj"]])
      # It should still relaunch the headless batch even when the windowed
      # batch failed; currently it never gets there (raises FakeSystemExit
      # instead), which is the defect.
      expect(headless_calls).to eq([["headless-proj"]])
    end
  end

  describe "HU2: a headless relaunch of a reused session keeps stale iTerm state" do
    # lib/workspace/commands/launch.rb#call_headless only writes
    # {"headless" => true} when the project is newly started, or has no
    # prior state at all:
    #
    #   @state[project] = {"headless" => true} unless reused.include?(project) && @state[project]
    #
    # A project previously launched in iTerm2 (state has "iterm_window_id",
    # no "headless" key) that is later relaunched with --headless, while its
    # tmux session is still running, is treated as "reused" and its state is
    # left untouched. `workspace focus` then still thinks it has an iTerm
    # window and tries to focus a window that no longer exists (or was
    # recycled to another project), instead of pointing at the tmux session.
    it "leaves a previously-windowed project's state without headless:true when its session is reused" do
      state = CLITestHelpers::FakeState.new
      state["proj"] = {"iterm_window_id" => 42}

      tmux = CLITestHelpers::FakeTmux.new
      tmux.define_singleton_method(:sessions) { ["proj"] }
      tmux.define_singleton_method(:start_headless) { |_name| raise "should not start a session that is already running" }

      launch = Workspace::Commands::Launch.new(
        state: state, iterm: CLITestHelpers::FakeITerm.new, window_manager: CLITestHelpers::FakeWindowManager.new,
        tmux: tmux, project_config: CLITestHelpers::FakeProjectConfig.new, window_layout: CLITestHelpers::FakeWindowLayout.new,
        config: Workspace::Config.new(workspace_dir: Dir.mktmpdir), output: StringIO.new, error_output: StringIO.new,
        sleeper: ->(_) {}
      )

      launch.call(["proj"], headless: true)

      # Focus/Tile decide "no iTerm window" from this flag; it must be set
      # once the project runs headless, even when its session was reused.
      # Currently it is left unset, which is the defect.
      expect(state["proj"]["headless"]).to be true
    end
  end

  describe "HU3: start_headless leaves a quoted -CC option intact" do
    # lib/workspace/tmux.rb#start_headless strips -C/-CC only from bare,
    # unquoted tokens on the `tmux_options:` line:
    #
    #   kept = Regexp.last_match(1).split.reject { |option| option.match?(/\A-C+\z/) }
    #
    # A config that quotes the value (a perfectly valid YAML style, e.g.
    # `tmux_options: "-CC"`) keeps the quote characters glued to the token,
    # so it never matches /\A-C+\z/ and survives into the headless copy.
    # tmuxinator then still asks tmux for control mode, which needs a
    # terminal -- defeating the whole point of --headless.
    it "does not strip a quoted -CC value from tmux_options" do
      tmpdir = Dir.mktmpdir
      config = Workspace::Config.new(workspace_dir: tmpdir)
      source = File.join(tmpdir, "workspace.proj.yml")
      allow(config).to receive(:config_path_for).with("proj").and_return(source)
      File.write(source, "name: proj\nroot: /tmp\ntmux_options: \"-CC\"\nwindows:\n  - main: echo hi\n")

      tmux = Workspace::Tmux.new(config: config)
      seen_content = nil
      # tmuxinator is spawned in its own process group (for its start
      # timeout); run `true` in its place and keep the config it was given.
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **opts|
        seen_content = File.read(args[3])
        original.call("true", **opts)
      end

      tmux.start_headless("proj")

      # A quoted -CC value should be stripped just like an unquoted one;
      # currently it survives, which is the defect.
      expect(seen_content).not_to include("-CC")
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir
    end
  end

  # HU4 (flags before the top-level subcommand word, e.g. `workspace
  # --headless launch foo`) was reviewed and deliberately not fixed here:
  # accepting flags in either position is a CLI-wide change, not specific to
  # headless launch, and today's behavior (a clear "Unknown subcommand"
  # error, exit 1) is not a silent failure.

  def build_relaunch_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    config = overrides[:config] || Workspace::Config.new(workspace_dir: Dir.mktmpdir)
    logger = Workspace::Logger.new(output: error_output)
    state = overrides[:state] || CLITestHelpers::FakeState.new
    window_manager = CLITestHelpers::FakeWindowManager.new
    tmux = CLITestHelpers::FakeTmux.new
    project_config = CLITestHelpers::FakeProjectConfig.new
    project_settings = CLITestHelpers::FakeProjectSettings.new
    hook_runner = CLITestHelpers::FakeHookRunner.new
    iterm = CLITestHelpers::FakeITerm.new
    window_layout = CLITestHelpers::FakeWindowLayout.new
    git = Workspace::Git.new(output: output, input: input)
    project_detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)

    launch_command = overrides[:launch_command] || Workspace::Commands::Launch.new(
      state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config,
      window_layout: window_layout, config: config, output: output, error_output: error_output
    )
    stop_command = Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
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
    stop_command_for_prune = instance_double(Workspace::Commands::Stop)
    prune_command = Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command_for_prune, output: output, input: input)

    cli = Workspace::CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: CLITestHelpers::FakeDoctor.new,
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
      claude_command: CLITestHelpers::FakeClaudeCommand.new,
      lookup_command: Workspace::Commands::Lookup.new(project_config: project_config, output: output),
      update_pane_command: CLITestHelpers::FakeUpdatePaneCommand.new,
      run_command: CLITestHelpers::FakeRunCommand.new,
      run_result_store: CLITestHelpers::FakeRunResultStore.new,
      run_and_report_command: CLITestHelpers::FakeRunAndReportCommand.new,
      capture_command: CLITestHelpers::FakeCaptureCommand.new,
      lock_command: CLITestHelpers::FakeLockCommand.new,
      dev_command: CLITestHelpers::FakeDevCommand.new,
      parent_command: CLITestHelpers::FakeParentCommand.new,
      agent_command: CLITestHelpers::FakeAgentCommand.new,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: CLITestHelpers::FakeConfigCommand.new,
      statusline_command: CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: CLITestHelpers::FakeAskCommand.new,
      restart_agent_command: nil,
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: FakeExitHandler,
      input: input,
      working_dir: Dir.tmpdir,
      clock: -> { Time.now },
      launch_mode: CLITestHelpers.launch_mode(headless: false)
    )
    [cli, output, error_output, hook_runner]
  end
end
