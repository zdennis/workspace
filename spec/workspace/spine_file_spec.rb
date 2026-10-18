require "spec_helper"
require "tmpdir"
require "digest"

RSpec.describe Workspace::SpineFile do
  def parse(text) = described_class.parse(text, relative: "40-verify.md")

  def codes(file) = file.warnings.map { |w| w["code"] }

  describe "frontmatter" do
    it "reads key: value lines, strips quotes and keeps a colon in the value" do
      file = parse(%(---\nspine: 1\ntitle: "Verify: by hand"\nowner: '%6'\nstatus: in_progress\n---\nBody\n))

      expect(file.value("title")).to eq("Verify: by hand")
      expect(file.value("owner")).to eq("%6")
      expect(file.frontmatter_lines).to eq(2..5)
      expect(file.warnings).to eq([])
    end

    it "reads inline lists and indented lists, and a scalar as a list of one" do
      file = parse(<<~MD)
        ---
        depends_on: [implement, "review"]
        gates:
          - checklist
          - ci
        artifacts: [one.md, "a, b.md"]
        play: play/research
        empty: []
        ---
      MD

      expect(file.list("depends_on")).to eq(%w[implement review])
      expect(file.list("gates")).to eq(%w[checklist ci])
      expect(file.list("artifacts")).to eq(["one.md", "a, b.md"])
      expect(file.list("play")).to eq(["play/research"])
      expect(file.list("empty")).to eq([])
      expect(file.list("missing")).to eq([])
      expect(file.key_span("gates")).to eq(3..5)
    end

    it "accepts list items that are not indented" do
      file = parse("---\ngates:\n- ci\n- pr\nstatus: done\n---\n")

      expect(file.list("gates")).to eq(%w[ci pr])
      expect(file.status).to eq("completed")
      expect(file.warnings).to eq([])
    end

    it "warns bad_line with the line number for lines that are not key: value or list items" do
      file = parse("---\nstatus: done\nnot a key line\n  nested: map\n- orphan item\n[broken\n---\n")

      expect(file.warnings.map { |w| [w["code"], w["line"]] }).to eq([["bad_line", 3], ["bad_line", 4], ["bad_line", 5], ["bad_line", 6]])
      expect(file.status).to eq("completed")
    end

    it "reads a value that starts with [ but is not a whole list as text" do
      file = parse("---\ntitle: [WIP] Fix refresh\ngates: [ci, pr\n---\n")

      expect(file.value("title")).to eq("[WIP] Fix refresh")
      expect(file.value("gates")).to eq("[ci, pr")
      expect(file.warnings).to eq([])
    end

    it "reads a quoted or folded-away empty value as no value" do
      file = parse("---\ntitle: \"\"\nstatus: ''\nowner: \"​\"\n---\n")

      expect([file.value("title"), file.status_raw, file.value("owner")]).to eq([nil, nil, nil])
    end

    it "keeps the first of a repeated key, with duplicate_key, and ignores the repeat's list items" do
      file = parse("---\nstatus: done\nstatus: blocked\ngates:\n  - ci\ngates:\n  - pr\n---\n")

      expect(file.status).to eq("completed")
      expect(file.list("gates")).to eq(["ci"])
      expect(file.warnings.map { |w| [w["code"], w["line"], w["value"]] }).to eq([["duplicate_key", 3, "status"], ["duplicate_key", 6, "gates"]])
    end

    it "ignores comment and blank lines" do
      file = parse("---\n# a comment\n\nstatus: done\n---\n")

      expect(file.warnings).to eq([])
      expect(file.status).to eq("completed")
    end

    it "reads CRLF files and a byte order mark" do
      file = parse("﻿---\r\nstatus: done\r\ntitle: Hi\r\n---\r\n\r\n## Done when\r\n- [x] one\r\n")

      expect(file.status).to eq("completed")
      expect(file.value("title")).to eq("Hi")
      expect(file.done_when).to include("total" => 1, "done" => 1)
    end

    it "warns no_frontmatter when the file has none, and when the closing line is missing" do
      none = parse("# Verify\n\n- [ ] nope\n")
      unclosed = parse("---\nstatus: done\ntitle: x\n")

      expect(codes(none)).to eq(["no_frontmatter"])
      expect(codes(unclosed)).to eq(["no_frontmatter"])
      expect(unclosed.status).to eq("unknown")
      expect(unclosed.frontmatter).to eq({})
      expect(unclosed.frontmatter_lines).to be_nil
    end

    it "does not look for the closing line past line 100" do
      far = parse("---\n#{"# c\n" * 100}status: done\n---\n")
      near = parse("---\n#{"# c\n" * 97}status: done\n---\n")

      expect(codes(far)).to eq(["no_frontmatter"])
      expect(near.status).to eq("completed")
    end

    it "reads an empty file as no frontmatter" do
      expect(codes(parse(""))).to eq(["no_frontmatter"])
    end

    it "clips long values and lists, with clipped warnings" do
      items = (1..25).map { |i| "i#{i}" }.join(", ")
      file = parse("---\ntitle: #{"t" * 200}\nnote: #{"n" * 400}\nowner: #{"o" * 600}\ngates: [#{items}]\n---\n")

      expect(file.value("title").size).to eq(120)
      expect(file.value("note").size).to eq(300)
      expect(file.value("owner").size).to eq(500)
      expect(file.list("gates").size).to eq(20)
      expect(file.warnings.select { |w| w["code"] == "clipped" }.map { |w| w["value"] }).to eq(%w[title note owner gates])
    end

    it "reads at most 40 keys and ignores keys over 64 characters" do
      keys = (1..45).map { |i| "k#{i}: v" }.join("\n")
      file = parse("---\n#{"x" * 65}: v\n#{keys}\n---\n")

      expect(file.frontmatter.size).to eq(40)
      expect(codes(file).count("clipped")).to eq(2)
    end

    it "folds control and format characters out of values" do
      file = parse("---\ntitle: a‮b\tc\e[31mred\n---\n")

      expect(file.value("title")).to eq("ab c [31mred")
    end

    it "folds Unicode line separators" do
      expect(parse("---\ntitle: a b c\n---\n").value("title")).to eq("a b c")
    end

    it "warns newer_format for a spine number above 1 and still reads the file" do
      file = parse("---\nspine: 2\nstatus: done\n---\n")

      expect(file.warnings.map { |w| [w["code"], w["line"]] }).to eq([["newer_format", 2]])
      expect(file.status).to eq("completed")
    end
  end

  describe "#status" do
    {
      "not_started" => "not_started", "todo" => "not_started", "Pending" => "not_started", "planned" => "not_started", "open" => "not_started",
      "not-started" => "not_started", "NOT STARTED" => "not_started",
      "in_progress" => "in_progress", "active" => "in_progress", "started" => "in_progress", "doing" => "in_progress", "WIP" => "in_progress", "in progress" => "in_progress",
      "blocked" => "blocked", "stuck" => "blocked",
      "completed" => "completed", "done" => "completed", "complete" => "completed", "finished" => "completed", "closed" => "completed",
      "skipped" => "skipped", "skip" => "skipped", "n/a" => "skipped", "wontdo" => "skipped",
      "finished?" => "unknown", "unknown" => "unknown", "shipped" => "unknown"
    }.each do |word, canonical|
      it "reads #{word.inspect} as #{canonical}" do
        file = parse("---\nstatus: #{word}\n---\n")

        expect(file.status).to eq(canonical)
        expect(file.status_raw).to eq(word)
      end
    end

    it "is unknown, with no raw word, when status is missing or empty" do
      expect(parse("---\ntitle: x\n---\n").status).to eq("unknown")
      empty = parse("---\nstatus:\n---\n")
      expect([empty.status, empty.status_raw, empty.warnings]).to eq(["unknown", nil, []])
    end

    it "is unknown for a list" do
      expect(parse("---\nstatus: [done]\n---\n").status).to eq("unknown")
    end
  end

  describe "#done_when" do
    it "counts column-0 boxes under ## Done when up to the next heading" do
      file = parse(<<~MD)
        ---
        status: in_progress
        ---

        - [x] before the heading

        ## Done when

        - [ ] first
        - [x] second
        - [X] third
          - [ ] indented
        - [~] other box
        text

        ## Notes

        - [ ] after
      MD

      expect(file.done_when["total"]).to eq(3)
      expect(file.done_when["done"]).to eq(2)
      expect(file.done_when["items"].first).to eq("text" => "first", "done" => false, "line" => 9)
    end

    it "ignores fenced code and HTML comments" do
      file = parse("---\nstatus: x\n---\n## Done when\n```\n- [ ] in fence\n```\n<!--\n- [ ] in comment\n-->\n- [ ] real\n")

      expect(file.done_when["items"].map { |i| i["text"] }).to eq(["real"])
    end

    it "is empty without the heading" do
      expect(parse("---\nstatus: done\n---\n- [ ] loose\n").done_when).to eq("total" => 0, "done" => 0, "items" => [])
    end

    it "reads the checklist of a file with no frontmatter" do
      expect(parse("## Done when\n- [x] a\n").done_when["total"]).to eq(1)
    end
  end

  describe ".read" do
    around do |example|
      Dir.mktmpdir("spine-file") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    it "reports path, a short SHA-256 of every byte, and the modification time" do
      path = File.join(@dir, "40-verify.md")
      File.binwrite(path, "---\nstatus: done\n---\n")
      File.utime(Time.utc(2026, 10, 17, 21, 40, 2), Time.utc(2026, 10, 17, 21, 40, 2), path)

      file = described_class.read(path, relative: "40-verify.md")

      expect(file.path).to eq(path)
      expect(file.revision).to eq(Digest::SHA256.hexdigest("---\nstatus: done\n---\n")[0, 8])
      expect(file.modified_at).to eq("2026-10-17T21:40:02Z")
      expect(file.read?).to be true
    end

    it "changes the revision when any byte changes, and only then" do
      path = File.join(@dir, "a.md")
      File.binwrite(path, "---\nstatus: done\n---\n")
      first = described_class.read(path).revision
      File.utime(Time.now + 60, Time.now + 60, path)
      expect(described_class.read(path).revision).to eq(first)

      File.binwrite(path, "---\nstatus: done\n---\n ")
      expect(described_class.read(path).revision).not_to eq(first)
      File.binwrite(path, "---\r\nstatus: done\r\n---\r\n")
      expect(described_class.read(path).revision).not_to eq(first)
    end

    it "reads the first 64 KB of a larger file, with too_large, and hashes all of it" do
      path = File.join(@dir, "big.md")
      body = "---\nstatus: done\n---\n" + ("x" * 100) + "\n"
      File.binwrite(path, body + ("y" * 70_000))

      file = described_class.read(path)

      expect(file.truncated).to be true
      expect(codes(file)).to eq(["too_large"])
      expect(file.status).to eq("completed")
      expect(file.revision).to eq(Digest::SHA256.hexdigest(body + ("y" * 70_000))[0, 8])
    end

    it "does not split a multibyte character at the 64 KB cut" do
      path = File.join(@dir, "wide.md")
      File.binwrite(path, "---\nstatus: done\n---\n" + ("é" * 40_000))

      file = described_class.read(path)

      expect(file.truncated).to be true
      expect(codes(file)).to eq(["too_large"])
    end

    it "refuses bytes that are not UTF-8, keeping the revision" do
      path = File.join(@dir, "bin.md")
      File.binwrite(path, "---\nstatus: done\n---\n\xFF\xFE")

      file = described_class.read(path)

      expect(codes(file)).to eq(["not_utf8"])
      expect(file.read?).to be false
      expect(file.status).to eq("unknown")
      expect(file.revision).to match(/\A\h{8}\z/)
    end

    it "does not follow a link" do
      File.write(File.join(@dir, "real.md"), "---\nstatus: done\n---\n")
      File.symlink("real.md", File.join(@dir, "link.md"))

      file = described_class.read(File.join(@dir, "link.md"), relative: "link.md")

      expect(codes(file)).to eq(["link"])
      expect([file.revision, file.read?, file.status]).to eq([nil, false, "unknown"])
    end

    it "refuses a folder and a named pipe" do
      FileUtils.mkdir(File.join(@dir, "dir.md"))
      fifo = File.join(@dir, "pipe.md")
      system("mkfifo", fifo)

      expect(codes(described_class.read(File.join(@dir, "dir.md")))).to eq(["not_a_file"])
      expect(codes(described_class.read(fifo))).to eq(["not_a_file"])
    end

    it "treats a missing file as not_a_file instead of raising" do
      expect(codes(described_class.read(File.join(@dir, "gone.md")))).to eq(["not_a_file"])
    end

    def codes(file) = file.warnings.map { |w| w["code"] }
  end

  it "never raises for arbitrary bytes" do
    random = Random.new(7)
    200.times do
      bytes = Array.new(random.rand(0..300)) { random.rand(256) }.pack("C*")
      bytes = "---\n#{bytes}" if random.rand(2).zero?
      expect { described_class.parse(bytes) }.not_to raise_error
    end
  end
end
