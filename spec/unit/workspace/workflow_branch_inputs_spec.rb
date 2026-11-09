require "spec_helper"

RSpec.describe Workspace::WorkflowBranchInputs do
  let(:git) { instance_double(Workspace::Git, worktree_branch: "x") }
  let(:project) { double("project", root: "/r") }
  let(:start_ref) { instance_double(Workspace::StartRef, project: project) }
  let(:protected_branch) { instance_double(Workspace::ProtectedBranch, call: nil) }
  let(:summary) { {"available" => true, "found" => false} }
  let(:pull_request_status) { instance_double(Workspace::PullRequestStatus, summary: summary) }
  let(:declared) { {"task" => {}, "pr" => {}} }
  let(:definition) { double("definition", to_h: {"inputs" => declared}) }
  let(:inputs) { {} }
  let(:subject_under_test) { described_class.new(git: git, start_ref: start_ref, protected_branch: protected_branch, pull_request_status: pull_request_status) }

  def run
    subject_under_test.call(definition, "/w", inputs)
  end

  def pr(state)
    {"available" => true, "found" => true, "number" => 12, "url" => "https://github.com/o/r/pull/12", "title" => "Title", "state" => state}
  end

  it "fills task and pr from an open pull request" do
    allow(pull_request_status).to receive(:summary).and_return(pr("OPEN"))
    expect(run).to eq([
      {"task" => "#12: Title (https://github.com/o/r/pull/12)", "pr" => "12"},
      {"task" => "pull_request", "pr" => "pull_request"}
    ])
  end

  %w[CLOSED MERGED].each do |state|
    it "fills the branch task for a #{state} pull request" do
      allow(pull_request_status).to receive(:summary).and_return(pr(state))
      expect(run).to eq([{"task" => "Branch x"}, {"task" => "branch"}])
    end
  end

  it "fills the branch task when gh gives an open pull request no number" do
    allow(pull_request_status).to receive(:summary).and_return(pr("OPEN").merge("number" => nil))
    expect(run).to eq([{"task" => "Branch x"}, {"task" => "branch"}])
  end

  it "fills the branch task with no pull request" do
    expect(run).to eq([{"task" => "Branch x"}, {"task" => "branch"}])
  end

  [{"available" => false, "reason" => "gh_missing"}, {"available" => false, "reason" => "timeout"}, {"available" => false, "reason" => "error"}].each do |answer|
    it "fills the branch task when gh says #{answer["reason"]}" do
      allow(pull_request_status).to receive(:summary).and_return(answer)
      expect(run).to eq([{"task" => "Branch x"}, {"task" => "branch"}])
    end
  end

  it "fills only pr when task is given and a pull request is open" do
    allow(pull_request_status).to receive(:summary).and_return(pr("OPEN"))
    given = {"task" => "mine"}
    expect(subject_under_test.call(definition, "/w", given)).to eq([{"task" => "mine", "pr" => "12"}, {"pr" => "pull_request"}])
  end

  it "fills nothing when task is given and there is no pull request" do
    given = {"task" => "mine"}
    expect(subject_under_test.call(definition, "/w", given)).to eq([given, {}])
  end

  it "counts an empty task as given" do
    given = {"task" => ""}
    expect(subject_under_test.call(definition, "/w", given)).to eq([given, {}])
  end

  it "makes no git or gh call when nothing is fillable" do
    given = {"task" => "a", "pr" => "1"}
    expect(subject_under_test.call(definition, "/w", given)).to eq([given, {}])
    expect(git).not_to have_received(:worktree_branch)
    expect(pull_request_status).not_to have_received(:summary)
  end

  it "never adds an undeclared input" do
    declared.delete("pr")
    allow(pull_request_status).to receive(:summary).and_return(pr("OPEN"))
    expect(run.first.keys).to eq(["task"])
  end

  it "fills nothing for a protected branch" do
    allow(protected_branch).to receive(:call).and_return({reason: "default_branch", path: "/src/app"})
    expect(run).to eq([inputs, {}])
    expect(pull_request_status).not_to have_received(:summary)
  end

  it "fills nothing without a branch" do
    allow(git).to receive(:worktree_branch).and_return(nil)
    expect(run).to eq([inputs, {}])
    expect(pull_request_status).not_to have_received(:summary)
  end

  def expect_inputs_untouched
    expect(run).to eq([inputs, {}])
  end

  it "returns the inputs untouched when git raises" do
    allow(git).to receive(:worktree_branch).and_raise(Workspace::Error, "x")
    expect_inputs_untouched
  end

  it "returns the inputs untouched when start_ref raises" do
    allow(start_ref).to receive(:project).and_raise(Workspace::Error, "x")
    expect_inputs_untouched
  end

  it "returns the inputs untouched when protected_branch raises" do
    allow(protected_branch).to receive(:call).and_raise(Errno::ENOENT)
    expect_inputs_untouched
  end

  it "returns the inputs untouched when gh raises" do
    allow(pull_request_status).to receive(:summary).and_raise(Errno::ENOENT)
    expect_inputs_untouched
  end

  it "reads the given worktree path" do
    run
    expect(git).to have_received(:worktree_branch).with("/w")
    expect(start_ref).to have_received(:project).with("/w")
    expect(protected_branch).to have_received(:call).with("x", project)
    expect(pull_request_status).to have_received(:summary).with("/w")
  end

  it "does not change the given hash" do
    given = {"other" => "1"}.freeze
    result, = subject_under_test.call(definition, "/w", given)
    expect(given).to eq({"other" => "1"})
    expect(result).to eq({"other" => "1", "task" => "Branch x"})
  end
end
