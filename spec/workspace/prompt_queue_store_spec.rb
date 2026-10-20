require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PromptQueueStore do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "api", "prompt-queue.json") }
  let(:now) { [Time.utc(2026, 10, 19, 12, 0, 0)] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
  let(:ids) { (1..20).map { |n| format("%016x", n) } }
  let(:pending_ids) { ids.dup }
  let(:alive) { [4242] }

  subject(:store) do
    described_class.new(path: path, clock: clock, id_generator: -> { pending_ids.shift }, pid_alive: ->(pid) { alive.include?(pid) })
  end

  after { FileUtils.remove_entry(dir) }

  let(:identity) { {"server_pid" => "77", "pane_pid" => 100, "agent_pid" => 101, "session_id" => "s1"} }

  def add(text = "hello", pane_id: "%5")
    store.add(pane_id: pane_id, text: text, identity: identity)
  end

  def ready_at(seconds) = Time.utc(2026, 10, 19, 12, 0, seconds)

  describe "#add" do
    it "queues entries in order, numbering positions per pane" do
      expect(add("one")).to match([:added, hash_including("id" => ids.first, "position" => 1, "state" => "queued",
        "text" => "one", "queued_at" => "2026-10-19T12:00:00.000Z", "pane_pid" => 100, "session_id" => "s1")])
      expect(add("two", pane_id: "%6").last["position"]).to eq(1)
      expect(add("three").last["position"]).to eq(2)
      expect(store.entries(pane_id: "%5").map { |e| e["text"] }).to eq(%w[one three])
      expect(store.pane_ids).to eq(%w[%5 %6])
    end

    it "refuses a ninth entry for one pane" do
      8.times { add }

      expect(add).to eq([:queue_full, nil])
      expect(add(pane_id: "%6").first).to eq(:added)
    end

    it "never replaces a file it can't read" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")

      expect { add }.to raise_error(Workspace::Error, /can't be read/)
      expect(File.read(path)).to eq("{nope")
    end
  end

  it "reads a missing file as empty without creating it" do
    expect(store.entries).to eq([])
    expect(File.exist?(path)).to be(false)
  end

  describe "#claim" do
    it "claims the head entry once the pane is ready, recording the readiness it went by" do
      add("one")
      add("two")

      entry, reaped = store.claim("%5", daemon_pid: 4242) { ready_at(1) }

      expect(entry).to include("text" => "one", "state" => "delivering", "daemon_pid" => 4242,
        "claimed_at" => "2026-10-19T12:00:00.000Z", "claimed_fresh_since" => "2026-10-19T12:00:01.000Z")
      expect(reaped).to eq([])
      expect(store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first).to be_nil
    end

    it "claims nothing when the pane isn't ready" do
      add

      expect(store.claim("%5", daemon_pid: 4242) { nil }.first).to be_nil
      expect(store.entries.first["state"]).to eq("queued")
    end

    it "takes one entry per turn end: readiness must be later than the last delivery" do
      add("one")
      add("two")
      first, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      now[0] = ready_at(3)
      store.start_paste(first)
      store.finish(first, :delivered)

      expect(store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first).to be_nil
      expect(store.claim("%5", daemon_pid: 4242) { ready_at(3) }.first).to be_nil
      expect(store.claim("%5", daemon_pid: 4242) { ready_at(4) }.first).to include("text" => "two")
    end

    it "puts back an abandoned claim whose paste never started" do
      add
      store.claim("%5", daemon_pid: 999) { ready_at(1) }

      entry, reaped = store.claim("%5", daemon_pid: 4242) { ready_at(1) }

      expect(reaped).to eq([])
      expect(entry).to include("daemon_pid" => 4242)
    end

    it "drops an abandoned claim whose paste may have started, as the caller's to report" do
      add("one")
      add("two")
      first, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      store.start_paste(first)
      now[0] += described_class::STALE_CLAIM + 1

      entry, reaped = store.claim("%5", daemon_pid: 4242) { ready_at(1) }

      expect(reaped.map { |e| e["text"] }).to eq(["one"])
      expect(entry).to include("text" => "two")
    end

    it "leaves a live, recent claim alone" do
      add("one")
      add("two")
      store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      now[0] += described_class::STALE_CLAIM - 1

      expect(store.claim("%5", daemon_pid: 4242) { ready_at(2) }).to eq([nil, []])
    end

    it "waits for the head while a later entry of the pane is delivering" do
      add("one")
      add("two")
      first, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      store.finish(first, :requeue)
      raw = JSON.parse(File.read(path))
      raw["entries"].reverse!
      File.write(path, JSON.generate(raw))
      second, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      raw = JSON.parse(File.read(path))
      raw["entries"].reverse!
      File.write(path, JSON.generate(raw))

      expect(second).to include("text" => "two")
      expect(store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first).to be_nil
    end

    it "never lets a claim that was reaped and taken again start or finish the paste" do
      add
      stale, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      now[0] += described_class::STALE_CLAIM + 1
      current, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }

      expect(store.start_paste(stale)).to eq(:missing)
      expect(store.finish(stale, :drop)).to be_nil
      expect(store.start_paste(current)).to eq(:started)
      expect(store.start_paste(current)).to eq(:missing)
    end

    it "takes an unreadable last delivery as none" do
      add
      raw = JSON.parse(File.read(path))
      raw["panes"] = {"%5" => {"last_delivered_at" => "garbage"}}
      File.write(path, JSON.generate(raw))

      expect(store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first).not_to be_nil
    end

    it "lets one of two threads racing for the head claim it" do
      add
      claims = Array.new(2) { Thread.new { store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first } }.map(&:value)

      expect(claims.compact.size).to eq(1)
    end
  end

  it "refuses a file with entries that aren't objects instead of dropping them" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("entries" => ["x"], "panes" => {}))

    expect { add }.to raise_error(Workspace::Error, /can't be read/)
  end

  it "doesn't rewrite the file when nothing changed" do
    add
    before = File.mtime(path)
    File.utime(before - 60, before - 60, path)

    store.bind_session("%5", "s1")
    store.claim("%5", daemon_pid: 4242) { nil }

    expect(File.mtime(path)).to eq(before - 60)
  end

  describe "#start_paste and #finish" do
    before { add("one") }

    let!(:claimed) { store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first }

    it "removes a delivered entry and keeps the paste time as the pane's last delivery" do
      now[0] = ready_at(2)
      expect(store.start_paste(claimed)).to eq(:started)
      now[0] = ready_at(5)

      expect(store.finish(claimed, :delivered)).to include("paste_started_at" => "2026-10-19T12:00:02.000Z")
      expect(store.entries).to eq([])
      expect(JSON.parse(File.read(path))["panes"]).to eq("%5" => {"last_delivered_at" => "2026-10-19T12:00:02.000Z"})
    end

    it "restarts the claim's clock at the paste, so a long wait for the delivery lock doesn't get it reaped mid-paste" do
      now[0] += described_class::STALE_CLAIM - 1
      store.start_paste(claimed)
      now[0] += described_class::STALE_CLAIM - 1

      expect(store.claim("%5", daemon_pid: 4242) { ready_at(1) }).to eq([nil, []])
      expect(store.entries.first).to include("state" => "delivering")
    end

    it "puts a requeued entry back at the head with no claim" do
      add("two")
      store.start_paste(claimed)

      store.finish(claimed, :requeue)

      expect(store.entries.first).to include("text" => "one", "state" => "queued")
      expect(store.entries.first.keys).not_to include("daemon_pid", "claimed_at", "claimed_fresh_since", "paste_started_at")
    end

    it "removes a dropped entry without touching the last delivery" do
      store.finish(claimed, :drop)

      expect(store.entries).to eq([])
      expect(JSON.parse(File.read(path))["panes"]).to eq({})
    end

    it "types nothing for an entry cancelled while claimed" do
      expect(store.cancel(claimed["id"]).first).to eq(:cancel_requested)

      expect(store.start_paste(claimed)).to eq(:cancelled)
      expect(store.entries).to eq([])
    end

    it "says an entry is gone" do
      store.finish(claimed, :drop)

      expect(store.start_paste(claimed)).to eq(:missing)
      expect(store.finish(claimed, :drop)).to be_nil
    end

    it "rejects an unknown outcome" do
      expect { store.finish(claimed, :lost) }.to raise_error(ArgumentError)
    end
  end

  describe "#proceed" do
    before { add("one") }

    let!(:claimed) { store.claim("%5", daemon_pid: 4242) { ready_at(1) }.first }

    it "lets a current claim go on, marking nothing, so it can still be cancelled" do
      expect(store.proceed(claimed)).to eq(:ok)
      expect(store.entries.first.keys).not_to include("paste_started_at")
      expect(store.cancel(claimed["id"]).first).to eq(:cancel_requested)
    end

    it "removes an entry cancelled while claimed" do
      store.cancel(claimed["id"])

      expect(store.proceed(claimed)).to eq(:cancelled)
      expect(store.entries).to eq([])
    end

    it "says a claim that is no longer current is missing" do
      store.finish(claimed, :requeue)

      expect(store.proceed(claimed)).to eq(:missing)
    end
  end

  it "moves a pane's entries from one conversation to the next" do
    add("one")
    add("two")
    add("other", pane_id: "%6")
    identity["session_id"] = "s0"
    add("older")

    expect(store.rebind_session("%5", from: "s1", to: "s2")).to eq(2)
    expect(store.entries.map { |e| [e["text"], e["session_id"]] })
      .to eq([["one", "s2"], ["two", "s2"], ["other", "s1"], ["older", "s0"]])
    expect(store.rebind_session("%5", from: nil, to: "s3")).to eq(0)
  end

  describe "#cancel" do
    it "removes a queued entry, refuses one being pasted, and doesn't know a gone one" do
      add("one")
      add("two")
      first, = store.claim("%5", daemon_pid: 4242) { ready_at(1) }
      store.start_paste(first)

      expect(store.cancel(first["id"]).first).to eq(:pasting)
      expect(store.cancel(ids[1]).first).to eq(:cancelled)
      expect(store.cancel(ids[1])).to eq([:unknown, nil])
    end
  end

  it "binds the first session id seen to entries queued without one" do
    identity["session_id"] = nil
    add
    add(pane_id: "%6")

    expect(store.bind_session("%5", "s9")).to eq(1)
    expect(store.entries.map { |e| e["session_id"] }).to eq(["s9", nil])
  end

  it "drops the queued entries the block names a reason for" do
    add("one")
    add("two")
    add("three", pane_id: "%6")

    dropped = store.drop_queued("%5") { |e| (e["text"] == "two") ? "pane_gone" : nil }

    expect(dropped.map { |e, reason| [e["text"], reason] }).to eq([["two", "pane_gone"]])
    expect(store.entries.map { |e| e["text"] }).to eq(%w[one three])
  end

  it "marks an entry announced and gives its position" do
    add("one")
    add("two")

    expect(store.announce(ids[1])).to include("announced" => true, "position" => 2)
    expect(store.announce("nope")).to be_nil
  end
end
