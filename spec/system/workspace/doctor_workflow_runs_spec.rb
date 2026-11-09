require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Doctor, "workflow runs" do
  let(:health) { double("run_health") }
  let(:found) { {orphans: [], unreadable: [], leaked: [], warnings: []} }
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:launch_mode) { Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }) }
  let(:doctor) do
    described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
      project_detector: double("project_detector", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new,
      run_health: health, which: ->(_exe) { true }, launch_mode: launch_mode)
  end

  before { allow(health).to receive(:call).and_return(found) }

  def rows(fix: false) = doctor.report(fix: fix)[:rows].select { |row| row[:id].start_with?("workflow-run") }

  def orphan(id = "wr_1", **over)
    fields = {"id" => id, "workflow" => "rpiv", "workspace" => "app", "state" => "running", "worktree" => "/x", "why" => "its checkout /x is missing or unmounted"}.merge(over)
    Workspace::WorkflowRunHealth::Orphan.new(**fields.transform_keys(&:to_sym))
  end

  def leak(name = "edit", **over)
    {"namespace" => "app-abc", "dir" => "/locks/app-abc", "lock" => name, "run_id" => "wr_3", "role" => "holder", "worktree" => "/w"}.merge(over)
  end

  it "says all is well when nothing is found" do
    expect(rows).to contain_exactly(include(id: "workflow-runs", status: "ok"))
  end

  it "warns about an orphaned run, names the command, and says to check the path first" do
    found[:orphans] << orphan

    expect(rows).to contain_exactly(include(id: "workflow-run-orphaned", status: "warn", fix_command: nil, project: "app"))
    expect(rows.first[:message]).to include("missing or unmounted")
    expect(rows.first[:fix]).to include("check that the path is really gone", "workspace workflow cancel wr_1", "cannot be undone")
  end

  it "warns about an unreadable run file and a leaked lock, neither counted as an issue" do
    found[:unreadable] << "/runs/wr_2.json"
    found[:leaked] << leak
    result = doctor.report

    expect(rows.map { |row| row[:id] }).to contain_exactly("workflow-run-unreadable", "workflow-run-lock-leaked")
    expect(rows.last).to include(status: "ok", fix: nil, fix_command: nil)
    expect(rows.last[:message]).to include("blocks nothing", "next lock operation", "daemon's sweep")
    expect(rows.last[:message]).not_to include("lock clear")
    expect(rows.first[:message]).to include("stay held")
    expect(rows.first[:fix]).to include("needs a person to read it")
    expect(rows.first[:fix].to_s + rows.first[:message]).not_to match(/delet|ls -l|lock clear/)
    expect(rows.first[:fix]).not_to include("lock clear")
    expect(result[:rows].select { |row| row[:status] == "fail" }.map { |row| row[:id] }).not_to include("workflow-run-unreadable", "workflow-run-lock-leaked")
  end

  it "says a dev process under a dead run's lock gets the lock, and that a record without one blocks nothing" do
    found[:leaked] << leak("devenv", "delegate_pid" => 4242) << leak("edit", "role" => "waiter", "delegate_pid" => nil)
    messages = rows.map { |row| row[:message] }

    expect(messages.first).to include("pid 4242", "hands the lock to it", "until that process exits")
    expect(messages.first).not_to include("blocks nothing")
    expect(messages.last).to include("blocks nothing")
  end

  it "shows one capped list over all kinds and one row for the rest" do
    10.times { |i| found[:orphans] << orphan("wr_#{i}") }
    10.times { |i| found[:unreadable] << "/runs/u#{i}.json" }
    10.times { |i| found[:leaked] << leak("lock#{i}") }

    all = doctor.report[:rows]
    expect(all.count { |row| row[:id].start_with?("workflow-run-") }).to eq(20)
    expect(all.select { |row| row[:id] == "workflow-runs" }.map { |row| row[:message] }).to eq(["10 more orphaned runs, unreadable run files or leaked run locks not shown"])
  end

  it "escapes every value read from a run or lock file" do
    found[:orphans] << orphan("wr_1\e[31m", "workflow" => "a\nb", "state" => "x\e]0;t\a", "why" => "its checkout /p\rq is missing or unmounted", "workspace" => "w\e")
    found[:unreadable] << "/runs/\e[2Jx.json"
    found[:leaked] << leak("edit\nrm", "run_id" => "r\e[0m", "namespace" => "n\e", "dir" => "/d\e")
    text = doctor.report[:rows].select { |row| row[:id].start_with?("workflow-run") }.flat_map { |row| [row[:message], row[:fix], row[:project]] }.compact.join("\n")

    expect(text).not_to match(/[\e\a\r]/)
    expect(text.lines.size).to be < 10
  end

  it "leaves a hostile run id out of the cancel command" do
    found[:orphans] << orphan("wr_1; rm -rf ~")

    expect(rows.first[:fix]).not_to include("workflow cancel")
  end

  it "reports the same rows with --fix, and offers no command to run" do
    found[:orphans] << orphan
    found[:leaked] << leak
    without = rows.map { |row| row[:id] }

    expect(rows(fix: true).map { |row| row[:id] }).to eq(without)
    expect(rows(fix: true).map { |row| row[:fix_command] }).to all(be_nil)
  end

  it "skips the check without a run_health collaborator" do
    bare = described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer,
      project_detector: double("p", detect: nil), output: StringIO.new, project_settings: CLITestHelpers::FakeProjectSettings.new, which: ->(_exe) { true }, launch_mode: launch_mode)

    expect(bare.report[:rows].map { |row| row[:id] }).not_to include("workflow-runs")
  end

  describe "through build_cli, with a throwaway state directory" do
    around do |example|
      Dir.mktmpdir("wsd", "/tmp") do |home|
        saved = ENV.to_h
        ENV["HOME"] = home
        ENV["XDG_STATE_HOME"] = File.join(home, "state")
        ENV["XDG_CONFIG_HOME"] = File.join(home, "config")
        @home = home
        example.run
      ensure
        ENV.replace(saved)
      end
    end

    it "reports a run whose checkout is gone and a leaked lock, and writes nothing under the state directory" do
      config = Workspace::Config.new
      FileUtils.mkdir_p([config.workflow_runs_dir, File.join(config.lock_dir, "app-abc")])
      run = {"id" => "wr_9", "workflow" => "rpiv", "workspace" => "app", "state" => "running", "worktree" => File.join(@home, "gone"), "current" => "a",
             "definition" => {"steps" => [{"id" => "a"}]}, "steps" => {"a" => {"state" => "pending", "attempts" => []}}}
      File.write(File.join(config.workflow_runs_dir, "wr_9.json"), JSON.generate(run))
      File.write(File.join(config.lock_dir, "app-abc", "locks.json"), JSON.generate("edit" => {"holder" => {"kind" => "run", "run_id" => "wr_gone"}, "queue" => []}))
      snapshot = -> { Dir.glob(File.join(config.state_dir, "**", "*"), File::FNM_DOTMATCH).sort.to_h { |path| [path, [File.mtime(path), File.file?(path) ? File.binread(path) : nil]] } }
      before = snapshot.call
      out = StringIO.new
      cli = Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {})

      begin
        cli.run(%w[doctor --fix --json])
      rescue SystemExit
        nil
      end

      checks = JSON.parse(out.string)["checks"].select { |check| check["id"].start_with?("workflow-run") }
      expect(checks.map { |check| check["id"] }).to contain_exactly("workflow-run-orphaned", "workflow-run-lock-leaked")
      runs = snapshot.call.select { |path, _| path.start_with?(config.workflow_runs_dir) || path.start_with?(config.lock_dir) }
      expect(runs).to eq(before.select { |path, _| path.start_with?(config.workflow_runs_dir) || path.start_with?(config.lock_dir) })
    end
  end
end
