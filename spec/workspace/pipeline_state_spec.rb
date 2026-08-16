require "spec_helper"

RSpec.describe Workspace::PipelineState do
  let(:stages) do
    [
      {role: "researcher", pane_index: 0},
      {role: "implementer", pane_index: 1}
    ]
  end
  let(:pipeline_config) do
    instance_double(Workspace::PipelineConfig).tap do |c|
      allow(c).to receive(:stages_for).with("myapp").and_return(stages)
    end
  end

  subject(:state) { described_class.new(pipeline_config: pipeline_config) }

  def start!
    state.start(work_item_ref: "WC-42", workspace_name: "myapp", dispatch_id: "d-1")
  end

  describe "#advance" do
    it "moves a tracked item onto the given stage" do
      start!

      state.advance(work_item_ref: "WC-42", to_stage: stages[1])

      expect(state.current("WC-42")).to include(pane_index: 1, phase: "implementer")
    end

    it "does nothing for an item it is not tracking" do
      expect(state.advance(work_item_ref: "WC-99", to_stage: stages[1])).to be_nil
      expect(state.in_flight_refs).to be_empty
    end
  end

  describe "#complete" do
    it "stops tracking the item" do
      start!

      state.complete(work_item_ref: "WC-42")

      expect(state.current("WC-42")).to be_nil
      expect(state.in_flight_refs).to be_empty
    end

    it "does nothing for an item it is not tracking" do
      expect(state.complete(work_item_ref: "WC-99")).to be_nil
    end
  end
end
