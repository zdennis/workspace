require "spec_helper"

RSpec.describe Workspace::WorkflowNudger, "heartbeat" do
  let(:store) { instance_double(Workspace::WorkflowRunStore, going: []) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:downtime) { double("downtime", beat: nil, spans: []) }
  let(:spawned) { [] }
  subject(:nudger) do
    described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
      spawner: ->(argv, _log) { spawned << argv }, downtime: downtime, error_output: StringIO.new)
  end

  it "beats once per tick, even with no run going" do
    nudger.tick("app")
    nudger.tick("app")

    expect(downtime).to have_received(:beat).twice
  end

  it "still wakes a wakeable run when the beat raises" do
    run = Workspace::WorkflowRun.from_h({"id" => "wr_1", "workspace" => "app"})
    allow(store).to receive(:going).and_return([run])
    allow(Workspace::WorkflowEngine).to receive(:wakeable?).and_return(true)
    allow(downtime).to receive(:beat).and_raise("boom")

    expect(nudger.tick("app")).to eq(["wr_1"])
    expect(spawned.first).to include("advance", "wr_1")
  end

  it "ticks without a downtime object" do
    plain = described_class.new(store: store, panes: panes, executable: "x", log_path: ->(w) { w }, spawner: ->(*) {})

    expect(plain.tick("app")).to eq([])
  end
end
