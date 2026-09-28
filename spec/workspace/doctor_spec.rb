require "stringio"

RSpec.describe Workspace::Doctor do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_installer) { double("hook_installer") }
  let(:project_detector) { double("project_detector", detect: nil) }

  def build_doctor(**overrides)
    allow(hook_installer).to receive(:statusline_installed?).and_return(true) unless overrides.key?(:hook_installer)

    described_class.new(
      config: config,
      state: state,
      hook_installer: hook_installer,
      project_detector: project_detector,
      output: output,
      project_settings: CLITestHelpers::FakeProjectSettings.new,
      launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new,
        platform: "arm64-darwin", env: {}, which: ->(_exe) { true }),
      **overrides
    )
  end

  it "runs without crashing and produces output" do
    doctor = build_doctor
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing in test environment
    end
    expect(output.string).to include("workspace doctor")
    expect(output.string.length).to be > 0
  end

  it "checks for required commands and templates" do
    doctor = build_doctor
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing
    end
    expect(output.string).to include("ruby")
    expect(output.string).to include("tmux")
    expect(output.string).to include("git")
  end

  describe "duplicate window ID detection" do
    it "reports no issues when window IDs are unique" do
      state["proj-a"] = {"iterm_window_id" => 100}
      state["proj-b"] = {"iterm_window_id" => 200}

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on missing dependencies
      end
      expect(output.string).to include("no duplicate window IDs")
    end

    it "detects duplicate window IDs" do
      state["growth-engine"] = {"iterm_window_id" => 318}
      state["growth-engine-migrations"] = {"iterm_window_id" => 318}

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # Expected
      end
      expect(output.string).to include("duplicate window IDs detected")
      expect(output.string).to include("window 318 claimed by: growth-engine, growth-engine-migrations")
    end
  end

  describe "session monitoring check" do
    it "skips when not inside a workspace project" do
      allow(project_detector).to receive(:detect).and_return(nil)

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # Expected if other dependencies are missing
      end
      expect(output.string).to include("session monitoring (not inside a workspace project, skipped)")
    end

    it "reports missing hooks and a stopped agent for a detected project" do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")

      doctor = build_doctor(which: ->(_exe) { false })
      expect { doctor.run }.to raise_error(Workspace::Error)
      expect(output.string).to include("no hook-capable agent detected")
      expect(output.string).to include("session monitor agent not running for myapp")
    end

    it "reports installed hooks and a running agent" do
      require "socket"
      tmpdir = Dir.mktmpdir
      socket_path = File.join(tmpdir, "workspace-myapp.sock")
      server = UNIXServer.new(socket_path)

      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return(socket_path)
      allow(hook_installer).to receive(:installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" })
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on missing dependencies unrelated to session monitoring
      end
      expect(output.string).to include("session monitoring hooks installed for myapp")
      expect(output.string).to include("session monitor agent running for myapp")
    ensure
      server&.close
      FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir)
    end
  end

  describe "statusLine check" do
    before do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
    end

    it "reports statusLine routed through workspace" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer)
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on unrelated checks (e.g. agent not running)
      end
      expect(output.string).to include("✓  statusLine routed through workspace")
    end

    it "warns, without failing doctor, when statusLine isn't routed through workspace" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(hook_installer).to receive(:statusline_installed?).and_return(false)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer)
      begin
        doctor.run
      rescue Workspace::Error
        # Unrelated failures (e.g. agent not running) still raise; the
        # statusLine warning itself must not be why.
      end
      expect(output.string).to include("statusLine not routed through workspace")
      expect(output.string).to include("workspace doctor --fix")
    end

    it "skips the check when no hook-capable agent is detected" do
      doctor = build_doctor(which: ->(_exe) { false })
      begin
        doctor.run
      rescue Workspace::Error
        # Expected
      end
      expect(output.string).not_to include("statusLine")
    end
  end

  describe "--fix" do
    it "installs the statusLine entry via HookInstaller before running checks" do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
      allow(hook_installer).to receive(:installed?).and_return(true)
      project_settings = CLITestHelpers::FakeProjectSettings.new

      expect(hook_installer).to receive(:install_statusline)
        .with(instance_of(Workspace::AgentProvider), Dir.pwd, command: "workspace statusline", project_settings: project_settings)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer, project_settings: project_settings)
      begin
        doctor.run(fix: true)
      rescue Workspace::Error
        # Unrelated failures fine; the expectation above is what's under test
      end
    end

    it "does nothing when not inside a workspace project" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect(hook_installer).not_to receive(:install_statusline)

      doctor = build_doctor
      begin
        doctor.run(fix: true)
      rescue Workspace::Error
        # Expected
      end
    end
  end

  describe "pipeline config check" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:project_yml) { File.join(tmpdir, "myapp.yml") }

    before do
      FileUtils.touch(project_yml)
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
      allow(config).to receive(:project_config_path).with("myapp").and_return(project_yml)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reports an invalid pipeline config for the detected project" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp")
        .and_raise(Workspace::Error, "Invalid pipeline.panes[0].timeout in #{project_yml}: must be greater than 0")

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)

      expect { doctor.run }.to raise_error(Workspace::Error)
      expect(output.string).to include("pipeline config invalid for myapp")
      expect(output.string).to include("must be greater than 0")
    end

    it "is silent when the pipeline config is valid" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return([{role: "researcher", pane_index: 0, timeout: nil}])
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp").and_return([])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config valid for myapp")
    end

    it "warns when the pipeline block has no panes" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return(nil)
      allow(pipeline_config).to receive(:declared_but_empty?).with("myapp").and_return(true)
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp").and_return([])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config for myapp has no panes")
    end

    it "warns about a stage that names the bare completion sentinel, without failing the check" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return([{role: "implementer", pane_index: 0, timeout: nil}])
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp")
        .and_return(["myapp's pipeline stage implementer (pane 0) names the bare WORKSPACE_DONE: marker"])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config valid for myapp")
      expect(output.string).to include("names the bare WORKSPACE_DONE: marker")
    end

    it "skips the check when the project has no pipeline config file" do
      FileUtils.rm_f(project_yml)
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for)

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(pipeline_config).not_to have_received(:stages_for)
    end
  end

  describe "worktree lock hook check" do
    let(:git) { double("git") }
    let(:tmpdir) { Dir.mktmpdir }
    let(:worktree_path) { File.join(tmpdir, "worktree-a") }

    before do
      FileUtils.mkdir_p(worktree_path)
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "is skipped without a git dependency" do
      doctor = build_doctor(which: ->(exe) { exe == "claude" })
      allow(hook_installer).to receive(:installed?).and_return(true)

      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).not_to include("edit lock hooks")
    end

    it "reports every worktree with hooks installed" do
      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path])
      allow(hook_installer).to receive(:installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("edit lock hooks installed in every worktree")
    end

    it "warns, without failing doctor, about a worktree missing hooks" do
      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path])
      allow(hook_installer).to receive(:installed?).with(anything, worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, Dir.pwd, anything).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error => e
        # The worktree warning alone must never be why this raises.
        expect(e.message).not_to match(/edit lock hooks/)
      end

      expect(output.string).to include("edit lock hooks missing in 1 worktree(s): worktree-a")
      expect(output.string).to include("fix: run 'workspace init' from each worktree listed above")
    end

    it "falls back to full paths when worktree basenames collide" do
      other_worktree_path = File.join(tmpdir, "nested", "worktree-a")
      FileUtils.mkdir_p(other_worktree_path)

      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path, other_worktree_path])
      allow(hook_installer).to receive(:installed?).with(anything, worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, other_worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, Dir.pwd, anything).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("edit lock hooks missing in 2 worktree(s): #{worktree_path}, #{other_worktree_path}")
    end
  end

  describe "headless" do
    it "skips the iTerm2 and window-tool checks and says why" do
      doctor = build_doctor
      begin
        doctor.run(headless: true)
      rescue Workspace::Error
        # other dependencies may be missing on this machine
      end

      expect(output.string).to include("mode: headless (--headless)")
      expect(output.string).to include("⊘  iTerm2 (not needed headless, skipped)")
      expect(output.string).to include("⊘  window-tool (not needed headless, skipped)")
    end

    it "follows the launch mode when no flag is given" do
      doctor = build_doctor(launch_mode: CLITestHelpers.launch_mode(headless: true))
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("mode: headless (not macOS)")
    end

    it "checks iTerm2 when not headless" do
      doctor = build_doctor
      begin
        doctor.run(headless: false)
      rescue Workspace::Error
      end

      expect(output.string).to include("mode: iTerm2 (--no-headless)")
      expect(output.string).not_to include("not needed headless")
    end
  end
end
