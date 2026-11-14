require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowReviewOrphans do
  around do |example|
    Dir.mktmpdir("wf-orphans") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { Workspace::WorkflowRunStore.new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive")) }
  let(:tmux) { FakeTmux.new(sessions: ["app"], session_name: "app") }
  let(:panes) { RecordingWorkflowPanes.new }
  subject(:orphans) { described_class.new(tmux: tmux, store: store, panes: panes) }

  def write_run(id, state: "running", step_state: "reviewing", round: {"round" => 1, "delivery" => nil, "pane" => "%9", "window" => "@9"}, dir: "runs", kept: nil, current: "plan")
    run = {"id" => id, "workspace" => "app", "state" => state, "current" => current, "reason" => nil, "definition" => {"steps" => [{"id" => "plan"}, {"id" => "build"}]},
           "steps" => {"plan" => {"state" => step_state, "review" => round, "review_window" => kept, "attempts" => [{"n" => 1}]}.compact,
                       "build" => {"state" => "pending", "attempts" => []}}}
    FileUtils.mkdir_p(File.join(@dir, dir))
    File.write(File.join(@dir, dir, "#{id}.json"), JSON.generate(run))
  end

  def window(id, mark, pane, store: nil)
    {window: id, name: "review-plan", review: mark, pane: pane, pid: 1, store: store}
  end

  def found = orphans.find.map { |each| [each[:window], each[:why]] }

  it "leaves the window the run's round records, by pane or by window id" do
    write_run("wr_1")
    tmux.review_window_list = [window("@9", "wr_1:plan:1", "%77"), window("@8", "wr_1:plan:1", "%9")]

    expect(found).to eq([])
  end

  it "finds a window whose run is over, whose run no one knows, and one its going run's round does not record" do
    write_run("wr_1", state: "completed", dir: "archive")
    write_run("wr_2", round: {"round" => 2, "delivery" => nil, "pane" => "%20", "window" => "@20"})
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1"), window("@2", "wr_404:plan:1", "%2"), window("@3", "wr_2:plan:1", "%3")]

    expect(found).to eq([["@1", "run_over"], ["@2", "run_unknown"], ["@3", "not_recorded"]])
    expect(orphans.find.first).to include(session: "app", pane: "%1", run_id: "wr_1", step: "plan", round: 1, workspace: "app")
  end

  it "takes a window of a run that moved past the reviewed step for an orphan" do
    write_run("wr_1", step_state: "passed", round: nil)
    tmux.review_window_list = [window("@9", "wr_1:plan:1", "%9")]

    expect(found).to eq([["@9", "not_recorded"]])
  end

  it "leaves the window a rejected round kept for the step's next one while the author works again, and not once the run moved on" do
    write_run("wr_1", step_state: "running", round: nil, kept: {"round" => 1, "window" => "@9", "pane" => "%9"})
    tmux.review_window_list = [window("@9", "wr_1:plan:1", "%9"), window("@8", "wr_1:plan:1", "%8")]

    expect(found).to eq([["@8", "not_recorded"]])

    write_run("wr_1", step_state: "passed", round: nil, kept: {"round" => 1, "window" => "@9"}, current: "build")

    expect(found).to eq([["@9", "not_recorded"], ["@8", "not_recorded"]])
  end

  it "leaves every window of a round still being delivered, which closes the run's other windows itself" do
    write_run("wr_1", round: {"round" => 2, "delivery" => "delivering", "pane" => "%9"})
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1"), window("@2", "wr_1:plan:2", "%2")]

    expect(found).to eq([])
  end

  it "leaves a window whose run file can't be read, and one whose mark is not a review round's" do
    FileUtils.mkdir_p(File.join(@dir, "runs"))
    File.write(File.join(@dir, "runs", "wr_1.json"), "{not json")
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1"), window("@2", "hand-made", "%2")]

    expect(found).to eq([])
  end

  it "looks only at the session of the workspace given, and none for one on its own tmux socket" do
    write_run("wr_1", state: "cancelled", dir: "archive")
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1")]

    expect(orphans.find(workspace: "app").map { |each| each[:session] }).to eq(["app"])
    socketed = described_class.new(tmux: FakeTmux.new(session_name: "app", sockets: {"app" => "-L"}), store: store, panes: panes)
    expect(socketed.find(workspace: "app")).to eq([])
  end

  it "leaves a window whose run's workspace runs on its own tmux socket, since a session of that name here is another's" do
    write_run("wr_1", state: "completed", dir: "archive")
    socketed = FakeTmux.new(sessions: ["app"], session_name: "app", sockets: {"app" => "-L"})
    socketed.review_window_list = [window("@1", "wr_1:plan:1", "%1")]

    expect(described_class.new(tmux: socketed, store: store, panes: panes).find).to eq([])
  end

  it "leaves out a window another run store stamped, whatever this store holds under its id" do
    write_run("wr_1", state: "completed", dir: "archive")
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1", store: "0ther0ther0ther0"), window("@2", "wr_404:plan:1", "%2", store: "0ther0ther0ther0")]

    expect(orphans.find).to eq([])
  end

  it "judges a window this store stamped, and one with no stamp, by this store's run" do
    write_run("wr_1", state: "completed", dir: "archive")
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1", store: store.stamp), window("@2", "wr_1:plan:1", "%2")]

    expect(found).to eq([["@1", "run_over"], ["@2", "run_over"]])
    expect(orphans.find.map { |each| each[:closable] }).to eq([true, true])
  end

  it "reports a window whose run this store does not have, stamped or not, and never closes it" do
    tmux.review_window_list = [window("@2", "wr_404:plan:1", "%2"), window("@3", "wr_405:plan:1", "%3", store: store.stamp)]

    listed = orphans.find

    expect(listed.map { |each| [each[:why], each[:closable]] }).to eq([["run_unknown", false], ["run_unknown", false]])
    expect(listed.map { |each| orphans.close(each) }).to eq([false, false])
    expect(tmux.killed_windows).to be_empty
    expect(panes.calls).to be_empty
  end

  it "closes an orphan's window and removes its pane's reviewer binding" do
    write_run("wr_1", state: "completed", dir: "archive")
    tmux.review_window_list = [window("@1", "wr_1:plan:1", "%1")]

    expect(orphans.close(orphans.find.first)).to be(true)
    expect(tmux.killed_windows).to eq(["@1"])
    expect(panes.calls).to eq([[:unbind, "wr_1", {role: "reviewer", pane: "%1"}]])
  end
end
