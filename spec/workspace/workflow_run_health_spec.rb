require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRunHealth do
  let(:root) { Dir.mktmpdir("ws-run-health") }
  let(:runs_dir) { File.join(root, "runs") }
  let(:lock_dir) { File.join(root, "locks") }
  let(:checkout) { File.join(root, "checkout").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(root, "archive")) }
  let(:health) { described_class.new(store: store, liveness: Workspace::RunLiveness.new(dir: runs_dir), lock_dir: lock_dir) }

  before { FileUtils.mkdir_p([runs_dir, lock_dir]) }

  after { FileUtils.remove_entry(root) }

  def run_hash(id, state: "running", worktree: checkout)
    {"id" => id, "workflow" => "rpiv", "workspace" => "app", "state" => state, "worktree" => worktree, "current" => "a",
     "definition" => {"steps" => [{"id" => "a"}]}, "steps" => {"a" => {"state" => "pending", "attempts" => []}}}
  end

  def write_run(id, **options)
    File.write(File.join(runs_dir, "#{id}.json"), JSON.generate(run_hash(id, **options)))
  end

  def write_locks(namespace, data)
    FileUtils.mkdir_p(File.join(lock_dir, namespace))
    File.write(File.join(lock_dir, namespace, "locks.json"), data.is_a?(String) ? data : JSON.generate(data))
  end

  def run_lock(run_id, role: :holder)
    record = {"kind" => "run", "run_id" => run_id, "worktree" => checkout}
    (role == :holder) ? {"holder" => record, "queue" => []} : {"holder" => nil, "queue" => [record]}
  end

  describe "orphaned runs" do
    %w[queued running waiting paused].each do |state|
      it "does not call a #{state} run with its checkout orphaned" do
        write_run("wr_1", state: state)

        expect(health.call[:orphans]).to be_empty
      end
    end

    %w[queued running waiting].each do |state|
      it "calls a #{state} run whose checkout is gone orphaned" do
        write_run("wr_1", state: state, worktree: File.join(root, "gone"))

        expect(health.call[:orphans].map { |run| run["id"] }).to eq(["wr_1"])
        expect(health.call[:orphans].first["why"]).to include("is missing or unmounted")
      end
    end

    it "calls a run that records no checkout orphaned" do
      write_run("wr_1", worktree: nil)

      expect(health.call[:orphans].first["why"]).to eq("it records no checkout")
    end

    %w[completed failed cancelled].each do |state|
      it "ignores a #{state} run whose checkout is gone" do
        write_run("wr_1", state: state, worktree: File.join(root, "gone"))

        expect(health.call[:orphans]).to be_empty
      end
    end

    it "lists a run file that can't be read as unreadable, not orphaned" do
      File.write(File.join(runs_dir, "wr_2.json"), "{not json")

      result = health.call
      expect(result[:unreadable]).to eq([File.join(runs_dir, "wr_2.json")])
      expect(result[:orphans]).to be_empty
    end
  end

  describe "leaked run locks" do
    it "finds a lock held by a run that is over" do
      write_run("wr_1", state: "completed")
      write_locks("app-abc", {"edit" => run_lock("wr_1")})

      expect(health.call[:leaked]).to eq([{"namespace" => "app-abc", "dir" => File.join(lock_dir, "app-abc"), "lock" => "edit", "run_id" => "wr_1", "role" => "holder", "worktree" => checkout, "delegate_pid" => nil}])
    end

    it "finds a lock held by a run with no file, and a waiter" do
      write_locks("app-abc", {"edit" => run_lock("wr_9"), "devenv" => run_lock("wr_8", role: :waiter)})

      expect(health.call[:leaked].map { |leak| [leak["lock"], leak["role"]] }).to contain_exactly(%w[edit holder], %w[devenv waiter])
    end

    it "carries the pid of a delegate dev process, and none when there is no usable one" do
      write_locks("app-abc", {"devenv" => {"holder" => {"kind" => "run", "run_id" => "wr_1", "delegate" => {"pid" => 4242, "started" => "s"}}, "queue" => []},
                              "edit" => {"holder" => {"kind" => "run", "run_id" => "wr_1", "delegate" => "junk"}, "queue" => []}})

      expect(health.call[:leaked].to_h { |leak| [leak["lock"], leak["delegate_pid"]] }).to eq("devenv" => 4242, "edit" => nil)
    end

    it "does not report a lock held by a live run" do
      write_run("wr_1")
      write_locks("app-abc", {"edit" => run_lock("wr_1")})

      expect(health.call[:leaked]).to be_empty
    end

    it "does not report a lock whose run file can't be read, and ignores process holders" do
      File.write(File.join(runs_dir, "wr_2.json"), "{not json")
      write_locks("app-abc", {"edit" => run_lock("wr_2"), "dev" => {"holder" => {"kind" => "process", "pid" => 1}, "queue" => []}})

      expect(health.call[:leaked]).to be_empty
    end

    it "reads the lock stores of every repository" do
      write_locks("app-abc", {"edit" => run_lock("wr_1")})
      write_locks("other-def", {"edit" => run_lock("wr_2")})

      expect(health.call[:leaked].map { |leak| leak["namespace"] }).to contain_exactly("app-abc", "other-def")
    end

    it "warns about a corrupt lock file and still reads the others" do
      write_locks("bad-1", "{nope")
      write_locks("app-abc", {"edit" => run_lock("wr_1")})

      result = health.call
      expect(result[:warnings].first).to include("bad-1", "locks.json")
      expect(result[:leaked].size).to eq(1)
    end

    it "does not flag a live run's lock in another repository, nor a lock whose run moved to the archive" do
      write_run("wr_1")
      write_locks("other-def", {"edit" => run_lock("wr_1")})
      FileUtils.mkdir_p(File.join(root, "archive"))
      File.write(File.join(root, "archive", "wr_2.json"), JSON.generate(run_hash("wr_2", state: "completed")))
      write_locks("app-abc", {"edit" => run_lock("wr_2")})

      expect(health.call[:leaked].map { |leak| [leak["namespace"], leak["run_id"]] }).to eq([%w[app-abc wr_2]])
    end

    it "changes no byte, mtime, file or directory of the lock, run and archive stores" do
      write_run("wr_1", state: "completed")
      write_run("wr_3", worktree: File.join(root, "gone"))
      File.write(File.join(runs_dir, "wr_4.json"), "{not json")
      FileUtils.mkdir_p(File.join(root, "archive"))
      File.write(File.join(root, "archive", "wr_5.json"), JSON.generate(run_hash("wr_5", state: "completed")))
      write_locks("app-abc", {"edit" => run_lock("wr_1")})
      write_locks("bad-1", "{nope")
      snapshot = -> { Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h { |path| [path, [File.mtime(path), File.file?(path) ? File.binread(path) : nil]] } }
      before = snapshot.call

      health.call

      expect(snapshot.call).to eq(before)
    end

    it "creates nothing for a repository whose lock store has no lock file" do
      FileUtils.mkdir_p(File.join(lock_dir, "empty-1"))

      health.call

      expect(Dir.children(File.join(lock_dir, "empty-1"))).to be_empty
    end
  end
end
