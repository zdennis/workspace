require "spec_helper"
require "stringio"

RSpec.describe Workspace::Doctor, "workflow sweep" do
  let(:schedule) { instance_double(Workspace::SweepSchedule) }
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:launch_mode) { Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }) }

  def rows(schedule, fix: false)
    doctor = described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
      project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      sweep_schedule: schedule, command_probe: ->(_name, _flag) {}, app_probe: ->(_id) { false }, which: ->(_exe) { true }, launch_mode: launch_mode)
    doctor.report(fix: fix)[:rows].select { |row| row[:id] == "workflow-sweep" }
  end

  it "is ok when the entry is installed and loaded" do
    allow(schedule).to receive(:status).and_return("installed" => true, "loaded" => true)

    expect(rows(schedule)).to contain_exactly(include(status: "ok", message: "workflow sweep: installed"))
  end

  it "stays ok but says so when launchctl could not say whether it is loaded" do
    allow(schedule).to receive(:status).and_return("installed" => true, "loaded" => nil)

    expect(rows(schedule).first).to include(status: "ok")
    expect(rows(schedule).first[:message]).to include("could not say")
  end

  it "warns with the install command when it is not installed" do
    allow(schedule).to receive(:status).and_return("installed" => false, "loaded" => false)

    expect(rows(schedule, fix: true)).to contain_exactly(include(status: "warn", fix_command: "workspace workflow sweep --install"))
    expect(rows(schedule).first).to include(message: a_string_including("only for workflows that set a timeout"), fix: a_string_starting_with("only if you use workflow timeouts"))
    expect(schedule).to have_received(:status).at_least(:once)
  end

  it "warns when installed but not loaded" do
    allow(schedule).to receive(:status).and_return("installed" => true, "loaded" => false)

    expect(rows(schedule).first[:message]).to include("installed but not loaded")
  end

  it "warns when the schedule cannot be read, and has no row when none is wired" do
    allow(schedule).to receive(:status).and_raise(Workspace::Error.new("bad\nplist", code: "sweep_launchctl_failed"))

    expect(rows(schedule).first).to include(status: "warn")
    expect(rows(schedule).first[:fix]).to include("workflow sweep --installed")
    expect(rows(schedule).first[:message]).not_to include("\n")
    expect(rows(nil)).to eq([])
  end
end
