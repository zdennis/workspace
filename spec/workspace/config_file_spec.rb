require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::ConfigFile do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "p.yml") }

  after { FileUtils.rm_rf(dir) }

  def read(text)
    File.write(path, text)
    described_class.read("project", path)
  end

  it "reports a missing file as not existing, with no error" do
    result = described_class.read("project", path)

    expect(result).to have_attributes(exists: false, etag: nil, data: {}, parse_error: nil, locations: {})
    expect(result).to be_readable
  end

  it "reads a mapping with the etag of its bytes and where each key sits (1-based)" do
    result = read("dev:\n  up: bin/dev  # inline\n  ready_timeout: 5m\nhooks: {}\n")

    expect(result.data).to eq("dev" => {"up" => "bin/dev", "ready_timeout" => "5m"}, "hooks" => {})
    expect(result.etag).to eq("sha256:#{Digest::SHA256.hexdigest(File.read(path))}")
    expect(result.locations).to include("dev" => [1, 1], "dev.up" => [2, 3], "dev.ready_timeout" => [3, 3], "hooks" => [4, 1])
  end

  it "treats an empty file and a comment-only file as an empty mapping" do
    expect(read("").data).to eq({})
    expect(read("# nothing here\n")).to have_attributes(data: {}, parse_error: nil)
  end

  it "reports a syntax error as data with Psych's line and column" do
    result = read("a: 1\nb: [\n")

    expect(result.parse_error).to eq("message" => "did not find expected node content while parsing a flow node", "line" => 3, "column" => 1)
    expect(result.data).to eq({})
    expect(result).not_to be_readable
  end

  it "reports a top level that isn't a mapping at line 1, column 1" do
    expect(read("- a\n- b\n").parse_error).to eq("message" => "expected a mapping at the top level, got array", "line" => 1, "column" => 1)
  end

  it "reports a disallowed alias or tag without a position" do
    error = read("a: &x 1\nb: *x\n").parse_error
    expect(error["message"]).to match(/alias/i)
    expect(error).not_to have_key("line")

    expect(read("a: !ruby/object:Object {}\n").parse_error["message"]).to match(/Object/)
  end

  it "reports an unreadable file as a parse error rather than raising" do
    File.write(path, "a: 1")
    File.chmod(0o000, path)

    expect(described_class.read("project", path).parse_error["message"]).to be_a(String)
  ensure
    File.chmod(0o600, path)
  end
end
