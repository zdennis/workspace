require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Doctor, "review windows" do
  let(:orphans) { instance_double(Workspace::WorkflowReviewOrphans, find: found) }
  let(:found) { [] }
  let(:tmux) { FakeTmux.new }
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:launch_mode) { Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }) }
  let(:doctor) do
    described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
      project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      review_orphans: orphans, tmux: tmux, which: ->(_exe) { true }, launch_mode: launch_mode)
  end

  def rows(fix: false, prefix: "workflow-review-window") = doctor.report(fix: fix)[:rows].select { |row| row[:id].start_with?(prefix) }

  def orphan(window = "@4", why: "run_over", run_id: "wr_1")
    {session: "app", window: window, pane: "%4", review: "#{run_id}:plan:2", run_id: run_id, step: "plan", round: 2, workspace: "app", run: nil, why: why, closable: why != "run_unknown"}
  end

  it "adds no row when no review window is left over" do
    expect(rows).to be_empty
  end

  it "warns about each left-over review window, saying why and that the sweep closes it, and --fix closes nothing" do
    found << orphan << orphan("@5", why: "not_recorded")

    listed = rows(fix: true)

    expect(listed.map { |row| row[:status] }).to eq(%w[warn warn])
    expect(listed.first[:message]).to eq("review window @4 in session app (run wr_1, step plan, round 2) is left over: its run is over")
    expect(listed.last[:message]).to end_with("its run's review round does not use it")
    expect(listed.first).to include(fix_command: "workspace workflow sweep")
    expect(tmux.killed_windows).to be_empty
  end

  it "gives a window whose run this state directory does not have a by-hand fix, not the sweep" do
    found << orphan("@6", why: "run_unknown")

    expect(rows.first).to include(fix_command: nil)
    expect(rows.first[:fix]).to include("tmux kill-window -t @6", "workflow sweep leaves it")
    expect(rows.first[:message]).to end_with("no workflow run in this state directory has its id")
  end

  it "reports a window whose run this state directory does not have as the sweep's unconfirmed row, and --fix leaves it open" do
    Dir.mktmpdir("doctor-review") do |dir|
      store = Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive"))
      tmux = FakeTmux.new(sessions: ["app"], session_name: "app")
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_404:plan:1", pane: "%7", pid: 7}]
      real = Workspace::WorkflowReviewOrphans.new(tmux: tmux, store: store, panes: FakeWorkflowPanes.new)
      doctor = described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
        project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
        review_orphans: real, tmux: tmux, which: ->(_exe) { true }, launch_mode: launch_mode)

      listed = doctor.report(fix: true)[:rows].select { |row| row[:id] == "workflow-review-window-orphaned" }

      expect(listed).to contain_exactly(include(status: "warn", fix_command: nil))
      expect(listed.first[:message]).to eq("review window @7 in session app (run wr_404, step plan, round 1) is left over: no workflow run in this state directory has its id")
      expect(listed.first[:fix]).to include("tmux kill-window -t @7", "workflow sweep leaves it")
      expect(tmux.killed_windows).to be_empty
    end
  end

  it "escapes what a window's mark and session carry" do
    found << orphan.merge(session: "a\e[31mb", run_id: "wr\nx")

    expect(rows.first[:message]).to include("session a\\e[31mb", "run wr\\nx")
  end

  it "lists at most the row limit, then one row for the rest" do
    25.times { |n| found << orphan("@#{n}") }

    expect(rows.size).to eq(21)
    expect(rows.last[:message]).to eq("5 more left-over review windows not shown")
  end

  describe "tmux renumber-windows" do
    def renumber_rows = rows(prefix: "tmux-renumber-windows")

    it "warns when it is on, with the command that turns it off" do
      tmux.renumber_windows = true

      expect(renumber_rows).to contain_exactly(include(status: "warn", fix_command: "tmux set-option -g renumber-windows off"))
      expect(renumber_rows.first[:message]).to include("renumber-windows is on", "reads as moved")
    end

    it "warns about a session that turns it on for itself, naming the session" do
      tmux = FakeTmux.new(sessions: %w[app other])
      tmux.renumber_windows = {nil => false, "other" => true}
      doctor = described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
        project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
        tmux: tmux, which: ->(_exe) { true }, launch_mode: launch_mode)

      listed = doctor.report[:rows].select { |row| row[:id] == "tmux-renumber-windows" }

      expect(listed.size).to eq(1)
      expect(listed.first[:message]).to start_with("tmux renumber-windows is on in session other:")
    end

    it "says nothing when it is off or tmux can't say" do
      tmux.renumber_windows = false
      expect(renumber_rows).to be_empty
      tmux.renumber_windows = nil
      expect(renumber_rows).to be_empty
    end
  end
end
