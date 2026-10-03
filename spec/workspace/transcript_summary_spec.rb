require "tmpdir"

RSpec.describe Workspace::TranscriptSummary do
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
end
