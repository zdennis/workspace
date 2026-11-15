# frozen_string_literal: true

# Keeps `.claude/CLAUDE.md` small enough to load in full. Per-file detail
# belongs in `docs/architecture/`; the index there is one short line per file.
RSpec.describe ".claude/CLAUDE.md size" do
  # Files deliberately left out of the index, each with the reason.
  let(:unlisted) { {} }

  let(:text) { File.read(File.join(PROJECT_ROOT, ".claude/CLAUDE.md")) }
  let(:section) do
    match = text.match(/^## Project Structure$(.*?)(?=^## |\z)/m)
    expect(match).not_to be_nil, "`## Project Structure` heading is missing from .claude/CLAUDE.md"
    match[1]
  end
  let(:body_lines) { section.lines.map(&:chomp).reject { |l| l.strip.empty? || l.start_with?("#") } }
  let(:file_lines) { body_lines.select { |l| l.start_with?("- `") } }
  let(:paths) { file_lines.map { |l| l[/`([^`]*)`/, 1] } }
  let(:doc_lines) do
    Dir[File.join(PROJECT_ROOT, "docs/architecture/*.md")].flat_map { |f| File.readlines(f, chomp: true) }
  end

  it "stays under 90,000 characters" do
    expect(text.length).to be <= 90_000,
      "CLAUDE.md is #{text.length} characters (Claude Code's limit is 150k). Move per-file detail to " \
      "docs/architecture/<subsystem>.md and keep one line per file."
  end

  it "keeps each Project Structure line to 300 characters" do
    long = body_lines.select { |l| l.length > 300 }.map { |l| l[0, 60] }
    expect(long).to be_empty,
      "shorten to one sentence; the full text belongs in docs/architecture/<subsystem>.md: #{long.join(" | ")}"
  end

  it "indexes more than 100 files" do
    expect(file_lines.size).to be > 100
  end

  it "has every indexed path as a bullet in some docs/architecture file" do
    missing = paths.reject { |p| doc_lines.any? { |l| l.start_with?("- `#{p}`") } }
    expect(missing).to be_empty, "missing from docs/architecture: #{missing.join(", ")}"
  end

  it "indexes each path once" do
    dupes = paths.tally.select { |_, n| n > 1 }.keys
    expect(dupes).to be_empty, "duplicate index entries: #{dupes.join(", ")}"
  end

  it "indexes every lib/workspace file" do
    files = Dir[File.join(PROJECT_ROOT, "lib/workspace/**/*.rb")].map { |f| f.delete_prefix("#{PROJECT_ROOT}/") }
    missing = (files + ["lib/workspace.rb"]) - paths - unlisted.keys
    expect(missing.sort).to be_empty,
      "add a one-line index entry under Project Structure and a full entry in docs/architecture: #{missing.sort.join(", ")}"
  end
end
