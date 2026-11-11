require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowReviewRevision do
  # Writes +output+ to the log it is given and +errors+ to its err_log, and answers +result+, recording the command,
  # cwd, timeout, logs and env.
  checker_stub = Class.new do
    attr_accessor :output, :errors, :result
    attr_reader :calls

    def initialize
      @output = "plan-rev-1\n"
      @errors = ""
      @result = {exit_code: 0, timed_out: false}
      @calls = []
    end

    def call(cwd:, timeout:, log:, command: nil, argv: nil, stop_when: nil, env: {}, err_log: nil)
      @calls << {command: command, cwd: cwd, timeout: timeout, log: log, err_log: err_log, env: env, stopped: stop_when&.call}
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, output)
      File.write(err_log, errors) if err_log
      result
    end
  end
  before { stub_const("CheckerStub", checker_stub) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:worktree) { File.join(@dir, "app") }
  let(:artifacts) { File.join(worktree, ".workflow", "wr_1") }
  let(:guard) { RecordingGuard.new }
  let(:checker) { CheckerStub.new }
  let(:revision_command) { nil }
  let(:step) { {"id" => "plan", "produces" => ["plan.md"], "review" => {"from" => ["skeptic"], "revision" => revision_command}} }
  subject(:reader) { described_class.new(guard: guard, checker: checker) }

  before do
    FileUtils.mkdir_p(artifacts)
    File.write(File.join(artifacts, "plan.md"), "The plan.\n")
  end

  def run_hash
    {"id" => "wr_1", "workspace" => "app", "worktree" => worktree, "artifacts_dir" => artifacts, "base_sha" => "b" * 40, "current" => "plan",
     "steps" => {"plan" => {"state" => "reviewing", "attempts" => [{"n" => 2}], "review" => {"round" => 1}}}}
  end

  def revision = reader.call(run: run_hash, step: step)

  it "answers the same revision for the same files, HEAD and tree" do
    first = revision

    expect(first[:problem]).to be_nil
    expect(first[:revision]).to match(/\A\h{64}\z/)
    expect(revision).to eq(first)
    expect(guard.calls).to include([:head, worktree], [:tree_digest, worktree])
  end

  it "answers another revision once a produces file is edited" do
    before = revision[:revision]
    File.write(File.join(artifacts, "plan.md"), "The plan, answered.\n")

    expect(revision[:revision]).not_to eq(before)
  end

  it "answers another revision once HEAD or the tracked tree moves" do
    before = revision[:revision]
    guard.heads << "c" * 40
    moved_head = revision[:revision]
    guard.trees << "u" * 64

    expect(moved_head).not_to eq(before)
    expect(revision[:revision]).not_to eq(moved_head)
  end

  it "reads a produces file that turned into a link as missing, never through the link" do
    before = revision[:revision]
    File.write(File.join(@dir, "elsewhere.md"), "The plan.\n")
    File.delete(File.join(artifacts, "plan.md"))
    File.symlink(File.join(@dir, "elsewhere.md"), File.join(artifacts, "plan.md"))

    expect(revision).to include(problem: nil)
    expect(revision[:revision]).not_to eq(before)
  end

  it "is a problem when the tracked tree can't be read" do
    guard.trees << nil

    expect(revision).to eq(revision: nil, problem: "the checkout's tracked files could not be read")
  end

  context "with a review revision command" do
    let(:revision_command) { "workspace plan status --json" }

    it "runs it in the checkout with the run's environment and time limit, its log beside the step's check logs" do
      revision

      call = checker.calls.last
      expect(call).to include(command: "workspace plan status --json", cwd: worktree, timeout: described_class::TIMEOUT,
        log: File.join(artifacts, "steps", "plan.2.r1.revision.log"), err_log: File.join(artifacts, "steps", "plan.2.r1.revision.err"))
      expect(call[:env]).to include("WORKSPACE_RUN_ID" => "wr_1", "WORKSPACE_RUN_ARTIFACTS" => artifacts, "WORKSPACE_RUN_BASE_SHA" => "b" * 40)
    end

    it "adds its output to the hash, so a change in the output alone is another revision" do
      before = revision[:revision]
      checker.output = "plan-rev-2\n"

      expect(revision[:revision]).not_to eq(before)
    end

    it "hashes stdout only, so a change on stderr alone is the same revision" do
      checker.errors = "Warning: the agent daemon is not running\n"
      before = revision[:revision]
      checker.errors = "Warning: something else entirely\n"

      expect(revision[:revision]).to eq(before)
    end

    it "is a problem when the command's output is larger than it hashes" do
      stub_const("#{described_class}::MAX_BYTES", File.size(File.join(artifacts, "plan.md")))
      checker.output = "x" * 100

      expect(revision[:problem]).to start_with("the review revision command's output is larger than #{described_class::MAX_BYTES} bytes")
    end

    it "keeps the files in the hash, so an edit with the same output is another revision too" do
      before = revision[:revision]
      File.write(File.join(artifacts, "plan.md"), "Objections answered.\n")

      expect(revision[:revision]).not_to eq(before)
    end

    it "is a problem, never a revision, when the command fails" do
      checker.result = {exit_code: 3, timed_out: false}

      expect(revision).to eq(revision: nil, problem: "the review revision command exited 3 (stderr #{File.join(artifacts, "steps", "plan.2.r1.revision.err")})")
    end

    it "is a problem when the command runs past its time limit" do
      checker.result = {exit_code: nil, timed_out: true}

      expect(revision[:revision]).to be_nil
      expect(revision[:problem]).to start_with("the review revision command ran past #{described_class::TIMEOUT} seconds")
    end

    it "is a problem when the command was stopped or could not run" do
      checker.result = {exit_code: nil, timed_out: false, error: "stopped: the run moved on"}

      expect(revision[:problem]).to start_with("the review revision command did not finish: stopped: the run moved on")
    end

    it "passes stop_when on to the command" do
      reader.call(run: run_hash, step: step, stop_when: -> { :asked })

      expect(checker.calls.last[:stopped]).to eq(:asked)
    end
  end

  it "is a problem when a produces file is larger than it hashes" do
    stub_const("#{described_class}::MAX_BYTES", 4)

    expect(revision).to eq(revision: nil, problem: "plan.md is larger than 4 bytes")
  end

  it "keeps a recompute's worst case inside the window after which it counts as lost" do
    guard_reads = Workspace::WorkflowGuard::HEAD_TIMEOUT + Workspace::WorkflowGuard::GIT_TIMEOUT * 3 # HEAD, git --version, filter.* entries, the diff
    command = described_class::TIMEOUT + Workspace::WorkflowCheck::KILL_GRACE + Workspace::WorkflowCheck::STOP_POLL

    expect(guard_reads + command).to be < Workspace::WorkflowTransitions::DELIVERY_WINDOW
    expect(described_class::TIMEOUT).to be >= 60
  end
end
