require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowStepCheck do
  around do |example|
    Dir.mktmpdir("step-check") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:checkout) { File.join(@dir, "app").tap { |path| FileUtils.mkdir_p(path) } }
  let(:tmp_root) { File.join(@dir, "tmp").tap { |path| FileUtils.mkdir_p(path) } }
  let(:plan) { {"workflow" => "flow", "step" => "s", "command" => "true", "timeout" => 30, "base_sha" => "abc", "run" => "wr_preview", "in_checkout" => true} }
  let(:engine) { instance_double(Workspace::WorkflowEngine, check_plan: plan) }
  subject(:step_check) { described_class.new(engine: engine, checker: Workspace::WorkflowCheck.new, tmp_root: tmp_root) }

  def check(**options)
    step_check.call(definition: :definition, step: "s", worktree: checkout, **options)
  end

  it "runs the command in the checkout with the run's environment and the given artifacts directory" do
    fixture = File.join(@dir, "fixture").tap { |path| FileUtils.mkdir_p(path) }
    plan["command"] = 'echo "$WORKSPACE_RUN_ID|$WORKSPACE_RUN_ARTIFACTS|$WORKSPACE_RUN_BASE_SHA|$(pwd)"; test -d "$WORKSPACE_RUN_ARTIFACTS"'

    result = check(artifacts: fixture)

    expect(result).to include("passed" => true, "exit_code" => 0, "timed_out" => false, "artifacts" => fixture, "artifacts_created" => false)
    expect(File.read(result["log"]).chomp).to eq("wr_preview|#{fixture}|abc|#{checkout}")
  end

  it "makes an empty artifacts directory and the log under the temporary directory when none is given" do
    plan["command"] = 'test -z "$(ls "$WORKSPACE_RUN_ARTIFACTS")"'

    result = check

    expect(result).to include("passed" => true, "artifacts_created" => true)
    expect(result["artifacts"]).to start_with(tmp_root)
    expect(result["log"]).to start_with(tmp_root)
  end

  it "reports a failing command and a timeout as not passed" do
    plan["command"] = "echo bad; exit 3"
    expect(check).to include("passed" => false, "exit_code" => 3)

    plan["command"] = "sleep 5"
    plan["timeout"] = 0.2
    expect(check).to include("passed" => false, "exit_code" => nil, "timed_out" => true)
  end

  it "reports a checkout that is gone without raising" do
    result = step_check.call(definition: :definition, step: "s", worktree: File.join(@dir, "gone"))

    expect(result).to include("passed" => false, "exit_code" => nil)
    expect(result["error"]).to include("could not run the check")
  end

  it "refuses an artifacts path that is missing or a file, before anything is made" do
    File.write(File.join(@dir, "file"), "x")

    [File.join(@dir, "nope"), File.join(@dir, "file")].each do |path|
      expect { check(artifacts: path) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("artifacts_not_directory") }
    end
    expect(Dir.children(tmp_root)).to eq([])
  end

  it "takes a relative artifacts path from the current directory" do
    FileUtils.mkdir_p(File.join(@dir, "rel"))

    result = Dir.chdir(@dir) { check(artifacts: "rel") }

    expect(result["artifacts"]).to eq(File.join(@dir, "rel"))
  end

  it "makes the artifacts directory and puts the log in check.log beside it" do
    result = check

    expect(File.directory?(result["artifacts"])).to be true
    expect(File.basename(result["log"])).to eq("check.log")
    expect(File.dirname(result["log"])).to eq(File.dirname(result["artifacts"]))
    expect(File.basename(File.dirname(result["log"]))).to start_with("workspace-check-")
  end

  it "refuses an empty artifacts path" do
    expect { check(artifacts: "") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("artifacts_not_directory") }
  end

  it "does not read a timed-out check as passed even when the checker reports exit 0" do
    liar = Class.new { def call(**) = {exit_code: 0, timed_out: true} }.new
    result = described_class.new(engine: engine, checker: liar, tmp_root: tmp_root).call(definition: :definition, step: "s", worktree: checkout)

    expect(result["passed"]).to be false
  end

  describe "old temporary directories" do
    let(:now) { Time.now }
    subject(:step_check) { described_class.new(engine: engine, checker: Workspace::WorkflowCheck.new, tmp_root: tmp_root, wall_clock: -> { now }) }

    def made(name, age)
      File.join(tmp_root, name).tap do |path|
        FileUtils.mkdir_p(path)
        File.utime(now - age, now - age, path)
      end
    end

    it "keeps a directory holding the given artifacts, one of another name, and one owned by someone else" do
      holding = made("workspace-check-20200101-1-abc123", 2 * 86_400)
      FileUtils.mkdir_p(File.join(holding, "artifacts"))
      notes = made("workspace-check-notes-mine", 2 * 86_400)
      foreign = made("workspace-check-20200101-2-def456", 2 * 86_400)
      stat = instance_double(File::Stat, directory?: true, uid: Process.uid + 1, mtime: now - 2 * 86_400)
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(foreign).and_return(stat)

      check(artifacts: File.join(holding, "artifacts"))

      expect([holding, notes, foreign].map { |path| File.exist?(path) }).to eq([true, true, true])
    end

    it "sweeps under a temporary directory whose name holds glob characters" do
      odd = File.join(@dir, "t[mp]{x}").tap { |path| FileUtils.mkdir_p(path) }
      old = File.join(odd, "workspace-check-20200101-1-abc123").tap { |path| FileUtils.mkdir_p(path) }
      File.utime(now - 2 * 86_400, now - 2 * 86_400, old)

      described_class.new(engine: engine, checker: Workspace::WorkflowCheck.new, tmp_root: odd, wall_clock: -> { now }).call(definition: :definition, step: "s", worktree: checkout)

      expect(File.exist?(old)).to be false
    end

    it "removes workspace-check directories a day old, keeps newer ones and other names, and follows no link" do
      old = made("workspace-check-20200101-1-aaaaaa", 2 * 86_400)
      young = made("workspace-check-20200101-2-bbbbbb", 3600)
      other = made("other-old", 2 * 86_400)
      target = made("target", 0)
      File.write(File.join(target, "keep"), "x")
      link = File.join(tmp_root, "workspace-check-link")
      File.symlink(target, link)
      File.lutime(now - 2 * 86_400, now - 2 * 86_400, link)

      check

      expect(File.exist?(old)).to be false
      expect([young, other, File.join(target, "keep")].map { |path| File.exist?(path) }).to eq([true, true, true])
      expect(File.symlink?(link)).to be true
    end
  end

  it "passes the engine's refusals through" do
    allow(engine).to receive(:check_plan).and_raise(Workspace::Error.new("no", code: "step_without_status"))

    expect { check }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("step_without_status") }
  end
end
