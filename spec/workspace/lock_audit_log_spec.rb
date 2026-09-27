require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::LockAuditLog do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-audit") }
  let(:path) { File.join(tmpdir, "locks.jsonl") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def log(rotate_bytes: described_class::DEFAULT_ROTATE_BYTES)
    described_class.new(dir: tmpdir, rotate_bytes: rotate_bytes)
  end

  def lines
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  it "appends one JSON line per event" do
    log.append(event: "acquire", name: "edit", data: {"holder" => {"pid" => 1}})
    log.append(event: "release", name: "edit", data: {"holder" => {"pid" => 1}})

    entries = lines
    expect(entries.size).to eq(2)
    expect(entries[0]["event"]).to eq("acquire")
    expect(entries[1]["event"]).to eq("release")
  end

  it "includes a timestamp and the lock name" do
    log.append(event: "acquire", name: "edit", data: {})

    entry = lines.first
    expect(entry["lock"]).to eq("edit")
    expect { Time.iso8601(entry["timestamp"]) }.not_to raise_error
  end

  it "merges data fields alongside event and lock" do
    log.append(event: "deny", name: "edit", data: {"agent" => {"pid" => 2}, "holder" => {"pid" => 1}})

    entry = lines.first
    expect(entry["agent"]).to eq({"pid" => 2})
    expect(entry["holder"]).to eq({"pid" => 1})
  end

  it "rotates to locks.jsonl.1 once the next line would exceed the threshold" do
    small_log = log(rotate_bytes: 10)
    small_log.append(event: "acquire", name: "edit", data: {})
    small_log.append(event: "release", name: "edit", data: {})

    expect(File.exist?("#{path}.1")).to be true
    expect(lines.size).to eq(1)
  end

  it "never raises when the directory disappears out from under it" do
    FileUtils.remove_entry(tmpdir)

    expect { log.append(event: "acquire", name: "edit", data: {}) }.not_to raise_error
  end
end
