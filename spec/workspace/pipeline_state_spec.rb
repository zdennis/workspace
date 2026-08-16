require "spec_helper"
require "tmpdir"

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

  describe "persistence" do
    let(:tmpdir) { Dir.mktmpdir("ws-pipeline-state") }
    let(:state_path) { File.join(tmpdir, "nested", "pipeline.json") }

    subject(:state) { described_class.new(pipeline_config: pipeline_config, state_path: state_path) }

    after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

    def persisted = JSON.parse(File.read(state_path))

    def reloaded
      described_class.new(pipeline_config: pipeline_config, state_path: state_path)
    end

    it "stays purely in memory when given no state path" do
      memory_only = described_class.new(pipeline_config: pipeline_config)
      memory_only.start(work_item_ref: "WC-42", workspace_name: "myapp", dispatch_id: "d-1")

      expect(memory_only.in_flight_refs).to eq(["WC-42"])
      expect(Dir.children(tmpdir)).to be_empty
    end

    it "writes the item to disk when it starts, creating the directory" do
      start!

      expect(persisted).to eq(
        "WC-42" => {
          "work_item_ref" => "WC-42", "workspace_name" => "myapp",
          "dispatch_id" => "d-1", "pane_index" => 0, "phase" => "researcher"
        }
      )
    end

    it "records the new stage when the item advances" do
      start!
      state.advance(work_item_ref: "WC-42", to_stage: stages[1])

      expect(persisted["WC-42"]).to include("pane_index" => 1, "phase" => "implementer")
    end

    it "removes the item from disk when it completes" do
      start!
      state.complete(work_item_ref: "WC-42")

      expect(persisted).to be_empty
    end

    it "leaves no temp files behind" do
      start!
      state.advance(work_item_ref: "WC-42", to_stage: stages[1])

      expect(Dir.children(File.dirname(state_path))).to eq(["pipeline.json"])
    end

    it "reads entries back with symbol keys so callers see one shape" do
      start!
      state.advance(work_item_ref: "WC-42", to_stage: stages[1])

      expect(reloaded.current("WC-42")).to eq(
        work_item_ref: "WC-42", workspace_name: "myapp",
        dispatch_id: "d-1", pane_index: 1, phase: "implementer"
      )
    end

    it "starts empty rather than raising when the file is truncated" do
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, '{"WC-42": {"pane_ind')

      expect(reloaded.in_flight_refs).to be_empty
    end

    it "starts empty rather than raising when the file holds the wrong shape" do
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, "[1, 2, 3]")

      expect(reloaded.in_flight_refs).to be_empty
    end

    it "skips entries that are not objects and keeps the ones that are" do
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, JSON.generate("WC-42" => {"pane_index" => 1}, "WC-43" => "nonsense"))

      expect(reloaded.in_flight_refs).to eq(["WC-42"])
    end

    it "keeps the file readable only by its owner" do
      start!

      expect(File.stat(state_path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(state_path)).mode & 0o777).to eq(0o700)
    end
  end
end
