require "tmpdir"

RSpec.describe Workspace::TaskStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:dir) { File.join(tmpdir, "tasks") }
  let(:error_output) { StringIO.new }
  let(:now) { [Time.utc(2026, 10, 2, 12, 0, 0)] }
  let(:store) { described_class.new(dir: dir, clock: -> { now.first }, error_output: error_output) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#start" do
    it "creates a task record readable by workspace, with private modes" do
      task = store.start(workspace: "app.worktree-X", title: "Fix login", ref: "PROJ-1", branch: "PROJ-1", path: "/w/X")

      expect(task).to include("workspace" => "app.worktree-X", "title" => "Fix login", "ref" => "PROJ-1",
        "branch" => "PROJ-1", "path" => "/w/X", "created_at" => "2026-10-02T12:00:00Z")
      expect(task["id"]).to match(/\A\h{8}\z/)
      expect(store.active_for("app.worktree-X")).to eq(task)
      file = File.join(dir, "#{task["id"]}.json")
      expect(File.stat(file).mode & 0o777).to eq(0o600)
      expect(File.stat(dir).mode & 0o777).to eq(0o700)
    end

    it "returns the active task when the workspace already has one" do
      first = store.start(workspace: "w", title: "A")

      expect(store.start(workspace: "w")["id"]).to eq(first["id"])
      expect(Dir.glob(File.join(dir, "*.json")).size).to eq(1)
    end

    it "replaces the title of an existing task only when one is given" do
      first = store.start(workspace: "w", title: "A")

      expect(store.start(workspace: "w", title: "B")["title"]).to eq("B")
      expect(store.start(workspace: "w")["title"]).to eq("B")
      expect(store.active_for("w")["id"]).to eq(first["id"])
    end

    it "keeps every task when invocations start at the same moment" do
      threads = 8.times.map { |i| Thread.new { store.start(workspace: "w#{i}") } }
      threads.each(&:join)

      expect(Dir.glob(File.join(dir, "*.json")).size).to eq(8)
    end

    it "raises Workspace::Error when the store directory can't be created" do
      File.write(File.join(tmpdir, "blocked"), "")
      blocked = described_class.new(dir: File.join(tmpdir, "blocked", "tasks"))

      expect { blocked.start(workspace: "w") }.to raise_error(Workspace::Error, /Could not access task store/)
    end
  end

  describe "#active_for" do
    it "is nil and creates nothing when there is no store" do
      expect(store.active_for("w")).to be_nil
      expect(File.exist?(dir)).to be(false)
    end

    it "skips a file that is not a task record, with a warning, and leaves it" do
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "bad.json"), "{nope")
      File.write(File.join(dir, "list.json"), "[]")
      task = store.start(workspace: "w")

      expect(store.active_for("w")).to eq(task)
      expect(error_output.string).to include("bad.json (not valid JSON)", "list.json (not a task record)")
      expect(File.exist?(File.join(dir, "bad.json"))).to be(true)
    end
  end

  describe "warnings" do
    it "warn once per version of a bad file, again after it changes" do
      FileUtils.mkdir_p(dir)
      bad = File.join(dir, "bad.json")
      File.write(bad, "{nope")

      3.times { store.active_for("w") }
      expect(error_output.string.scan("bad.json").size).to eq(1)

      File.write(bad, "{still nope")
      File.utime(Time.now + 5, Time.now + 5, bad)
      store.active_for("w")
      expect(error_output.string.scan("bad.json").size).to eq(2)
    end
  end

  describe "#archive" do
    it "moves the task to archive/ with its outcome and removes it from the active set" do
      task = store.start(workspace: "w", title: "A")
      now[0] = Time.utc(2026, 10, 3)

      archived = store.archive("w", outcome: "merged")

      expect(archived).to include("id" => task["id"], "outcome" => "merged", "archived_at" => "2026-10-03T00:00:00Z", "title" => "A")
      expect(store.active_for("w")).to be_nil
      expect(File.exist?(File.join(dir, "#{task["id"]}.json"))).to be(false)
      expect(File.stat(File.join(dir, "archive", "#{task["id"]}.json")).mode & 0o777).to eq(0o600)
      expect(store.archived.map { |r| r["id"] }).to eq([task["id"]])
    end

    it "is nil when the workspace has no active task" do
      expect(store.archive("w", outcome: "abandoned")).to be_nil
    end

    it "gives a restarted workspace a new task" do
      first = store.start(workspace: "w")
      store.archive("w", outcome: "abandoned")

      expect(store.start(workspace: "w")["id"]).not_to eq(first["id"])
    end

    it "rejects an unknown outcome" do
      store.start(workspace: "w")

      expect { store.archive("w", outcome: "done") }.to raise_error(ArgumentError, /unknown outcome/)
      expect(store.active_for("w")).not_to be_nil
    end

    it "keeps only the newest ARCHIVE_LIMIT archived tasks" do
      stub_const("Workspace::TaskStore::ARCHIVE_LIMIT", 3)
      ids = 5.times.map do |i|
        now[0] = Time.utc(2026, 10, 2, 12, i)
        id = store.start(workspace: "w#{i}")["id"]
        store.archive("w#{i}", outcome: "merged")
        id
      end

      expect(store.archived.map { |r| r["id"] }).to eq(ids.last(3).reverse)
    end
  end
end
