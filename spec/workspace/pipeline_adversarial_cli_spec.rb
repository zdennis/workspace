require "spec_helper"
require "stringio"
require "tmpdir"

# Adversarial CLI/UX specs for the sentinel-token + timeout work
# (commits 2c9ebe9, 5604ed0, 2ffe90b). Each `it` is one confirmed defect,
# tagged with a PU id, and fails against the current code for the reason
# stated in its description.
RSpec.describe "pipeline reliability adversarial CLI specs" do
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
    start_command = Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
    kill_command = Workspace::Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: input)
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

  let(:tmpdir) { Dir.mktmpdir("ws-pipeline-adversarial", "/tmp") }
  let(:config) do
    dir = tmpdir
    Class.new(Workspace::Config) do
      define_method(:pipeline_state_path) { |name| File.join(dir, "#{name}-pipeline.json") }
      define_method(:agent_socket_path) { |name| File.join(dir, "#{name}.sock") }
    end.new
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def write_state(project, entries)
    File.write(config.pipeline_state_path(project), JSON.generate(entries))
  end

  # PU1: pipeline status shows the deadline for an in-flight stage.
  #
  # pipeline_state.rb now persists deadline_at per entry (used for restart
  # recovery and the timeout failure message), but cli.rb's status table
  # (cli.rb, cmd_pipeline_status) only ever prints work item / pane / phase.
  # An operator staring at `pipeline status` while a stage runs has no way to
  # tell whether, or when, it is about to be failed for a timeout — they only
  # find out after the fact from the agent's stderr/log. This defect also
  # covers the --json path silently keeping deadline_at (so at least scripts
  # can see it) while the human-facing table drops it on the floor.
  it "PU1 | medium | pipeline status hides an in-flight stage's deadline from the human-readable table | lib/workspace/cli.rb:1385 | print a DEADLINE column (or the ISO deadline_at) alongside pane/stage" do
    now = Time.utc(2026, 9, 27, 12, 0, 0)
    cli, output, = build_test_cli(config: config, clock: -> { now })
    write_state("myapp",
      "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                  "deadline_at" => "2026-09-27T12:30:00.000Z"})

    cli.run(["pipeline", "status", "myapp"])

    expect(output.string).to include("(in 30m)")
  end

  # PU2: the timeout failure message reported to the coordinator/operator is
  # phrased as an absolute ISO timestamp ("by 2026-09-27T12:30:00Z") instead
  # of naming the configured timeout duration ("30m", "1800s", etc). An
  # operator or coordinator log reading "timed out: no WORKSPACE_DONE:tok-1
  # line by 2026-09-27T12:30:00Z" has no idea whether that stage was given
  # 30 seconds or 3 hours without cross-referencing the project's YAML — the
  # one piece of information (the configured budget) that would explain why
  # it fired is missing from the message that fires it.
  it "PU2 | low | stage-timeout failure message reports an absolute ISO deadline instead of the configured timeout duration | lib/workspace/commands/agent.rb:423 | interpolate the stage's configured timeout (e.g. \"30m\") into the failure message" do
    tmux = CLITestHelpers::FakeTmux.new
    pollers = []
    sentinel_poller_factory = lambda do |session_name:, pane:, token:, deadline:|
      poller = Object.new
      poller.define_singleton_method(:start) do |on_error: nil, on_timeout: nil, &block|
        poller.define_singleton_method(:fire_timeout) { on_timeout.call }
        poller
      end
      poller.define_singleton_method(:stop) {}
      pollers << poller
      poller
    end

    project_config_path = File.join(tmpdir, "myapp.yml")
    config_double = instance_double(Workspace::Config,
      agent_socket_path: File.join(tmpdir, "myapp.sock"),
      work_coordinator_socket: File.join(tmpdir, "wc.sock"),
      work_coordinator_status_socket: File.join(tmpdir, "wc-status.sock"),
      handoff_dir: File.join(tmpdir, "handoffs"))
    allow(config_double).to receive(:project_config_path).with("myapp").and_return(project_config_path)

    File.write(project_config_path, <<~YAML)
      pipeline:
        panes:
          - role: researcher
            timeout: 30m
    YAML

    pipeline_config = Workspace::PipelineConfig.new(config: config_double)
    pipeline_state = Workspace::PipelineState.new(pipeline_config: pipeline_config)
    error_output = StringIO.new
    now = Time.utc(2026, 9, 27, 12, 0, 0)

    agent = Workspace::Commands::Agent.new(
      config: config_double,
      tmux: tmux,
      work_coordinator_client: instance_double(Workspace::WorkCoordinatorClient, report_status: {}),
      pipeline_config: pipeline_config,
      pipeline_state: pipeline_state,
      signal_trapper: Class.new {
        def trap(*)
        end
      }.new,
      sentinel_poller_factory: sentinel_poller_factory,
      token_generator: -> { "tok-1" },
      clock: -> { now },
      retry_backoff: 0,
      output: StringIO.new,
      error_output: error_output
    )

    # Drive the private dispatch path the same way the socket server would,
    # without opening a real socket or thread.
    agent.instance_variable_set(:@current_name, "myapp")
    agent.send(:handle_command,
      "work_item_ref" => "WC-42", "dispatch_id" => "d-1", "body" => "go")

    pollers.first.fire_timeout

    expect(error_output.string).to include("30m")
  end
end
