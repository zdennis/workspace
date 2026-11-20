require "tmpdir"
require "json"

RSpec.describe Workspace::WorkQueueStore do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "api", "work-queue.json") }
  let(:history_path) { File.join(dir, "api", "work-queue-history.jsonl") }
  let(:now) { Time.utc(2026, 11, 20, 12, 0, 0) }
  let(:clock) { double("clock", now: now) }
  let(:ids) { %w[aaaa1111 bbbb2222 cccc3333 dddd4444 eeee5555].each }
  let(:history) { Workspace::WorkQueueHistory.new(path: history_path, clock: clock) }
  let(:max_items) { 50 }
  let(:store) { described_class.new(path: path, history: history, clock: clock, id_generator: -> { ids.next }, max_items: max_items) }

  after { FileUtils.remove_entry(dir) }

  def add(spec = {"workflow" => "rpiv"}, **options)
    store.add(kind: "workflow", spec: spec, **options)
  end

  def order
    store.snapshot["items"].map { |i| i["id"] }
  end

  def code_of
    yield
    nil
  rescue Workspace::Error => e
    e.code
  end

  describe "#snapshot" do
    it "reads an empty queue, and makes no file, when there is none" do
      expect(store.snapshot).to eq("revision" => 0, "paused" => nil, "items" => [])
      expect(File.exist?(path)).to be(false)
    end
  end

  describe "#add" do
    it "appends a queued item with the design's fields and stable id" do
      outcome, item, position = add({"workflow" => "rpiv"}, headless: true, on_fail: "continue", dedupe_key: "k", added_by: "%3")
      expect([outcome, position]).to eq([:added, 1])
      expect(item).to include("id" => "aaaa1111", "kind" => "workflow", "spec" => {"workflow" => "rpiv"}, "headless" => true,
        "on_fail" => "continue", "added_at" => "2026-11-20T12:00:00.000Z", "added_by" => "%3", "dedupe_key" => "k",
        "state" => "queued", "started_at" => nil, "reason" => nil,
        "result" => {"run_id" => nil, "log_path" => nil, "error" => nil})
      expect(store.snapshot["items"]).to eq([item])
    end

    it "writes the file at mode 0600" do
      add
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "retries an id that is taken" do
      store
      generated = %w[aaaa1111 aaaa1111 bbbb2222].each
      other = described_class.new(path: path, history: history, clock: clock, id_generator: -> { generated.next })
      other.add(kind: "go", spec: {})
      other.add(kind: "go", spec: {})
      expect(other.snapshot["items"].map { |i| i["id"] }).to eq(%w[aaaa1111 bbbb2222])
    end

    context "with positions" do
      before { 3.times { add } }

      it "puts :top first among the queued items" do
        add({}, position: :top)
        expect(order.first).to eq("dddd4444")
      end

      it "puts a before: item before the target" do
        _, _, position = add({}, position: {before: "cccc"})
        expect(order).to eq(%w[aaaa1111 bbbb2222 dddd4444 cccc3333])
        expect(position).to eq(3)
      end

      it "puts an after: item after the target" do
        add({}, position: {after: "aaaa"})
        expect(order).to eq(%w[aaaa1111 dddd4444 bbbb2222 cccc3333])
      end

      it "puts :after_current at the top when nothing is current" do
        add({}, position: :after_current)
        expect(order.first).to eq("dddd4444")
      end

      it "puts :after_current right after the current item" do
        store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
        add({}, position: :after_current)
        expect(order).to eq(%w[aaaa1111 dddd4444 bbbb2222 cccc3333])
      end

      it "puts :top after the current item too" do
        store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
        add({}, position: :top)
        expect(order).to eq(%w[aaaa1111 dddd4444 bbbb2222 cccc3333])
      end

      it "refuses to go before the current item" do
        store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
        expect(code_of { add({}, position: {before: "aaaa"}) }).to eq("item_starting")
      end

      it "refuses an unknown target" do
        expect(code_of { add({}, position: {after: "zzzz"}) }).to eq("unknown_queue_item")
      end
    end

    it "gives unchanged for a repeated dedupe key and adds nothing" do
      add({}, dedupe_key: "k")
      revision = store.snapshot["revision"]
      outcome, item, position = add({}, dedupe_key: "k")
      expect([outcome, item["id"], position]).to eq([:unchanged, "aaaa1111", 1])
      expect(store.snapshot).to include("revision" => revision)
      expect(order).to eq(%w[aaaa1111])
    end

    context "with a cap of two" do
      let(:max_items) { 2 }

      it "refuses past it with queue_full" do
        2.times { add }
        error = begin
          add
        rescue Workspace::Error => e
          e
        end
        expect(error.code).to eq("queue_full")
        expect(error.details).to eq(limit: 2)
        expect(order.size).to eq(2)
      end
    end
  end

  describe "#find and prefixes" do
    before { 2.times { add } }

    it "finds by unique prefix" do
      expect(store.find("bb")["id"]).to eq("bbbb2222")
    end

    it "names an unknown id" do
      expect(code_of { store.find("zz") }).to eq("unknown_queue_item")
    end

    it "refuses an empty prefix as unknown, with a message that asks for an id" do
      error = begin
        store.find("")
      rescue Workspace::Error => e
        e
      end
      expect(error.code).to eq("unknown_queue_item")
      expect(error.message).to match(/Give an item id/)
      expect(code_of { store.find(nil) }).to eq("unknown_queue_item")
    end

    it "refuses a prefix of several items" do
      error = begin
        described_class.new(path: path, history: history, clock: clock, id_generator: -> { "aaaa9999" }).add(kind: "go", spec: {})
        store.find("aaaa")
      rescue Workspace::Error => e
        e
      end
      expect(error.code).to eq("ambiguous_queue_item")
      expect(error.details[:matches]).to eq(%w[aaaa1111 aaaa9999])
    end
  end

  describe "#remove" do
    before { 3.times { add } }

    it "removes queued items" do
      removed = store.remove(%w[aaaa cccc])
      expect(removed.map { |i| i["id"] }).to eq(%w[aaaa1111 cccc3333])
      expect(order).to eq(%w[bbbb2222])
    end

    it "removes none when one id is unknown" do
      expect(code_of { store.remove(%w[aaaa zzzz]) }).to eq("unknown_queue_item")
      expect(order.size).to eq(3)
    end

    it "refuses a starting item with item_starting" do
      store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
      expect(code_of { store.remove(%w[aaaa]) }).to eq("item_starting")
    end

    it "refuses an active or held item with item_active" do
      store.transaction do |q|
        item = q.claim_next(claimed_by: {"pid" => 1})
        q.record_run(item["id"], claim: item["claim"], run_id: "r1")
      end
      expect(code_of { store.remove(%w[aaaa]) }).to eq("item_active")
      store.transaction { |q| q.hold("aaaa1111", reason: "gate") }
      expect(code_of { store.remove(%w[aaaa]) }).to eq("item_active")
    end
  end

  describe "#move" do
    before { 3.times { add } }

    it "moves before, after, to the top and to the bottom" do
      expect(store.move("cccc", before: "aaaa")[0]).to eq(:moved)
      expect(order).to eq(%w[cccc3333 aaaa1111 bbbb2222])
      store.move("cccc", after: "bbbb")
      expect(order).to eq(%w[aaaa1111 bbbb2222 cccc3333])
      store.move("cccc", top: true)
      expect(order.first).to eq("cccc3333")
      store.move("cccc", bottom: true)
      expect(order.last).to eq("cccc3333")
    end

    it "returns the item and its new position" do
      _, item, position = store.move("cccc", top: true)
      expect([item["id"], position]).to eq(["cccc3333", 1])
    end

    it "gives unchanged, and bumps no revision, when nothing moves" do
      revision = store.snapshot["revision"]
      expect(store.move("aaaa", top: true)[0]).to eq(:unchanged)
      expect(store.move("cccc", bottom: true)[0]).to eq(:unchanged)
      expect(store.move("bbbb", after: "aaaa")[0]).to eq(:unchanged)
      expect(store.snapshot["revision"]).to eq(revision)
    end

    it "needs exactly one target" do
      expect { store.move("aaaa") }.to raise_error(ArgumentError)
      expect { store.move("aaaa", top: true, bottom: true) }.to raise_error(ArgumentError)
    end

    it "refuses a stale --if-revision with the current one" do
      error = begin
        store.move("cccc", top: true, if_revision: 1)
      rescue Workspace::Error => e
        e
      end
      expect(error.code).to eq("stale_revision")
      expect(error.details).to include(revision: 3, path: path)
      expect(order).to eq(%w[aaaa1111 bbbb2222 cccc3333])
    end

    it "moves when --if-revision matches" do
      expect(store.move("cccc", top: true, if_revision: 3)[0]).to eq(:moved)
    end

    it "gives unchanged when before: or after: names the item itself" do
      expect(store.move("bbbb", before: "bbbb")).to include(:unchanged)
      expect(store.move("bbbb", after: "bbb")[0]).to eq(:unchanged)
      expect(order).to eq(%w[aaaa1111 bbbb2222 cccc3333])
    end

    it "refuses before: a starting item and before: an active item" do
      store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
      expect(code_of { store.move("cccc", before: "aaaa") }).to eq("item_starting")
      store.transaction { |q| q.adopt("aaaa1111", run_id: "r") }
      expect(code_of { store.move("cccc", before: "aaaa") }).to eq("item_active")
      expect(code_of { add({}, position: {before: "aaaa"}) }).to eq("item_active")
      expect(order).to eq(%w[aaaa1111 bbbb2222 cccc3333])
    end

    it "moves after: the current item to the top of the queued items" do
      store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
      store.move("cccc", after: "aaaa")
      expect(order).to eq(%w[aaaa1111 cccc3333 bbbb2222])
    end

    it "refuses a starting item and an active item" do
      store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
      expect(code_of { store.move("aaaa", bottom: true) }).to eq("item_starting")
      store.transaction { |q| q.adopt("aaaa1111", run_id: "r1") }
      expect(code_of { store.move("aaaa", bottom: true) }).to eq("item_active")
    end

    it "keeps the current item first when another goes to the top" do
      store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1}) }
      store.move("cccc", top: true)
      expect(order).to eq(%w[aaaa1111 cccc3333 bbbb2222])
    end
  end

  describe "revision" do
    it "starts at 0 and goes up by one on each write" do
      add
      expect(store.snapshot["revision"]).to eq(1)
      add
      store.remove(%w[bbbb])
      expect(store.snapshot["revision"]).to eq(3)
    end

    it "does not change on a read or a transaction that changes nothing" do
      add
      store.transaction { |q| q.items }
      store.find("aaaa")
      expect(store.snapshot["revision"]).to eq(1)
    end

    it "does not write when the block raises" do
      add
      expect { store.transaction { |q| q.set_enabled(true) && raise("boom") } }.to raise_error("boom")
      expect(store.snapshot).to include("revision" => 1)
      expect(store.snapshot).not_to have_key("enabled")
    end
  end

  describe "toggle and pause" do
    it "leaves enabled absent until set, then keeps true and false" do
      add
      expect(store.snapshot).not_to have_key("enabled")
      expect(store.set_enabled(true)).to be(true)
      expect(store.snapshot["enabled"]).to be(true)
      expect(store.set_enabled(true)).to be(false)
      store.set_enabled(false)
      expect(store.snapshot["enabled"]).to be(false)
    end

    it "pauses with a reason and the time, keeping the first reason" do
      expect(store.pause("failed_check")).to be(true)
      expect(store.snapshot["paused"]).to eq("reason" => "failed_check", "at" => "2026-11-20T12:00:00.000Z")
      expect(store.pause("claim_lost")).to be(false)
      expect(store.snapshot["paused"]["reason"]).to eq("failed_check")
    end

    it "resumes, saying whether it was paused" do
      store.pause("x")
      expect(store.resume).to be(true)
      expect(store.snapshot["paused"]).to be_nil
      expect(store.resume).to be(false)
    end
  end

  describe "claims" do
    let(:holder) { {"pid" => 42, "started" => "Thu Nov 20 11:59:00 2026"} }

    before { 2.times { add } }

    it "claims the first queued item as starting with its claim fields" do
      item = store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(item).to include("id" => "aaaa1111", "state" => "starting", "claimed_at" => "2026-11-20T12:00:00.000Z",
        "claimed_by" => holder, "started_at" => "2026-11-20T12:00:00.000Z")
      expect(item["claim"]).to match(/\A\h{16}\z/)
      expect(store.find("aaaa")).to eq(item)
      expect(store.snapshot["items"].last).not_to have_key("claim")
    end

    it "claims nothing when no item is queued" do
      store.remove(%w[aaaa bbbb])
      expect(store.transaction { |q| q.claim_next(claimed_by: holder) }).to be_nil
    end

    it "claims nothing while a starting, active or held item exists" do
      store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(store.transaction { |q| q.claim_next(claimed_by: holder) }).to be_nil
      store.transaction { |q| q.adopt("aaaa1111", run_id: "r") }
      expect(store.transaction { |q| q.claim_next(claimed_by: holder) }).to be_nil
      store.transaction { |q| q.hold("aaaa1111", reason: "gate") }
      expect(store.transaction { |q| q.claim_next(claimed_by: holder) }).to be_nil
      expect(store.find("bbbb")["state"]).to eq("queued")
    end

    it "claims the next queued item once the current one is finished" do
      store.transaction { |q| q.claim_next(claimed_by: holder) }
      store.transaction { |q| q.finish("aaaa1111", outcome: "interrupted") }
      expect(store.transaction { |q| q.claim_next(claimed_by: holder) }["id"]).to eq("bbbb2222")
    end

    it "records the run, goes active and clears the claim fields" do
      item = store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(store.transaction { |q| q.record_run("aaaa1111", claim: item["claim"], run_id: "run-9") }).to eq(:recorded)
      stored = store.find("aaaa")
      expect(stored).to include("state" => "active")
      expect(stored["result"]).to include("run_id" => "run-9")
      expect(stored.keys & %w[claim claimed_at claimed_by]).to eq([])
    end

    it "refuses to record when the claim no longer matches" do
      store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(store.transaction { |q| q.record_run("aaaa1111", claim: "other", run_id: "r") }).to eq(:lost)
      expect(store.find("aaaa")).to include("state" => "starting")
      expect(store.find("aaaa")["result"]["run_id"]).to be_nil
    end

    it "refuses to record when the item is gone or not starting" do
      item = store.transaction { |q| q.claim_next(claimed_by: holder) }
      store.transaction { |q| q.finish("aaaa1111", outcome: "interrupted") }
      expect(store.transaction { |q| q.record_run("aaaa1111", claim: item["claim"], run_id: "r") }).to eq(:lost)
      expect(store.transaction { |q| q.record_run("bbbb2222", claim: item["claim"], run_id: "r") }).to eq(:lost)
    end

    it "adopts a starting item as active, and nothing else" do
      store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(store.transaction { |q| q.adopt("aaaa1111", run_id: "r7") }["state"]).to eq("active")
      expect(store.transaction { |q| q.adopt("aaaa1111", run_id: "r8") }).to be_nil
      expect(store.transaction { |q| q.adopt("bbbb2222", run_id: "r8") }).to be_nil
    end

    it "holds with a reason and puts a held item back to active" do
      store.transaction { |q| q.adopt(q.claim_next(claimed_by: holder)["id"], run_id: "r") }
      store.transaction { |q| q.hold("aaaa1111", reason: "gate") }
      expect(store.find("aaaa")).to include("state" => "held", "reason" => "gate")
      store.transaction { |q| q.unhold("aaaa1111") }
      expect(store.find("aaaa")).to include("state" => "active", "reason" => nil)
      expect(store.transaction { |q| q.hold("zzzz", reason: "x") }).to be_nil
    end

    it "holds only an active item and unholds only a held one, returning nil otherwise" do
      expect(store.transaction { |q| q.hold("aaaa1111", reason: "gate") }).to be_nil
      expect(store.transaction { |q| q.unhold("aaaa1111") }).to be_nil
      store.transaction { |q| q.claim_next(claimed_by: holder) }
      expect(store.transaction { |q| q.hold("aaaa1111", reason: "gate") }).to be_nil
      store.transaction { |q| q.adopt("aaaa1111", run_id: "r") }
      expect(store.transaction { |q| q.unhold("aaaa1111") }).to be_nil
      store.transaction { |q| q.hold("aaaa1111", reason: "gate") }
      expect(store.transaction { |q| q.hold("aaaa1111", reason: "parked") }).to be_nil
      expect(store.find("aaaa")["reason"]).to eq("gate")
      expect(store.find("bbbb")["state"]).to eq("queued")
      expect(store.transaction { |q| q.unhold("bbbb2222") }).to be_nil
    end
  end

  describe "finish" do
    before do
      add
      store.transaction do |q|
        item = q.claim_next(claimed_by: {"pid" => 1})
        q.record_run(item["id"], claim: item["claim"], run_id: "run-1")
      end
    end

    it "moves the item to history inside the lock, without its claim fields or state" do
      entry = store.transaction { |q| q.finish("aaaa1111", outcome: "failed", reason: "failed_check") }
      expect(store.snapshot["items"]).to eq([])
      expect(history.entries).to eq([entry])
      expect(entry).to include("id" => "aaaa1111", "outcome" => "failed", "reason" => "failed_check",
        "finished_at" => "2026-11-20T12:00:00.000Z")
      expect(entry["result"]).to include("run_id" => "run-1", "error" => nil)
      expect(entry.keys & %w[state claim claimed_at claimed_by]).to eq([])
    end

    it "records an error in the result" do
      entry = store.transaction { |q| q.finish("aaaa1111", outcome: "launch_failed", reason: "start_failed", error: "boom") }
      expect(entry["result"]["error"]).to eq("boom")
    end

    it "returns nil for an item that is gone" do
      expect(store.transaction { |q| q.finish("zzzz", outcome: "skipped") }).to be_nil
    end

    it "prunes history older than its retention on a write and keeps a recent entry" do
      old = (now - (400 * 24 * 3600)).utc.iso8601(3)
      recent = (now - (2 * 24 * 3600)).utc.iso8601(3)
      FileUtils.mkdir_p(File.dirname(history_path))
      File.write(history_path, [{"id" => "old", "finished_at" => old}, {"id" => "recent", "finished_at" => recent}].map { |e| JSON.generate(e) + "\n" }.join)
      add({}, dedupe_key: "z")
      expect(history.entries.map { |e| e["id"] }).to eq(%w[recent])
    end

    it "appends nothing to the history when the block raises after finish" do
      expect {
        store.transaction do |q|
          q.finish("aaaa1111", outcome: "failed")
          raise "boom"
        end
      }.to raise_error("boom")
      expect(store.find("aaaa")["state"]).to eq("active")
      expect(File.exist?(history_path)).to be(false)
    end

    it "appends nothing to the history when the queue file can't be written" do
      allow(Workspace::AtomicFile).to receive(:write).and_raise(Errno::EACCES)
      expect { store.transaction { |q| q.finish("aaaa1111", outcome: "failed") } }.to raise_error(Workspace::Error)
      expect(File.exist?(history_path)).to be(false)
    end

    it "gives :lost and changes nothing when the claim does not match or the item is gone" do
      add
      claimed = store.transaction do |q|
        q.finish("aaaa1111", outcome: "succeeded")
        q.claim_next(claimed_by: {"pid" => 1})
      end
      expect(claimed["id"]).to eq("bbbb2222")
      expect(store.transaction { |q| q.finish("bbbb2222", outcome: "launch_failed", claim: "other") }).to eq(:lost)
      expect(store.transaction { |q| q.finish("zzzz", outcome: "launch_failed", claim: claimed["claim"]) }).to eq(:lost)
      expect(store.find("bbbb")["state"]).to eq("starting")
      expect(history.entries.map { |e| e["id"] }).to eq(%w[aaaa1111])
      entry = store.transaction { |q| q.finish("bbbb2222", outcome: "launch_failed", claim: claimed["claim"], error: "e") }
      expect(entry).to include("outcome" => "launch_failed")
      expect(history.entries.map { |e| e["id"] }).to eq(%w[aaaa1111 bbbb2222])
    end
  end

  describe "a file that can't be read" do
    before do
      FileUtils.mkdir_p(File.dirname(path))
    end

    ["not json", "[]", '{"items": "x"}', '{"items": [], "revision": "1"}', '{"items": [], "enabled": "yes"}'].each do |content|
      it "refuses #{content.inspect}, reads and writes alike, and leaves it as it was" do
        File.write(path, content)
        expect { store.snapshot }.to raise_error(Workspace::Error, /can't be read/)
        expect { add }.to raise_error(Workspace::Error, /nothing was changed/)
        expect(File.read(path)).to eq(content)
      end
    end

    it "treats a blank file as an empty queue" do
      File.write(path, "  \n")
      expect(store.snapshot["items"]).to eq([])
    end
  end
end
