require "spec_helper"

RSpec.describe Workspace::WorkflowSweep, "heartbeat" do
  let(:run) { instance_double(Workspace::WorkflowRun, workspace: "app") }
  let(:store) { instance_double(Workspace::WorkflowRunStore, going: [run], unreadable: []) }
  let(:reviews) { instance_double(Workspace::WorkflowReviewSweep, orphan_rows: []) }
  let(:downtime) { double("downtime", beat: nil) }
  subject(:sweep) do
    described_class.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, downtime: downtime)
  end

  before { allow(sweep).to receive(:sweep_run).and_return({"outcome" => "nothing"}) }

  it "beats once per pass, a dry run too" do
    sweep.call
    sweep.call(dry_run: true)

    expect(downtime).to have_received(:beat).twice
  end

  it "still sweeps the runs when the beat raises" do
    allow(downtime).to receive(:beat).and_raise("boom")

    expect(sweep.call).to eq([{"outcome" => "nothing"}])
  end
end
