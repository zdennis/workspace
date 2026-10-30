require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Inbox, "gate links" do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-gate") }
  let(:config) do
    state = tmpdir
    Class.new(Workspace::Config) { define_method(:state_dir) { state } }.new
  end
  let(:now) { Time.utc(2026, 10, 30, 12, 0, 0) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "pr-1") }
  let(:ledger) { instance_double(Workspace::SessionLedger, open_session_for: "sess-1") }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:store_factory) do
    ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, clock: -> { now }, error_output: error_output) }
  end
  let(:runs) { {"wr_1" => run("wr_1", "triage", [1, 2])} }
  let(:run_store) do
    table = runs
    Class.new do
      define_method(:find) { |id| table.fetch(id) { raise Workspace::Error.new("No run", code: "unknown_run") } }
    end.new
  end
  let(:gate_rows) { [gate_row("wr_1", "triage", 2)] }
  let(:derived) do
    rows = gate_rows
    Class.new do
      define_method(:rows) { |workspaces:, projects:| {rows: rows, warnings: []} }
    end.new
  end
  let(:env) { {"TMUX_PANE" => "%3"} }

  def build(env: self.env, ledger: self.ledger)
    described_class.new(config: config, notes: notes, project_detector: project_detector, session_ledger: ledger,
      store_factory: store_factory, run_store: run_store, derived: derived, env: env, clock: -> { now },
      output: output, error_output: error_output)
  end

  subject(:command) { build }

  after { FileUtils.remove_entry(tmpdir) }

  def run(id, step, attempts, workspace: "pr-1", state: "running")
    {"id" => id, "workspace" => workspace, "state" => state, "current" => step,
     "steps" => {step => {"attempts" => attempts.map { |n| {"n" => n} }}}}
  end

  def gate_row(run_id, step, attempt, workspace: "pr-1")
    {"id" => "workflow:waiting_you:#{run_id}", "derived" => true, "kind" => "workflow_waiting_you", "fingerprint" => "#{step}:t",
     "type" => "alert", "state" => "open", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
     "title" => "Workflow waits", "body" => nil,
     "links" => {"pane" => nil, "plan_task" => nil, "pr" => nil, "run_id" => run_id, "step" => step, "attempt" => attempt},
     "created_at" => "t", "updated_at" => "t"}
  end

  def post(run_id = "wr_1", cmd: command, key: "pr-feedback:wr_1", **opts)
    cmd.add(title: "PR #1 feedback", type: "review_request", links: {run_id: run_id}, dedupe_key: key, working_dir: "/app",
      source: {kind: "agent"}, **opts)[:results].first["item"]
  end

  def listed(cmd = command, **opts)
    output.truncate(0)
    output.rewind
    cmd.list(working_dir: "/app", json: true, include_derived: true, **opts)
    JSON.parse(output.string)["items"]
  end

  def gate(items)
    items.find { |item| item["kind"] == "workflow_waiting_you" }
  end

  describe "stamping" do
    it "stores the run's current step and its last attempt" do
      expect(post["links"]).to include("run_id" => "wr_1", "step" => "triage", "attempt" => 2)
      expect(error_output.string).to eq("")
    end

    it "takes the stamp again on an upsert, so a repost after a reject carries the new attempt" do
      post
      runs["wr_1"]["steps"]["triage"]["attempts"] << {"n" => 3}

      item = post

      expect(item["links"]).to include("step" => "triage", "attempt" => 3)
    end

    it "stamps nothing on an item that links no run" do
      item = command.add(title: "x", working_dir: "/app")[:results].first["item"]

      expect(item["links"].keys).not_to include("step", "attempt")
    end

    {
      "an unknown run" => ->(t) { "wr_missing" },
      "a finished run" => ->(t) { t.runs["wr_1"]["state"] = "completed" and "wr_1" },
      "a run of another workspace" => ->(t) { t.runs["wr_1"]["workspace"] = "other" and "wr_1" }
    }.each do |label, setup|
      it "stores null and says so on stderr for #{label}" do
        item = post(setup.call(self))

        expect(item["links"]).to include("step" => nil, "attempt" => nil)
        expect(item["links"]["run_id"]).not_to be_nil
        expect(error_output.string).to eq("Run #{item["links"]["run_id"]} is not going in this workspace, so this item is not tied to a step.\n")
      end
    end

    it "refuses a step key in --from-json links" do
      path = File.join(tmpdir, "item.json")
      File.write(path, JSON.generate("title" => "t", "links" => {"run_id" => "wr_1", "step" => "triage"}))

      expect { command.add_from_json(path, working_dir: "/app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_inbox_item") }
    end

    it "stamps from --from-json links.run_id" do
      path = File.join(tmpdir, "item.json")
      File.write(path, JSON.generate("title" => "t", "links" => {"run_id" => "wr_1"}))

      item = command.add_from_json(path, working_dir: "/app")[:results].first["item"]

      expect(item["links"]).to include("step" => "triage", "attempt" => 2)
    end

    it "stamps on edit --link-run and clears the run, step and attempt together on an empty one" do
      item = command.add(title: "x", working_dir: "/app")[:results].first["item"]

      edited = command.edit(item["id"], links: {run_id: "wr_1"}, working_dir: "/app")[:results].first["item"]
      expect(edited["links"]).to include("run_id" => "wr_1", "step" => "triage", "attempt" => 2)

      cleared = command.edit(item["id"], links: {run_id: ""}, working_dir: "/app")[:results].first["item"]
      expect(cleared["links"]).to include("run_id" => nil, "step" => nil, "attempt" => nil)
    end
  end

  describe "edit and stamp edge cases" do
    def plain
      command.add(title: "x", working_dir: "/app")[:results].first["item"]
    end

    it "stores null step and attempt on edit --link-run for a run that is not going" do
      edited = command.edit(plain["id"], links: {run_id: "wr_missing"}, working_dir: "/app")[:results].first["item"]

      expect(edited["links"]).to include("run_id" => "wr_missing", "step" => nil, "attempt" => nil)
      expect(error_output.string).to include("is not going in this workspace")
    end

    it "adds no step or attempt keys when editing other links" do
      edited = command.edit(plain["id"], links: {pr: 4}, working_dir: "/app")[:results].first["item"]

      expect(edited["links"].keys).not_to include("step", "attempt")
    end

    it "leaves a stamped item's step and attempt alone when another field changes" do
      item = post
      edited = command.edit(item["id"], title: "new", working_dir: "/app")[:results].first["item"]

      expect(edited["links"]).to include("step" => "triage", "attempt" => 2)
    end

    it "treats a run whose file can't be read as not going" do
      item = post("wr_broken")

      expect(item["links"]).to include("step" => nil, "attempt" => nil)
    end

    it "words the stderr line for a global item" do
      command.add(title: "g", links: {run_id: "wr_1"}, target: {global: true}, working_dir: "/app")

      expect(error_output.string).to eq("Run links need a workspace-scoped item, so this item is not tied to a step.\n")
    end

    it "surfaces a broken store of the gate's workspace as a warning" do
      post
      File.write(config.inbox_path("workspace", "pr-1"), "{not json")
      output.truncate(0)
      output.rewind
      command.list(working_dir: "/app", json: true, include_derived: true)

      expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).to include("inbox_store_unreadable")
    end
  end

  describe "covered_by on the derived gate row" do
    let(:agent_command) { command }

    it "names the one agent-posted item at the gate's step and attempt" do
      item = post

      expect(gate(listed)["covered_by"]).to eq(item["id"])
    end

    it "counts a snoozed item" do
      item = post
      command.snooze([item["id"]], for_duration: "1h", working_dir: "/app")

      expect(gate(listed(states: %w[open snoozed]))["covered_by"]).to eq(item["id"])
    end

    it "keeps the row in the JSON and leaves it out of the text output" do
      post
      expect(listed.map { |i| i["kind"] }).to include("workflow_waiting_you")

      output.truncate(0)
      output.rewind
      command.list(working_dir: "/app", include_derived: true)

      expect(output.string).not_to include("Workflow waits")
    end

    it "is null with no item" do
      expect(gate(listed)["covered_by"]).to be_nil
    end

    it "is null with two items for the run" do
      post
      post(key: "other")

      expect(gate(listed)["covered_by"]).to be_nil
    end

    it "is null when the one item is at an older attempt" do
      runs["wr_1"]["steps"]["triage"]["attempts"] = [{"n" => 1}]
      post
      runs["wr_1"]["steps"]["triage"]["attempts"] = [{"n" => 1}, {"n" => 2}]

      expect(gate(listed)["covered_by"]).to be_nil
    end

    it "is null for an item posted by a cli session even with --source-kind agent" do
      post(cmd: build(ledger: instance_double(Workspace::SessionLedger, open_session_for: nil)))

      expect(gate(listed)["covered_by"]).to be_nil
    end

    it "is null for a done item, an item of another type and an item whose source is not agent" do
      done = post
      command.done([done["id"]], working_dir: "/app")
      command.add(title: "n", type: "note", links: {run_id: "wr_1"}, source: {kind: "agent"}, working_dir: "/app")
      command.add(title: "u", type: "review_request", links: {run_id: "wr_1"}, source: {kind: "cli"}, working_dir: "/app")

      expect(gate(listed)["covered_by"]).to be_nil
    end

    it "is null for an item in another workspace" do
      other = instance_double(Workspace::ProjectDetector, detect: "elsewhere")
      cmd = described_class.new(config: config, notes: notes, project_detector: other, session_ledger: ledger, store_factory: store_factory,
        run_store: run_store, derived: derived, env: env, clock: -> { now }, output: output, error_output: error_output)
      cmd.add(title: "x", type: "review_request", links: {run_id: "wr_1"}, source: {kind: "agent"}, working_dir: "/app")

      expect(gate(listed)["covered_by"]).to be_nil
    end
  end
end
