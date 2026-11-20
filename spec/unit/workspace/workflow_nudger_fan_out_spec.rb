require "spec_helper"

# The daemon's tick wakes a run for a fan_out sibling off the cursor, read on the sibling's own step and slots.
RSpec.describe Workspace::WorkflowNudger, "with a fan_out group" do
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:spawned) { [] }
  let(:now) { Time.utc(2026, 10, 4, 12, 30, 0) }
  subject(:nudger) do
    described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(workspace) { "/log/#{workspace}.log" },
      spawner: ->(argv, log) { spawned << [argv, log] and nil }, clock: -> { now }, error_output: StringIO.new)
  end

  def grouped(test)
    {"id" => "wr_1", "workspace" => "app", "state" => "running", "current" => "lint",
     "definition" => {"steps" => [{"id" => "lint", "group" => "checks"}, {"id" => "test", "group" => "checks"}]},
     "steps" => {"lint" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00Z"}]}, "test" => test}}
  end

  def advances = spawned.map(&:first).select { |argv| argv[3] == "advance" }

  it "wakes the run for a sibling's continue line that is due, though the cursor's step has nothing" do
    mark = {"step" => "test", "attempt" => 1, "pane" => "%7", "pid" => 9, "kind" => "claude", "since" => "2026-10-04T12:20:00Z"}
    test = {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00Z"}], "continue_pending" => mark}
    allow(store).to receive(:going).and_return([Workspace::WorkflowRun.from_h(grouped(test))])

    expect(nudger.tick("app")).to eq(["wr_1"])
    expect(advances).to eq([[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1"]])
  end

  it "leaves the run alone when no sibling wakes" do
    test = {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00Z"}]}
    allow(store).to receive(:going).and_return([Workspace::WorkflowRun.from_h(grouped(test))])

    expect(nudger.tick("app")).to eq([])
    expect(advances).to eq([])
  end
end
