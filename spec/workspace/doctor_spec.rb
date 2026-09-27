require "stringio"

RSpec.describe Workspace::Doctor do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_installer) { double("hook_installer") }
  let(:project_detector) { double("project_detector", detect: nil) }

  def build_doctor(**overrides)
    described_class.new(
      config: config,
      state: state,
      hook_installer: hook_installer,
      project_detector: project_detector,
      output: output,
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

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config valid for myapp")
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
end
