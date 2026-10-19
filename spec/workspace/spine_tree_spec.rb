require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::SpineTree do
  around do |example|
    Dir.mktmpdir("spine-tree") do |dir|
      @notes = File.realpath(dir)
      example.run
    end
  end

  def write(relative, text = nil, **front)
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    text ||= "---\n#{front.map { |k, v| "#{k}: #{v}" }.join("\n")}\n---\n"
    File.write(path, text)
    path
  end

  def tree = described_class.read(@notes)

  def doc = tree.to_h

  def stage(path) = tree.find(path)

  def codes(stage) = stage.all_warnings.map { |w| w["code"] }

  describe "a full default spine" do
    before do
      write("goal.md", "---\ntitle: Fix OAuth token refresh race\n---\nBrief\n")
      write("10-research.md", status: "completed", kind: "research", gates: "[checklist]")
      write("20-plan.md", status: "completed", kind: "plan", gates: "[plan, checklist]", depends_on: "[research]")
      write("30-implement.md", <<~MD)
        ---
        spine: 1
        title: Implement
        kind: implement
        status: active
        description: Make the refresh path safe
        note:
        owner: "%6"
        depends_on: [plan]
        gates: [plan]
        artifacts:
          - IMPLEMENTATION_PLAN.md
        updated: 2026-10-17T21:40:00Z
        updated_by: claude %6
        ---

        ## Done when

        - [x] one
        - [x] two
        - [ ] three
        - [ ] four
      MD
      write("40-verify.md", status: "not_started", depends_on: "[implement]", gates: "[checklist, ci]")
      write("50-review.md", status: "todo")
      write("60-ship.md", status: "")
      write("README.md", "# the spine\n")
    end

    it "answers the documented shape" do
      result = doc

      expect(result.keys).to eq(%w[dir exists goal stages not_stages truncated warnings])
      expect(result["dir"]).to eq(File.join(@notes, "spine"))
      expect(result["exists"]).to be true
      expect(result["goal"]).to include("file" => "goal.md", "title" => "Fix OAuth token refresh race", "revision" => match(/\A\h{8}\z/))
      expect(result["stages"].map { |s| s["path"] }).to eq(%w[research plan implement verify review ship])
      expect(result["not_stages"]).to eq(["README.md"])
      expect(result["truncated"]).to be_nil
      expect(result["warnings"]).to eq([])
    end

    it "reads every field of a stage" do
      implement = doc["stages"][2]

      expect(implement).to include(
        "path" => "implement", "file" => "30-implement.md", "number" => 30, "id" => "implement",
        "revision" => match(/\A\h{8}\z/), "title" => "Implement", "description" => "Make the refresh path safe",
        "status" => "in_progress", "status_raw" => "active", "note" => nil, "kind" => "implement", "owner" => "%6",
        "depends_on" => ["plan"], "gates" => ["plan"], "artifacts" => ["IMPLEMENTATION_PLAN.md"], "play" => nil, "agent" => nil,
        "updated" => "2026-10-17T21:40:00Z", "updated_by" => "claude %6", "modified_at" => match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/),
        "warnings" => [], "truncated" => false, "children" => []
      )
      expect(implement["done_when"]).to include("total" => 4, "done" => 2)
      expect(implement["done_when"]["items"].first).to include("text" => "one", "done" => true)
      expect(implement).not_to have_key("rollup")
    end

    it "gives a file with no title a title from its id, and kinds by id" do
      expect(doc["stages"].map { |s| s["title"] }).to eq(%w[Research Plan Implement Verify Review Ship])
      expect(doc["stages"].map { |s| s["kind"] }).to eq(%w[research plan implement verify review ship])
    end

    it "reads statuses, aliases and an empty status" do
      expect(doc["stages"].map { |s| [s["status"], s["status_raw"]] }).to eq(
        [["completed", "completed"], ["completed", "completed"], ["in_progress", "active"], ["not_started", "not_started"], ["not_started", "todo"], ["unknown", nil]]
      )
    end

    it "round-trips through JSON" do
      expect(JSON.parse(JSON.generate(doc))).to eq(doc)
    end
  end

  it "orders a custom stage numbered 35 between its neighbours and defaults its kind to custom" do
    write("30-implement.md", status: "completed")
    write("40-verify.md", status: "not_started")
    write("35-security-review.md", status: "in_progress", owner: "you", depends_on: "[implement]")

    expect(doc["stages"].map { |s| [s["number"], s["path"], s["kind"]] }).to eq(
      [[30, "implement", "implement"], [35, "security-review", "custom"], [40, "verify", "verify"]]
    )
    expect(doc["stages"][1]["title"]).to eq("Security review")
    expect(doc["stages"][1]["owner"]).to eq("you")
  end

  it "orders by number, not by name, and then by id" do
    write("100-late.md", status: "todo")
    write("20-mid.md", status: "todo")
    write("9-early.md", status: "todo")
    write("20-aaa.md", status: "todo")

    expect(doc["stages"].map { |s| s["file"] }).to eq(%w[9-early.md 20-aaa.md 20-mid.md 100-late.md])
  end

  it "reads a missing spine/ as exists: false" do
    expect(doc).to eq("dir" => File.join(@notes, "spine"), "exists" => false, "goal" => nil, "stages" => [], "not_stages" => [], "truncated" => nil, "warnings" => [])
  end

  it "reads a missing notes directory as exists: false" do
    expect(described_class.read(File.join(@notes, "nope")).to_h["exists"]).to be false
  end

  it "reads an empty spine/ as existing with no stages" do
    FileUtils.mkdir_p(File.join(@notes, "spine"))

    expect(doc).to include("exists" => true, "stages" => [])
  end

  describe "malformed files" do
    it "keeps a file with no closing --- in place as unknown, with no_frontmatter" do
      write("30-implement.md", status: "completed")
      write("45-perf.md", "---\nstatus: in_progress\ntitle: Perf\n")
      write("50-review.md", status: "todo")

      stages = doc["stages"]

      expect(stages.map { |s| s["path"] }).to eq(%w[implement perf review])
      expect(stages[1]).to include("status" => "unknown", "status_raw" => nil, "title" => "Perf")
      expect(stages[1]["warnings"].map { |w| w["code"] }).to eq(["no_frontmatter"])
    end

    it "reads an unknown status word as unknown and keeps the word, with no warning" do
      write("40-verify.md", status: "finished?")

      expect(doc["stages"].first).to include("status" => "unknown", "status_raw" => "finished?", "warnings" => [])
    end

    it "never gives a status outside the six values" do
      %w[a b c d].each_with_index { |word, i| write("#{i + 1}0-s#{i}.md", "---\nstatus: #{word}\n---\n") }
      write("50-x.md", "\xFF\xFE")
      write("60-y.md", "")
      write("70-z.md", "---\nstatus: [x]\n---\n")

      statuses = doc["stages"].map { |s| s["status"] }.uniq

      expect(statuses - %w[not_started in_progress blocked completed skipped unknown]).to eq([])
    end

    it "does not read bytes that are not UTF-8" do
      write("40-verify.md", "---\nstatus: done\n---\n\xFF")

      expect(doc["stages"].first).to include("status" => "unknown", "revision" => match(/\A\h{8}\z/))
      expect(doc["stages"].first["warnings"].map { |w| w["code"] }).to eq(["not_utf8"])
    end

    it "reads the first 64 KB of a big file with truncated: true and too_large" do
      write("40-verify.md", "---\nstatus: done\n---\n#{"x" * 70_000}")

      expect(doc["stages"].first).to include("status" => "completed", "truncated" => true)
      expect(codes(stage("verify"))).to eq(["too_large"])
    end

    it "carries a file's bad lines, duplicate keys, unknown kinds and gates" do
      write("40-verify.md", "---\nstatus: done\nstatus: todo\nkind: wild\ngates: [ci, bogus]\nwhat\n---\n")

      verify = stage("verify")

      expect(verify.all_warnings.map { |w| [w["code"], w["line"], w["value"]] }).to eq(
        [["duplicate_key", 3, "status"], ["unknown_kind", 4, "wild"], ["unknown_gate", 5, "bogus"], ["bad_line", 6, nil]]
      )
      expect(verify.kind).to eq("verify")
      expect(verify.gates).to eq(["ci"])
    end

    it "reads kind and gates case-insensitively" do
      write("40-verify.md", "---\nkind: Verify\ngates: [CI, Plan]\n---\n")

      expect([stage("verify").kind, stage("verify").gates, codes(stage("verify"))]).to eq(["verify", %w[ci plan], []])
    end

    it "warns newer_format on a stage and still reads it" do
      write("40-verify.md", "---\nspine: 3\nstatus: done\n---\n")

      expect(doc["stages"].first).to include("status" => "completed")
      expect(codes(stage("verify"))).to eq(["newer_format"])
    end
  end

  describe "dependencies" do
    it "drops an unknown dependency with unknown_dependency naming it" do
      write("10-a.md", status: "todo", depends_on: "[b, qa]")
      write("20-b.md", status: "todo")

      a = stage("a")

      expect(a.depends_on).to eq(["b"])
      expect(a.all_warnings).to eq([{"code" => "unknown_dependency", "line" => 3, "message" => "depends_on qa is not a stage of this folder.", "value" => "qa"}])
    end

    it "resolves depends_on among siblings only" do
      write("10-a.md", status: "todo")
      write("20-b.md", status: "todo")
      write("20-b/10-c.md", status: "todo", depends_on: "[a]")

      expect(stage("b/c").depends_on).to eq([])
      expect(codes(stage("b/c"))).to eq(["unknown_dependency"])
    end

    it "ignores a cycle's edges with dependency_cycle on each stage in it" do
      write("10-a.md", status: "todo", depends_on: "[b]")
      write("20-b.md", status: "todo", depends_on: "[c]")
      write("30-c.md", status: "todo", depends_on: "[a]")
      write("40-d.md", status: "todo", depends_on: "[a]")

      expect(%w[a b c d].map { |id| stage(id).depends_on }).to eq([[], [], [], ["a"]])
      expect(%w[a b c d].map { |id| codes(stage(id)) }).to eq([["dependency_cycle"]] * 3 + [[]])
    end

    it "treats a stage that depends on itself as a cycle" do
      write("10-a.md", status: "todo", depends_on: "[a]")

      expect(stage("a").depends_on).to eq([])
      expect(codes(stage("a"))).to eq(["dependency_cycle"])
    end
  end

  describe "duplicate ids" do
    it "shows both, warns duplicate_id on the second, and resolves depends_on to the first" do
      write("30-implement.md", status: "completed")
      write("31-implement.md", status: "todo")
      write("40-verify.md", status: "todo", depends_on: "[implement]")

      expect(doc["stages"].map { |s| [s["file"], s["warnings"].map { |w| w["code"] }] }).to eq(
        [["30-implement.md", []], ["31-implement.md", ["duplicate_id"]], ["40-verify.md", []]]
      )
      expect(stage("verify").depends_on).to eq(["implement"])
      expect(stage("implement").file.relative).to eq("30-implement.md")
    end
  end

  describe "sub-stages" do
    before do
      write("30-implement.md", status: "in_progress")
      write("30-implement/10-api.md", status: "done")
      write("30-implement/20-cache.md", status: "active")
      write("30-implement/20-cache/10-lock.md", status: "blocked")
      write("30-implement/20-cache/20-evict.md", status: "todo")
      write("30-implement/30-docs.md", status: "")
    end

    it "nests by folder and names paths with ids" do
      implement = doc["stages"].first

      expect(implement["children"].map { |c| [c["path"], c["file"]] }).to eq(
        [["implement/api", "30-implement/10-api.md"], ["implement/cache", "30-implement/20-cache.md"], ["implement/docs", "30-implement/30-docs.md"]]
      )
      cache = implement["children"][1]
      expect(cache["children"].map { |c| [c["path"], c["file"]] }).to eq(
        [["implement/cache/lock", "30-implement/20-cache/10-lock.md"], ["implement/cache/evict", "30-implement/20-cache/20-evict.md"]]
      )
    end

    it "rolls statuses up from the children, with counts, and only on a parent" do
      implement = doc["stages"].first
      cache = implement["children"][1]

      expect(implement["rollup"]).to eq("status" => "in_progress", "done" => 1, "total" => 3, "counts" => {"completed" => 1, "in_progress" => 1, "not_started" => 0, "blocked" => 0, "skipped" => 0, "unknown" => 1, "disputed" => 0})
      expect(cache["rollup"]).to eq("status" => "blocked", "done" => 0, "total" => 2, "counts" => {"completed" => 0, "in_progress" => 0, "not_started" => 1, "blocked" => 1, "skipped" => 0, "unknown" => 0, "disputed" => 0})
      expect(implement["children"][0]).not_to have_key("rollup")
    end

    it "finds a stage by path" do
      expect(stage("implement/cache/lock").file.relative).to eq("30-implement/20-cache/10-lock.md")
      expect(stage("implement/nope")).to be_nil
    end

    it "does not read a fourth level and warns too_deep on the third-level stage" do
      write("30-implement/20-cache/10-lock.md", status: "blocked")
      write("30-implement/20-cache/10-lock/10-deep.md", status: "todo")

      expect(stage("implement/cache/lock").children).to eq([])
      expect(codes(stage("implement/cache/lock"))).to eq(["too_deep"])
      expect(stage("implement/cache/lock/deep")).to be_nil
    end

    it "does not roll up from a stage's own status when it has no children" do
      expect(stage("implement/api").rollup).to be_nil
    end
  end

  describe "rollup rules" do
    def rollup_for(*statuses)
      write("10-p.md", status: "todo")
      statuses.each_with_index { |status, i| write("10-p/#{(i + 1) * 10}-c#{i}.md", status: status) }
      stage("p").rollup["status"]
    end

    it("is completed when every child that is not skipped is completed") { expect(rollup_for("done", "skip", "completed")).to eq("completed") }
    it("is blocked when any is blocked") { expect(rollup_for("done", "stuck", "todo")).to eq("blocked") }
    it("is in progress when any is in progress or completed") { expect(rollup_for("done", "todo")).to eq("in_progress") }
    it("is in progress for a lone in-progress child") { expect(rollup_for("active", "todo")).to eq("in_progress") }
    it("is not started when none started, counting unknown as not started") { expect(rollup_for("todo", "what")).to eq("not_started") }
    it("is skipped when everything is skipped") { expect(rollup_for("skip", "skip")).to eq("skipped") }
    it("ignores skipped children when others are underway") { expect(rollup_for("skip", "todo")).to eq("not_started") }

    it "counts a folder-only child by its own roll-up" do
      write("10-p.md", status: "todo")
      write("10-p/10-a.md", status: "completed")
      write("10-p/20-b/10-x.md", status: "completed")
      write("10-p/20-b/20-y.md", status: "completed")

      rollup = stage("p").rollup

      expect(rollup).to include("status" => "completed", "done" => 2, "total" => 2)
      expect(rollup["counts"]).to include("completed" => 2, "unknown" => 0)
    end

    it "takes a folder-only child whose sub-stages are all skipped as skipped" do
      write("10-p.md", status: "todo")
      write("10-p/10-a.md", status: "completed")
      write("10-p/20-b/10-x.md", status: "skipped")

      expect(stage("p").rollup).to include("status" => "completed", "done" => 1, "total" => 1)
      expect(stage("p").rollup["counts"]).to include("skipped" => 1)
    end

    it "gives a folder-only child that is under way the in-progress state" do
      write("10-p.md", status: "todo")
      write("10-p/10-a/10-b.md", status: "active")

      expect(stage("p").rollup).to include("status" => "in_progress", "done" => 0, "total" => 1)
    end
  end

  describe Workspace::SpineRollup do
    # [states, status, done, total], mirroring rollUp in workspace-ui's src/core/spine/model.ts
    {
      [] => nil,
      %w[skipped] => ["skipped", 0, 0],
      %w[skipped skipped] => ["skipped", 0, 0],
      %w[completed] => ["completed", 1, 1],
      %w[completed skipped] => ["completed", 1, 1],
      %w[completed completed] => ["completed", 2, 2],
      %w[completed blocked] => ["blocked", 1, 2],
      %w[blocked not_started] => ["blocked", 0, 2],
      %w[blocked in_progress] => ["blocked", 0, 2],
      %w[in_progress not_started] => ["in_progress", 0, 2],
      %w[completed not_started] => ["in_progress", 1, 2],
      %w[disputed not_started] => ["in_progress", 0, 2],
      %w[disputed] => ["in_progress", 0, 1],
      %w[disputed completed] => ["in_progress", 1, 2],
      %w[not_started not_started] => ["not_started", 0, 2],
      %w[unknown not_started] => ["not_started", 0, 2],
      %w[unknown] => ["not_started", 0, 1],
      %w[skipped not_started] => ["not_started", 0, 1],
      %w[skipped blocked] => ["blocked", 0, 1]
    }.each do |states, expected|
      it "rolls #{states.inspect} up to #{expected.inspect}" do
        result = described_class.call(states)

        if expected.nil?
          expect(result).to be_nil
        else
          expect([result["status"], result["done"], result["total"]]).to eq(expected)
          expect(result["counts"].values.sum).to eq(states.size)
        end
      end
    end

    it "counts a state it does not know as unknown" do
      expect(described_class.call(%w[weird])["counts"]["unknown"]).to eq(1)
    end

    it "takes the roll-up's status for a stage with none of its own" do
      expect(described_class.effective("unknown", {"status" => "completed"})).to eq("completed")
      expect(described_class.effective("unknown", nil)).to eq("unknown")
      expect(described_class.effective("blocked", {"status" => "completed"})).to eq("blocked")
    end
  end

  describe "a folder without a stage file" do
    it "shows an unknown stage with folder_without_file and its children" do
      write("30-implement/10-api.md", status: "done")

      implement = doc["stages"].first

      expect(implement).to include("path" => "implement", "file" => nil, "revision" => nil, "status" => "unknown", "status_raw" => nil, "title" => "Implement", "modified_at" => nil)
      expect(implement["warnings"].map { |w| w["code"] }).to eq(["folder_without_file"])
      expect(implement["children"].map { |c| c["path"] }).to eq(["implement/api"])
      expect(implement["rollup"]["status"]).to eq("completed")
    end
  end

  describe "links" do
    it "does not follow a linked stage file" do
      outside = File.join(@notes, "outside.md")
      File.write(outside, "---\nstatus: done\n---\n")
      FileUtils.mkdir_p(File.join(@notes, "spine"))
      File.symlink(outside, File.join(@notes, "spine", "40-verify.md"))

      verify = doc["stages"].first

      expect(verify).to include("path" => "verify", "status" => "unknown", "revision" => nil)
      expect(verify["warnings"].map { |w| w["code"] }).to eq(["link"])
    end

    it "does not follow a linked stage folder, and warns link on its stage" do
      elsewhere = File.join(@notes, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      File.write(File.join(elsewhere, "10-secret.md"), "---\nstatus: done\n---\n")
      write("30-implement.md", status: "todo")
      File.symlink(elsewhere, File.join(@notes, "spine", "30-implement"))

      implement = doc["stages"].first

      expect(implement["children"]).to eq([])
      expect(implement["warnings"].map { |w| w["code"] }).to eq(["link"])
      expect(implement).not_to have_key("rollup")
    end

    it "shows a linked stage folder with no stage file as a stage with link only" do
      elsewhere = File.join(@notes, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      FileUtils.mkdir_p(File.join(@notes, "spine"))
      File.symlink(elsewhere, File.join(@notes, "spine", "30-implement"))

      expect(doc["stages"].first["warnings"].map { |w| w["code"] }).to eq(["link"])
    end

    it "does not follow a linked spine folder" do
      elsewhere = File.join(@notes, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      File.write(File.join(elsewhere, "10-a.md"), "---\nstatus: done\n---\n")
      File.symlink(elsewhere, File.join(@notes, "spine"))

      expect(doc).to include("exists" => true, "stages" => [])
      expect(doc["warnings"].map { |w| w["code"] }).to eq(["link"])
    end

    it "does not follow a linked goal.md" do
      outside = File.join(@notes, "outside.md")
      File.write(outside, "---\ntitle: Stolen\n---\n")
      FileUtils.mkdir_p(File.join(@notes, "spine"))
      File.symlink(outside, File.join(@notes, "spine", "goal.md"))

      expect(doc["goal"]).to include("file" => "goal.md", "title" => nil, "revision" => nil)
      expect(doc["goal"]["warnings"].map { |w| w["code"] }).to eq(["link"])
    end
  end

  describe "things that are not stages" do
    it "lists misnamed files and folders, hidden names left out" do
      write("10-a.md", status: "todo")
      write("Research notes.md", "# x\n")
      write("1000-four.md", "x")
      write("20-Upper.md", "x")
      write(".DS_Store", "x")
      write("misc/note.md", "x")
      write("10-a/notes.md", "x")

      expect(doc["not_stages"]).to eq(["10-a/notes.md", "1000-four.md", "20-Upper.md", "Research notes.md", "misc"])
    end

    it "refuses a folder named like a stage file" do
      FileUtils.mkdir_p(File.join(@notes, "spine", "40-verify.md"))

      expect(doc["stages"].first["warnings"].map { |w| w["code"] }).to eq(["not_a_file"])
    end

    it "keeps goal.md out of the stages and reads it with its warnings" do
      write("goal.md", "no frontmatter\n")

      expect(doc["goal"]).to include("title" => nil)
      expect(doc["goal"]["warnings"].map { |w| w["code"] }).to eq(["no_frontmatter"])
      expect(doc["not_stages"]).to eq([])
    end

    it "does not treat a nested goal.md as the goal" do
      write("30-a.md", status: "todo")
      write("30-a/goal.md", "x")

      expect(doc["goal"]).to be_nil
      expect(doc["not_stages"]).to eq(["30-a/goal.md"])
    end
  end

  describe "limits" do
    it "reads 64 names in a folder and says truncated: entries" do
      70.times { |i| write("n#{format("%02d", i)}.txt", "x") }

      expect(doc["not_stages"].size).to eq(64)
      expect(doc["truncated"]).to eq("entries")
    end

    it "reads 24 stages in a folder" do
      30.times { |i| write("#{format("%02d", i + 1)}-s#{i}.md", status: "todo") }

      expect(doc["stages"].size).to eq(24)
      expect(doc["stages"].last["number"]).to eq(24)
      expect(doc["truncated"]).to eq("stages")
    end

    it "reads 96 stages in all, later folders not at all" do
      6.times do |parent|
        write("#{(parent + 1) * 10}-p#{parent}.md", status: "todo")
        write("#{(parent + 1) * 10}-p#{parent}/10-first.md", status: "todo")
        20.times { |i| write("#{(parent + 1) * 10}-p#{parent}/#{(i + 2) * 10}-c#{i}.md", status: "todo") }
      end

      count = 0
      tree.each_stage { count += 1 }

      expect(count).to eq(96)
      expect(doc["truncated"]).to eq("stages")
      expect(stage("p4/first")).to be_a(Workspace::SpineTree::Stage)
      expect(tree.stages.last.children.size).to be < 21
    end

    it "counts a folder's stages before descending, so a big early stage does not starve later ones" do
      write("10-a.md", status: "todo")
      24.times { |i| write("10-a/#{format("%02d", i + 1)}-c#{i}.md", status: "todo") }
      24.times { |i| 3.times { |j| write("10-a/#{format("%02d", i + 1)}-c#{i}/#{j + 1}0-g#{j}.md", status: "todo") } }
      write("90-ship.md", status: "todo")

      expect(doc["stages"].map { |s| s["path"] }).to eq(%w[a ship])
      expect(doc["truncated"]).to eq("stages")
    end

    it "does not truncate within the limits" do
      24.times { |i| write("#{format("%02d", i + 1)}-s#{i}.md", status: "todo") }

      expect(doc["stages"].size).to eq(24)
      expect(doc["truncated"]).to be_nil
    end
  end

  it "does not write anything in the notes directory" do
    write("40-verify.md", status: "todo")
    before = Dir.glob(File.join(@notes, "**", "*"), File::FNM_DOTMATCH).sort.map { |p| [p, File.mtime(p)] }

    tree.to_h

    expect(Dir.glob(File.join(@notes, "**", "*"), File::FNM_DOTMATCH).sort.map { |p| [p, File.mtime(p)] }).to eq(before)
  end

  it "survives a spine of random bytes" do
    random = Random.new(3)
    30.times do |i|
      write("#{i}0-s#{i}.md", Array.new(random.rand(0..200)) { random.rand(256) }.pack("C*"))
    end

    expect { JSON.generate(doc) }.not_to raise_error
  end
end
