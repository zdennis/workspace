require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PlanFile do
  def parse(text, **options) = described_class.parse(text, **options)

  def plan_text(*lines) = (lines.join("\n") + "\n")

  describe ".parse tasks" do
    it "reads one task per column-0 checklist line under ## Tasks" do
      plan = parse(plan_text("# Plan", "", "## Tasks", "", "- [ ] T1 First", "- [~] T2 Second", "- [x] T3 Third", "- [X] T4 Fourth",
        "- [-] T5 Fifth -- not needed", "- [!] T6 Sixth -- needs a key"))

      expect(plan.tasks.map { |t| [t.id, t.title, t.state, t.reason, t.line] }).to eq([
        ["T1", "First", "todo", nil, 5], ["T2", "Second", "in_progress", nil, 6], ["T3", "Third", "done", nil, 7],
        ["T4", "Fourth", "done", nil, 8], ["T5", "Fifth", "skipped", "not needed", 9], ["T6", "Sixth", "blocked", "needs a key", 10]
      ])
      expect(plan.warnings).to eq([])
    end

    it "counts the states and works out left and percent" do
      plan = parse(plan_text("## Tasks", "- [x] T1 a", "- [x] T2 b", "- [-] T3 c -- no", "- [~] T4 d", "- [!] T5 e -- why", "- [ ] T6 f"))

      expect(plan.counts).to eq("total" => 6, "done" => 2, "in_progress" => 1, "skipped" => 1, "blocked" => 1, "todo" => 1, "left" => 3)
      expect(plan.percent).to eq(50)
    end

    it "gives zero percent and no current for a plan without tasks" do
      plan = parse(plan_text("# Plan", "## Tasks"))

      expect(plan.counts["total"]).to eq(0)
      expect(plan.percent).to eq(0)
      expect(plan.current).to be_nil
    end

    it "names the first in-progress task as current, else the first to do" do
      with_progress = parse(plan_text("## Tasks", "- [ ] T1 a", "- [~] T2 b", "- [~] T3 c"))
      without = parse(plan_text("## Tasks", "- [x] T1 a", "- [ ] T2 b", "- [ ] T3 c"))
      finished = parse(plan_text("## Tasks", "- [x] T1 a"))

      expect(with_progress.current).to eq("id" => "T2", "title" => "b", "phase" => nil)
      expect(without.current).to eq("id" => "T2", "title" => "b", "phase" => nil)
      expect(finished.current).to be_nil
    end

    it "takes the phase from the nearest heading above that is not Tasks" do
      plan = parse(plan_text("## Tasks", "- [ ] T0 loose", "### Phase 1", "- [x] T1 a", "#### Step 1.1", "- [ ] T2 b", "### Phase 2", "- [ ] T3 c"))

      expect(plan.tasks.map(&:phase)).to eq([nil, "Phase 1", "Step 1.1", "Phase 2"])
      expect(plan.current).to eq("id" => "T0", "title" => "loose", "phase" => nil)
    end

    it "does not count indented checkboxes" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 a", "  - [ ] sub item", "\t- [x] tabbed"))

      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "does not count tasks outside ## Tasks" do
      plan = parse(plan_text("- [ ] T0 before", "## Tasks", "- [ ] T1 a", "## Task details", "- [ ] T2 detail", "## Notes", "- [ ] T3 note"))

      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "does not count lines that are nearly task lines, and ends Tasks at a level-1 heading" do
      plan = parse(plan_text("## Tasks", "- [ ]T1 a", "-  [ ] T2 b", "- [xx] T3 c", "* [ ] T4 d", "- [ ] T5 e", "# Appendix", "- [ ] T6 f"))

      expect(plan.tasks.map(&:id)).to eq(["T5"])
      expect(plan.warnings).to eq([])
    end

    it "keeps a trailing # in a phase name and ends Tasks at a bare ## heading" do
      plan = parse(plan_text("## Tasks", "### C#", "- [ ] T1 a", "### Closed ###", "- [ ] T2 b", "##", "- [ ] T3 c"))

      expect(plan.tasks.map { |t| [t.id, t.phase] }).to eq([["T1", "C#"], ["T2", "Closed"]])
    end

    it "matches the Tasks heading without regard to case" do
      expect(parse(plan_text("## tasks", "- [ ] T1 a")).tasks.size).to eq(1)
    end

    it "does not count fenced code, of either fence character, and counts again after it" do
      plan = parse(plan_text("## Tasks", "```", "- [ ] T1 in a fence", "```", "~~~md", "- [ ] T2 in another", "~~~", "- [ ] T3 real"))

      expect(plan.tasks.map(&:id)).to eq(["T3"])
    end

    it "does not close a fence with the other fence character" do
      plan = parse(plan_text("## Tasks", "```", "~~~", "- [ ] T1 still inside", "```", "- [ ] T2 outside"))

      expect(plan.tasks.map(&:id)).to eq(["T2"])
    end

    it "skips a byte order mark at the start of the file" do
      plan = parse("﻿---\ntitle: Hi\n---\n## Tasks\n- [ ] T1 a\n")

      expect(plan.title).to eq("Hi")
    end

    it "closes frontmatter with ... as well as ---" do
      expect(parse(plan_text("---", "title: Hi", "...", "## Tasks", "- [ ] T1 a")).title).to eq("Hi")
    end

    it "keeps a fence open until a fence at least as long closes it" do
      plan = parse(plan_text("## Tasks", "````", "```", "- [ ] T1 inside", "```", "````", "- [ ] T2 outside"))

      expect(plan.tasks.map(&:id)).to eq(["T2"])
    end

    it "reads a heading inside a fence as code, not as a heading" do
      plan = parse(plan_text("## Tasks", "```", "## Elsewhere", "```", "- [ ] T1 still in Tasks"))

      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "does not count tasks inside HTML comments, on one line or several" do
      plan = parse(plan_text("## Tasks", "<!-- - [ ] T1 hidden -->", "- [ ] T2 shown", "<!--", "- [ ] T3 hidden", "-->", "- [ ] T4 shown",
        "text <!-- inline --> more", "- [ ] T5 shown"))

      expect(plan.tasks.map(&:id)).to eq(%w[T2 T4 T5])
    end

    it "does not read a fence inside a comment" do
      plan = parse(plan_text("## Tasks", "<!--", "```", "-->", "- [ ] T1 counted"))

      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "reads a comment that never closes as hiding the rest of the file" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 a", "<!-- oops", "- [ ] T2 hidden"))

      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "reads CRLF line endings" do
      plan = parse("---\r\nstatus: paused\r\n---\r\n## Tasks\r\n- [ ] T1 a\r\n- [-] T2 b -- why\r\n")

      expect(plan.tasks.map { |t| [t.id, t.title, t.reason] }).to eq([["T1", "a", nil], ["T2", "b", "why"]])
      expect(plan.status).to eq("paused")
    end

    it "keeps a dash pair inside the title of a task that is not skipped or blocked" do
      expect(parse(plan_text("## Tasks", "- [ ] T1 Split A -- B")).tasks.first.title).to eq("Split A -- B")
    end

    it "accepts ids with dots and dashes, and a trailing colon" do
      plan = parse(plan_text("## Tasks", "- [ ] CLI-D18 a", "- [ ] 1.2 b", "- [ ] T3: c"))

      expect(plan.tasks.map { |t| [t.id, t.title] }).to eq([["CLI-D18", "a"], ["1.2", "b"], ["T3", "c"]])
    end

    it "accepts the empty text and text with no newline at the end" do
      expect(parse("").tasks).to eq([])
      expect(parse("## Tasks\n- [ ] T1 a").tasks.size).to eq(1)
    end
  end

  describe ".parse warnings" do
    it "warns no_id for a task line with no id and still counts it" do
      plan = parse(plan_text("## Tasks", "- [ ] Add the token store", "- [ ] T2 b"))

      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "no_id", "line" => 2, "message" => a_kind_of(String)))
      expect(plan.tasks.first).to have_attributes(id: nil, title: "Add the token store", state: "todo")
      expect(plan.counts["total"]).to eq(2)
    end

    it "warns no_id for a task line with nothing after the box" do
      plan = parse(plan_text("## Tasks", "- [ ]"))

      expect(plan.warnings.map { |w| w["code"] }).to eq(["no_id"])
      expect(plan.tasks.first).to have_attributes(id: nil, title: "")
    end

    it "warns bad_state for an unknown box character and counts the task as to do" do
      plan = parse(plan_text("## Tasks", "- [?] T1 a"))

      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "bad_state", "line" => 2))
      expect(plan.tasks.first.state).to eq("todo")
      expect(plan.counts["left"]).to eq(1)
    end

    it "warns duplicate_id on the second use of an id and counts both" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 a", "- [ ] T1 b", "- [ ] T1 c"))

      expect(plan.warnings.map { |w| [w["code"], w["line"]] }).to eq([["duplicate_id", 3], ["duplicate_id", 4]])
      expect(plan.counts["total"]).to eq(3)
    end

    it "warns missing_reason for a skipped or blocked task without one" do
      plan = parse(plan_text("## Tasks", "- [-] T1 a", "- [!] T2 b --", "- [!] T3 c -- fine"))

      expect(plan.warnings.map { |w| [w["code"], w["line"]] }).to eq([["missing_reason", 2], ["missing_reason", 3]])
      expect(plan.tasks.map(&:reason)).to eq([nil, nil, "fine"])
      expect(plan.tasks[1].title).to eq("b")
    end

    it "reads the reason of a task that has an id and no title" do
      plan = parse(plan_text("## Tasks", "- [!] T1 -- waiting on X"))

      expect(plan.tasks.first).to have_attributes(id: "T1", title: "", reason: "waiting on X")
      expect(plan.warnings).to eq([])
    end

    it "keeps warnings on one line in the order they were found" do
      plan = parse(plan_text("## Tasks", "- [?] words only"))

      expect(plan.warnings.map { |w| w["code"] }).to eq(%w[bad_state no_id])
    end

    it "warns truncated when told the read stopped early" do
      plan = parse("## Tasks\n- [ ] T1 a\n", truncated: true)

      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "truncated", "line" => nil))
    end

    it "lists warnings in the order of the lines" do
      plan = parse(plan_text("## Tasks", "- [?] T1 a", "- [ ] Words only", "- [ ] T1 again"))

      expect(plan.warnings.map { |w| w["line"] }).to eq([2, 3, 4])
    end
  end

  describe ".parse frontmatter" do
    it "reads title, status and owner_pane, and the plan version" do
      plan = parse(plan_text("---", "plan: 1", "title: \"Auth rewrite\"", "status: paused", "owner_pane: '%19'", "---", "## Tasks", "- [ ] T1 a"))

      expect(plan).to have_attributes(title: "Auth rewrite", status: "paused", owner_pane: "%19")
      expect(plan.frontmatter["plan"]).to eq("1")
      expect(plan.tasks.first.line).to eq(8)
    end

    it "unescapes a double-quoted title and keeps the text of one it cannot unescape" do
      expect(parse(plan_text("---", %q(title: "Say \"hi\""), "---")).title).to eq('Say "hi"')
      expect(parse(plan_text("---", %q(title: "C:\dir"), "---")).title).to eq(%q(C:\dir))
    end

    it "defaults the status to active and the rest to nil" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 a"))

      expect(plan).to have_attributes(status: "active", title: nil, owner_pane: nil)
    end

    it "treats an unknown status as active and warns bad_state" do
      plan = parse(plan_text("---", "status: finished", "---", "## Tasks"))

      expect(plan.status).to eq("active")
      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "bad_state", "line" => 2))
    end

    it "treats a blank owner_pane as unset" do
      expect(parse(plan_text("---", "owner_pane:", "---")).owner_pane).to be_nil
    end

    it "reads a --- line that never closes as ordinary text, not frontmatter" do
      plan = parse(plan_text("---", "status: paused", "## Tasks", "- [ ] T1 a"))

      expect(plan.status).to eq("active")
      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "reads a --- rule with no key lines before the next --- as text, so the tasks count" do
      plan = parse(plan_text("---", "just a rule", "---", "## Tasks", "- [ ] T1 a"))

      expect(plan.frontmatter).to eq({})
      expect(plan.tasks.map(&:id)).to eq(["T1"])
    end

    it "skips lines of frontmatter that are not key: value" do
      plan = parse(plan_text("---", "just words", "title: Hi", "---"))

      expect(plan.title).to eq("Hi")
    end

    it "does not read a --- later in the file as frontmatter" do
      plan = parse(plan_text("# Plan", "---", "status: paused", "---", "## Tasks", "- [ ] T1 a"))

      expect(plan.status).to eq("active")
    end
  end

  describe "frontmatter position" do
    it "reports the lines between the --- lines and the status line, for a writer that changes only that line" do
      plan = parse(plan_text("---", "plan: 1", "status: paused", "---", "## Tasks"))

      expect(plan.frontmatter_lines).to eq(2..3)
      expect(plan.status_line).to eq(3)
    end

    it "reports nothing without frontmatter or a status line" do
      expect(parse(plan_text("## Tasks")).frontmatter_lines).to be_nil
      expect(parse(plan_text("---", "title: x", "---")).status_line).to be_nil
    end
  end

  describe ".path_in" do
    it "puts the plan file in the notes directory" do
      expect(described_class.path_in("/n")).to eq("/n/IMPLEMENTATION_PLAN.md")
    end
  end

  describe ".read" do
    around do |example|
      Dir.mktmpdir("plan-file") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    let(:path) { File.join(@dir, "IMPLEMENTATION_PLAN.md") }

    it "returns nil for a file that is not there" do
      expect(described_class.read(path)).to be_nil
      expect(described_class.read(File.join(@dir, "no", "such", "plan.md"))).to be_nil
    end

    it "parses the file and reports its signature and update time" do
      File.write(path, "## Tasks\n- [ ] T1 a\n")
      time = Time.utc(2026, 10, 12, 14, 3, 11, 123_456.789r)
      File.utime(time, time, path)

      plan = described_class.read(path)

      expect(plan.tasks.size).to eq(1)
      expect(plan.signature).to eq("#{time.to_i * 1_000_000_000 + 123_456_789}:#{File.size(path)}")
      expect(plan.updated_at).to eq("2026-10-12T14:03:11Z")
    end

    it "returns nil for a path below a file" do
      File.write(path, "x")

      expect(described_class.read(File.join(path, "x"))).to be_nil
    end

    it "stops at 1 MB and says so, without counting a half line" do
      count = (described_class::MAX_BYTES / 100) + 100
      lines = Array.new(count) { |i| "- [ ] T#{i} #{"x" * 90}\n" }
      File.write(path, "## Tasks\n" + lines.join)

      plan = described_class.read(path)

      expect(plan.warnings.map { |w| w["code"] }).to eq(["truncated"])
      expect(plan.tasks.size).to be < count
      expect(plan.tasks.last.title).to eq("x" * 90)
    end

    it "reads an empty file as an empty plan" do
      File.write(path, "")

      plan = described_class.read(path)

      expect(plan.tasks).to eq([])
      expect(plan.warnings).to eq([])
      expect(plan.signature).to end_with(":0")
    end

    it "reads a file longer than 1 MB with no line break as an empty, truncated plan" do
      File.write(path, "x" * (described_class::MAX_BYTES + 10))

      plan = described_class.read(path)

      expect(plan.tasks).to eq([])
      expect(plan.warnings.map { |w| w["code"] }).to eq(["truncated"])
    end

    it "reads bytes that are not valid UTF-8 without failing" do
      File.binwrite(path, "## Tasks\n- [ ] T1 caf\xE9\n".b)

      expect(described_class.read(path).tasks.first.id).to eq("T1")
    end

    it "reads a file that cannot be read as an empty plan with an unreadable warning" do
      Dir.mkdir(path)

      plan = described_class.read(path)

      expect(plan.tasks).to eq([])
      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "unreadable", "line" => nil))
    end
  end
  describe ".set_status and .set_owner_pane" do
    around do |example|
      Dir.mktmpdir("plan-write") do |dir|
        @path = File.join(dir, "IMPLEMENTATION_PLAN.md")
        example.run
      end
    end

    let(:body) { "# Plan\n\n## Tasks\n- [ ] T1 One\n" }

    def write(text) = File.binwrite(@path, text)

    def content = File.binread(@path)

    it "rewrites only the status line and keeps every other byte" do
      write("---\nplan: 1\nstatus: active\ntitle: \"A: b\"\n---\n" + body)

      expect(described_class.set_status(@path, "paused")).to be true

      expect(content).to eq("---\nplan: 1\nstatus: paused\ntitle: \"A: b\"\n---\n" + body)
    end

    it "changes the signature of the file" do
      write("---\nstatus: active\n---\n" + body)
      before = described_class.read(@path).signature

      described_class.set_status(@path, "paused")

      expect(described_class.read(@path).signature).not_to eq(before)
    end

    it "is a no-op that leaves the file alone when the status already reads that way" do
      write("---\nstatus:   paused\n---\n" + body)
      before = File.stat(@path).mtime

      expect(described_class.set_status(@path, "paused")).to be false

      expect(content).to eq("---\nstatus:   paused\n---\n" + body)
      expect(File.stat(@path).mtime).to eq(before)
    end

    it "treats an absent status as active and writes nothing for active" do
      write("---\ntitle: T\n---\n" + body)

      expect(described_class.set_status(@path, "active")).to be false
      expect(content).to eq("---\ntitle: T\n---\n" + body)
    end

    it "repairs a status that is not one of the three when asked for active" do
      write("---\nstatus: bogus\n---\n" + body)

      expect(described_class.set_status(@path, "active")).to be true
      expect(content).to eq("---\nstatus: active\n---\n" + body)
    end

    it "adds the key before the closing line when the frontmatter has no status" do
      write("---\ntitle: T\n---\n" + body)

      expect(described_class.set_status(@path, "paused")).to be true

      expect(content).to eq("---\ntitle: T\nstatus: paused\n---\n" + body)
    end

    it "adds frontmatter when the file has none" do
      write(body)

      expect(described_class.set_status(@path, "paused")).to be true

      expect(content).to eq("---\nplan: 1\nstatus: paused\n---\n" + body)
      expect(described_class.read(@path)).to have_attributes(status: "paused", tasks: satisfy { |t| t.size == 1 })
    end

    it "adds frontmatter after a byte order mark" do
      write("\uFEFF" + body)

      described_class.set_status(@path, "paused")

      expect(content).to eq("\uFEFF---\nplan: 1\nstatus: paused\n---\n".b + body.b)
      expect(described_class.read(@path).status).to eq("paused")
    end

    it "keeps CRLF line endings on the line it replaces and the line it adds" do
      write("---\r\nstatus: active\r\n---\r\n## Tasks\r\n- [ ] T1 a\r\n")
      described_class.set_status(@path, "paused")
      expect(content).to start_with("---\r\nstatus: paused\r\n---\r\n")

      write("---\r\ntitle: T\r\n---\r\n## Tasks\r\n")
      described_class.set_status(@path, "paused")
      expect(content).to start_with("---\r\ntitle: T\r\nstatus: paused\r\n---\r\n")
    end

    it "keeps bytes that are not valid UTF-8" do
      write("---\nstatus: active\n---\n## Tasks\n- [ ] T1 caf\xE9\n".b)

      described_class.set_status(@path, "paused")

      expect(content).to eq("---\nstatus: paused\n---\n## Tasks\n- [ ] T1 caf\xE9\n".b)
    end

    it "rewrites a plan longer than the read limit whole" do
      tail = "x" * (described_class::MAX_BYTES + 10)
      write("---\nstatus: active\n---\n" + tail)

      described_class.set_status(@path, "paused")

      expect(content).to eq("---\nstatus: paused\n---\n" + tail)
    end

    it "keeps the file mode and leaves no temporary file" do
      write("---\nstatus: active\n---\n" + body)
      File.chmod(0o640, @path)

      described_class.set_status(@path, "paused")

      expect(File.stat(@path).mode & 0o777).to eq(0o640)
      expect(Dir.children(File.dirname(@path))).to eq(["IMPLEMENTATION_PLAN.md"])
    end

    it "writes through a symlink and leaves the link in place" do
      target = File.join(File.dirname(@path), "real.md")
      File.write(target, "---\nstatus: active\n---\n" + body)
      File.symlink(target, @path)

      described_class.set_status(@path, "paused")

      expect(File.symlink?(@path)).to be true
      expect(File.read(target)).to start_with("---\nstatus: paused\n")
    end

    it "raises ENOENT when there is no file" do
      expect { described_class.set_status(@path, "paused") }.to raise_error(Errno::ENOENT)
    end

    it "raises ENOENT for active too when there is no file" do
      expect { described_class.set_status(@path, "active") }.to raise_error(Errno::ENOENT)
    end

    it "adds frontmatter to an empty file" do
      write("")

      expect(described_class.set_status(@path, "paused")).to be true

      expect(content).to eq("---\nplan: 1\nstatus: paused\n---\n")
    end

    it "sets owner_pane quoted, replacing a blank value" do
      write("---\nowner_pane:\nstatus: active\n---\n" + body)

      expect(described_class.set_owner_pane(@path, "%19")).to be true

      expect(content).to eq("---\nowner_pane: \"%19\"\nstatus: active\n---\n" + body)
      expect(described_class.read(@path).owner_pane).to eq("%19")
    end

    it "leaves owner_pane alone when it already names that pane" do
      write("---\nowner_pane: \"%19\"\n---\n" + body)

      expect(described_class.set_owner_pane(@path, "%19")).to be false
    end

    it "changes the last of two status lines, the one the parser reads" do
      write("---\nstatus: active\nstatus: done\n---\n" + body)

      described_class.set_status(@path, "paused")

      expect(content).to eq("---\nstatus: active\nstatus: paused\n---\n" + body)
    end
  end

  describe ".parse task owners" do
    it "reads the pane id of an owner comment at the end of a task line" do
      plan = parse(plan_text("## Tasks", "- [~] T1 First <!-- owner: %19 -->", "- [!] T2 Second -- needs a key <!--owner:%4-->", "- [ ] T3 Third"))

      expect(plan.tasks.map { |t| [t.id, t.title, t.state, t.reason, t.owner] }).to eq([
        ["T1", "First", "in_progress", nil, "%19"], ["T2", "Second", "blocked", "needs a key", "%4"], ["T3", "Third", "todo", nil, nil]
      ])
      expect(plan.tasks.first.to_h).to include("owner" => "%19")
      expect(plan.warnings).to eq([])
    end

    it "reads the same id, title, state, reason, counts and current with or without owners" do
      plain = parse(plan_text("## Tasks", "- [~] T1 First", "- [!] T2 Second -- why", "- [ ] T3 Third"))
      owned = parse(plan_text("## Tasks", "- [~] T1 First <!-- owner: %19 -->", "- [!] T2 Second -- why <!-- owner: %4 -->", "- [ ] T3 Third"))

      strip = ->(plan) { plan.tasks.map { |t| t.to_h.except("owner") } }
      expect(strip.call(owned)).to eq(strip.call(plain))
      expect([owned.counts, owned.current, owned.percent]).to eq([plain.counts, plain.current, plain.percent])
    end

    it "ignores other comments and takes the first owner comment" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 First <!-- note --> <!-- owner: %2 --> <!-- owner: %3 -->"))

      expect(plan.tasks.first.owner).to eq("%2")
      expect(plan.tasks.first.title).to eq("First")
    end

    it "warns bad_owner and gives no owner for a value that is not a pane id; an empty one is no owner" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 First <!-- owner: alice -->", "- [ ] T2 Second <!-- owner: -->"))

      expect(plan.tasks.map(&:owner)).to eq([nil, nil])
      expect(plan.warnings).to contain_exactly(a_hash_including("code" => "bad_owner", "line" => 2))
    end

    it "does not read an owner from a comment that is still open at the end of the line" do
      plan = parse(plan_text("## Tasks", "- [ ] T1 First <!-- owner: %2", "-->", "- [ ] T2 Second"))

      expect(plan.tasks.map { |t| [t.id, t.owner] }).to eq([["T1", nil], ["T2", nil]])
    end
  end

  describe ".set_task" do
    around do |example|
      Dir.mktmpdir("plan-task") do |dir|
        @path = File.join(dir, "IMPLEMENTATION_PLAN.md")
        example.run
      end
    end

    def write(text) = File.binwrite(@path, text)

    def content = File.binread(@path)

    let(:head) { "---\nplan: 1\n---\n# Plan\n\n## Tasks\n" }

    it "adds an owner comment and changes the box, keeping every other byte" do
      write(head + "- [ ] T1 One\n- [ ] T2 Two  \n## Task details\n- [ ] T2 not a task\n")

      expect(described_class.set_task(@path, "T2", state: "in_progress", owner: "%19")).to be true

      expect(content).to eq(head + "- [ ] T1 One\n- [~] T2 Two <!-- owner: %19 -->\n## Task details\n- [ ] T2 not a task\n")
      expect(described_class.read(@path).tasks.last.to_h).to include("id" => "T2", "state" => "in_progress", "owner" => "%19")
    end

    it "replaces an owner in place and keeps a reason and CRLF line endings" do
      write("## Tasks\r\n- [!] T1 One -- why <!-- owner: %3 --> tail\r\n")

      described_class.set_task(@path, "T1", owner: "%8")

      expect(content).to eq("## Tasks\r\n- [!] T1 One -- why <!-- owner: %8 --> tail\r\n")
    end

    it "removes the owner comment with owner: nil" do
      write("## Tasks\n- [~] T1 One <!-- owner: %3 -->\n")

      described_class.set_task(@path, "T1", state: "todo", owner: nil)

      expect(content).to eq("## Tasks\n- [ ] T1 One\n")
    end

    it "leaves the owner alone by default and writes nothing when the line already reads that way" do
      write("## Tasks\n- [~] T1 One <!-- owner: %3 -->\n")

      expect(described_class.set_task(@path, "T1", state: "in_progress")).to be false
      expect(described_class.set_task(@path, "T1", owner: "%3")).to be false
      expect(described_class.set_task(@path, "T1", state: "done")).to be true
      expect(content).to eq("## Tasks\n- [x] T1 One <!-- owner: %3 -->\n")
    end

    it "fixes an unknown box character when it sets the state" do
      write("## Tasks\n- [é] T1 One\n")

      described_class.set_task(@path, "T1", state: "blocked")

      expect(content).to eq("## Tasks\n- [!] T1 One\n")
    end

    it "raises unknown_task for an id that is not a task" do
      write("## Tasks\n- [ ] T1 One\n## Task details\n- [ ] T9 not counted\n")

      expect { described_class.set_task(@path, "T9", owner: "%1") }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_task") }
      expect(content).to eq("## Tasks\n- [ ] T1 One\n## Task details\n- [ ] T9 not counted\n")
    end

    it "refuses an owner that would not read back: after a comment left open, or inside a nested one" do
      ["## Tasks\n- [ ] T1 One <!-- open\n-->\n", "## Tasks\n- [ ] T1 One <!-- x <!-- owner: %1 -->\n"].each do |text|
        write(text)

        expect { described_class.set_task(@path, "T1", owner: "%8") }.to raise_error(Workspace::Error, /can't be rewritten/)
        expect(content).to eq(text)
      end
    end

    it "removes a malformed owner comment with owner: nil" do
      write("## Tasks\n- [ ] T1 One <!-- owner: alice -->\n")

      expect(described_class.set_task(@path, "T1", owner: nil)).to be true

      expect(content).to eq("## Tasks\n- [ ] T1 One\n")
    end

    it "keeps one owner comment: replaces the first and drops the rest" do
      write("## Tasks\n- [ ] T1 One <!-- owner: %2 --> <!-- note --> <!-- owner: %3 -->\n")

      described_class.set_task(@path, "T1", owner: "%9")

      expect(content).to eq("## Tasks\n- [ ] T1 One <!-- owner: %9 --> <!-- note -->\n")
    end

    it "rejects a value that is not a pane id before reading anything" do
      expect { described_class.set_task(@path, "T1", owner: "alice") }.to raise_error(ArgumentError)
      expect { described_class.set_task(@path, "T1", state: "nope") }.to raise_error(ArgumentError)
    end

    it "raises ENOENT when there is no file" do
      expect { described_class.set_task(@path, "T1", owner: "%1") }.to raise_error(Errno::ENOENT)
    end
  end
  describe "task verbs" do
    around do |example|
      Dir.mktmpdir("plan-verbs") do |dir|
        @path = File.join(dir, "IMPLEMENTATION_PLAN.md")
        example.run
      end
    end

    def write(text) = File.binwrite(@path, text)

    def content = File.binread(@path)

    let(:head) { "---\nplan: 1\n---\n# Plan\n\n## Tasks\n" }
    let(:phased) { head + "### One\n- [ ] T1 First\n- [~] T2 Second <!-- owner: %4 -->\n### Two\n- [ ] T3 Third\n## Task details\nText\n" }

    describe "#revision" do
      it "is the first 8 hex digits of the SHA-256 of the whole file, and changes with any byte" do
        write(phased)
        revision = described_class.read(@path).revision

        expect(revision).to eq(Digest::SHA256.hexdigest(phased)[0, 8])
        expect(described_class.revision_of(phased)).to eq(revision)
        write(phased.sub("First", "Firsd"))
        expect(described_class.read(@path).revision).not_to eq(revision)
      end

      it "covers the whole file when it is longer than the read limit" do
        text = phased + ("x" * 100 + "\n") * ((described_class::MAX_BYTES / 101) + 50)
        write(text)

        expect(described_class.read(@path).revision).to eq(Digest::SHA256.hexdigest(text)[0, 8])
      end
    end

    describe "#next_id" do
      it "continues the prefix of the last task, past the highest number with that prefix" do
        expect(parse("## Tasks\n- [ ] T1 a\n- [ ] T9 b\n- [ ] T3 c\n").next_id).to eq("T10")
        expect(parse("## Tasks\n- [ ] T4 a\n- [ ] E2 b\n").next_id).to eq("E3")
        expect(parse("## Tasks\n- [ ] PROJ-12 a\n").next_id).to eq("PROJ-13")
        expect(parse("## Tasks\n").next_id).to eq("T1")
      end

      it "is what add_task uses without an id, and reports the id it chose" do
        write(phased)

        expect(described_class.add_task(@path, title: "Fourth").id).to eq("T4")
        expect(described_class.add_task(@path, title: "Fifth").id).to eq("T5")
      end
    end

    describe ".add_task" do
      it "adds after the last task of the plan by default, changing nothing else" do
        write(phased)

        result = described_class.add_task(@path, id: "T4", title: "Fourth")

        expect(result).to have_attributes(changed: true, revision: described_class.read(@path).revision)
        expect(content).to eq(phased.sub("- [ ] T3 Third\n", "- [ ] T3 Third\n- [ ] T4 Fourth\n"))
      end

      it "adds under a phase after that phase's last task, or after its heading when it has none" do
        write(phased)
        described_class.add_task(@path, id: "T4", title: "Fourth", phase: "One")
        expect(described_class.read(@path).tasks.map { |t| [t.id, t.phase] }).to eq([%w[T1 One], %w[T2 One], %w[T4 One], %w[T3 Two]])

        write(head + "### Empty\n### Next\n- [ ] T1 a\n")
        described_class.add_task(@path, id: "T2", title: "b", phase: "Empty")
        expect(described_class.read(@path).tasks.map { |t| [t.id, t.phase] }).to eq([%w[T2 Empty], %w[T1 Next]])
      end

      it "adds after a named task" do
        write(phased)

        described_class.add_task(@path, id: "T4", title: "Fourth", after: "T1")

        expect(described_class.read(@path).tasks.map(&:id)).to eq(%w[T1 T4 T2 T3])
      end

      it "adds into an empty Tasks section before the next heading, past blank lines" do
        write("## Tasks\n\n<!-- hint -->\n\n## Task details\n")

        described_class.add_task(@path, id: "T1", title: "First")

        expect(content).to eq("## Tasks\n\n<!-- hint -->\n- [ ] T1 First\n\n## Task details\n")
      end

      it "keeps CRLF and adds a line ending to a last line that has none" do
        write("## Tasks\r\n- [ ] T1 First")

        described_class.add_task(@path, id: "T2", title: "Second")

        expect(content).to eq("## Tasks\r\n- [ ] T1 First\r\n- [ ] T2 Second")
      end

      it "writes a skipped or blocked task with its reason" do
        write(phased)

        described_class.add_task(@path, id: "T4", title: "Fourth", state: "blocked", reason: "needs db")

        expect(described_class.read(@path).tasks.last).to have_attributes(id: "T4", state: "blocked", reason: "needs db", title: "Fourth")
      end

      it "refuses an id that is already used, naming its line, and writes nothing" do
        write(phased)

        expect { described_class.add_task(@path, id: "T2", title: "Again") }
          .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["line"]]).to eq(["task_exists", 9]) }
        expect(content).to eq(phased)
      end

      it "refuses a bad id, title or reason, a missing reason, an unknown phase or anchor, and a plan with no Tasks section" do
        write(phased)
        {
          {id: "nodigit", title: "x"} => "invalid_task",
          {id: "T9", title: ""} => "invalid_task",
          {id: "T9", title: "a -- b"} => "invalid_task",
          {id: "T9", title: "a <!-- b -->"} => "invalid_task",
          {id: "T9", title: "a\nb"} => "invalid_task",
          {id: "T9", title: "x", state: "blocked"} => "reason_required",
          {id: "T9", title: "x", reason: "why"} => "invalid_task",
          {id: "T9", title: "x", phase: "Nope"} => "unknown_phase",
          {id: "T9", title: "x", after: "T77"} => "unknown_task",
          {id: "T9", title: "x", after: "T1", phase: "Two"} => "invalid_task"
        }.each do |args, code|
          expect { described_class.add_task(@path, **args) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq(code) }
        end
        write("# Plan\nNo list\n")
        expect { described_class.add_task(@path, id: "T1", title: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_task_section") }
        expect(content).to eq("# Plan\nNo list\n")
      end

      it "refuses a stale revision with the current one, writing nothing" do
        write(phased)

        expect { described_class.add_task(@path, id: "T4", title: "x", if_revision: "deadbeef") }
          .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["revision"]]).to eq(["stale_revision", described_class.revision_of(phased)]) }
        expect(content).to eq(phased)
      end

      it "accepts the current revision, in any case" do
        write(phased)

        described_class.add_task(@path, id: "T4", title: "x", if_revision: described_class.revision_of(phased).upcase)

        expect(described_class.read(@path).tasks.size).to eq(4)
      end
    end

    describe ".change_task" do
      it "sets a state, keeping the owner comment and every other byte" do
        write(phased)

        result = described_class.change_task(@path, "T2", state: "done")

        expect(result.changed).to be true
        expect(content).to eq(phased.sub("- [~] T2 Second <!-- owner: %4 -->", "- [x] T2 Second <!-- owner: %4 -->"))
      end

      it "writes the reason of a blocked task before the owner comment, and drops it when the task leaves the state" do
        write(phased)

        described_class.change_task(@path, "T2", state: "blocked", reason: "waiting")
        expect(content).to include("- [!] T2 Second -- waiting <!-- owner: %4 -->\n")
        expect(described_class.read(@path).tasks[1]).to have_attributes(state: "blocked", reason: "waiting", owner: "%4", title: "Second")

        described_class.change_task(@path, "T2", state: "todo")
        expect(content).to eq(phased.sub("- [~] T2", "- [ ] T2"))
      end

      it "changes the reason of a blocked task and keeps it when only the owner changes" do
        write(head + "- [!] T1 One -- old\n")

        described_class.change_task(@path, "T1", reason: "new")
        expect(content).to eq(head + "- [!] T1 One -- new\n")
        described_class.change_task(@path, "T1", owner: "%3")
        expect(content).to eq(head + "- [!] T1 One -- new <!-- owner: %3 -->\n")
      end

      it "needs a reason to block or skip, unless the line has one, and refuses one for other states" do
        write(phased)

        expect { described_class.change_task(@path, "T1", state: "skipped") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("reason_required") }
        expect { described_class.change_task(@path, "T1", state: "done", reason: "why") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_task") }
        expect { described_class.change_task(@path, "T1", state: "done", reason: "bad -- one") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_task") }
        expect(content).to eq(phased)
      end

      it "refuses to block a task whose title holds a ' -- ', rather than misread the title as a reason" do
        write(head + "- [ ] T1 a -- b\n")

        expect { described_class.change_task(@path, "T1", state: "blocked", reason: "r") }.to raise_error(Workspace::Error)
        expect(content).to eq(head + "- [ ] T1 a -- b\n")
      end

      it "is unchanged when the task already reads that way, and still checks the revision" do
        write(phased)

        expect(described_class.change_task(@path, "T1", state: "todo").changed).to be false
        expect { described_class.change_task(@path, "T1", state: "done", if_revision: "00000000") }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("stale_revision") }
      end

      it "leaves the reason alone for set_task" do
        write(head + "- [!] T1 One -- why\n")

        described_class.set_task(@path, "T1", state: "in_progress")

        expect(content).to eq(head + "- [~] T1 One -- why\n")
      end
    end

    describe ".move_task" do
      it "moves a whole line, owner comment included, after or before another task" do
        write(phased)

        described_class.move_task(@path, "T2", after: "T3")
        expect(described_class.read(@path).tasks.map { |t| [t.id, t.phase, t.owner] }).to eq([["T1", "One", nil], ["T3", "Two", nil], ["T2", "Two", "%4"]])

        described_class.move_task(@path, "T2", before: "T1")
        expect(described_class.read(@path).tasks.map(&:id)).to eq(%w[T2 T1 T3])
        expect(content).to include("- [~] T2 Second <!-- owner: %4 -->\n")
      end

      it "moves to the end of a phase, and reports unchanged when it is already there" do
        write(phased)

        expect(described_class.move_task(@path, "T1", phase: "Two").changed).to be true
        expect(described_class.read(@path).tasks.map { |t| [t.id, t.phase] }).to eq([%w[T2 One], %w[T3 Two], %w[T1 Two]])
        expect(described_class.move_task(@path, "T1", phase: "Two").changed).to be false
        expect(described_class.move_task(@path, "T3", before: "T1").changed).to be false
      end

      it "keeps every other line, so a move and its reverse restore the file" do
        write(phased)

        described_class.move_task(@path, "T1", after: "T3")
        described_class.move_task(@path, "T1", before: "T2")

        expect(content).to eq(phased)
      end

      it "handles a last line with no ending" do
        write("## Tasks\n- [ ] T1 a\n- [ ] T2 b")

        described_class.move_task(@path, "T2", before: "T1")

        expect(content).to eq("## Tasks\n- [ ] T2 b\n- [ ] T1 a")
      end

      it "keeps CRLF endings when it moves the last line, which has none, to the middle" do
        write("## Tasks\r\n- [ ] T1 a\r\n- [ ] T2 b\r\n- [ ] T3 c")

        described_class.move_task(@path, "T3", before: "T2")

        expect(content).to eq("## Tasks\r\n- [ ] T1 a\r\n- [ ] T3 c\r\n- [ ] T2 b")
      end

      it "refuses an unknown task, anchor or phase, no place or two, and a task relative to itself" do
        write(phased)
        {
          ["T9", {after: "T1"}] => "unknown_task",
          ["T1", {after: "T9"}] => "unknown_task",
          ["T1", {before: "T9"}] => "unknown_task",
          ["T1", {phase: "Nope"}] => "unknown_phase",
          ["T1", {}] => "invalid_task",
          ["T1", {after: "T2", before: "T3"}] => "invalid_task",
          ["T1", {after: "T1"}] => "invalid_task"
        }.each do |(id, args), code|
          expect { described_class.move_task(@path, id, **args) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq(code) }
        end
        expect(content).to eq(phased)
      end

      it "refuses a stale revision" do
        write(phased)

        expect { described_class.move_task(@path, "T1", after: "T3", if_revision: "00000000") }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("stale_revision") }
      end
    end

    it "counts and current follow the written plan, so plan_progress sees the change" do
      write(phased)

      described_class.change_task(@path, "T1", state: "done")
      described_class.add_task(@path, id: "T4", title: "Fourth")

      plan = described_class.read(@path)
      expect(plan.counts).to include("total" => 4, "done" => 1, "in_progress" => 1, "todo" => 2)
      expect(plan.current).to include("id" => "T2")
    end
  end

  describe ".retitle_task" do
    around do |example|
      Dir.mktmpdir("plan-retitle") do |dir|
        @path = File.join(dir, "IMPLEMENTATION_PLAN.md")
        example.run
      end
    end

    def write(text) = File.binwrite(@path, text)

    def content = File.binread(@path).force_encoding(Encoding::UTF_8)

    it "keeps CRLF endings and every other line byte for byte" do
      write("---\r\nstatus: active\r\n---\r\n## Tasks\r\n- [ ] T1 One\r\n- [!] T2 Two -- why <!-- owner: %3 -->\r\n")

      result = described_class.retitle_task(@path, "T2", title: "Deux")

      expect(result.changed).to be(true)
      expect(content).to eq("---\r\nstatus: active\r\n---\r\n## Tasks\r\n- [ ] T1 One\r\n- [!] T2 Deux -- why <!-- owner: %3 -->\r\n")
    end

    it "writes and reads back a multibyte title" do
      write("## Tasks\n- [ ] T1 Ünï\n- [ ] T2 Two\n")

      described_class.retitle_task(@path, "T1", title: "Проверка ✓")

      expect(content).to eq("## Tasks\n- [ ] T1 Проверка ✓\n- [ ] T2 Two\n")
      expect(described_class.read(@path).tasks.first.title).to eq("Проверка ✓")
    end

    it "changes nothing when the title is the same" do
      write("## Tasks\n- [ ] T1 One\n")

      expect(described_class.retitle_task(@path, "T1", title: "One").changed).to be(false)
      expect(content).to eq("## Tasks\n- [ ] T1 One\n")
    end

    it "refuses a bad title and an unknown task, leaving the file alone" do
      write("## Tasks\n- [ ] T1 One\n")

      expect { described_class.retitle_task(@path, "T1", title: "a -- b") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_task") }
      expect { described_class.retitle_task(@path, "T7", title: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_task") }
      expect(content).to eq("## Tasks\n- [ ] T1 One\n")
    end

    it "refuses a line that is not valid UTF-8" do
      write("## Tasks\n- [ ] T1 One \xFF\n".b)

      expect { described_class.retitle_task(@path, "T1", title: "x") }.to raise_error(Workspace::Error)
    end
  end
end
