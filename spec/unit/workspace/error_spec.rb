RSpec.describe Workspace::Error do
  it "defaults to the error code with no details and no retry" do
    error = described_class.new("x")
    expect([error.message, error.code, error.details, error.retry]).to eq(["x", "error", {}, nil])
  end

  it "carries a code, details and retry" do
    error = described_class.new("x", code: "dirty", details: {"n" => 1}, retry_with: {"flags" => ["--force"]})
    expect([error.code, error.details, error.retry]).to eq(["dirty", {"n" => 1}, {"flags" => ["--force"]}])
  end

  it "still works with raise Class, message" do
    expect { raise described_class, "plain" }.to raise_error(described_class, "plain")
  end

  it "gives UsageError the usage code" do
    expect(Workspace::UsageError.new("x").code).to eq("usage")
  end

  it "gives ConfigParseError the config_parse code and its path and reason" do
    error = Workspace::ConfigParseError.new("/p.yml", "bad")
    expect([error.code, error.details]).to eq(["config_parse", {"path" => "/p.yml", "reason" => "bad"}])
  end

  it "reports unsaved work with counts and a --force retry" do
    error = Workspace::UnsavedWorkError.new("m", unsaved: {changed_files: 3, unpushed_commits: 1, branch: "b"})
    expect(error.code).to eq("unsaved_work")
    expect(error.details).to eq({"changed_files" => 3, "unpushed_commits" => 1, "branch" => "b"})
    expect(error.retry).to eq({"flags" => ["--force"], "destructive" => true})
  end

  it "reports unsaved_unknown when git couldn't check" do
    error = Workspace::UnsavedWorkError.new("m", unsaved: :unknown)
    expect([error.code, error.details]).to eq(["unsaved_unknown", {}])
    expect(error.retry).to eq({"flags" => ["--force"], "destructive" => true})
  end
end
