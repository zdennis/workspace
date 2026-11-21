require "spec_helper"
require "digest"

load File.join(PROJECT_ROOT, "script", "demo-calculator")

RSpec.describe DemoCalculator::RunRecord do
  let(:record) do
    described_class.build(
      stamp: "20261121T040506Z", base_sha: "abc", branch: "calc-demo/20261121T040506Z",
      workspace_sha: "def", workspace_version: "0.163.0",
      items: [{"workflow" => "calc-01-add-sub", "id" => "i1", "extra" => 1}, {"workflow" => "calc-02-mul-div", "id" => "i2"}],
      definitions: {"calc-01-add-sub" => "one\n", "calc-02-mul-div" => "two\n"}
    )
  end

  it "holds the run's identity and the workspace that drove it" do
    expect(record).to include("stamp" => "20261121T040506Z", "base_sha" => "abc", "branch" => "calc-demo/20261121T040506Z", "wait" => nil)
    expect(record["workspace"]).to eq("sha" => "def", "version" => "0.163.0")
  end

  it "keeps only the workflow and id of each item, in order" do
    expect(record["items"]).to eq([{"workflow" => "calc-01-add-sub", "id" => "i1"}, {"workflow" => "calc-02-mul-div", "id" => "i2"}])
  end

  it "stores the sha256 of each definition's text" do
    expect(record["definitions"]).to eq("calc-01-add-sub" => Digest::SHA256.hexdigest("one\n"), "calc-02-mul-div" => Digest::SHA256.hexdigest("two\n"))
  end

  it "keeps a nil item id and nil workspace facts as nil" do
    nils = described_class.build(stamp: "s", base_sha: "b", branch: "x", workspace_sha: nil, workspace_version: nil, items: [{"workflow" => "w", "id" => nil}], definitions: {})
    expect(nils["items"]).to eq([{"workflow" => "w", "id" => nil}])
    expect(nils["workspace"]).to eq("sha" => nil, "version" => nil)
  end
end
