require "spec_helper"
require "tmpdir"
require "stringio"

# Adversarial CLI/UX coverage for `workspace ask` (commits 9508396, 2fb0724,
# e999ff1, 27bb7b7 vs origin/main). Each example is a confirmed defect,
# tagged AU<n> for cross-reference with the review report. See
# lib/workspace/commands/ask.rb, lib/workspace/ask_store.rb, and the `ask`
# dispatch in lib/workspace/cli.rb.
RSpec.describe "workspace ask adversarial findings" do
  def build_test_cli(output:, error_output:, ask_command: CLITestHelpers::FakeAskCommand.new, input: StringIO.new)
    config = Workspace::Config.new
    logger = Workspace::Logger.new(output: error_output)
    state = CLITestHelpers::FakeState.new
    window_manager = CLITestHelpers::FakeWindowManager.new
    tmux = CLITestHelpers::FakeTmux.new
    project_config = CLITestHelpers::FakeProjectConfig.new
    doctor = CLITestHelpers::FakeDoctor.new
    project_settings = CLITestHelpers::FakeProjectSettings.new
    hook_runner = CLITestHelpers::FakeHookRunner.new
    working_dir = Dir.tmpdir
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

    Workspace::CLI.new(
      config: config, state: state, project_config: project_config, git: git, window_manager: window_manager,
      doctor: doctor, project_settings: project_settings, hook_runner: hook_runner, project_detector: project_detector,
      launch_command: launch_command, kill_command: kill_command, finish_command: finish_command, start_command: start_command,
      stop_command: stop_command, focus_command: focus_command, tile_command: tile_command, layout_command: layout_command,
      resize_command: resize_command, init_command: init_command, repair_command: repair_command, cleanup_command: cleanup_command,
      prune_command: prune_command, claude_command: claude_command, lookup_command: lookup_command, update_pane_command: update_pane_command,
      run_command: run_command, run_result_store: run_result_store, run_and_report_command: run_and_report_command,
      capture_command: capture_command, lock_command: lock_command, dev_command: dev_command, parent_command: parent_command,
      agent_command: agent_command, sessions_command: sessions_command, session_event_command: session_event_command,
      config_command: CLITestHelpers::FakeConfigCommand.new, ask_command: ask_command, logger: logger,
      output: output, error_output: error_output, exit_handler: FakeExitHandler, input: input, working_dir: working_dir,
      clock: -> { Time.now }
    )
  end

  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:ask_command) { CLITestHelpers::FakeAskCommand.new }
  let(:cli) { build_test_cli(output: output, error_output: error_output, ask_command: ask_command) }

  # --- AU1: reserved-word question text hijacks the subcommand dispatch ---
  # cmd_ask (cli.rb:850-856) dispatches purely on args.first, so a question
  # whose text happens to equal a subcommand name can never be recorded --
  # it is silently routed to that subcommand instead. Each example asserts
  # the correct behavior (the question gets recorded) and fails against the
  # current dispatch.
  describe "subcommand dispatch vs. question text (cli.rb:850-856)" do
    it "AU1a: a question that is literally 'list' should still be recorded, not routed to `ask list`" do
      expect { cli.run(["ask", "list", "--default", "x"]) }.not_to raise_error

      expect(ask_command.calls).to contain_exactly(
        a_hash_including(action: :call, question: "list", default: "x")
      )
    end

    it "AU1b: a question that is literally 'answer' should still be recorded, not routed to `ask answer`" do
      expect { cli.run(["ask", "answer", "--default", "x"]) }.not_to raise_error

      expect(ask_command.calls).to contain_exactly(
        a_hash_including(action: :call, question: "answer", default: "x")
      )
    end

    it "AU1c: a question that is literally 'help' should still be recorded, not swallowed by the help screen" do
      cli.run(["ask", "help", "--default", "x"])

      expect(ask_command.calls).to contain_exactly(
        a_hash_including(action: :call, question: "help", default: "x")
      )
    end
  end

  # --- AU3: in-CLI help omits --json on `ask answer`, contradicting docs/README.ask.md ---
  describe "help text vs documented behavior" do
    it "AU3: ask_help's usage line for `ask answer` omits [--json], even though `ask answer --json` is supported and documented" do
      cli.run(["ask", "help"])

      usage_line = output.string.lines.find { |l| l.include?("ask answer") }
      expect(usage_line).not_to be_nil
      # docs/README.ask.md documents: workspace ask answer <id> "<answer>" [--json]
      expect(usage_line).to include("--json")
    end
  end
end

# --- Direct Ask coverage: no validation on blank input ---
RSpec.describe Workspace::Commands::Ask do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-ask-adversarial") }
  let(:config) { instance_double(Workspace::Config, ask_state_path: File.join(tmpdir, "asks.json")) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "myapp") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  subject(:command) do
    described_class.new(config: config, project_detector: project_detector, alert_config: nil,
      env: {}, output: output, error_output: error_output)
  end

  it "AU5: rejects a whitespace-only question or default instead of recording a meaningless record" do
    expect { command.call(question: "   ", default: "   ", working_dir: "/app") }.to raise_error(Workspace::Error)
    # Currently: Ask#call and AskStore#add apply no presence/blank check, so
    # this records `{"question"=>"   ","default"=>"   ",...}` and returns
    # exit_code: 0 -- a question a human can never meaningfully resolve.
  end
end
