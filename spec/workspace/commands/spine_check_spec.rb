require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Spine, "#check" do
  around do |example|
    Dir.mktmpdir("spine-check") do |dir|
      @root = File.realpath(dir)
      @notes = File.join(@root, "notes")
      @state = File.join(@root, "state")
      FileUtils.mkdir_p(@notes)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:events) { [] }
  let(:event_log) do
    log = instance_double(Workspace::EventLog, latest_agent_states: {})
    allow(log).to receive(:record) { |**event| events << event }
    log
  end
  let(:clock) { -> { Time.utc(2026, 10, 18, 9, 0, 0) } }
  subject(:command) do
    described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
      env: {}, clock: clock, output: output)
  end

  let(:body) { "# Verify\n\n## Done when\n- [ ] Tests pass\n- [x] Docs updated\n- [ ] Released\n\n## Notes\n- [ ] not an item\n" }

  before { allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes}) }

  def write(text, relative = "40-verify.md")
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
  end

  def read(relative = "40-verify.md") = File.binread(File.join(@notes, "spine", relative))

  def revision = Workspace::SpineFile.read(File.join(@notes, "spine", "40-verify.md")).revision

  def answer = JSON.parse(output.string)

  def refusal(&block)
    block.call
    raise "no refusal"
  rescue Workspace::Error => e
    e
  end

  let(:file) { "---\nstatus: in_progress\nupdated: 2026-10-01T00:00:00Z\nunknown_key: [a, b]\n---\n#{body}" }

  before { write(file) }

  it "ticks items, changes only their boxes, and answers every item" do
    command.check(name: "api", path: "verify", items: [1, 3], done: true, json: true)

    expect(read).to eq(file.sub("- [ ] Tests pass", "- [x] Tests pass").sub("- [ ] Released", "- [x] Released"))
    expect(answer).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "path" => "verify", "file" => "40-verify.md",
      "items" => [{"n" => 1, "text" => "Tests pass", "done" => true}, {"n" => 2, "text" => "Docs updated", "done" => true},
        {"n" => 3, "text" => "Released", "done" => true}],
      "done_when" => {"total" => 3, "done" => 3}, "changed" => [1, 3], "revision" => revision)
  end

  it "unticks an item" do
    command.check(name: "api", path: "verify", items: [2], done: false, json: true)

    expect(read).to eq(file.sub("- [x] Docs", "- [ ] Docs"))
    expect(answer["changed"]).to eq([2])
    expect(answer["done_when"]).to eq("total" => 3, "done" => 0)
  end

  it "leaves an item that already reads as asked alone: nothing written, no event" do
    mtime = File.mtime(File.join(@notes, "spine", "40-verify.md"))

    command.check(name: "api", path: "verify", items: [2], done: true, json: true)

    expect(read).to eq(file)
    expect(File.mtime(File.join(@notes, "spine", "40-verify.md"))).to eq(mtime)
    expect(answer["changed"]).to eq([])
    expect(answer["revision"]).to eq(revision)
    expect(events).to be_empty
  end

  it "changes only the items that differ when some already read as asked" do
    command.check(name: "api", path: "verify", items: [1, 2], done: true, json: true)

    expect(answer["changed"]).to eq([1])
  end

  it "keeps CRLF line endings, a BOM and every other byte" do
    crlf = "﻿---\r\nstatus: in_progress\r\n---\r\n## Done when\r\n- [ ] One\r\n- [ ] Two\r\n\r\nlast line without newline".b
    write(crlf)

    command.check(name: "api", path: "verify", items: [2], done: true)

    expect(read).to eq(crlf.sub("- [ ] Two".b, "- [x] Two".b))
    expect(read.encoding).to eq(Encoding::BINARY)
  end

  it "accepts a file with no frontmatter and reads an uppercase X as done" do
    write("## Done when\n- [X] a\n- [ ] b\n")

    command.check(name: "api", path: "verify", items: [1, 2], done: false)

    expect(read).to eq("## Done when\n- [ ] a\n- [ ] b\n")
  end

  it "records one spine_changed line with change done_when, the numbers and the new revision" do
    command.check(name: "api", path: "verify", items: [3, 1, 1], done: true, by: "alice")

    expect(events).to eq([{type: "spine_changed", project: "api", data: {"workspace" => "api", "path" => "verify", "change" => "done_when",
                                                                         "items" => [1, 3], "by" => "alice", "revision" => revision}}])
  end

  it "refuses a stale revision and writes nothing" do
    error = refusal { command.check(name: "api", path: "verify", items: [1], done: true, if_revision: "deadbeef") }

    expect(error.code).to eq("stale_revision")
    expect(error.details).to include("revision" => revision)
    expect(read).to eq(file)
    expect(events).to be_empty
  end

  it "accepts the current revision" do
    command.check(name: "api", path: "verify", items: [1], done: true, if_revision: revision.upcase)

    expect(read).to include("- [x] Tests pass")
  end

  it "refuses an item out of range, even when another item is fine, and writes nothing" do
    [[1, 4], [9]].each do |items|
      error = refusal { command.check(name: "api", path: "verify", items: items, done: true) }
      expect(error.code).to eq("unknown_item")
      expect(error.details).to include("total" => 3)
    end
    expect(read).to eq(file)
  end

  it "refuses an item on a stage with no checklist" do
    write("---\nstatus: in_progress\n---\nBody\n")

    error = refusal { command.check(name: "api", path: "verify", items: [1], done: true) }

    expect(error.code).to eq("unknown_item")
    expect(error.details["total"]).to eq(0)
  end

  it "does not take an item in a fenced block or another section" do
    write("## Done when\n- [ ] real\n```\n- [ ] fenced\n```\n## Other\n- [ ] other\n")

    error = refusal { command.check(name: "api", path: "verify", items: [2], done: true) }

    expect(error.code).to eq("unknown_item")
  end

  it "refuses a stage file that is a link" do
    path = File.join(@notes, "spine", "40-verify.md")
    File.rename(path, File.join(@root, "elsewhere.md"))
    File.symlink(File.join(@root, "elsewhere.md"), path)

    error = refusal { command.check(name: "api", path: "verify", items: [1], done: true) }

    expect(error.code).to eq("spine_unwritable")
    expect(File.binread(File.join(@root, "elsewhere.md"))).to eq(file)
  end

  it "refuses a folder-only stage, an unknown stage and a missing spine" do
    FileUtils.mkdir_p(File.join(@notes, "spine", "50-ship"))
    write("---\nstatus: not_started\n---\n", "50-ship/10-a.md")
    expect(refusal { command.check(name: "api", path: "ship", items: [1], done: true) }.details).to include("reason" => "no_file")
    expect(refusal { command.check(name: "api", path: "nope", items: [1], done: true) }.code).to eq("unknown_stage")
    FileUtils.rm_rf(File.join(@notes, "spine"))
    expect(refusal { command.check(name: "api", path: "verify", items: [1], done: true) }.code).to eq("no_spine")
  end

  it "rejects no items and non-positive numbers as usage errors" do
    expect { command.check(name: "api", path: "verify", items: [], done: true) }.to raise_error(Workspace::UsageError)
    expect { command.check(name: "api", path: "verify", items: ["1"], done: true) }.to raise_error(Workspace::UsageError)
  end

  it "prints a line without --json" do
    command.check(name: "api", path: "verify", items: [1], done: true)
    command.check(name: "api", path: "verify", items: [1], done: true)

    expect(output.string).to eq("api: verify item 1 ticked (2/3 done)\napi: verify already reads as asked (2/3 done)\n")
  end

  it "keeps the frontmatter's updated time (a tick is not a status change)" do
    command.check(name: "api", path: "verify", items: [1], done: true)

    expect(Workspace::SpineFile.read(File.join(@notes, "spine", "40-verify.md")).value("updated")).to eq("2026-10-01T00:00:00Z")
  end
end
