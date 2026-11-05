require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::SpineWriter do
  around do |example|
    Dir.mktmpdir("spine-writer") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  subject(:writer) { described_class.new }

  let(:updated) { "2026-10-17T22:01:00Z" }

  def stage(bytes, name: "40-verify.md")
    path = File.join(@dir, name)
    File.binwrite(path, bytes)
    path
  end

  def set(path, status: "completed", note: nil, owner: nil, by: "person", if_revision: nil)
    values = {"status" => status, "note" => note, "owner" => owner}.compact
    writer.write(path, relative: File.basename(path), values: values, by: by, updated: updated, if_revision: if_revision)
  end

  it "keeps every byte outside the four keys: comments, unknown keys, block lists, CRLF and a BOM" do
    original = "\xEF\xBB\xBF---\r\nspine: 1\r\n# a comment\r\nstatus: in_progress\r\ntitle: Verify\r\nnote: old reason\r\nartifacts:\r\n  - a.md\r\n  - b.md\r\nowner: \"%6\"\r\nweird key: [not\r\n---\r\n\r\n# Body\r\n\r\n- [ ] one\r\n".b
    path = stage(original)

    result = set(path, note: "all green")

    expect(result).to have_attributes(changed: true, previous: "in_progress", status: "completed", note: "all green")
    expected = original.sub("status: in_progress\r\n", "status: completed\r\n").sub("note: old reason\r\n", "note: all green\r\n")
      .sub("weird key: [not\r\n", "weird key: [not\r\nupdated: 2026-10-17T22:01:00Z\r\nupdated_by: person\r\n")
    expect(File.binread(path)).to eq(expected)
    expect(result.revision).to eq(Workspace::SpineFile.read(path).revision)
  end

  it "adds missing keys at the end of the block, in the file's line ending" do
    path = stage("---\ntitle: Verify\n---\nBody\n")

    set(path, status: "blocked", note: "waiting on CI")

    expect(File.binread(path)).to eq("---\ntitle: Verify\nstatus: blocked\nnote: waiting on CI\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\nBody\n")
  end

  it "adds keys to an empty block" do
    path = stage("---\n---\nBody\n")

    set(path, status: "in_progress")

    expect(File.binread(path)).to eq("---\nstatus: in_progress\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\nBody\n")
  end

  it "clears the note when the status changes and none is given, and keeps it when the status stays" do
    path = stage("---\nstatus: blocked\nnote: why\n---\n")

    expect(set(path, status: "blocked")).to have_attributes(changed: false, note: "why")
    expect(File.binread(path)).to eq("---\nstatus: blocked\nnote: why\n---\n")

    set(path, status: "in_progress")
    expect(File.binread(path)).not_to include("note:")
    expect(File.binread(path)).to include("status: in_progress\n")
  end

  it "removes the items of a list under a key it rewrites, and nothing else" do
    path = stage("---\nnote:\n  - a\n  - b\nstatus: blocked\n---\n")

    set(path, status: "blocked", note: "one line")

    expect(File.binread(path)).to eq("---\nnote: one line\nstatus: blocked\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\n")
  end

  it "does not write when the status and note already read as asked" do
    path = stage("---\nstatus: done\nnote: fine\n---\n")
    before = File.stat(path).mtime

    result = set(path, status: "completed", note: "fine")

    expect(result.changed).to be(false)
    expect(File.stat(path).mtime).to eq(before)
    expect(File.binread(path)).to eq("---\nstatus: done\nnote: fine\n---\n")
  end

  it "quotes a note a plain reader or a YAML reader would take differently" do
    path = stage("---\nstatus: blocked\n---\n")

    set(path, status: "in_progress", note: "waiting: on CI")
    expect(File.binread(path)).to include("note: \"waiting: on CI\"\n")
    expect(Workspace::SpineFile.read(path).value("note")).to eq("waiting: on CI")

    set(path, status: "blocked", note: "[x] done")
    expect(Workspace::SpineFile.read(path).value("note")).to eq("[x] done")

    set(path, status: "skipped", note: "yes")
    expect(File.binread(path)).to include("note: \"yes\"\n")
  end

  it "quotes a note a YAML reader would read as a date or a number" do
    path = stage("---\nstatus: blocked\n---\n")

    set(path, note: "2026-10-17")
    expect(File.binread(path)).to include("note: \"2026-10-17\"\n")

    set(path, status: "skipped", note: "0x1f")
    expect(File.binread(path)).to include("note: \"0x1f\"\n")
  end

  it "removes the continuation lines of a block scalar it rewrites" do
    path = stage("---\nnote: |\n  line one\n  line two\nstatus: blocked\n---\n")

    set(path, status: "blocked", note: "short")

    expect(File.binread(path)).to eq("---\nnote: short\nstatus: blocked\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\n")
  end

  it "removes a second copy of a key it writes, since a YAML reader would take that one" do
    path = stage("---\nstatus: blocked\nnote: a\nnote: b\n  more\nowner: me\n---\n")

    set(path, status: "blocked", note: "c")

    expect(File.binread(path)).to eq("---\nstatus: blocked\nnote: c\nowner: me\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\n")
    expect(Workspace::SpineFile.read(path).warnings).to eq([])
  end

  it "clears an existing note with an empty one" do
    path = stage("---\nstatus: blocked\nnote: old\n---\n")

    set(path, status: "blocked", note: "")

    expect(File.binread(path)).to eq("---\nstatus: blocked\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\n")
  end

  it "keeps the file mode and leaves no temp file behind" do
    path = stage("---\nstatus: blocked\n---\n")
    File.chmod(0o640, path)

    set(path, status: "completed")

    expect(File.stat(path).mode & 0o777).to eq(0o640)
    expect(Dir.children(@dir)).to eq(["40-verify.md"])
  end

  describe "--if-revision" do
    it "refuses a different revision with the current revision and status, and changes nothing" do
      path = stage("---\nstatus: in_progress\n---\n")
      current = Workspace::SpineFile.read(path).revision

      expect { set(path, if_revision: "deadbeef") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("stale_revision")
        expect(e.details).to eq("revision" => current, "status" => "in_progress")
      }
      expect(File.binread(path)).to eq("---\nstatus: in_progress\n---\n")
    end

    it "writes when the revision matches, in any case" do
      path = stage("---\nstatus: in_progress\n---\n")

      expect(set(path, if_revision: Workspace::SpineFile.read(path).revision.upcase).changed).to be(true)
    end
  end

  describe "owner" do
    it "changes only the owner line, updated and updated_by, byte for byte" do
      original = "\xEF\xBB\xBF---\r\nspine: 1\r\n# c\r\nstatus: in_progress\r\nowner: \"%6\"\r\nnote: keep me\r\ntags:\r\n  - a\r\n---\r\n\r\n# Body\r\n".b
      path = stage(original)

      result = set(path, status: nil, owner: "%9")

      expect(result).to have_attributes(changed: true, previous: "in_progress", status: "in_progress", owner: "%9", previous_owner: "%6", note: "keep me")
      expected = original.sub('owner: "%6"', 'owner: "%9"').sub("  - a\r\n", "  - a\r\nupdated: 2026-10-17T22:01:00Z\r\nupdated_by: person\r\n")
      expect(File.binread(path)).to eq(expected)
    end

    it "adds a missing owner and clears it with an empty value" do
      path = stage("---\nstatus: blocked\n---\nBody\n")

      set(path, status: nil, owner: "claude %6")
      expect(File.read(path)).to eq("---\nstatus: blocked\nowner: claude %6\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\nBody\n")

      result = set(path, status: nil, owner: "")
      expect(result).to have_attributes(changed: true, owner: nil)
      expect(File.read(path)).not_to include("owner")
    end

    it "writes nothing when the owner is already that value" do
      path = stage("---\nstatus: blocked\nowner: you\n---\n")
      expect(set(path, status: nil, owner: "you")).to have_attributes(changed: false, owner: "you")
      expect(File.read(path)).to eq("---\nstatus: blocked\nowner: you\n---\n")
    end

    it "changes only the note when given a note alone, keeping the status line as written" do
      path = stage("---\nstatus: done\n---\n")
      set(path, status: nil, note: "why")
      expect(File.read(path)).to eq("---\nstatus: done\nnote: why\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\n")
    end

    it "keeps the owner when the status changes" do
      path = stage("---\nstatus: blocked\nowner: you\n---\n")
      expect(set(path, status: "completed")).to have_attributes(owner: "you")
    end
  end

  describe "refusals (spine_unwritable)" do
    def reason_of(path)
      set(path)
      raise "no refusal"
    rescue Workspace::Error => e
      expect(e.code).to eq("spine_unwritable")
      e.details["reason"]
    end

    it "refuses a linked file and leaves its target alone" do
      target = File.join(@dir, "target.md")
      File.write(target, "---\nstatus: blocked\n---\n")
      link = File.join(@dir, "40-verify.md")
      File.symlink(target, link)

      expect(reason_of(link)).to eq("link")
      expect(File.read(target)).to eq("---\nstatus: blocked\n---\n")
    end

    it "refuses a file that is not a regular file" do
      path = File.join(@dir, "40-verify.md")
      Dir.mkdir(path)

      expect(reason_of(path)).to eq("not_a_file")
    end

    it "refuses a change the reader would not see: the closing --- pushed past line 100, or the status past the 40-key cap" do
      comments = stage("---\n" + ("#c\n" * 96) + "---\nBody\n")
      expect(reason_of(comments)).to eq("unreadable_result")
      expect(File.binread(comments)).to eq("---\n" + ("#c\n" * 96) + "---\nBody\n")

      keys = stage("---\n" + (1..40).map { |i| "k#{i}: x\n" }.join + "status: todo\n---\n", name: "50-keys.md")
      expect(reason_of(keys)).to eq("unreadable_result")
    end

    it "refuses a named pipe without opening it" do
      path = File.join(@dir, "40-verify.md")
      File.mkfifo(path)

      expect(reason_of(path)).to eq("not_a_file")
    end

    it "refuses a file with no closing ---, or no frontmatter" do
      expect(reason_of(stage("---\nstatus: blocked\nBody\n"))).to eq("no_frontmatter")
      expect(reason_of(stage("Body only\n"))).to eq("no_frontmatter")
      expect(File.read(File.join(@dir, "40-verify.md"))).to eq("Body only\n")
    end

    it "refuses a file over the size cap" do
      path = stage("---\nstatus: blocked\n---\n" + ("x" * Workspace::SpineFile::MAX_BYTES))

      expect(reason_of(path)).to eq("too_large")
    end

    it "refuses bytes that are not UTF-8" do
      path = stage("---\nstatus: blocked\ntitle: caf\xE9\n---\n".b)

      expect(reason_of(path)).to eq("not_utf8")
    end

    it "refuses a file that is gone" do
      expect(reason_of(File.join(@dir, "40-verify.md"))).to eq("missing")
    end

    it "starts over once when the file changes under it, then refuses" do
      path = stage("---\nstatus: blocked\n---\n")
      calls = 0
      allow(writer).to receive(:replace_unless_changed).and_wrap_original do |original, *args|
        calls += 1
        File.binwrite(path, "---\nstatus: blocked\n---\nedited #{calls}\n")
        original.call(*args)
      end

      expect(reason_of(path)).to eq("changed_while_writing")
      expect(calls).to eq(2)
      expect(File.read(path)).to end_with("edited 2\n")
      expect(Dir.children(@dir)).to eq(["40-verify.md"])
    end
  end
end
