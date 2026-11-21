require "spec_helper"

load File.join(PROJECT_ROOT, "script", "demo-calculator")

RSpec.describe DemoCalculator::Wait do
  let(:t0) { Time.utc(2026, 11, 21, 4, 0, 0) }

  def item(id, state) = {"id" => id, "state" => state}

  def stop(row, now: t0 + 60, held_since: {}, held_limit: 1200, timeout: 14_400)
    described_class.stop_reason(row, now: now, started_at: t0, held_since: held_since, held_limit: held_limit, timeout: timeout)
  end

  describe ".parse_duration" do
    it "reads seconds, minutes and hours" do
      expect(%w[45s 20m 4h].map { |text| described_class.parse_duration(text) }).to eq([45, 1200, 14_400])
    end

    it "rejects anything else" do
      %w[20 m 1d 1.5h -5m].each { |text| expect { described_class.parse_duration(text) }.to raise_error(ArgumentError, /not a duration/) }
    end
  end

  describe ".stop_reason" do
    it "keeps waiting while items are queued, starting or active" do
      expect(stop({"state" => "on", "items" => [item("a", "active"), item("b", "queued")]})).to be_nil
    end

    it "stops empty when no items are left" do
      expect(stop({"state" => "on", "items" => []})).to eq("reason" => "empty", "item" => nil)
      expect(stop({})).to eq("reason" => "empty", "item" => nil)
    end

    it "stops paused, naming a held item when there is one" do
      expect(stop({"state" => "paused", "items" => [item("a", "queued")]})).to eq("reason" => "paused", "item" => nil)
      expect(stop({"state" => "paused", "items" => [item("a", "held")]})).to eq("reason" => "paused", "item" => "a")
    end

    it "stops held only once an item has been held for the limit" do
      row = {"state" => "on", "items" => [item("a", "held")]}
      expect(stop(row, now: t0 + 1199, held_since: {"a" => t0})).to be_nil
      expect(stop(row, now: t0 + 1200, held_since: {"a" => t0})).to eq("reason" => "held", "item" => "a")
    end

    it "keeps waiting on a held item with no known hold time" do
      expect(stop({"state" => "on", "items" => [item("a", "held")]})).to be_nil
    end

    it "stops on timeout" do
      expect(stop({"state" => "on", "items" => [item("a", "active")]}, now: t0 + 14_400)).to eq("reason" => "timeout", "item" => nil)
    end

    it "stops disabled when the queue is off with items left, but empty when nothing is left" do
      expect(stop({"state" => "off", "items" => [item("a", "queued")]})).to eq("reason" => "disabled", "item" => nil)
      expect(stop({"state" => "off", "items" => []})["reason"]).to eq("empty")
    end

    it "prefers timeout, then paused, then disabled, then held, then empty" do
      off_held = {"state" => "off", "items" => [item("a", "held")]}
      expect(stop(off_held, now: t0 + 5000, held_since: {"a" => t0})["reason"]).to eq("disabled")
      held = {"state" => "paused", "items" => [item("a", "held")]}
      both = {now: t0 + 5000, held_since: {"a" => t0}}
      expect(stop(held, **both, timeout: 100)["reason"]).to eq("timeout")
      expect(stop(held, **both)["reason"]).to eq("paused")
      expect(stop(held.merge("state" => "on"), **both)["reason"]).to eq("held")
      expect(stop({"state" => "paused", "items" => []})["reason"]).to eq("paused")
      expect(stop({"state" => "on", "items" => []}, now: t0 + 20_000)["reason"]).to eq("timeout")
    end
  end

  describe ".advance?" do
    let(:idle) { {"daemon_running" => true, "items" => [item("a", "queued")]} }

    it "does not advance when the queue advances itself" do
      expect(described_class.advance?(idle, work_queue_feature: 2)).to be(false)
    end

    it "advances a queue without auto-advance when nothing is current" do
      expect(described_class.advance?(idle, work_queue_feature: 1)).to be(true)
      expect(described_class.advance?(idle, work_queue_feature: nil)).to be(true)
    end

    it "advances when the daemon is not running" do
      expect(described_class.advance?(idle.merge("daemon_running" => false), work_queue_feature: 2)).to be(true)
    end

    it "does not advance while an item is starting or active" do
      %w[starting active].each do |state|
        row = idle.merge("items" => [item("a", state), item("b", "queued")], "daemon_running" => false)
        expect(described_class.advance?(row, work_queue_feature: 1)).to be(false)
      end
    end

    it "does not advance with nothing queued" do
      expect(described_class.advance?({"items" => [item("a", "held")]}, work_queue_feature: 1)).to be(false)
      expect(described_class.advance?({"items" => []}, work_queue_feature: 1)).to be(false)
    end
  end

  describe ".held_since" do
    let(:items) { [item("a", "held"), item("b", "held"), item("c", "queued")] }
    let(:events) do
      [
        {"type" => "work_queue_item_held", "timestamp" => "2026-11-21T03:00:00.000Z", "data" => {"id" => "a"}},
        {"type" => "work_queue_item_held", "timestamp" => "2026-11-21T03:30:00.000Z", "data" => {"id" => "a"}},
        {"type" => "work_queue_item_held", "timestamp" => "2026-11-21T03:10:00.000Z", "data" => {"id" => "c"}},
        {"type" => "work_queue_paused", "timestamp" => "2026-11-21T03:40:00.000Z", "data" => {"id" => "b"}}
      ]
    end

    it "uses the newest held event, else the first sighting, and leaves out items not held" do
      seen = {"a" => t0, "b" => t0 + 30}
      expect(described_class.held_since(events: events, items: items, first_seen: seen))
        .to eq("a" => Time.utc(2026, 11, 21, 3, 30), "b" => t0 + 30)
    end

    it "leaves out a held item with neither event nor sighting" do
      expect(described_class.held_since(events: [], items: items, first_seen: {})).to eq({})
    end

    it "skips an event with an unreadable timestamp" do
      bad = [{"type" => "work_queue_item_held", "timestamp" => "soon", "data" => {"id" => "a"}}]
      expect(described_class.held_since(events: bad, items: items, first_seen: {"a" => t0})).to eq("a" => t0)
    end
  end
end
