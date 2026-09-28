# Adversarial CLI/UX coverage for the delivery-verification changes on this
# branch (commits 2f37809, aa94a4e, caf6fb4). Each `it` is one confirmed
# defect, tagged DU<n> in its description. No real tmux/iTerm; FakeTmux and
# doubles only.
RSpec.describe "delivery adversarial (CLI/UX)" do
  describe "DU1: workspace run gives no actionable guidance when text landed but Enter didn't submit it" do
    let(:output) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:tmux) { double("tmux") }
    let(:state) { double("state") }
    let(:window_manager) { double("window_manager") }

    subject(:command) do
      Workspace::Commands::Run.new(
        tmux: tmux, state: state, window_manager: window_manager,
        output: output, error_output: error_output
      )
    end

    before do
      allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
      allow(tmux).to receive(:deliver).and_return(
        Workspace::Tmux::Delivery.new(
          status: :unsubmitted,
          message: "the text is in myproject:0.2, but pressing Enter twice didn't change the screen; it may not have been submitted"
        )
      )
    end

    # docs/README.run.md documents --dry-run, --pane, --split, --wait, etc.
    # but says nothing about a delivered-but-unsubmitted command raising an
    # error. A caller (human or agent) sees "Error: Failed to send command
    # ... it may not have been submitted" and, per Run#send_text, has no way
    # to learn from `run` itself that retrying would type the command twice
    # -- that guidance only exists in docs/README.agent.md, for the separate
    # `workspace agent` socket protocol.
    it "tells the caller not to resend the command, since it already reached the pane" do
      expect { command.call("myproject", "echo hi") }.to raise_error(Workspace::Error) do |error|
        text = error.message.downcase
        expect(text).to satisfy("mention that resending would type it again") { |t|
          t.include?("resend") || t.include?("typed twice") || t.include?("don't run it again") ||
            t.include?("do not run it again") || t.include?("sent again")
        }
      end
    end
  end

  describe "DU2: workspace run --dry-run prints commands that do not match what --dry-run's own sibling call actually runs" do
    let(:output) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:tmux) { double("tmux") }
    let(:state) { double("state") }
    let(:window_manager) { double("window_manager") }

    subject(:command) do
      Workspace::Commands::Run.new(
        tmux: tmux, state: state, window_manager: window_manager,
        output: output, error_output: error_output
      )
    end

    before do
      allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
    end

    # Tmux#deliver (lib/workspace/tmux.rb) no longer uses `send-keys -l` at
    # all: it loads the text into a paste buffer and runs `paste-buffer`,
    # specifically because tmux 3.x parses a `send-keys -l` argument starting
    # with '-' as a flag. --dry-run (run.rb:50) still prints the old
    # `send-keys -l ... <command>` line, which is not the command that would
    # really run and would mislead anyone piping --dry-run output into a
    # script or using it to predict tmux's flag-parsing behavior.
    it "prints the paste-buffer/load-buffer commands that deliver() really issues" do
      command.call("myproject", "echo hi", dry_run: true)

      printed = output.string
      expect(printed).to include("paste-buffer").or include("load-buffer")
      expect(printed).not_to include("send-keys -l")
    end
  end

  describe "DU3: the CLI's contract with Launch#call and Start#call is pinned, not defensively guarded" do
    # cmd_launch and cmd_start (lib/workspace/cli.rb:314,344) index into
    # `result` unguarded: `@exit_handler.exit(result[:exit_code]) if result &&
    # !result[:exit_code].zero?`. Rather than adding a defensive type check
    # in the CLI for a shape only Commands::Launch/Commands::Start ever
    # produce, the contract is pinned at the source: both #call methods must
    # return a Hash with :exit_code and :prompt_failures keys (or nil, which
    # the CLI already handles). spec/workspace/commands/launch_spec.rb:245
    # already asserts the exact shape for a real Launch#call; this test
    # holds the same contract for Start#call, and asserts the general shape
    # for both so a future change to either can't drift silently.
    it "Launch#call returns a Hash with :exit_code and :prompt_failures" do
      tmpdir = Dir.mktmpdir
      config = Workspace::Config.new(workspace_dir: tmpdir)
      allow(config).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
      allow(config).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
      state = Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
      project_config = double("project_config", exists?: true)
      tmux = double("tmux", start_server: nil, rename_window: nil)
      allow(tmux).to receive(:command_for).with("proj1", reattach: false).and_return("tmuxinator start proj1 --attach")
      allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
      allow(tmux).to receive(:sessions).and_return(["proj1"])
      allow(tmux).to receive(:reattach_or_start) { |session, start| "tmux -CC attach -t #{session} || tmux has-session -t #{session} 2>/dev/null || #{start}" }
      iterm = double("iterm", session_map: {}, find_existing_sessions: {}, find_launcher_window_id: nil,
        create_launcher_panes: {"proj1" => "new-uid"})
      window_manager = double("window_manager", iterm_windows: {300 => "workspace-proj1"})
      window_layout = double("window_layout", arrange: nil)
      pipeline_config = double("pipeline_config", stages_for: nil, literal_sentinel_warnings: [])

      launch = Workspace::Commands::Launch.new(
        state: state, iterm: iterm, window_manager: window_manager, tmux: tmux,
        project_config: project_config, window_layout: window_layout, config: config,
        pipeline_config: pipeline_config, output: StringIO.new, error_output: StringIO.new
      )

      result = launch.call(["proj1"])

      expect(result).to be_a(Hash)
      expect(result).to include(:exit_code, :prompt_failures)
      expect(result[:exit_code]).to be_an(Integer)
      expect(result[:prompt_failures]).to be_a(Hash)
    end

    it "Start#call returns a Hash with :exit_code and :prompt_failures, or nil, from the launch command" do
      tmpdir = Dir.mktmpdir
      git = double("git")
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
      allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
      allow(git).to receive(:create_worktree)
      project_config = double("project_config", create_worktree: "myproject.worktree-PROJ-123")
      project_settings = CLITestHelpers::FakeProjectSettings.new
      launch_command = double("launch_command", call: {exit_code: 0, prompt_failures: {}})

      start = Workspace::Commands::Start.new(
        git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, output: StringIO.new, input: StringIO.new
      )

      result = start.call("PROJ-123")

      expect(result).to satisfy("be a Hash with :exit_code/:prompt_failures, or nil") { |r|
        r.nil? || (r.is_a?(Hash) && r.key?(:exit_code) && r.key?(:prompt_failures))
      }
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir
    end
  end
end
