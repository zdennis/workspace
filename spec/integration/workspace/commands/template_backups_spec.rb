require "spec_helper"
require "tmpdir"
require "digest"
require "stringio"

# Commands::TemplateBackups over a real TmuxinatorBackupStore, TmuxinatorConfigWriter and NameMigration lock in a
# temporary directory; the selection and the project config are doubles.
RSpec.describe Workspace::Commands::TemplateBackups do
  around do |example|
    Dir.mktmpdir("template-backups") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) do
    instance_double(Workspace::Config, render_state_dir: File.join(@dir, "state", ".render"), tmuxinator_backups_dir: File.join(@dir, "state", "backups", "tmuxinator")).tap do |c|
      allow(c).to receive(:config_path_for) { |name| File.join(@dir, "tmuxinator", "workspace.#{name}.yml") }
      allow(c).to receive(:agent_lock_path) { |name| File.join(@dir, "locks", "#{name}.lock") }
    end
  end
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:backups) { Workspace::TmuxinatorBackupStore.new(config: config, writer: writer) }
  let(:locks) { Workspace::NameMigration.new(config: config, project_config: nil, tmux: nil, state: nil, event_log: nil, project_catalog_factory: nil, writer: writer) }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig).tap do |pc|
      allow(pc).to receive(:config_path_for) { |name| config.config_path_for(name) }
      allow(pc).to receive(:exists?) { |name| File.exist?(config.config_path_for(name)) }
    end
  end
  let(:selection) { ->(names:, **) { names } }
  let(:retention) { instance_double(Workspace::TmuxinatorBackupConfig, keep: 20, max_age: nil) }
  let(:output) { StringIO.new }
  subject(:command) { described_class.new(backups: backups, selection: selection, locks: locks, project_config: project_config, retention: retention, writer: writer, output: output) }

  before { FileUtils.mkdir_p([File.join(@dir, "locks"), File.join(@dir, "tmuxinator")]) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def path(name) = config.config_path_for(name)

  def render(name, text, root: nil)
    writer.write(name, text, kind: :project, template: "team", template_sha: sha("tpl"),
      inputs: {workspace_name: name, agent_kind: "claude", agent_command: "claude", project_root: root})
  end

  def record_text(name) = File.read(writer.record_path(name))

  def outcomes(result) = result[:results].to_h { |row| [row["workspace"], [row["outcome"], row["reason"]]] }

  # What `template apply` leaves: a batch of reason apply with the file as it was and as it was written.
  def apply_batch(name, before:, after:, root: nil)
    render(name, before, root: root) if before
    batch = backups.open(reason: "apply")
    backups.add(batch, name: name, path: path(name))
    render(name, after, root: root)
    backups.finish(batch, name: name, sha_after: sha(after), record_sha_after: sha(record_text(name)))
    batch.id
  end

  describe "#backup" do
    it "copies each config and record into one manual batch" do
      render("a", "a v1\n")
      render("b", "b v1\n")

      result = command.backup(names: %w[a b])

      expect(outcomes(result)).to eq("a" => ["backed_up", nil], "b" => ["backed_up", nil])
      manifest = backups.find(result[:extra]["backup"])
      expect(manifest).to include("reason" => "manual")
      expect(manifest["entries"].map { |e| e["name"] }).to eq(%w[a b])
      expect(File.read(backups.copy_path(manifest, "a"))).to eq("a v1\n")
      expect(File.read(backups.copy_path(manifest, "a", kind: :record))).to eq(record_text("a"))
      expect(result).to include(status: "ok", exit_code: 0)
      expect(output.string).to include("a: backed up", "Backup: #{manifest["id"]}")
    end

    it "skips a workspace whose config is gone, and keeps no batch when nothing was copied" do
      result = command.backup(names: %w[ghost])

      expect(outcomes(result)).to eq("ghost" => ["skipped", "gone"])
      expect(result[:extra]).to include("backup" => nil, "skipped" => {"gone" => 1})
      expect(backups.list).to be_empty
    end

    it "fails a config that is a symbolic link and copies the rest" do
      render("a", "a\n")
      File.write(File.join(@dir, "real.yml"), "x\n")
      File.symlink(File.join(@dir, "real.yml"), path("b"))

      result = command.backup(names: %w[a b])

      expect(outcomes(result)).to eq("a" => ["backed_up", nil], "b" => ["failed", "backup_symlink"])
      expect(result).to include(status: "partial", exit_code: 3)
    end

    it "gives a lock that can't be taken a workspace_locked row" do
      render("a", "a\n")
      allow(locks).to receive(:with_locks).and_raise(Workspace::NameMigration::LockUnavailable, "Permission denied")

      expect(outcomes(command.backup(names: %w[a]))).to eq("a" => ["failed", "workspace_locked"])
    end
  end

  describe "#list and #prune" do
    it "lists the batches newest first, as text and as a document" do
      render("a", "a\n")
      first = command.backup(names: %w[a])[:extra]["backup"]
      second = command.backup(names: %w[a])[:extra]["backup"]
      output.truncate(0)
      output.rewind

      command.list
      expect(output.string.lines.map { |l| l.split.first }).to eq([second, first])

      output.truncate(0)
      output.rewind
      command.list(json: true)
      doc = JSON.parse(output.string)
      expect(doc["backups"].map { |b| b["id"] }).to eq([second, first])
      expect(doc["backups"].first).to include("reason" => "manual", "workspaces" => ["a"])
    end

    it "says there are none" do
      command.list
      expect(output.string).to eq("No tmuxinator backups.\n")
    end

    it "removes the batches past the limits but keeps each workspace's newest" do
      render("a", "a\n")
      render("b", "b\n")
      old_a = command.backup(names: %w[a])[:extra]["backup"]
      command.backup(names: %w[a b])
      allow(retention).to receive(:keep).and_return(1)

      result = command.prune

      expect(result[:results]).to eq([{"id" => old_a, "outcome" => "pruned"}])
      expect(result[:extra]).to eq("kept" => 1)
    end
  end

  describe "#restore" do
    it "puts a written config and its record back, takes a batch of what it replaced and keeps the file's mode" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      old_record = backups.find(batch)["entries"].first
      File.chmod(0o600, path("a"))

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["restored", nil])
      expect(File.read(path("a"))).to eq("a v1\n")
      expect(sha(record_text("a"))).to eq(old_record["record_sha_before"])
      expect(File.stat(path("a")).mode & 0o777).to eq(0o600)
      own = backups.find(result[:extra]["backup"])
      expect(own).to include("reason" => "restore")
      expect(File.read(backups.copy_path(own, "a"))).to eq("a v2\n")
      expect(result[:extra]).to include("restored_from" => batch)
    end

    it "refuses a config edited since the batch wrote it, writing nothing for that workspace, until --force" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      File.write(path("a"), "hand edit\n")

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["failed", "restore_conflict"])
      expect(result[:results].first).to include("code" => "restore_conflict", "files" => ["config"])
      expect(result).to include(status: "failed", exit_code: 1)
      expect(File.read(path("a"))).to eq("hand edit\n")
      expect(result[:extra]["backup"]).to be_nil

      forced = command.restore(id: batch, force: true)

      expect(outcomes(forced)).to eq("a" => ["restored", nil])
      expect(File.read(path("a"))).to eq("a v1\n")
      expect(File.read(backups.copy_path(backups.find(forced[:extra]["backup"]), "a"))).to eq("hand edit\n")
    end

    it "refuses a record changed since the batch wrote it, and leaves the config alone" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      File.write(writer.record_path("a"), "{}")

      result = command.restore(id: batch)

      expect(result[:results].first).to include("outcome" => "failed", "files" => ["record"])
      expect(File.read(path("a"))).to eq("a v2\n")
    end

    it "deletes a config and record the batch created" do
      batch = apply_batch("new", before: nil, after: "new v1\n")

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("new" => ["restored", nil])
      expect(File.exist?(path("new"))).to be(false)
      expect(File.exist?(writer.record_path("new"))).to be(false)
    end

    it "restores only the workspaces named, and refuses one the batch lacks" do
      a = apply_batch("a", before: "a v1\n", after: "a v2\n")
      expect { command.restore(id: a, names: %w[zzz]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }

      render("b", "b v1\n")
      batch = backups.open(reason: "apply")
      %w[a b].each do |name|
        backups.add(batch, name: name, path: path(name))
        backups.finish(batch, name: name, sha_after: sha(File.read(path(name))), record_sha_after: sha(record_text(name)))
      end
      render("b", "b v2\n")
      backups.finish(batch, name: "b", sha_after: sha("b v2\n"), record_sha_after: sha(record_text("b")))

      result = command.restore(id: batch.id, names: %w[b])

      expect(outcomes(result)).to eq("b" => ["restored", nil])
      expect(File.read(path("b"))).to eq("b v1\n")
    end

    it "says unchanged for files already as the batch has them, and takes no batch" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      command.restore(id: batch)

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["unchanged", nil])
      expect(result[:extra]["backup"]).to be_nil
    end

    it "skips a workspace whose config and record are gone and whose name no longer exists" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      File.delete(path("a"))
      writer.remove_record("a")

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["skipped", "gone"])
      expect(result[:extra]["skipped"]).to eq("gone" => 1)
      expect(File.exist?(path("a"))).to be(false)
    end

    it "reads the files inside the lock, so a remove that finished while it waited is seen as gone" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      real = locks
      removing = Class.new do
        def initialize(real, step) = (@real, @step = real, step)

        def with_locks(*names, &block)
          @step.call
          @real.with_locks(*names, &block)
        end
      end
      step = lambda do
        File.delete(path("a"))
        writer.remove_record("a")
      end
      command = described_class.new(backups: backups, selection: selection, locks: removing.new(real, step), project_config: project_config, retention: retention, writer: writer, output: output)

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["skipped", "gone"])
      expect(File.exist?(path("a"))).to be(false)
    end

    it "reads the checkout from the config copy when the batch has no record, restoring while it exists" do
      checkout = File.join(@dir, "checkout")
      FileUtils.mkdir_p(checkout)
      File.write(path("plain"), "name: plain\nroot: #{checkout}\n")
      File.write(path("removed"), "name: removed\nroot: #{File.join(@dir, "nope")}\n")
      File.write(path("unknown"), "not yaml root\n")
      batch = command.backup(names: %w[plain removed unknown])[:extra]["backup"]
      %w[plain removed unknown].each { |name| File.delete(path(name)) }

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("plain" => ["restored", nil], "removed" => ["skipped", "gone"], "unknown" => ["skipped", "gone"])
      expect(result[:results].last["message"]).to include("doesn't say where its checkout is")
      expect(File.exist?(writer.record_path("plain"))).to be(false)

      forced = command.restore(id: batch, force: true)
      expect(outcomes(forced)["unknown"]).to eq(["restored", nil])
      expect(File.exist?(path("unknown"))).to be(true)
    end

    it "brings back a file deleted alone, without --force" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      File.delete(writer.record_path("a"))
      expect(outcomes(command.restore(id: batch))).to eq("a" => ["restored", nil])
      expect(File.exist?(writer.record_path("a"))).to be(true)
      expect(File.read(path("a"))).to eq("a v1\n")

      batch = apply_batch("b", before: "b v1\n", after: "b v2\n")
      File.delete(path("b"))
      expect(outcomes(command.restore(id: batch))).to eq("b" => ["restored", nil])
      expect(File.read(path("b"))).to eq("b v1\n")
    end

    it "puts back a batch that deleted a config" do
      render("a", "a v1\n")
      batch = backups.open(reason: "apply")
      backups.add(batch, name: "a", path: path("a"))
      File.delete(path("a"))
      writer.remove_record("a")
      backups.finish(batch, name: "a", sha_after: nil, record_sha_after: nil)

      result = command.restore(id: batch.id)

      expect(outcomes(result)).to eq("a" => ["restored", nil])
      expect(File.read(path("a"))).to eq("a v1\n")
    end

    it "refuses a manual backup's file that changed since, until --force" do
      render("a", "a v1\n")
      manual = command.backup(names: %w[a])[:extra]["backup"]
      File.write(path("a"), "later edit\n")

      expect(outcomes(command.restore(id: manual))).to eq("a" => ["failed", "restore_conflict"])
      expect(File.read(path("a"))).to eq("later edit\n")
      expect(outcomes(command.restore(id: manual, force: true))).to eq("a" => ["restored", nil])
      expect(File.read(path("a"))).to eq("a v1\n")
    end

    it "keeps a config's mode past the umask, and makes a recreated config and record by the writer's rules" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      File.chmod(0o664, path("a"))
      old_umask = File.umask(0o077)
      begin
        command.restore(id: batch)
        expect(File.stat(path("a")).mode & 0o777).to eq(0o664)

        gone = apply_batch("g", before: "g v1\n", after: "g v2\n", root: @dir)
        File.delete(path("g"))
        File.delete(writer.record_path("g"))
        command.restore(id: gone)
        expect(File.stat(writer.record_path("g")).mode & 0o777).to eq(0o600)
        expect(File.stat(path("g")).mode & 0o777).to eq(0o600)
      ensure
        File.umask(old_umask)
      end
    end

    it "restores an accidentally deleted config while its checkout remains, and skips one whose checkout is gone" do
      checkout = File.join(@dir, "checkout")
      FileUtils.mkdir_p(checkout)
      render("kept", "kept v1\n", root: checkout)
      render("lost", "lost v1\n", root: File.join(@dir, "removed"))
      batch = command.backup(names: %w[kept lost])[:extra]["backup"]
      %w[kept lost].each do |name|
        File.delete(path(name))
        writer.remove_record(name)
      end

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("kept" => ["restored", nil], "lost" => ["skipped", "gone"])
      expect(File.read(path("kept"))).to eq("kept v1\n")
      expect(File.exist?(writer.record_path("kept"))).to be(true)
      expect(File.exist?(path("lost"))).to be(false)
    end

    it "puts the config back when the record can't be written, and still finishes its entry in the restore batch" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      allow(writer).to receive(:put_record).and_raise(Errno::EACCES)

      result = command.restore(id: batch)

      expect(result[:results].first).to include("outcome" => "failed", "code" => "error")
      expect(File.read(path("a"))).to eq("a v2\n")
      own = backups.find(result[:extra]["backup"])
      expect(own["entries"].first).to include("name" => "a", "sha_after" => sha("a v2\n"))
    end

    it "gives a lock that can't be taken a workspace_locked row" do
      batch = apply_batch("a", before: "a v1\n", after: "a v2\n")
      allow(locks).to receive(:with_locks).and_raise(Workspace::NameMigration::LockUnavailable, "Permission denied")

      result = command.restore(id: batch)

      expect(outcomes(result)).to eq("a" => ["failed", "workspace_locked"])
      expect(File.read(path("a"))).to eq("a v2\n")
    end

    it "refuses an unknown batch id" do
      expect { command.restore(id: "nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("backup_not_found") }
    end
  end
end
