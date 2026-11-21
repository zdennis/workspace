require "spec_helper"
require "rbconfig"
require "tmpdir"

RSpec.describe Workspace::WorkQueueDesk do
  let(:dir) { Dir.mktmpdir }
  let(:history) { Workspace::WorkQueueHistory.new(path: File.join(dir, "history.jsonl")) }
  let(:store) { Workspace::WorkQueueStore.new(path: File.join(dir, "work-queue.json"), history: history) }
  let(:runs) { {} }
  let(:run_store) do
    Class.new do
      def initialize(runs) = @runs = runs

      def run(id) = @runs[id] || raise(Workspace::Error.new("no run #{id}", code: "unknown_run"))

      def going = @runs.values.reject { |r| Workspace::WorkflowRunStore::TERMINAL_STATES.include?(r.state) }
    end.new(runs)
  end
  let(:spawned) { [] }
  let(:waiting) { [] }
  let(:clock_time) { {now: Time.utc(2026, 11, 20, 12, 0, 0)} }
  let(:log_output) { StringIO.new }
  let(:spawner) { ->(argv, log) { (spawned << [argv, log]) && Struct.new(:value).new(:exited) } }
  subject(:desk) do
    described_class.new(workspace: "api-w", store: store, run_store: run_store, executable: "/ws/bin/workspace",
      log_path: ->(name) { "/log/#{name}.log" }, spawner: spawner, waiter: ->(&block) { waiting << block },
      clock: -> { clock_time[:now] }, logger: Workspace::Logger.new(output: log_output, enabled: true))
  end

  after { FileUtils.remove_entry(dir) }

  def add_run(id, state: "running", workspace: "api-w")
    runs[id] = Workspace::WorkflowRun.from_h("id" => id, "state" => state, "workspace" => workspace, "current" => "s1", "steps" => {"s1" => {"state" => "running"}})
  end

  def queue_item(**options)
    store.add(kind: "workflow", spec: {"workflow" => "rpiv"}, **options)[1]["id"]
  end

  def active_item(run_id)
    id = queue_item
    store.transaction do |queue|
      claim = queue.claim_next(claimed_by: {"pid" => 1})["claim"]
      queue.record_run(id, claim: claim, run_id: run_id)
    end
    id
  end

  # Lets the spawned pass end, as its reaping thread's exit would.
  def finish_pass
    waiting.shift.call
  end

  it "starts `work-queue advance --name WORKSPACE` as its own process, logging to the workspace's log" do
    queue_item
    desk.scan

    expect(spawned).to eq([[[RbConfig.ruby, "/ws/bin/workspace", "work-queue", "advance", "--name", "api-w"], "/log/api-w.log"]])
  end

  it "starts none for a queue with no items, whether asked by a scan or a turn end" do
    desk.scan
    desk.turn_ended

    expect(spawned).to be_empty
  end

  it "leaves whether the queue is on to the pass: a disabled queue with items gets one" do
    store.set_enabled(false)
    queue_item
    desk.scan

    expect(spawned.size).to eq(1)
  end

  it "runs one pass at a time, and a scan meanwhile asks for nothing more" do
    queue_item
    desk.scan
    desk.scan
    expect(spawned.size).to eq(1)

    finish_pass
    desk.scan

    expect(spawned.size).to eq(1)
  end

  it "runs the pass a turn end asked for while one ran, right after it" do
    queue_item
    desk.scan
    desk.turn_ended
    expect(spawned.size).to eq(1)

    finish_pass

    expect(spawned.size).to eq(2)
  end

  describe "a scan" do
    it "starts another pass once the queue file's revision moves" do
      queue_item
      desk.scan
      finish_pass
      queue_item
      desk.scan

      expect(spawned.size).to eq(2)
    end

    it "starts another pass once the current item's run changes, and none while it stands still" do
      add_run("run-1")
      active_item("run-1")
      desk.scan
      finish_pass
      desk.scan
      expect(spawned.size).to eq(1)

      add_run("run-1", state: "completed")
      desk.scan

      expect(spawned.size).to eq(2)
    end

    it "starts another pass when a run of the workspace that blocked a start ends, and not for another workspace's" do
      add_run("other", workspace: "web-w")
      add_run("run-9")
      queue_item
      desk.scan
      finish_pass
      add_run("other", state: "completed", workspace: "web-w")
      desk.scan
      expect(spawned.size).to eq(1)

      add_run("run-9", state: "completed")
      desk.scan

      expect(spawned.size).to eq(2)
    end

    it "starts a pass for a current item every BACKSTOP seconds even when nothing changed, since a park's time can run out" do
      add_run("run-1")
      active_item("run-1")
      desk.scan
      finish_pass
      clock_time[:now] += described_class::BACKSTOP - 1
      desk.scan
      expect(spawned.size).to eq(1)

      clock_time[:now] += 1
      desk.scan

      expect(spawned.size).to eq(2)
    end

    it "has no backstop for a queue with nothing current" do
      queue_item
      desk.scan
      finish_pass
      clock_time[:now] += described_class::BACKSTOP * 10
      desk.scan

      expect(spawned.size).to eq(1)
    end

    it "starts a pass for a current item whose run has gone, so the pass can finish it" do
      active_item("run-gone")
      desk.scan

      expect(spawned.size).to eq(1)
    end
  end

  describe "a turn end" do
    it "starts a pass even when nothing a scan reads has changed" do
      add_run("run-1")
      active_item("run-1")
      desk.scan
      finish_pass
      desk.turn_ended

      expect(spawned.size).to eq(2)
    end
  end

  describe "a restarted daemon" do
    it "starts a pass on its first scan for an item left starting or active, before anything new could start" do
      id = queue_item
      store.transaction { |queue| queue.claim_next(claimed_by: {"pid" => 999_999}) }
      desk.scan

      expect(store.find(id)["state"]).to eq("starting")
      expect(spawned.size).to eq(1)
    end
  end

  describe "a pass that can't be started or waited on" do
    it "logs a spawn that raises and starts again on the next ask" do
      failing = true
      spawner = ->(argv, log) { failing ? raise(Errno::ENOENT, "ruby") : (spawned << [argv, log]) && nil }
      desk = described_class.new(workspace: "api-w", store: store, run_store: run_store, executable: "/ws/bin/workspace",
        log_path: ->(name) { "/log/#{name}.log" }, spawner: spawner, logger: Workspace::Logger.new(output: log_output, enabled: true))
      queue_item
      desk.scan
      expect(log_output.string).to include("could not start a pass for api-w (Errno::ENOENT")

      failing = false
      desk.turn_ended

      expect(spawned.size).to eq(1)
    end

    it "takes a spawner that gives no thread as a pass that has ended" do
      desk = described_class.new(workspace: "api-w", store: store, run_store: run_store, executable: "/ws/bin/workspace",
        log_path: ->(name) { "/log/#{name}.log" }, spawner: ->(argv, log) { (spawned << [argv, log]) && nil })
      queue_item
      desk.scan
      desk.turn_ended

      expect(spawned.size).to eq(2)
    end

    it "ends the pass when reading the thread raises" do
      thread = Object.new
      def thread.value = raise("gone")
      desk = described_class.new(workspace: "api-w", store: store, run_store: run_store, executable: "/ws/bin/workspace",
        log_path: ->(name) { "/log/#{name}.log" }, spawner: ->(argv, log) { (spawned << [argv, log]) && thread },
        waiter: ->(&block) { block.call }, logger: Workspace::Logger.new(output: log_output, enabled: true))
      queue_item
      desk.scan
      desk.turn_ended

      expect(spawned.size).to eq(2)
      expect(log_output.string).to include("could not read how the pass ended (RuntimeError: gone)")
    end

    it "logs a queue file it can't read and raises nothing" do
      File.write(File.join(dir, "work-queue.json"), "not json")

      expect { desk.scan }.not_to raise_error
      expect(spawned).to be_empty
      expect(log_output.string).to include("could not look at the queue of api-w")
    end
  end
end
