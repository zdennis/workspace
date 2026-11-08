require "tmpdir"
require "json"

RSpec.describe Workspace::SkillsState do
  let(:dir) { Dir.mktmpdir }
  let(:state) { described_class.new(dir: dir) }

  after { FileUtils.remove_entry(dir) }

  it "reads as empty when there is no file" do
    expect(state.declined).to eq([])
  end

  it "round-trips the declined keys, dropping repeats" do
    state.declined = %w[codex pi codex]
    expect(state.declined).to eq(%w[codex pi])
    expect(File.read(state.path)).to eq(JSON.pretty_generate({"declined" => %w[codex pi]}) + "\n")
  end

  it "makes the state directory" do
    nested = described_class.new(dir: File.join(dir, "a", "b"))
    nested.declined = ["pi"]
    expect(nested.declined).to eq(["pi"])
  end

  it "reads a corrupt file as empty" do
    File.write(state.path, "{nope")
    expect(state.declined).to eq([])
  end

  it "reads a file of the wrong shape as empty and keeps only strings" do
    File.write(state.path, '["x"]')
    expect(state.declined).to eq([])
    File.write(state.path, '{"declined": ["pi", 3, null]}')
    expect(state.declined).to eq(["pi"])
  end

  it "replaces a corrupt file on write and leaves no temp file" do
    File.write(state.path, "{nope")
    state.declined = ["pi"]
    expect(state.declined).to eq(["pi"])
    expect(Dir.children(dir)).to contain_exactly("skills.json", "skills.json.lock")
  end
end
