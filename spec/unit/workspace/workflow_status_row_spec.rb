require "spec_helper"

RSpec.describe Workspace::WorkflowStatus::Row do
  let(:hash) do
    {"id" => "wr_1", "workflow" => "rpiv", "title" => nil, "workspace" => "app", "state" => "running", "created_at" => "2026-01-01T00:00:00Z",
     "pane" => "%3", "current" => {"step" => "plan", "reason" => {"code" => "waiting_you"}}, "steps" => [{"id" => "plan"}], "extra" => {"a" => 1}}
  end

  it "reads the stored values" do
    row = described_class.from_h(hash)

    expect([row.id, row.workflow, row.workspace, row.state, row.pane]).to eq(["wr_1", "rpiv", "app", "running", "%3"])
    expect(row.current).to eq({"step" => "plan", "reason" => {"code" => "waiting_you"}})
  end

  it "gives back the row it was made from, keys in order, and freezes it" do
    row = described_class.from_h(hash)

    expect(JSON.generate(row.to_h)).to eq(JSON.generate(hash))
    expect(row.to_h).to be_frozen
    expect(row.to_h["current"]).to be_frozen
  end

  it "reads a missing key as nil and a non-Hash as an empty row" do
    expect(described_class.from_h({}).current).to be_nil
    expect(described_class.from_h(nil).to_h).to eq({})
  end

  it "is returned as it is when already a row" do
    row = described_class.from_h(hash)

    expect(described_class.from_h(row)).to equal(row)
  end
end
