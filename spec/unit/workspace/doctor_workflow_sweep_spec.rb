require "spec_helper"
require "stringio"

RSpec.describe Workspace::Doctor, "workflow sweep" do
  let(:schedule) { instance_double(Workspace::SweepSchedule) }
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:launch_mode) { Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }) }

  def rows(schedule, fix: false, last_path: nil, now: Time.utc(2026, 1, 1, 12, 0, 0))
    doctor = described_class.new(sweep_last_path: last_path, sweep_log_path: "/state/sweep.log", clock: -> { now }, config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
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

  describe "the last pass record" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "sweep-last.json") }
    let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }

    after { FileUtils.remove_entry(dir) }

    def write_record(at:, acted: 2, errors: [])
      pass = {"at" => at.iso8601, "scope" => "full", "acted" => acted, "errors" => errors}
      File.write(path, JSON.generate("last" => pass, "last_full" => pass))
    end

    before { allow(schedule).to receive(:status).and_return("installed" => true, "loaded" => true, "up_to_date" => true) }

    it "shows the last full pass with counts when fresh" do
      write_record(at: now - 120, acted: 3, errors: ["x"])

      expect(rows(schedule, last_path: path, now: now)).to contain_exactly(
        include(status: "ok", message: "workflow sweep: installed; last full pass 2 min ago (3 acted, 1 error)")
      )
    end

    it "warns when the last full pass is older than two intervals" do
      write_record(at: now - 11 * 60)

      expect(rows(schedule, last_path: path, now: now)).to contain_exactly(
        include(status: "ok"), include(status: "warn", message: a_string_including("11 min ago"), fix: a_string_including("wait one interval", "/state/sweep.log"))
      )
    end

    it "warns when no pass was recorded" do
      expect(rows(schedule, last_path: path, now: now)).to contain_exactly(
        include(status: "ok"), include(status: "warn", message: a_string_including("no full pass recorded yet"), fix: a_string_including("wait one interval", "/state/sweep.log"))
      )
    end

    it "warns, not errors, on a corrupt record" do
      File.write(path, "{nope")

      expect(rows(schedule, last_path: path, now: now)).to contain_exactly(
        include(status: "ok"),
        include(status: "warn", message: "sweep-last.json is not a valid sweep record", fix: "delete #{path}; the next sweep rewrites it")
      )
    end

    [["a non-Hash top level", "[]"], ["a non-Hash last_full", '{"last_full":5}'], ["a bad at", '{"last_full":{"at":"yesterday"}}'],
      ["a Hash acted", '{"last_full":{"at":"2026-11-15T00:00:00Z","acted":{}}}']].each do |name, body|
      it "treats #{name} as an invalid record" do
        File.write(path, body)

        expect(rows(schedule, last_path: path, now: now)).to include(include(status: "warn", message: "sweep-last.json is not a valid sweep record"))
      end
    end

    it "shows an age past 90 minutes in hours" do
      write_record(at: now - 5 * 3600)

      expect(rows(schedule, last_path: path, now: now).first[:message]).to include("last full pass 5 h ago")
    end

    it "warns with the install command when the plist is out of date" do
      allow(schedule).to receive(:status).and_return("installed" => true, "loaded" => true, "up_to_date" => false)
      write_record(at: now - 60)

      expect(rows(schedule, last_path: path, now: now)).to include(include(status: "warn", fix_command: "workspace workflow sweep --install", fix: a_string_including("after upgrading workspace or moving Ruby")))
    end

    it "gives only the not-installed warning, without checking staleness" do
      allow(schedule).to receive(:status).and_return("installed" => false, "loaded" => false)

      expect(rows(schedule, last_path: path, now: now)).to contain_exactly(include(status: "warn", message: a_string_including("not installed")))
    end
  end
end
