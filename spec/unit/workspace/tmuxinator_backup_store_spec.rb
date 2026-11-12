require "tmpdir"
require "digest"
require "json"

RSpec.describe Workspace::TmuxinatorBackupStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:now) { Time.utc(2026, 11, 12, 10, 0, 0) }
  let(:clock) { double("clock", now: now) }
  let(:suffixes) { %w[aaaaaa bbbbbb cccccc dddddd eeeeee ffffff].each }
  subject(:store) { described_class.new(config: config, writer: writer, clock: clock, id_suffix: -> { suffixes.next }) }

  around do |example|
    old = ENV["XDG_STATE_HOME"]
    ENV["XDG_STATE_HOME"] = state_home
    example.run
  ensure
    ENV["XDG_STATE_HOME"] = old
    FileUtils.rm_rf(tmpdir)
  end

  def sha(text) = Digest::SHA256.hexdigest(text)

  def config_file(name, text)
    path = File.join(tmpdir, "tmuxinator", "workspace.#{name}.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def record_file(name, text)
    path = writer.record_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def manifest(batch) = JSON.parse(File.read(File.join(batch.dir, "manifest.json")))

  it "keeps batches under the tmuxinator backups state directory" do
    expect(config.tmuxinator_backups_dir).to eq(File.join(state_home, "workspace", "backups", "tmuxinator"))
  end

  describe "#open" do
    it "makes the batch directory and a manifest with no entries" do
      batch = store.open(reason: "apply", templates: {"project.yml" => "abc"})

      expect(batch.id).to eq("20261112T100000000000Z-aaaaaa")
      expect(manifest(batch)).to eq({
        "schema" => 1, "id" => batch.id, "created_at" => "2026-11-12T10:00:00.000000Z", "reason" => "apply",
        "templates" => {"project.yml" => "abc"}, "entries" => [], "sets" => []
      })
    end
  end

  describe "#add" do
    let(:batch) { store.open(reason: "apply") }

    it "copies the config and the render record and lists them with their shas" do
      path = config_file("app", "one\n")
      record = record_file("app", "{}\n")

      entry = store.add(batch, name: "app", path: path)

      expect(entry).to include("name" => "app", "path" => path, "sha_before" => sha("one\n"),
        "record_path" => record, "record_sha_before" => sha("{}\n"))
      expect(File.read(store.copy_path(batch, "app"))).to eq("one\n")
      expect(File.read(store.copy_path(batch, "app", kind: :record))).to eq("{}\n")
      expect(manifest(batch)["entries"]).to eq([entry])
    end

    it "records a nil sha_before for a file that did not exist, so the batch is known to have created it" do
      path = File.join(tmpdir, "tmuxinator", "workspace.new.yml")

      entry = store.add(batch, name: "new", path: path)

      expect(entry).to include("sha_before" => nil, "record_sha_before" => nil)
      expect(store.copy_path(batch, "new")).to be_nil
      expect(store.copy_path(batch, "new", kind: :record)).to be_nil
    end

    it "keeps the first entry and copy of a workspace added twice" do
      path = config_file("a", "a1")
      first = store.add(batch, name: "a", path: path)
      store.add(batch, name: "b", path: config_file("b", "b1"))
      File.write(path, "a2")

      expect(store.add(batch, name: "a", path: path)).to eq(first)
      expect(manifest(batch)["entries"].map { |e| [e["name"], e["sha_before"]] }).to eq([["a", sha("a1")], ["b", sha("b1")]])
      expect(File.read(store.copy_path(batch, "a"))).to eq("a1")
    end

    it "treats a manifest whose entries are not all Hashes as unreadable" do
      File.write(File.join(batch.dir, "manifest.json"), JSON.generate(manifest(batch).merge("entries" => ["x"])))

      expect(store.list).to eq([])
    end

    it "raises, and lists nothing, when the copy cannot be written, rather than calling a real file created" do
      path = config_file("app", "one")
      FileUtils.chmod(0o500, batch.dir)

      expect { store.add(batch, name: "app", path: path) }.to raise_error(SystemCallError)
      expect(manifest(batch)["entries"]).to eq([])
    ensure
      FileUtils.chmod(0o700, batch.dir)
    end

    it "stores the bytes it hashes" do
      path = config_file("app", "caf\xC3\xA9\n")

      entry = store.add(batch, name: "app", path: path)

      expect(File.binread(store.copy_path(batch, "app"))).to eq("caf\xC3\xA9\n".b)
      expect(entry["sha_before"]).to eq(sha("caf\xC3\xA9\n".b))
    end

    it "refuses a config that is a symbolic link, with backup_symlink" do
      target = config_file("real", "x")
      link = File.join(tmpdir, "tmuxinator", "workspace.app.yml")
      File.symlink(target, link)

      expect { store.add(batch, name: "app", path: link) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("backup_symlink") }
      expect(manifest(batch)["entries"]).to eq([])
    end

    it "refuses a render record that is a symbolic link" do
      path = config_file("app", "x")
      FileUtils.mkdir_p(File.dirname(writer.record_path("app")))
      File.symlink(path, writer.record_path("app"))

      expect { store.add(batch, name: "app", path: path) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("backup_symlink") }
    end

    it "refuses a name that is not a plain file name" do
      ["", ".", "..", "a/b", "../x", nil].each do |bad|
        expect { store.add(batch, name: bad, path: "/nope") }.to raise_error(ArgumentError)
        expect { store.copy_path(batch, bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#open" do
    it "keeps batches made in one second apart and ordered by their time" do
      times = [Time.utc(2026, 11, 12, 10, 0, 0, 5), Time.utc(2026, 11, 12, 10, 0, 0, 9)]
      allow(clock).to receive(:now).and_return(*times)
      first = store.open(reason: "apply")
      second = store.open(reason: "apply")

      expect(store.list.map { |m| m["id"] }).to eq([second.id, first.id])
    end

    it "tries another suffix when the id is taken" do
      taken = %w[aaaaaa aaaaaa bbbbbb].each
      store = described_class.new(config: config, writer: writer, clock: clock, id_suffix: -> { taken.next })
      first = store.open(reason: "apply")
      second = store.open(reason: "apply")

      expect([first.id, second.id].uniq.size).to eq(2)
      expect(second.id).to end_with("-bbbbbb")
    end
  end

  describe "#finish" do
    it "fills sha_after for a listed workspace" do
      batch = store.open(reason: "apply")
      store.add(batch, name: "app", path: config_file("app", "one"))

      store.finish(batch, name: "app", sha_after: sha("two"), record_sha_after: sha("r"))

      expect(manifest(batch)["entries"].first).to include("sha_after" => sha("two"), "record_sha_after" => sha("r"))
    end

    it "answers nil for a workspace the batch does not list" do
      expect(store.finish(store.open(reason: "apply"), name: "x", sha_after: nil)).to be_nil
    end
  end

  describe "#create" do
    it "opens a batch and adds every entry" do
      batch = store.create([{name: "a", path: config_file("a", "1")}, {name: "b", path: config_file("b", "2")}], reason: "manual")

      expect(manifest(batch)).to include("reason" => "manual")
      expect(manifest(batch)["entries"].map { |e| e["name"] }).to eq(%w[a b])
    end
  end

  describe "#discard_if_empty" do
    it "does nothing for a batch whose manifest is unreadable" do
      batch = store.open(reason: "apply")
      File.write(File.join(batch.dir, "manifest.json"), "{")

      expect(store.discard_if_empty(batch)).to be(false)
      expect(Dir.exist?(batch.dir)).to be(true)
    end

    it "removes a batch with no entries" do
      batch = store.open(reason: "apply")

      expect(store.discard_if_empty(batch)).to be(true)
      expect(Dir.exist?(batch.dir)).to be(false)
    end

    it "keeps a batch with an entry" do
      batch = store.open(reason: "apply")
      store.add(batch, name: "a", path: config_file("a", "1"))

      expect(store.discard_if_empty(batch)).to be(false)
      expect(Dir.exist?(batch.dir)).to be(true)
    end
  end

  describe "#list and #find" do
    it "lists newest first and skips a directory whose manifest is unreadable" do
      first = store.open(reason: "apply")
      second = store.open(reason: "manual")
      File.write(File.join(first.dir, "manifest.json"), "{")
      third = store.open(reason: "restore")

      expect(store.list.map { |m| m["id"] }).to eq([third.id, second.id])
    end

    it "is empty before any batch exists" do
      expect(store.list).to eq([])
    end

    it "finds a batch by id" do
      batch = store.open(reason: "apply")

      expect(store.find(batch.id)).to include("id" => batch.id, "reason" => "apply")
    end

    it "raises backup_not_found for an unknown id and one that could climb out of the directory" do
      store.open(reason: "apply")

      ["20261112T100000000000Z-ffffff", "../x", ""].each do |id|
        expect { store.find(id) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("backup_not_found") }
      end
    end
  end

  describe "#prune" do
    def batch_at(time, names)
      allow(clock).to receive(:now).and_return(time)
      batch = store.open(reason: "apply")
      names.each { |name| store.add(batch, name: name, path: config_file(name, name)) }
      batch
    end

    it "keeps a batch past keep when it is the newest to hold a workspace" do
      4.times { |i| batch_at(now + i, ["w#{i}"]) }

      expect(store.prune(keep: 1)).to eq([])
      expect(store.list.size).to eq(4)
    end

    it "removes the older batches past keep when a newer batch holds the same workspaces" do
      old = batch_at(now, %w[a b])
      mid = batch_at(now + 1, %w[a b])
      newest = batch_at(now + 2, %w[a b])

      expect(store.prune(keep: 1)).to eq([mid.id, old.id])
      expect(store.list.map { |m| m["id"] }).to eq([newest.id])
    end

    it "never removes the newest batch of a workspace, however old or far down" do
      only_a = batch_at(now, %w[a])
      batch_at(now + 1, %w[b])
      batch_at(now + 2, %w[b])
      allow(clock).to receive(:now).and_return(now + 365 * 86_400)

      removed = store.prune(keep: 1, max_age: 86_400)

      expect(removed.size).to eq(1)
      expect(removed).not_to include(only_a.id)
      expect(store.list.map { |m| m["id"] }).to include(only_a.id)
    end

    it "removes batches older than max_age but not newer ones" do
      old = batch_at(now, %w[a])
      fresh = batch_at(now + 3 * 86_400, %w[a])
      allow(clock).to receive(:now).and_return(now + 3 * 86_400 + 60)

      expect(store.prune(max_age: 86_400)).to eq([old.id])
      expect(store.list.map { |m| m["id"] }).to eq([fresh.id])
    end

    it "counts a batch with no entries toward keep and removes it once past it" do
      older = batch_at(now, %w[a])
      empty = batch_at(now + 1, [])
      batch_at(now + 2, %w[a])

      expect(store.prune(keep: 2)).to eq([older.id])
      expect(store.prune(keep: 1)).to eq([empty.id])
    end

    it "keeps a batch whose created_at cannot be read when pruning by age" do
      odd = batch_at(now, %w[a])
      manifest_path = File.join(odd.dir, "manifest.json")
      File.write(manifest_path, JSON.generate(JSON.parse(File.read(manifest_path)).merge("created_at" => "junk")))
      batch_at(now + 1, %w[a])
      allow(clock).to receive(:now).and_return(now + 365 * 86_400)

      expect(store.prune(max_age: 86_400)).to eq([])
    end

    it "sweeps an id-shaped directory with no manifest once it is over an hour old, and not before" do
      stray = File.join(config.tmuxinator_backups_dir, "20261112T100000000000Z-abcdef")
      FileUtils.mkdir_p(stray)
      File.utime(now, now, stray)
      allow(clock).to receive(:now).and_return(now + 600)
      expect(store.prune).to eq([])
      allow(clock).to receive(:now).and_return(now + 3700)

      expect(store.prune).to eq(["20261112T100000000000Z-abcdef"])
      expect(Dir.exist?(stray)).to be(false)
    end

    it "orders by created_at, so a later batch is newest whatever its suffix" do
      later = batch_at(now + 1, %w[a])
      earlier = batch_at(now, %w[a])

      expect(store.list.map { |m| m["id"] }).to eq([later.id, earlier.id])
    end

    it "does nothing with no limits" do
      batch_at(now, %w[a])
      batch_at(now + 1, %w[a])

      expect(store.prune).to eq([])
    end
  end
end
