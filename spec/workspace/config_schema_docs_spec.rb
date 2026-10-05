require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe Workspace::ConfigSchemaDocs do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:doc_path) { File.join(root, "docs/README.config.md") }

  it "leaves docs/README.config.md as the schema renders it" do
    text = File.read(doc_path)
    expect(described_class.rewrite(text)).to eq(text), "docs/README.config.md is out of date; run script/generate-config-docs"
  end

  it "lists every settable key in the generated table" do
    table = described_class.render("keys")
    expect(Workspace::ConfigSchema.all.select(&:settable?).map(&:name)).to all(satisfy { |name| table.include?("| `#{name}` |") })
  end

  it "marks global keys and names the restart-only keys" do
    expect(described_class.render("keys")).to include("| `launch.headless` | Global. ")
    expect(described_class.render("restart")).to include("`locks.ps_timeout`, `locks.reap_interval`, `alerts.notify`, `alerts.idle_after` and `agentd.poll_interval`")
  end

  it "replaces only the text between markers" do
    text = "before\n<!-- BEGIN GENERATED: restart -->\nstale\n<!-- END GENERATED: restart -->\nafter\n"
    out = described_class.rewrite(text)
    expect(out).to start_with("before\n<!-- BEGIN GENERATED: restart -->\n")
    expect(out).to end_with("<!-- END GENERATED: restart -->\nafter\n")
    expect(out).not_to include("stale")
  end

  it "refuses a block name it can't render" do
    expect { described_class.rewrite("<!-- BEGIN GENERATED: nope -->\n<!-- END GENERATED: nope -->\n") }.to raise_error(ArgumentError, /nope/)
  end

  describe "script/generate-config-docs" do
    it "exits 0 under --check when the docs are current, and rewrites a stale copy" do
      script = File.join(root, "script/generate-config-docs")
      _out, status = Open3.capture2e(script, "--check")
      expect(status.exitstatus).to eq(0)

      Dir.mktmpdir("ws-docs") do |dir|
        copy = File.join(dir, "README.config.md")
        File.write(copy, File.read(doc_path).sub(/(<!-- BEGIN GENERATED: restart -->\n).*?(<!-- END GENERATED)/m, "\\1stale\n\\2"))
        _out, status = Open3.capture2e(script, "--check", copy)
        expect(status.exitstatus).to eq(1)
        _out, status = Open3.capture2e(script, copy)
        expect(status.exitstatus).to eq(0)
        expect(File.read(copy)).to eq(File.read(doc_path))
      end
    end
  end
end
