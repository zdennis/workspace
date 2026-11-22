require "spec_helper"
require "stringio"

RSpec.describe Workspace::Doctor, "orphaned agent daemons" do
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:launch_mode) { Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }) }
  let(:stopper) { instance_double(Workspace::AgentDaemonStopper) }
  let(:configured) { ["alpha"] }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: configured) }
  let(:processes) { [] }
  let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new(processes)) }

  def proc_entry(pid, args)
    {pid: pid, ppid: 1, command: args.split.first, args: args}
  end

  def rows(fix: false, stopper: self.stopper, process_tree: self.process_tree, project_config: self.project_config)
    doctor = described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
      project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      command_probe: ->(_name, _flag) {}, app_probe: ->(_id) { false }, which: ->(_exe) { true }, launch_mode: launch_mode,
      project_config: project_config, daemon_stopper: stopper, process_tree: process_tree)
    doctor.report(fix: fix)[:rows].select { |row| row[:id] == "agentd-orphans" }
  end

  it "is ok with no daemons" do
    expect(rows).to contain_exactly(include(status: "ok"))
  end

  context "with daemons" do
    let(:processes) do
      [proc_entry(101, "ruby /x/bin/workspace agentd --name alpha"),
        proc_entry(102, "ruby /x/bin/workspace agentd --name=ghost"),
        proc_entry(103, "ruby /x/bin/workspace agentd Zombie"),
        proc_entry(104, "ruby /x/bin/workspace agentd"),
        proc_entry(Process.pid, "ruby /x/bin/workspace agentd --name self"),
        proc_entry(105, "vim agentd.rb"),
        proc_entry(106, "rg agentd lib"),
        proc_entry(107, "workspace agentd restart ghost"),
        proc_entry(108, "workspace agentd --ensure --name ghost2"),
        proc_entry(109, "ruby /x/bin/workspace agentd --name ghost"),
        proc_entry(110, "ruby /x/bin/workspace agentd --name Ghost")]
    end

    it "reports only daemons with no config, in both name forms, skipping unreadable names and this process" do
      row = rows.first

      expect(rows.size).to eq(1)
      expect(row).to include(status: "warn", fix: "workspace doctor --fix", fix_command: "workspace doctor --fix")
      expect(row[:message]).to include("ghost (pid 102)", "Zombie (pid 103)")
      expect(row[:message]).not_to include("alpha", "pid 104", "self", "pid 105", "pid 106", "pid 107", "ghost2", "pid 109", "pid 110")
    end

    it "stops each orphan once under --fix and reports a refusal as refused" do
      allow(stopper).to receive(:call).with(name: "ghost").and_return(Workspace::AgentDaemonStopper::Result.new(:stopped, 102, "stopped"))
      allow(stopper).to receive(:call).with(name: "Zombie").and_return(Workspace::AgentDaemonStopper::Result.new(:refused, nil, "no process holds its socket"))

      found = rows(fix: true)

      expect(stopper).to have_received(:call).with(name: "ghost").once
      expect(stopper).to have_received(:call).with(name: "Zombie").once
      expect(stopper).not_to have_received(:call).with(name: "alpha")
      expect(found).to contain_exactly(
        include(status: "ok", message: a_string_including("ghost (pid 102)")),
        include(status: "warn", message: a_string_including("refused to stop", "Zombie", "another HOME"))
      )
    end

    it "reads the process table once under --fix" do
      allow(stopper).to receive(:call).and_return(Workspace::AgentDaemonStopper::Result.new(:stopped, 1, "stopped"))

      rows(fix: true)

      expect(process_tree).to have_received(:snapshot).once
    end

    it "does not stop anything without --fix" do
      expect(stopper).not_to receive(:call)

      rows
    end
  end

  it "reports a daemon that failed to exit as a failure" do
    allow(process_tree).to receive(:snapshot).and_return(Workspace::ProcessTree::Snapshot.new([proc_entry(7, "workspace agentd --name ghost")]))
    allow(stopper).to receive(:call).and_return(Workspace::AgentDaemonStopper::Result.new(:timed_out, 7, "still there"))

    expect(rows(fix: true)).to contain_exactly(include(status: "fail", message: a_string_including("ghost (pid 7)", "still there")))
  end

  it "adds a single ok row under --fix with no orphans" do
    expect(stopper).not_to receive(:call)

    expect(rows(fix: true)).to contain_exactly(include(status: "ok"))
  end

  context "with the real stopper and a daemon holding no socket under this HOME" do
    it "warns, says it was not stopped, and signals nothing" do
      signals = []
      config = double("config", agent_running?: false, agent_socket_path: "/nonexistent/ghost.sock")
      real = Workspace::AgentDaemonStopper.new(config: config, process_tree: double("tree"), pid_finder: ->(_) { [] },
        signaller: ->(*args) { signals << args })
      allow(process_tree).to receive(:snapshot).and_return(Workspace::ProcessTree::Snapshot.new([proc_entry(88, "ruby /x/bin/workspace agentd --name ghost")]))

      found = rows(fix: true, stopper: real)

      expect(found).to contain_exactly(include(status: "warn", fix: a_string_including("ps -p 88 -o args="), fix_command: nil,
        message: a_string_including("pid 88 runs agentd for ghost", "no socket", "not stopped")))
      expect(signals).to be_empty
    end
  end

  it "has no row when a collaborator is missing" do
    expect(rows(stopper: nil)).to eq([])
    expect(rows(process_tree: nil)).to eq([])
    expect(rows(project_config: nil)).to eq([])
  end

  it "says the process table could not be read" do
    allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")

    expect(rows).to contain_exactly(include(status: "skipped", message: a_string_including("ps failed")))
  end
end
