require "tmpdir"

RSpec.describe Workspace::SessionLedger do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, "state", "workspace", "ledger.jsonl") }
  let(:now) { Time.utc(2026, 10, 2, 12, 0, 0) }
  let(:ledger) { described_class.new(path: path, clock: -> { now }, logger: Workspace::Logger.new) }

  after { FileUtils.remove_entry(tmpdir) }

  def lines
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  it "appends one JSON line stamped with the clock, creating the directory" do
    expect(ledger.record("event" => "session_start", "pane_slot" => "proj:0.1")).to be(true)

    expect(lines).to eq([{"at" => "2026-10-02T12:00:00.000000Z", "event" => "session_start", "pane_slot" => "proj:0.1"}])
  end

  it "keeps earlier lines and never rewrites them" do
    ledger.record("event" => "session_start")
    ledger.record("event" => "session_end")

    expect(lines.map { |line| line["event"] }).to eq(%w[session_start session_end])
  end

  it "leaves nil fields out" do
    ledger.record("event" => "session_end", "pane_slot" => nil)

    expect(lines.first).not_to have_key("pane_slot")
  end

  it "keeps the file and directory private" do
    ledger.record("event" => "session_start")

    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
  end

  it "does not interleave lines written from several processes" do
    ledger
    pids = 4.times.map do |i|
      fork do
        25.times { ledger.record("event" => "session_start", "session_id" => "#{i}-" + "x" * 5000) }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    expect(lines.size).to eq(100)
  end

  it "returns false instead of raising when the file can't be written" do
    FileUtils.mkdir_p(path)

    expect(ledger.record("event" => "session_start")).to be(false)
  end
end

RSpec.describe Workspace::SessionLedger, "#entries_for" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, "ledger.jsonl") }
  let(:ledger) { described_class.new(path: path, logger: Workspace::Logger.new) }

  after { FileUtils.remove_entry(tmpdir) }

  it "returns one workspace's entries, oldest first" do
    ledger.record("event" => "session_start", "workspace" => "a", "session_id" => "1")
    ledger.record("event" => "session_start", "workspace" => "b", "session_id" => "2")
    ledger.record("event" => "session_end", "workspace" => "a", "session_id" => "1")

    expect(ledger.entries_for("a").map { |e| [e["event"], e["session_id"]] }).to eq([%w[session_start 1], %w[session_end 1]])
  end

  it "skips a torn line and lines that aren't objects" do
    ledger.record("event" => "session_start", "workspace" => "a")
    File.open(path, "a") { |f| f.write("{\"workspace\":\"a\", torn\n[1,2]\n\"a\"\n") }
    ledger.record("event" => "session_end", "workspace" => "a")

    expect(ledger.entries_for("a").map { |e| e["event"] }).to eq(%w[session_start session_end])
  end

  it "raises rather than read as empty when the ledger exists but can't be read" do
    ledger.record("event" => "session_start", "workspace" => "a")
    File.chmod(0o000, path)

    expect { ledger.entries_for("a") }.to raise_error(Errno::EACCES)
  ensure
    File.chmod(0o600, path)
  end

  it "is empty when there is no ledger" do
    expect(ledger.entries_for("a")).to eq([])
  end

  # Every rule is checked against a real ledger file, written the way the hook writes it.
  describe "#slots_for" do
    let(:ledger) { described_class.new(path: path, clock: -> { Time.utc(2026, 10, 2, 12, 0, 0) }, logger: Workspace::Logger.new) }

    def start(slot, session_id, workspace: "a", **extra)
      ledger.record({"event" => "session_start", "workspace" => workspace, "pane_slot" => slot, "session_id" => session_id}.merge(extra.transform_keys(&:to_s)))
    end

    def finish(session_id, workspace: "a", **extra)
      ledger.record({"event" => "session_end", "workspace" => workspace, "session_id" => session_id}.merge(extra.transform_keys(&:to_s)))
    end

    def slots(workspace = "a")
      ledger.slots_for(workspace).to_h { |record| [record["pane_slot"], record] }
    end

    it "is empty when there is no ledger" do
      expect(ledger.slots_for("a")).to eq([])
    end

    it "returns what restore needs for each slot" do
      start("a:0.1", "s1", pane_id: "%4", tmux_server: "14794", cwd: "/p", transcript_path: "/t.jsonl", layout: "L1", source: "startup")

      expect(ledger.slots_for("a")).to eq([{"at" => "2026-10-02T12:00:00.000000Z", "pane_slot" => "a:0.1", "pane_id" => "%4", "tmux_server" => "14794",
                                            "session_id" => "s1", "transcript_path" => "/t.jsonl", "cwd" => "/p", "layout" => "L1"}])
    end

    it "keeps only the workspace's own slots" do
      start("a:0.1", "s1")
      start("b:0.1", "s2", workspace: "b")

      expect(slots.keys).to eq(["a:0.1"])
      expect(slots("b").keys).to eq(["b:0.1"])
    end

    it "reads the entries recorded under any of the names given, as a worktree workspace's session name" do
      start("a-wt-x:0.1", "s1", workspace: "a-wt-x")
      start("a-wt-x:0.2", "s2", workspace: "a.worktree-x")
      start("b:0.1", "s3", workspace: "b")

      expect(ledger.slots_for("a.worktree-x", "a-wt-x").map { |record| record["session_id"] }).to eq(%w[s1 s2])
    end

    it "takes the latest session started in a slot, as after /clear or a tmux restart that reused the slot" do
      start("a:0.1", "s1", pane_id: "%4")
      finish("s1", reason: "clear")
      start("a:0.1", "s2", pane_id: "%9")

      expect(slots["a:0.1"]).to include("session_id" => "s2", "pane_id" => "%9")
      expect(slots["a:0.1"]).not_to have_key("ended_at")
    end

    it "marks a slot whose session ended, with the reason" do
      start("a:0.1", "s1")
      finish("s1", reason: "prompt_input_exit")

      expect(slots["a:0.1"]).to include("session_id" => "s1", "end_reason" => "prompt_input_exit", "ended_at" => "2026-10-02T12:00:00.000000Z")
    end

    it "closes a session by its id when the end was recorded with no slot or another slot, as for a pane already gone or renumbered" do
      start("a:0.1", "s1")
      start("a:0.2", "s2")
      finish("s2", reason: "other")
      finish("s1", reason: "logout", pane_slot: "a:0.2")

      expect(slots["a:0.1"]).to include("end_reason" => "logout")
      expect(slots["a:0.2"]).to include("end_reason" => "other")
    end

    it "closes its own slot when a SessionEnd has no session id" do
      start("a:0.1", "s1")
      ledger.record("event" => "session_end", "workspace" => "a", "pane_slot" => "a:0.1", "reason" => "logout")

      expect(slots["a:0.1"]).to include("end_reason" => "logout")
    end

    it "ignores an end for a session no slot holds any more" do
      start("a:0.1", "s1")
      start("a:0.1", "s2")
      finish("s1", reason: "logout")

      expect(slots["a:0.1"]).not_to have_key("end_reason")
    end

    it "counts a session once, in the slot it started in last, as when a sibling pane closed and the index changed" do
      start("a:0.3", "s1")
      start("a:0.2", "s1", source: "compact")

      expect(slots.keys).to eq(["a:0.2"])
    end

    it "reopens a slot when its ended session starts again, as after a resume" do
      start("a:0.1", "s1")
      finish("s1", reason: "other")
      start("a:0.1", "s1", source: "resume")

      expect(slots["a:0.1"]).not_to have_key("ended_at")
    end

    it "skips a start with no slot, a torn line and lines that aren't objects" do
      ledger.record("event" => "session_start", "workspace" => "a", "session_id" => "s0")
      File.open(path, "a") { |f| f.write("{\"workspace\":\"a\", torn\n[1,2]\n\"a\"\n") }
      start("a:0.1", "s1")

      expect(slots.keys).to eq(["a:0.1"])
    end

    it "keeps two sessions with no id in their own slots" do
      ledger.record("event" => "session_start", "workspace" => "a", "pane_slot" => "a:0.1")
      ledger.record("event" => "session_start", "workspace" => "a", "pane_slot" => "a:0.2")

      expect(slots.keys).to eq(["a:0.1", "a:0.2"])
    end

    it "ignores an end with neither a session id nor a slot" do
      start("a:0.1", "s1")
      ledger.record("event" => "session_end", "workspace" => "a", "reason" => "logout")

      expect(slots["a:0.1"]).not_to have_key("end_reason")
    end

    it "skips a start with an empty slot and an entry with an unknown event" do
      ledger.record("event" => "session_start", "workspace" => "a", "pane_slot" => "", "session_id" => "s0")
      start("a:0.1", "s1")
      ledger.record("event" => "session_pause", "workspace" => "a", "pane_slot" => "a:0.1", "session_id" => "s1", "reason" => "logout")

      expect(slots.keys).to eq(["a:0.1"])
      expect(slots["a:0.1"]).not_to have_key("end_reason")
    end

    it "keeps one record per slot however long the history is" do
      500.times { |i| start("a:0.#{i % 3}", "s#{i}") }

      expect(slots.transform_values { |record| record["session_id"] }).to eq("a:0.0" => "s498", "a:0.1" => "s499", "a:0.2" => "s497")
    end

    it "raises rather than read as empty when the ledger exists but can't be read" do
      start("a:0.1", "s1")
      File.chmod(0o000, path)

      expect { ledger.slots_for("a") }.to raise_error(Errno::EACCES)
    ensure
      File.chmod(0o600, path)
    end
  end
end
