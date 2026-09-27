require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockEnforcer do
  let(:state_dir) { Dir.mktmpdir("ws-lock-enforcer") }
  let(:lock_dir) { File.join(state_dir, "locks") }
  let(:store_dir) { File.join(lock_dir, "app-ns") }
  let(:config) { instance_double(Workspace::Config, lock_dir: lock_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:holder_agent) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app") }
  let(:other_agent) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.worktree-b") }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: store_dir)
  end

  def enforcer(lock_holder: other_agent)
    described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder)
  end

  def store(liveness: other_agent)
    Workspace::LockStore.new(dir: store_dir, liveness: liveness)
  end

  def hold(identity, task: nil)
    id = identity.current
    store.acquire("edit", identity: id, waiter_pid: id[:pid], waiter_started: id[:started], task: task)
  end

  describe "#check" do
    it "allows a non-editing tool even while the edit lock is held" do
      hold(holder_agent)

      expect(enforcer.check(tool_name: "Read")).to be_nil
    end

    it "allows an edit when there is no lock directory at all" do
      expect(enforcer.check(tool_name: "Edit")).to be_nil
    end

    it "allows an edit, without resolving the namespace, when no edit lock is held anywhere" do
      FileUtils.mkdir_p(lock_dir)
      expect(lock_namespace).not_to receive(:resolve)

      expect(enforcer.check(tool_name: "Edit")).to be_nil
    end

    it "allows the holder's own edit" do
      hold(holder_agent)

      expect(enforcer(lock_holder: holder_agent).check(tool_name: "Edit")).to be_nil
    end

    %w[Edit Write MultiEdit NotebookEdit].each do |tool|
      it "denies #{tool} by a non-holder with the lock's pane and task" do
        hold(holder_agent, task: "PROJ-12")

        message = enforcer(lock_holder: other_agent).check(tool_name: tool)

        expect(message).to eq("Workspace edit lock held by %1 (PROJ-12). Run: workspace lock acquire edit --wait")
      end
    end

    it "allows an edit when the calling agent cannot be identified" do
      hold(holder_agent)
      lock_holder = instance_double(Workspace::LockHolder, alive?: true)
      allow(lock_holder).to receive(:current).and_return(nil)

      expect(enforcer(lock_holder: lock_holder).check(tool_name: "Edit")).to be_nil
    end

    it "allows an edit when the recorded holder is stale" do
      hold(holder_agent)
      dead_holder = FakeLockIdentity.new(pid: 100, pane: "%1")
      dead_holder.kill(100)

      expect(enforcer(lock_holder: dead_holder).check(tool_name: "Edit")).to be_nil
    end

    it "includes a one-time displaced notice when the caller itself was taken over" do
      hold(other_agent, task: "PROJ-13")
      FileUtils.mkdir_p(store_dir)
      data = JSON.parse(File.read(File.join(store_dir, "locks.json")))
      data["edit"]["displaced"] = [{
        "pid" => 100, "started" => "start-100", "pane" => "%1", "task" => "PROJ-9",
        "idle_since" => 900, "at" => 1_212, "by" => {"pane" => "%2", "task" => "PROJ-13"}
      }]
      File.write(File.join(store_dir, "locks.json"), JSON.generate(data))

      message = enforcer(lock_holder: holder_agent).check(tool_name: "Edit")

      expect(message).to include("Your edit lock was taken over by %2 \"PROJ-13\" at ")
      expect(message).to include("after this agent had been idle for 312s.")
      expect(message).to include("Workspace edit lock held by %2 (PROJ-13). Run: workspace lock acquire edit --wait")
    end

    it "swallows errors and allows the edit" do
      hold(holder_agent)
      allow(JSON).to receive(:parse).and_raise(StandardError, "boom")

      expect(enforcer.check(tool_name: "Edit")).to be_nil
    end
  end

  describe "#release_all" do
    it "releases every lock the calling agent holds" do
      hold(holder_agent)

      released = enforcer(lock_holder: holder_agent).release_all

      expect(released).to eq(["edit"])
      expect(store.status("edit")["edit"]["holder"]).to be_nil
    end

    it "does nothing when there is no lock directory" do
      expect(lock_namespace).not_to receive(:resolve)

      expect(enforcer(lock_holder: holder_agent).release_all).to eq([])
    end

    it "does nothing when the calling agent cannot be identified" do
      FileUtils.mkdir_p(lock_dir)
      lock_holder = instance_double(Workspace::LockHolder)
      allow(lock_holder).to receive(:current).and_return(nil)

      expect(enforcer(lock_holder: lock_holder).release_all).to eq([])
    end

    it "swallows errors" do
      FileUtils.mkdir_p(lock_dir)
      allow(lock_namespace).to receive(:resolve).and_raise(Workspace::Error, "boom")

      expect(enforcer(lock_holder: holder_agent).release_all).to eq([])
    end
  end
end
