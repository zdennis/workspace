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
end
