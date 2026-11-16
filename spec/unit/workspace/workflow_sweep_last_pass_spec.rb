require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowSweep, "last pass and log trim" do
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "sweep.log") }
  let(:last_path) { File.join(dir, ".workflows", "sweep-last.json") }
  let(:now) { Time.utc(2026, 1, 2, 3, 4, 5) }
  let(:run) { instance_double(Workspace::WorkflowRun, workspace: "app") }
  let(:store) { instance_double(Workspace::WorkflowRunStore, going: [run], unreadable: []) }
  let(:reviews) { instance_double(Workspace::WorkflowReviewSweep, orphan_rows: []) }
  let(:row) { {"outcome" => "nothing"} }
  let(:paths) { {log_path: log_path, last_path: last_path} }

  def build(**opts)
    described_class.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, clock: -> { now }, **opts)
  end

  def record = JSON.parse(File.read(last_path))

  before do
    allow(store).to receive(:run).and_return(run)
    allow_any_instance_of(described_class).to receive(:sweep_run) { row }
  end

  after { FileUtils.remove_entry(dir) }

  it "writes last and last_full for an unfiltered pass" do
    build(**paths).call

    expect(record["last"]).to eq("at" => "2026-01-02T03:04:05Z", "scope" => "all", "acted" => 0, "errors" => [])
    expect(record["last_full"]).to eq(record["last"])
  end

  it "updates last only for a workspace pass, keeping last_full" do
    build(**paths).call
    full = record["last_full"]
    later = build(**paths.merge(clock: -> { now + 60 }))
    later.call(workspace: "app")

    expect(record["last"]["scope"]).to eq("workspace" => "app")
    expect(record["last"]["at"]).to eq("2026-01-02T03:05:05Z")
    expect(record["last_full"]).to eq(full)
  end

  it "records a run scope" do
    build(**paths).call(run: "r1")

    expect(record["last"]["scope"]).to eq("run" => "r1")
    expect(record).not_to have_key("last_full")
  end

  it "writes nothing for a dry run" do
    build(**paths).call(dry_run: true)

    expect(File.exist?(last_path)).to be(false)
  end

  it "counts acted rows and lists failed ones with a shortened message" do
    rows = [{"outcome" => "retried"}, {"outcome" => "failed", "run_id" => "r1", "reason" => "boom", "message" => "x" * 500}, {"outcome" => "nothing"}]
    i = -1
    allow(store).to receive(:going).and_return([run, run, run])
    allow_any_instance_of(described_class).to receive(:sweep_run) { rows[i += 1] }
    build(**paths).call

    expect(record["last"]["acted"]).to eq(2)
    expect(record["last"]["errors"].size).to eq(1)
    expect(record["last"]["errors"][0]).to include("run_id" => "r1", "reason" => "boom")
    expect(record["last"]["errors"][0]["message"].size).to be < 500
  end

  it "does not fail the pass when the record can't be written" do
    FileUtils.mkdir_p(last_path)

    expect(build(**paths).call).to eq([row])
  end

  it "cuts a log over the limit to a line boundary in place, same inode, a dry run too" do
    File.write(log_path, (1..100_000).map { |n| "line #{n}\n" }.join)
    inode = File.stat(log_path).ino
    build(**paths).call(dry_run: true)

    text = File.read(log_path)
    expect(File.size(log_path)).to be <= 256 * 1024
    expect(text).to start_with("line ")
    expect(text).to end_with("line 100000\n")
    expect(File.stat(log_path).ino).to eq(inode)
  end

  it "leaves a small log alone" do
    File.write(log_path, "hello\nworld")
    build(**paths).call

    expect(File.read(log_path)).to eq("hello\nworld")
  end

  it "writes no files without paths" do
    build.call

    expect(Dir.children(dir)).to be_empty
  end
  it "keeps a tail with no newline as it is" do
    File.write(log_path, "x" * 2000)
    build(log_path: log_path, log_limit: 1000, log_keep: 500).call

    expect(File.read(log_path)).to eq("x" * 500)
  end

  it "keeps the first line of a tail that already starts on a line boundary" do
    File.write(log_path, ("a" * 9 + "\n") * 200)
    build(log_path: log_path, log_limit: 1000, log_keep: 500).call

    expect(File.read(log_path)).to eq(("a" * 9 + "\n") * 50)
  end

  it "leaves a log of exactly the limit alone" do
    File.write(log_path, "ab\n" * 100)
    build(log_path: log_path, log_limit: 300, log_keep: 100).call

    expect(File.size(log_path)).to eq(300)
  end

  it "leaves the log whole when log_keep is not under its size" do
    File.write(log_path, "ab\n" * 100)
    build(log_path: log_path, log_limit: 100, log_keep: 500).call

    expect(File.size(log_path)).to eq(300)
  end

  [["invalid JSON", "{nope"], ["invalid UTF-8", "{\"a\":\"\xFF\"}".b], ["a non-Hash document", "[1]"]].each do |label, content|
    it "writes a fresh record over #{label}" do
      FileUtils.mkdir_p(File.dirname(last_path))
      File.binwrite(last_path, content)
      build(**paths).call

      expect(record["last_full"]["scope"]).to eq("all")
    end
  end

  it "lists unreadable run files in errors" do
    allow(store).to receive(:unreadable).and_return(["/x/bad.json"])
    build(**paths).call

    expect(record["last"]["errors"].map { |e| e["run_id"] }).to eq(["bad"])
    expect(record["last"]["errors"][0]["reason"]).to eq("unreadable_run")
  end
end
