require "tmpdir"
require "json"

RSpec.describe Workspace::TranscriptLabel do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "session.jsonl") }

  subject(:reader) { described_class.new }

  after { FileUtils.remove_entry(dir) }

  def write(*lines)
    File.write(path, lines.map { |line| line.is_a?(String) ? line : JSON.generate(line) }.join("\n") + "\n")
  end

  def ai_title(title) = {"type" => "ai-title", "aiTitle" => title, "sessionId" => "s"}

  def last_prompt(text) = {"type" => "last-prompt", "lastPrompt" => text, "leafUuid" => "u"}

  it "returns the last ai-title in the transcript" do
    write(ai_title("First"), {"type" => "mode"}, ai_title("Second"))

    expect(reader.read(path)).to eq(title: "Second", last_prompt: nil)
  end

  it "returns the last last-prompt alongside the title" do
    write(last_prompt("one"), ai_title("T"), last_prompt("two"))

    expect(reader.read(path)).to eq(title: "T", last_prompt: "two")
  end

  it "cleans whitespace and caps each value at 80 characters" do
    write(ai_title("a\n\tb"), last_prompt("x" * 200))

    result = reader.read(path)

    expect(result[:title]).to eq("a b")
    expect(result[:last_prompt]).to eq("x" * 80)
  end

  it "ignores unparseable lines and entries of the wrong shape" do
    write("not json", '{"type":"ai-title"}', '{"type":"ai-title","aiTitle":7}', ai_title("Good"), '{"type":"ai-title","aiTit')

    expect(reader.read(path)).to eq(title: "Good", last_prompt: nil)
  end

  it "returns nil values for a missing or unreadable file and a nil or non-jsonl path" do
    expect(reader.read(File.join(dir, "missing.jsonl"))).to eq(title: nil, last_prompt: nil)
    expect(reader.read(nil)).to eq(title: nil, last_prompt: nil)
    other = File.join(dir, "notes.txt")
    File.write(other, JSON.generate(ai_title("Nope")))
    expect(reader.read(other)).to eq(title: nil, last_prompt: nil)
    expect(reader.read(dir)).to eq(title: nil, last_prompt: nil)
  end

  it "reads only the tail of a large transcript, dropping a cut first line" do
    filler = JSON.generate("type" => "x", "pad" => "p" * 1000)
    write(ai_title("Old"), *Array.new(1500, filler), ai_title("New"))

    expect(reader.read(path)[:title]).to eq("New")
    write(ai_title("Old"), *Array.new(1500, filler))
    expect(reader.read(path)[:title]).to be_nil
  end

  it "keeps the cache bounded" do
    paths = Array.new(described_class::MAX_CACHED + 5) { |i| File.join(dir, "s#{i}.jsonl").tap { |p| File.write(p, JSON.generate(ai_title("T#{i}")) + "\n") } }

    expect(paths.map { |p| reader.read(p)[:title] }).to eq(paths.each_index.map { |i| "T#{i}" })
    expect(reader.instance_variable_get(:@cache).size).to be <= described_class::MAX_CACHED
  end

  it "rereads when the file changes and not otherwise" do
    write(ai_title("One"))
    expect(reader.read(path)[:title]).to eq("One")
    allow(File).to receive(:open).and_call_original

    reader.read(path)
    expect(File).not_to have_received(:open)

    File.write(path, JSON.generate(ai_title("Two")) + "\n", mode: "a")
    expect(reader.read(path)[:title]).to eq("Two")
  end
end
