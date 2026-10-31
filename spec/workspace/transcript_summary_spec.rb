require "tmpdir"

RSpec.describe Workspace::TranscriptSummary do
  describe "#main_activity_after?" do
    let(:dir) { Dir.mktmpdir("transcript-activity") }
    let(:path) { File.join(dir, "t.jsonl") }
    let(:stop) { Time.utc(2026, 10, 31, 12, 0, 0) }
    let(:later) { "2026-10-31T12:00:01.000Z" }
    let(:earlier) { "2026-10-31T11:59:59.000Z" }

    after { FileUtils.remove_entry(dir) }

    def transcript(*records)
      File.write(path, records.map { |r| r.is_a?(String) ? r : JSON.generate(r) }.join("\n") + "\n")
    end

    def activity = summary.main_activity_after?(path, stop)

    let(:summary) { described_class.new }

    described_class::HOUSEKEEPING_RECORDS.each do |type|
      it "doesn't count #{type}" do
        transcript({"type" => type, "timestamp" => later})
        expect(activity).to be_nil
      end
    end

    %w[user assistant queue-operation api-request cost-v2].each do |type|
      it "counts #{type} stamped after the time and answers its type" do
        transcript({"type" => type, "timestamp" => later})
        expect(activity).to eq(type)
      end

      it "doesn't count #{type} stamped before the time" do
        transcript({"type" => type, "timestamp" => earlier})
        expect(activity).to be_nil
      end
    end

    it "finds a record that sits before an older one, since records aren't in time order" do
      transcript({"type" => "api-request", "timestamp" => later}, {"type" => "user", "timestamp" => earlier})
      expect(activity).to eq("api-request")
    end

    it "doesn't count sidechain records" do
      transcript({"type" => "assistant", "timestamp" => later, "isSidechain" => true})
      expect(activity).to be_nil
    end

    it "skips unstamped records" do
      transcript({"type" => "api-request-blob"})
      expect(activity).to be_nil
    end

    it "counts a line it can't parse, such as one still being written" do
      transcript({"type" => "system", "timestamp" => later}, %({"type":"assist))
      expect(activity).to eq("unreadable")
    end

    it "counts a stamp it can't read" do
      transcript({"type" => "user", "timestamp" => "soon"})
      expect(activity).to eq("unreadable")
    end

    it "counts an unreadable transcript" do
      expect(summary.main_activity_after?(File.join(dir, "gone.jsonl"), stop)).to eq("unreadable")
      expect(summary.main_activity_after?(nil, stop)).to eq("unreadable")
      expect(summary.main_activity_after?(dir, stop)).to eq("unreadable")
    end

    it "reads the tail of a large transcript" do
      filler = JSON.generate({"type" => "user", "timestamp" => earlier, "pad" => "x" * 2000})
      transcript(*Array.new(400) { filler }, {"type" => "queue-operation", "timestamp" => later})
      expect(activity).to eq("queue-operation")
    end

    context "with the structure of a real transcript" do
      let(:fixture) { File.expand_path("../fixtures/claude_transcripts/turn_end_then_wake_up.jsonl", __dir__) }
      let(:records) { File.readlines(fixture).map { |line| JSON.parse(line) } }
      let(:turn_end) { Time.iso8601(records.find { |r| r["subtype"] == "stop_hook_summary" }["timestamp"]) }

      it "holds structure only" do
        expect(records.flat_map(&:keys).uniq - %w[type subtype operation timestamp isSidechain isMeta]).to be_empty
      end

      it "finds nothing in the turn end's own records" do
        wake_up = records.index { |r| r["type"] == "queue-operation" }
        transcript(*records.first(wake_up))

        expect(activity_at(turn_end)).to be_nil
      end

      it "finds the later wake-up" do
        expect(summary.main_activity_after?(fixture, turn_end)).not_to be_nil
      end

      def activity_at(time) = summary.main_activity_after?(path, time)
    end
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:summary) { described_class.new }

  after { FileUtils.remove_entry(tmpdir) }

  def transcript(*entries, name: "t.jsonl")
    File.join(tmpdir, name).tap { |path| File.write(path, entries.map { |e| e.is_a?(String) ? e : JSON.generate(e) }.join("\n") + "\n") }
  end

  def assistant(*blocks, **extra)
    {"type" => "assistant", "message" => {"role" => "assistant", "content" => blocks}, "timestamp" => "2026-10-02T10:00:00.000Z"}.merge(extra)
  end

  def text(value) = {"type" => "text", "text" => value}

  it "returns the text of the last assistant message with its timestamp" do
    path = transcript(assistant(text("first")), assistant(text("all done")))

    expect(summary.last_assistant_message(path)).to eq("text" => "all done", "truncated" => false, "at" => "2026-10-02T10:00:00.000Z")
  end

  it "joins the text blocks and skips tool calls and thinking" do
    path = transcript(assistant({"type" => "thinking", "thinking" => "hmm"}, text("part one"), {"type" => "tool_use", "name" => "Bash"}, text("part two")))

    expect(summary.last_assistant_message(path)["text"]).to eq("part one\npart two")
  end

  it "skips a final assistant entry that has no text, such as a tool call" do
    path = transcript(assistant(text("the report")), assistant({"type" => "tool_use", "name" => "Bash"}))

    expect(summary.last_assistant_message(path)["text"]).to eq("the report")
  end

  it "skips sub-agent (sidechain) messages and user lines" do
    path = transcript(
      assistant(text("main answer")),
      assistant(text("sub-agent chatter"), "isSidechain" => true),
      {"type" => "user", "message" => {"role" => "user", "content" => "a prompt"}}
    )

    expect(summary.last_assistant_message(path)["text"]).to eq("main answer")
  end

  it "skips a malformed line" do
    path = transcript(assistant(text("good")), "{not json \"assistant\"")

    expect(summary.last_assistant_message(path)["text"]).to eq("good")
  end

  it "cuts a long message and says so" do
    path = transcript(assistant(text("x" * (described_class::MAX_LENGTH + 10))))

    result = summary.last_assistant_message(path)

    expect(result["text"].length).to eq(described_class::MAX_LENGTH)
    expect(result["truncated"]).to be(true)
  end

  it "reads only the tail of a large transcript and drops the partial first line" do
    filler = assistant(text("old " * 100))
    lines = Array.new(described_class::TAIL_BYTES / 100) { filler } + [assistant(text("newest"))]
    path = transcript(*lines)

    expect(File.size(path)).to be > described_class::TAIL_BYTES
    expect(summary.last_assistant_message(path)["text"]).to eq("newest")
  end

  it "is nil when the tail holds no assistant text" do
    path = transcript({"type" => "user", "message" => {"role" => "user", "content" => "hi"}})

    expect(summary.last_assistant_message(path)).to be_nil
  end

  it "is nil for a nil path, a path that isn't .jsonl, a directory and a missing file" do
    other = File.join(tmpdir, "t.txt").tap { |p| File.write(p, "x") }
    dir = File.join(tmpdir, "d.jsonl").tap { |p| Dir.mkdir(p) }

    [nil, other, dir, File.join(tmpdir, "missing.jsonl")].each do |path|
      expect(summary.last_assistant_message(path)).to be_nil
    end
  end

  it "scrubs bytes that aren't valid UTF-8" do
    path = File.join(tmpdir, "bad.jsonl")
    File.binwrite(path, JSON.generate(assistant(text("ok"))).sub("ok", "o\xFFk") + "\n")

    expect(summary.last_assistant_message(path)["text"]).to be_a(String)
  end

  describe "#last_turn_record" do
    def error_line(**extra)
      assistant(text("API Error: 500"), **{"uuid" => "u-err", "isApiErrorMessage" => true, "error" => "unknown", "isSidechain" => false}.merge(extra))
    end

    def housekeeping = [{"type" => "last-prompt", "lastPrompt" => "go"}, {"type" => "ai-title", "aiTitle" => "T"}]

    it "reads a final error followed by housekeeping lines" do
      path = transcript(assistant(text("fine"), "uuid" => "u-ok"), error_line, *housekeeping)

      expect(summary.last_turn_record(path)).to eq("type" => "assistant", "api_error" => true, "uuid" => "u-err")
    end

    it "reads a good assistant line after an error as no error" do
      path = transcript(error_line, assistant(text("recovered"), "uuid" => "u-ok"))

      expect(summary.last_turn_record(path)).to eq("type" => "assistant", "api_error" => false, "uuid" => "u-ok")
    end

    it "ignores isApiErrorMessage that appears only inside content" do
      path = transcript(assistant(text('{"isApiErrorMessage": true}'), "uuid" => "u-1"))

      expect(summary.last_turn_record(path)["api_error"]).to be(false)
    end

    it "skips a sidechain error" do
      path = transcript(assistant(text("main"), "uuid" => "u-main"), error_line("isSidechain" => true, "uuid" => "u-side"))

      expect(summary.last_turn_record(path)).to include("api_error" => false, "uuid" => "u-main")
    end

    it "skips an isMeta user line after an error, so the error is still last" do
      path = transcript(error_line, {"type" => "user", "isMeta" => true, "uuid" => "u-meta", "message" => {"role" => "user", "content" => "caveat"}})

      expect(summary.last_turn_record(path)).to include("api_error" => true, "uuid" => "u-err")
    end

    it "counts a real user line after an error" do
      path = transcript(error_line, {"type" => "user", "isMeta" => false, "uuid" => "u-user", "message" => {"role" => "user", "content" => "retry"}})

      expect(summary.last_turn_record(path)).to eq("type" => "user", "api_error" => false, "uuid" => "u-user")
    end

    it "skips a malformed line" do
      path = transcript(error_line, "{not json")

      expect(summary.last_turn_record(path)["api_error"]).to be(true)
    end

    it "is nil for a missing file, a non-jsonl path or no turn records" do
      other = File.join(tmpdir, "t.txt").tap { |p| File.write(p, "x") }
      empty = transcript(*housekeeping, name: "e.jsonl")

      [nil, other, File.join(tmpdir, "missing.jsonl"), empty].each do |path|
        expect(summary.last_turn_record(path)).to be_nil
      end
    end
  end
end
