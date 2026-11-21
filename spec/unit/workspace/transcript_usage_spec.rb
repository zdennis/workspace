RSpec.describe Workspace::TranscriptUsage do
  let(:from) { Time.utc(2026, 11, 17, 12, 0, 0) }
  let(:to) { Time.utc(2026, 11, 17, 13, 0, 0) }

  def stamp(minutes) = (from + minutes * 60).utc.iso8601

  def assistant(id, minutes, extra = {}, usage: {"input_tokens" => 1, "output_tokens" => 2})
    message = {"id" => id, "model" => "claude-x"}
    message["usage"] = usage unless usage == :none
    JSON.generate({"type" => "assistant", "timestamp" => minutes && stamp(minutes), "message" => message}.merge(extra))
  end

  def scan(lines, floor: from, sidechain: false)
    Workspace::TranscriptUsage::Scan.new(from: from, to: to, floor: floor, sidechain: sidechain).feed(lines)
  end

  describe described_class::Scan do
    let(:lines) do
      [
        JSON.generate({"type" => "user", "timestamp" => stamp(-1)}),
        assistant("a", 1, usage: {"input_tokens" => 1}),
        "not json",
        assistant("b", 2, {"version" => "2.1.0"}, usage: {"input_tokens" => 5}),
        assistant(nil, 3, usage: {"output_tokens" => 7}),
        assistant("a", 4, usage: {"input_tokens" => 3, "output_tokens" => 4}),
        assistant(nil, 5, usage: {"output_tokens" => 9})
      ]
    end

    it "leaves the same state when fed in two halves as when fed all at once" do
      whole = scan(lines)
      split = Workspace::TranscriptUsage::Scan.new(from: from, to: to, floor: from)
      split.feed(lines.first(3)).feed(lines.drop(3))
      expect(split.messages).to eq(whole.messages)
      expect([split.reached?, split.unreadable?, split.seen?, split.version]).to eq([whole.reached?, whole.unreadable?, whole.seen?, whole.version])
      expect(whole.counted.map(&:usage)).to eq([{"input_tokens" => 3, "output_tokens" => 4}, {"input_tokens" => 5}, {"output_tokens" => 7}, {"output_tokens" => 9}])
    end

    it "keys a message by id: its first line decides the window and its last line's usage counts" do
      result = scan([assistant("a", -5, usage: {"input_tokens" => 1}), assistant("a", 5, usage: {"input_tokens" => 9})])
      expect(result.counted).to be_empty
      expect(result.messages["a"].usage).to eq({"input_tokens" => 9})
    end

    it "reaches back only when a line is at or before the floor" do
      expect(scan([assistant("a", 1)]).reached?).to be false
      expect(scan([assistant("a", 1)], floor: from + 60).reached?).to be true
    end

    it "leaves out sidechain lines unless the scan is a sidechain one" do
      line = assistant("a", 1, {"isSidechain" => true})
      expect(scan([line]).messages).to be_empty
      expect(scan([line], sidechain: true).counted.size).to eq(1)
    end

    it "is unreadable for a usage line with no time or a usage that is not a Hash" do
      expect(scan([assistant("a", nil)]).unreadable?).to be true
      expect(scan([assistant("a", 1, usage: 5)]).unreadable?).to be true
      expect(scan([assistant("a", 1, usage: :none)]).unreadable?).to be false
    end

    it "sees a line inside the window and records its version only then" do
      result = scan([assistant("a", -5, {"version" => "1.0.0"}), assistant("b", 90, {"version" => "3.0.0"})])
      expect([result.seen?, result.version]).to eq([false, nil])
    end
  end

  describe "a window that ends at a millisecond stamp" do
    def line(id, at) = JSON.generate({"type" => "assistant", "timestamp" => at, "message" => {"id" => id, "usage" => {"input_tokens" => 1, "output_tokens" => 2}}})

    it "keeps a message inside the last second and drops one after the end" do
      window = described_class::Scan.new(from: Time.utc(2026, 11, 17, 12, 0, 0), to: Time.iso8601("2026-11-17T12:00:05.100Z"), floor: Time.utc(2026, 11, 17, 12, 0, 0), sidechain: false)
      window.feed([line("in", "2026-11-17T12:00:05.050Z"), line("out", "2026-11-17T12:00:05.500Z")])

      expect(window.counted.size).to eq(1)
    end
  end

  describe ".read_line" do
    it "reads an assistant line's time, id, usage, model and version" do
      read = described_class.read_line(assistant("a", 1, {"version" => "2.1.0"}))
      expect(read.to_h).to eq(at: from + 60, sidechain: false, message: true, id: "a", usage: {"input_tokens" => 1, "output_tokens" => 2},
        model: "claude-x", version: "2.1.0", unreadable: false)
    end

    it "drops an invalid or synthetic model and version, and a non-String id" do
      line = JSON.generate({"type" => "assistant", "timestamp" => stamp(1), "version" => "bad version",
                            "message" => {"id" => 5, "model" => "<synthetic>", "usage" => {}}})
      expect(described_class.read_line(line).to_h.values_at(:id, :model, :version)).to eq([nil, nil, nil])
    end

    it "marks usage with no readable time or not a Hash as unreadable, and a non-assistant line as no message" do
      expect(described_class.read_line(assistant("a", nil)).unreadable).to be true
      expect(described_class.read_line(assistant("a", 1, usage: 5)).to_h.values_at(:usage, :unreadable)).to eq([nil, true])
      user = described_class.read_line(JSON.generate({"type" => "user", "timestamp" => stamp(1), "isSidechain" => true}))
      expect(user.to_h.values_at(:message, :sidechain, :unreadable)).to eq([false, true, false])
    end

    it "is nil for a line that is not a JSON object" do
      expect(described_class.read_line("not json")).to be_nil
      expect(described_class.read_line("[1]")).to be_nil
    end
  end

  describe ".transcript_path?" do
    it "takes an absolute .jsonl path and refuses others" do
      expect(described_class.transcript_path?("/tmp/a.jsonl")).to be true
      expect(described_class.transcript_path?("tmp/a.jsonl")).to be false
      expect(described_class.transcript_path?("/tmp/a\n.jsonl")).to be false
      expect(described_class.transcript_path?(nil)).to be false
    end
  end

  describe ".session_entry" do
    let(:ledger) { double("ledger", recent_entries: entries) }
    let(:start) { {"event" => "session_start", "pane_id" => "%1", "workspace" => "ws", "session_id" => "s1", "at" => stamp(-10)} }
    let(:entries) { [start] }

    def pick(**overrides)
      described_class.session_entry(ledger: ledger, names: ["ws"], pane: "%1", started: from, ended: to, server: nil, **overrides)
    end

    it "picks the latest start for the pane at or before the end" do
      expect(pick).to eq([start, false])
    end

    it "drops a session that ended before the attempt began" do
      entries << {"event" => "session_end", "session_id" => "s1", "at" => stamp(-5)}
      expect(pick).to be_nil
    end

    it "finds none with no ledger or another workspace" do
      expect(pick(ledger: nil)).to be_nil
      expect(pick(names: ["other"])).to be_nil
    end
  end

  describe ".total" do
    it "sums the counts and refuses a count that is not a whole number" do
      expect(described_class.total([{"input_tokens" => 1}, {"input_tokens" => 2, "output_tokens" => 3}])).to eq({"input_tokens" => 3, "output_tokens" => 3})
      expect(described_class.total([{"input_tokens" => -1}])).to be_nil
      expect(described_class.total([])).to be_nil
    end
  end
end
