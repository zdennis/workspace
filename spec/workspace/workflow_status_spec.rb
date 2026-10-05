require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowStatus do
  around do |example|
    Dir.mktmpdir("wf-status") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { [Time.utc(2026, 10, 4, 13, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2 wr_3] }
  let(:store) do
    Workspace::WorkflowRunStore.new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive"), clock: -> { now.first }, id_generator: -> { ids.shift })
  end
  let(:panes) { FakeWorkflowPanes.new }
  let(:snapshot) { {"panes" => [{"pane_id" => "%5", "kind" => "claude", "state" => "working"}]} }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:asks) { [] }
  let(:ask_store) { instance_double(Workspace::AskStore) }
  subject(:status) do
    described_class.new(store: store, panes: panes, snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { ask_store }, clock: -> { now.first })
  end

  before do
    allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0) { snapshot }
    allow(ask_store).to receive(:list).with(open_only: true) { asks }
  end

  def create(state: "running", step_state: "running", reason: nil, workspace: "app", pane: "%5", bound: true, timeout: nil, **rest)
    run = store.create({
      "workflow" => "rpiv", "title" => "RPIV", "workspace" => workspace, "project" => "app", "worktree" => "/src/app", "task" => "t1",
      "inputs" => {"task" => "X-1"}, "state" => state, "created_at" => "2026-10-04T12:00:00Z", "started_at" => "2026-10-04T12:00:00Z",
      "ended_at" => nil, "current" => "plan", "pane" => pane, "loops" => {}, "reason" => reason, "artifacts_dir" => "/src/app/.workflow/wr",
      "definition" => {"steps" => [{"id" => "research", "title" => "Research", "timeout" => nil}, {"id" => "plan", "title" => "Plan", "timeout" => timeout}]},
      "steps" => {"research" => {"state" => "passed", "attempts" => [{"n" => 1}]},
                  "plan" => {"state" => step_state, "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:30:00Z"}, {"n" => 2, "started_at" => "2026-10-04T12:40:00Z"}]}}
    }.merge(rest))
    panes.bind(workspace: workspace, pane: pane, run_id: run["id"]) if bound
    run
  end

  def current(id = "wr_1")
    status.run(id)["runs"].first["current"]
  end

  def action(name, *args, needs: [])
    {"action" => name, "args" => args, "needs" => needs}
  end

  it "shows a run an agent is working on, with no reason" do
    create

    result = status.run("wr_1")

    expect(result["warnings"]).to eq([])
    expect(result["runs"]).to eq([{
      "id" => "wr_1", "workflow" => "rpiv", "title" => "RPIV", "workspace" => "app", "project" => "app", "state" => "running",
      "created_at" => "2026-10-04T12:00:00Z", "started_at" => "2026-10-04T12:00:00Z", "ended_at" => nil, "cancelled_by" => nil,
      "current" => {"step" => "plan", "attempt" => 2, "state" => "running", "reason" => nil, "flags" => []},
      "steps" => [{"id" => "research", "title" => "Research", "state" => "passed", "attempts" => 1, "gate" => nil},
        {"id" => "plan", "title" => "Plan", "state" => "running", "attempts" => 2, "gate" => nil}],
      "pane" => "%5", "task" => "t1", "inputs" => {"task" => "X-1"}, "loops" => {}, "artifacts_dir" => "/src/app/.workflow/wr",
      "events_path" => File.join(@dir, "runs", "wr_1.events.jsonl")
    }])
  end

  it "says pane_gone when the pane an agent should be working in is not there, and how to get going again" do
    create(bound: false)

    expect(status.run("wr_1")["runs"].first["state"]).to eq("waiting")
    expect(current["reason"]).to eq("code" => "pane_gone", "since" => "2026-10-04T12:40:00Z",
      "details" => {"step" => "plan", "pane" => "%5", "workspace" => "app"},
      "actions" => [action("launch", "app"), action("workflow resume", "wr_1"), action("workflow cancel", "wr_1")])
    expect(snapshot_client).not_to have_received(:fetch)
  end

  it "says waiting_you when the pane shows a permission prompt" do
    create
    snapshot["panes"].first.merge!("state" => "waiting", "waiting_since" => "2026-10-04T12:50:00Z", "waiting_message" => "Claude needs your permission to use Bash")

    expect(current["reason"]).to eq("code" => "waiting_you", "since" => "2026-10-04T12:50:00Z",
      "details" => {"kind" => "prompt", "step" => "plan", "pane" => "%5", "message" => "Claude needs your permission to use Bash"},
      "actions" => [action("focus", "app", "--pane", "%5")])
  end

  it "puts a permission prompt before a stored turn_ended_incomplete" do
    create(state: "waiting", reason: {"code" => "turn_ended_incomplete", "since" => "t", "details" => {"step" => "plan", "missing" => ["x"]}})
    snapshot["panes"].first.merge!("state" => "waiting", "waiting_since" => "2026-10-04T12:50:00Z", "waiting_message" => "Allow?")

    expect(current["reason"]["details"]).to include("kind" => "prompt")
  end

  it "looks at the pane while the step's check runs, too" do
    create(step_state: "checking")
    snapshot["panes"].first.merge!("state" => "waiting", "waiting_since" => "2026-10-04T12:50:00Z", "waiting_message" => "Allow?")

    expect(current["reason"]["details"]).to include("kind" => "prompt")
  end

  it "says waiting_you when a question asked from the run's pane is open, with the answer as something the caller supplies" do
    create
    asks << {"id" => "a1b2c3", "question" => "Postgres or sqlite?", "asked_at" => "2026-10-04T12:45:00Z", "status" => "open", "pane" => "%5"}

    expect(current["reason"]).to eq("code" => "waiting_you", "since" => "2026-10-04T12:45:00Z",
      "details" => {"kind" => "ask", "step" => "plan", "ask" => "a1b2c3", "question" => "Postgres or sqlite?"},
      "actions" => [action("ask answer", "a1b2c3", "--name", "app", needs: [{"name" => "answer", "flag" => nil}]), action("focus", "app", "--pane", "%5")])
  end

  describe "with the workspace's real question store, read by a process with no UTF-8 locale" do
    let(:ask_path) { File.join(@dir, "asks.json") }
    let(:ask_store) { Workspace::AskStore.new(path: ask_path, error_output: StringIO.new) }

    before { allow(ask_store).to receive(:list).and_call_original }

    it "shows the run, and a question from its pane, though the store holds non-ASCII text" do
      create
      ask_store.add(question: "Où ça ?", default: "ici", pane: "%9")
      ask_store.add(question: "Déjà fait — on continue ?", default: "oui", pane: "%5")

      result = without_utf8_locale { status.run("wr_1") }

      expect(result["warnings"]).to eq([])
      expect(result["runs"].first["current"]["reason"]["details"]).to include("kind" => "ask", "question" => "Déjà fait — on continue ?")
      expect(without_utf8_locale { status.runs }["runs"].size).to eq(1)
    end

    it "warns and goes on without the question when the store's bytes are not UTF-8" do
      create
      File.binwrite(ask_path, "[{\"id\":\"a1\",\"question\":\"caf\xC3\",\"status\":\"open\",\"pane\":\"%5\"}]".b)

      result = without_utf8_locale { status.run("wr_1") }

      expect(result["runs"].first["current"]["reason"]).to be_nil
      expect(result["warnings"]).to eq(["The questions of 'app' could not be read (the file is not UTF-8 text), so an open question would not show here."])
    end
  end

  it "is not held by a question another pane of the workspace asked" do
    create
    asks << {"id" => "a1b2c3", "question" => "Postgres or sqlite?", "asked_at" => "2026-10-04T12:45:00Z", "status" => "open", "pane" => "%9"}
    asks << {"id" => "d4e5f6", "question" => "From outside tmux?", "asked_at" => "2026-10-04T12:46:00Z", "status" => "open", "pane" => nil}

    run = status.run("wr_1")["runs"].first

    expect(run["state"]).to eq("running")
    expect(run["current"]["reason"]).to be_nil
  end

  it "keeps a stored turn_ended_incomplete when the pane shows nothing more urgent" do
    create(state: "waiting", reason: {"code" => "turn_ended_incomplete", "since" => "2026-10-04T12:50:00Z",
                                      "details" => {"step" => "plan", "attempt" => 2, "missing" => ["/src/app/.workflow/wr/plan.md"]}})

    expect(current["reason"]).to include("code" => "turn_ended_incomplete",
      "actions" => [action("focus", "app", "--pane", "%5"), action("workflow resume", "wr_1"), action("workflow cancel", "wr_1")])
  end

  it "does not look at the pane for a run that waits at a gate, for a lock or on a failed step" do
    gate = {"code" => "waiting_you", "since" => "t", "details" => {"kind" => "gate", "step" => "plan", "artifacts" => []}}
    lock = {"code" => "waiting_lock", "since" => "t", "details" => {"resource" => "test-db", "holder" => {"run_id" => "wr_9", "kind" => "run"}}}
    failed = {"code" => "failed_check", "since" => "t", "details" => {"step" => "plan", "cause" => "check"}}
    create(state: "waiting", step_state: "passed", reason: gate, bound: false)
    create(state: "waiting", step_state: "waiting", reason: lock, bound: false)
    create(state: "waiting", step_state: "failed", reason: failed, bound: false)

    # A gate is rejected with a note: the caller supplies it after `--note`; it is never in `args`.
    expect(current("wr_1")["reason"]).to eq(gate.merge("actions" => [action("workflow approve", "wr_1"),
      action("workflow reject", "wr_1", needs: [{"name" => "note", "flag" => "--note"}]), action("workflow cancel", "wr_1")]))
    expect(current("wr_2")["reason"]["actions"]).to eq([action("workflow status", "wr_9"), action("workflow cancel", "wr_2")])
    expect(current("wr_3")["reason"]["actions"]).to eq([action("workflow resume", "wr_3"),
      action("workflow resume", "wr_3", "--from", "plan"), action("workflow cancel", "wr_3")])
    expect(snapshot_client).not_to have_received(:fetch)
  end

  it "offers `dev down` when the lock is held by a dev environment, which is what frees it" do
    lock = {"code" => "waiting_lock", "since" => "t",
            "details" => {"resource" => "devenv", "holder" => {"pid" => 700, "kind" => "process", "worktree" => "/src/app-tax"}}}
    agent = {"code" => "waiting_lock", "since" => "t", "details" => {"resource" => "test-db", "holder" => {"pid" => 800, "kind" => "agent"}}}
    create(state: "waiting", step_state: "waiting", reason: lock, bound: false)
    create(state: "waiting", step_state: "waiting", reason: agent, bound: false)

    expect(current("wr_1")["reason"]["actions"]).to eq([action("dev down", "--name", "app"), action("workflow cancel", "wr_1")])
    expect(current("wr_2")["reason"]["actions"]).to eq([action("workflow cancel", "wr_2")])
  end

  it "offers resume and cancel for a step that could not be started" do
    create(state: "waiting", step_state: "waiting", reason: {"code" => "waiting_you", "since" => "t", "details" => {"kind" => "dispatch", "step" => "plan"}})

    expect(current["reason"]["actions"]).to eq([action("workflow resume", "wr_1"), action("workflow cancel", "wr_1")])
  end

  it "gives every action `needs`, and never a placeholder among its args" do
    reasons = [
      {"code" => "waiting_you", "details" => {"kind" => "gate", "step" => "plan", "artifacts" => []}},
      {"code" => "waiting_you", "details" => {"kind" => "dispatch", "step" => "plan"}},
      {"code" => "waiting_lock", "details" => {"resource" => "devenv", "holder" => {"run_id" => "wr_9", "kind" => "process"}}},
      {"code" => "failed_check", "details" => {"step" => "plan"}},
      {"code" => "pane_gone", "details" => {"kind" => "dispatch", "step" => "plan"}}
    ]
    ids.push("wr_4", "wr_5", "wr_6")
    reasons.each { |reason| create(state: "waiting", step_state: "waiting", reason: reason.merge("since" => "t"), bound: false) }
    create
    asks << {"id" => "a1", "question" => "Q?", "asked_at" => "t", "status" => "open", "pane" => "%5"}

    actions = status.runs["runs"].flat_map { |run| run["current"]["reason"]["actions"] }

    expect(actions.size).to be > 12
    expect(actions.map(&:keys).uniq).to eq([%w[action args needs]])
    expect(actions.flat_map { |each| each["args"] }.grep(/\A[A-Z]+\z/)).to eq([])
    expect(actions.flat_map { |each| each["needs"] }.uniq).to eq([{"name" => "note", "flag" => "--note"}, {"name" => "answer", "flag" => nil}])
  end

  it "flags a step that has run past its timeout, and stops nothing" do
    create(timeout: 1200)
    expect(current["flags"]).to eq([])

    now[0] += 1
    expect(current["flags"]).to eq(["timed_out"])
    expect(current["reason"]).to be_nil
  end

  it "does not flag a step past its timeout that no agent is on any more: one at a gate, or one that failed" do
    now[0] += 3600
    create(timeout: 60, state: "waiting", step_state: "passed", reason: {"code" => "waiting_you", "since" => "t", "details" => {"kind" => "gate", "artifacts" => []}})

    expect(current["flags"]).to eq([])
  end

  it "flags a step that reads running while its pane's agent is idle: the turn ended and nothing saw it" do
    create
    snapshot["panes"].first["state"] = "idle"

    expect(current).to include("state" => "running", "reason" => nil, "flags" => ["idle"])
  end

  it "flags idle a pane that is done, once it has been quiet long enough for the turn's end to have been handled" do
    create
    snapshot["panes"].first.merge!("state" => "done", "state_since" => "2026-10-04T12:59:51Z")
    expect(current["flags"]).to eq([])

    snapshot["panes"].first["state_since"] = "2026-10-04T12:59:50Z"
    expect(current["flags"]).to eq(["idle"])
  end

  it "does not flag idle a step that has a reason, or one whose check runs" do
    create(state: "waiting", reason: {"code" => "turn_ended_incomplete", "since" => "t", "details" => {"step" => "plan", "missing" => ["x"]}})
    create(step_state: "checking", pane: "%6")
    snapshot["panes"].first["state"] = "idle"
    snapshot["panes"] << {"pane_id" => "%6", "kind" => "claude", "state" => "idle"}

    expect(current("wr_1")["flags"]).to eq([])
    expect(current("wr_2")["flags"]).to eq([])
  end

  describe "a run whose workspace has no agent daemon" do
    before { panes.daemon = false }

    it "warns that it will not move, what it keeps, and the two ways out, for a step an agent is on or a run queued for a lock" do
      create
      create(state: "waiting", step_state: "waiting", pane: "%6", bound: false,
        reason: {"code" => "waiting_lock", "since" => "t", "details" => {"resource" => "test-db", "holder" => {"run_id" => "wr_9"}}})
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :no_daemon))

      warnings = status.runs["warnings"]

      expect(warnings).to include(
        "Workflow run wr_1 will not move: 'app' has no agent daemon running. It keeps the locks it holds and its place in a queue. " \
        "Launch the workspace and run `workspace workflow resume wr_1`, or end it with `workspace workflow cancel wr_1`."
      )
      expect(warnings.grep(/Workflow run wr_2 will not move/).size).to eq(1)
    end

    it "does not warn for a run that waits for a person, or a finished one" do
      create(state: "waiting", step_state: "passed", bound: false, reason: {"code" => "waiting_you", "since" => "t", "details" => {"kind" => "gate", "artifacts" => []}})
      create(pane: "%6")
      store.update("wr_2") { |run| run.merge!("state" => "completed", "ended_at" => "2026-10-04T12:59:00Z") }

      expect(status.runs(all: true)["warnings"]).to eq([])
    end
  end

  it "warns, and goes on, when the workspace's daemon doesn't answer" do
    create
    allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :timeout))

    result = status.run("wr_1")

    expect(result["runs"].first["current"]["reason"]).to be_nil
    expect(result["warnings"]).to eq(["The agent daemon for 'app' did not answer, so a permission prompt in its panes would not show here."])
  end

  it "shows a finished run with no reason and no pane" do
    create
    store.update("wr_1") { |run| run.merge!("state" => "cancelled", "ended_at" => "2026-10-04T12:59:00Z", "cancelled_by" => "kill", "reason" => nil) }

    run = status.run("wr_1")["runs"].first

    expect(run).to include("state" => "cancelled", "cancelled_by" => "kill", "pane" => nil, "events_path" => File.join(@dir, "archive", "wr_1.events.jsonl"))
    expect(run["current"]).to include("reason" => nil, "flags" => [])
  end

  describe "#runs" do
    before do
      create
      create(workspace: "other", pane: "%7")
      create(pane: "%8")
      store.update("wr_3") { |run| run.merge!("state" => "completed", "ended_at" => "2026-10-04T12:59:00Z") }
      allow(snapshot_client).to receive(:fetch).with("other", timeout: 1.0).and_return("panes" => [])
    end

    it "lists the runs still going" do
      expect(status.runs["runs"].map { |run| run["id"] }).to eq(%w[wr_1 wr_2])
    end

    it "lists one workspace's runs" do
      expect(status.runs(workspace: "other")["runs"].map { |run| run["id"] }).to eq(["wr_2"])
    end

    it "leaves out a run whose file can't be read as a run, or can't be shown, with a warning naming each and a way out that works" do
      no_steps = File.join(@dir, "runs", "wr_2.json")
      File.write(no_steps, JSON.generate(JSON.parse(File.read(no_steps)).except("steps")))
      unreadable = File.join(@dir, "runs", "wr_7.json")
      File.write(unreadable, "{not json")
      # Whole enough to be a run, and still not showable: its attempt's start is not a time.
      ids.push("wr_4")
      create(pane: "%9", timeout: 60)
      odd = File.join(@dir, "runs", "wr_4.json")
      run = JSON.parse(File.read(odd))
      run["steps"]["plan"]["attempts"].last["started_at"] = "yesterday"
      File.write(odd, JSON.generate(run))

      result = status.runs

      expect(result["runs"].map { |each| each["id"] }).to eq(["wr_1"])
      way_out = "free a lock with `workspace lock clear NAME`, or delete the file."
      expect(result["warnings"]).to eq([
        "The run file #{no_steps} can't be read, so its run is not shown. What it held stays held: #{way_out}",
        "The run file #{unreadable} can't be read, so its run is not shown. What it held stays held: #{way_out}",
        "Workflow run wr_4 can't be shown: its run file is malformed. What it holds stays held: #{way_out}"
      ])
      expect(result["warnings"].join).not_to include("cancel")
      expect { status.run("wr_2") }.to raise_error(Workspace::Error) { |error|
        expect(error.code).to eq("unknown_run")
        expect(error.details).to eq("run_id" => "wr_2", "path" => no_steps)
      }
    end

    it "adds finished runs with all" do
      expect(status.runs(all: true)["runs"].map { |run| [run["id"], run["state"]] }).to eq([%w[wr_1 running], %w[wr_2 running], %w[wr_3 completed]])
    end
  end

  it "raises unknown_run for an id no run has" do
    expect { status.run("wr_9") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_run") }
  end
end
