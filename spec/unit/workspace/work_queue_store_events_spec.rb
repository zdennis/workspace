require "tmpdir"
require "json"

RSpec.describe Workspace::WorkQueueStore, "events" do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "work-queue.json") }
  let(:history) { Workspace::WorkQueueHistory.new(path: File.join(dir, "history.jsonl")) }
  # Keeps what {Workspace::EventLog#record} is given, with the queue file's revision at that moment.
  let(:event_log_class) do
    Class.new do
      attr_reader :events, :revisions

      def initialize(path)
        @path = path
        @events = []
        @revisions = []
      end

      def record(type:, project:, data: {})
        @events << [type, project, data]
        @revisions << JSON.parse(File.read(@path))["revision"]
        true
      end

      def types = @events.map(&:first)
    end
  end
  let(:event_log) { event_log_class.new(path) }
  let(:store) { described_class.new(path: path, history: history, workspace: "api-w", event_log: event_log) }

  after { FileUtils.remove_entry(dir) }

  def add(spec = {"workflow" => "rpiv", "prompt" => "fix  the\nbug"})
    store.add(kind: "workflow", spec: spec)[1]["id"]
  end

  def claimed(_id)
    claim = nil
    store.transaction { |q| claim = q.claim_next(claimed_by: {"pid" => 1})["claim"] }
    claim
  end

  def active(id, run_id = "run-1")
    claim = claimed(id)
    store.transaction { |q| q.record_run(id, claim: claim, run_id: run_id) }
  end

  it "records work_queue_item_started once a claimed item's run is recorded, with what it runs" do
    id = add
    claim = claimed(id)
    expect(event_log.events).to be_empty

    store.transaction { |q| q.record_run(id, claim: claim, run_id: "run-1") }
    store.transaction { |q| q.record_run(id, claim: claim, run_id: "run-1") }

    expect(event_log.events).to eq([["work_queue_item_started", "api-w",
      {"id" => id, "kind" => "workflow", "what" => "rpiv fix the bug", "run_id" => "run-1", "workspace" => "api-w"}]])
  end

  it "cuts what a started item runs to EVENT_WHAT_LENGTH characters, control characters made spaces" do
    id = add("workflow" => "rpiv", "prompt" => "a\e[31m#{"x" * 200}")
    active(id)

    what = event_log.events.last.last["what"]
    expect(what.length).to eq(described_class::EVENT_WHAT_LENGTH)
    expect(what).to start_with("rpiv a [31mxxx")
  end

  it "records work_queue_item_started for a starting item adopted after its holder died" do
    id = add
    claimed(id)
    store.transaction { |q| q.adopt(id, run_id: "found") }

    expect(event_log.events.map { |type, _, data| [type, data["run_id"]] }).to eq([["work_queue_item_started", "found"]])
  end

  it "records work_queue_item_held once per hold, not for an item already held or not active" do
    id = add
    active(id)
    event_log.events.clear
    store.transaction { |q| q.hold(id, reason: "gate") }
    store.transaction { |q| q.hold(id, reason: "gate") }
    store.transaction { |q| q.hold("nope", reason: "gate") }

    expect(event_log.events).to eq([["work_queue_item_held", "api-w", {"id" => id, "reason" => "gate", "workspace" => "api-w"}]])
  end

  it "records work_queue_item_finished with its outcome and run, once" do
    id = add
    active(id)
    event_log.events.clear
    store.transaction { |q| q.finish(id, outcome: "failed", reason: "failed") }
    store.transaction { |q| q.finish(id, outcome: "failed", reason: "failed") }

    expect(event_log.events).to eq([["work_queue_item_finished", "api-w",
      {"id" => id, "outcome" => "failed", "reason" => "failed", "run_id" => "run-1", "workspace" => "api-w"}]])
  end

  it "records nothing for a finish whose claim no longer matches" do
    id = add
    claimed(id)
    store.transaction { |q| q.finish(id, outcome: "launch_failed", claim: "other") }

    expect(event_log.events).to be_empty
  end

  it "records work_queue_paused with the current item when the queue pauses, and not again while it stays paused" do
    id = add
    active(id)
    event_log.events.clear
    store.pause("failed_check")
    store.pause("launch_failed")

    expect(event_log.events).to eq([["work_queue_paused", "api-w", {"reason" => "failed_check", "id" => id, "workspace" => "api-w"}]])
  end

  it "records work_queue_resumed only for a queue that was paused" do
    store.resume
    store.pause("interrupted")
    store.resume
    store.resume

    expect(event_log.types).to eq(%w[work_queue_paused work_queue_resumed])
    expect(event_log.events.first.last).to eq("reason" => "interrupted", "id" => nil, "workspace" => "api-w")
  end

  it "records nothing for a transaction whose block raises" do
    id = add
    active(id)
    event_log.events.clear

    expect { store.transaction { |q| q.finish(id, outcome: "succeeded") && raise("boom") } }.to raise_error("boom")
    expect(event_log.events).to be_empty
    expect(store.find(id)["state"]).to eq("active")
  end

  it "records the events after the queue file is written, in the order of the transitions" do
    id = add
    claimed(id)
    store.transaction do |q|
      q.adopt(id, run_id: "r")
      q.finish(id, outcome: "succeeded")
      q.pause("x")
    end

    expect(event_log.types).to eq(%w[work_queue_item_started work_queue_item_finished work_queue_paused])
    expect(event_log.revisions).to eq([store.snapshot["revision"]] * 3)
  end

  it "records nothing without an event log" do
    plain = described_class.new(path: path, history: history)
    plain.pause("x")

    expect(plain.snapshot["paused"]).to include("reason" => "x")
  end
end
