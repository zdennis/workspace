require "stringio"

# Adversarial specs for `workspace doctor --fix` CLI/UX and edge cases (H4).
# One failing `it` per confirmed defect, IDs HU1, HU2, ...
RSpec.describe "workspace doctor --fix adversarial CLI checks" do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_installer) { double("hook_installer") }

  def build_doctor(project_detector:, hook_installer:, output:)
    allow(hook_installer).to receive(:statusline_installed?).and_return(true)
    Workspace::Doctor.new(
      config: config,
      state: state,
      hook_installer: hook_installer,
      project_detector: project_detector,
      output: output,
      project_settings: CLITestHelpers::FakeProjectSettings.new,
      launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new,
        platform: "arm64-darwin", env: {}, which: ->(_exe) { true }),
      which: ->(_exe) { false }
    )
  end

  # HU1: `doctor --fix` outside a workspace project (project_detector.detect
  # returns nil) silently does nothing -- apply_fixes just returns, and run
  # continues normally with exit 0 if no other issues. The operator gets no
  # indication that --fix did (or didn't do) anything.
  it "HU1: says why --fix did nothing when not inside a workspace project" do
    project_detector = double("project_detector", detect: nil)
    doctor = build_doctor(project_detector: project_detector, hook_installer: hook_installer, output: output)

    begin
      doctor.run(fix: true)
    rescue Workspace::Error
      # unrelated missing-dependency issues in the test environment are fine
    end

    expect(output.string).to match(/--fix.*(not inside a workspace project|nothing to fix|no project detected)/i)
  end

  # HU2: `doctor --fix` when no hook-capable agent is on PATH (e.g. `claude`
  # missing) silently does nothing -- same problem as HU1, but the operator
  # is inside a project this time, so the silence is even more confusing.
  it "HU2: says why --fix did nothing when no hook-capable agent is on PATH" do
    project_detector = double("project_detector", detect: "my-project")
    doctor = build_doctor(project_detector: project_detector, hook_installer: hook_installer, output: output)

    begin
      doctor.run(fix: true)
    rescue Workspace::Error
      # unrelated missing-dependency issues in the test environment are fine
    end

    expect(output.string).to match(/--fix.*(no hook-capable agent|nothing to fix)/i)
  end
end
