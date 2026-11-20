require "tmpdir"
require "stringio"

RSpec.describe Workspace::Commands::WorkQueue do
  let(:dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 11, 20, 12, 0, 0) }
  let(:clock) { double("clock", now: now) }
  let(:ids) { %w[aaaa1111 bbbb2222 cccc3333 dddd4444].each }
  let(:histories) { Hash.new { |hash, name| hash[name] = Workspace::WorkQueueHistory.new(path: File.join(dir, "#{name}-history.jsonl"), clock: clock) } }
  let(:stores) do
    Hash.new do |hash, name|
      hash[name] = Workspace::WorkQueueStore.new(path: File.join(dir, "#{name}.json"), history: histories[name], clock: clock, id_generator: -> { ids.next })
    end
  end
  let(:store) { stores["api-w"] }
  let(:history) { histories["api-w"] }
  let(:advance) { double("advance", call: [{"outcome" => "started", "id" => "aaaa1111", "kind" => "workflow", "reason" => nil, "run_id" => "r9", "next_actions" => []}]) }
  let(:decisions) { double("decisions", cancel: nil) }
  let(:run_state) { "running" }
  let(:run_store) { double("run_store") }
  let(:roots) { {"api-w" => "/repo/api-w", "other" => "/repo/other"} }
  let(:checkout) do
    double("checkout").tap do |c|
      allow(c).to receive(:resolve) do |name, **|
        name ||= "api-w"
        {"workspace" => name, "path" => roots.fetch(name), "branch" => "feature"}
      end
    end
  end
  let(:go) { double("go", in_place_checkout: Workspace::Commands::WorkflowStart::Here.new(workspace: "api-w", path: "/repo/api-w", caller_pane: nil)) }
  let(:project) do
    Workspace::ProjectCatalog::Project.new(name: "api", members: [
      Workspace::ProjectCatalog::Member.new(workspace: "api-w"), Workspace::ProjectCatalog::Member.new(workspace: "other")
    ])
  end
  let(:status_scope) { double("status_scope", resolve: Workspace::StatusScope::Scope.new(kind: :project, project: project)) }
  let(:running) { true }
  let(:config) { double("config", agent_running?: running) }
  let(:input) { Workspace::PromptInput.new(StringIO.new("y\n")) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:command) do
    described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
      advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
      config: config, clock: clock, working_dir: "/repo/api-w", output: output, error_output: error_output, input: input)
  end

  before do
    allow(run_store).to receive(:run) { |id| Workspace::WorkflowRun.from_h("id" => id, "state" => run_state, "workspace" => "api-w", "current" => "s1", "steps" => {"s1" => {"state" => "running"}}) }
  end

  after { FileUtils.remove_entry(dir) }

  def queue_item(**options)
    store.add(kind: "workflow", spec: {"workflow" => "rpiv"}, **options)[1]["id"]
  end

  def make_current(state, run_id: "r1", reason: nil)
    store.set_enabled(true)
    queue_item
    store.transaction do |queue|
      item = queue.claim_next(claimed_by: {"pid" => 1, "started" => nil})
      queue.record_run(item["id"], claim: item["claim"], run_id: run_id)
      queue.hold(item["id"], reason: reason) if state == "held"
      item["id"]
    end
  end

  def claim_only
    queue_item
    store.transaction { |queue| queue.claim_next(claimed_by: {"pid" => 1, "started" => nil})["id"] }
  end

  describe "#add" do
    it "queues an item and returns its row" do
      rows = command.add(kind: "workflow", spec: {"workflow" => "rpiv"})
      expect(rows).to eq([{"outcome" => "added", "id" => "aaaa1111", "position" => 1, "kind" => "workflow"}])
      expect(store.snapshot["items"].first["added_by"]).to eq("person")
    end

    it "gives unchanged for a repeated dedupe key" do
      command.add(kind: "workflow", spec: {}, dedupe_key: "k")
      expect(command.add(kind: "workflow", spec: {}, dedupe_key: "k").first).to include("outcome" => "unchanged", "id" => "aaaa1111")
    end

    it "puts an item after the current one" do
      make_current("active")
      command.add(kind: "workflow", spec: {}, position: :bottom)
      rows = command.add(kind: "workflow", spec: {}, position: :after_current)
      expect(rows.first["position"]).to eq(2)
    end

    it "checks a go item against the named workspace's root" do
      command.add(kind: "go", spec: {"text" => "x"}, name: "other")
      expect(go).to have_received(:in_place_checkout).with("/repo/other", workspace: "other")
    end

    it "refuses a go item where go can't run in place" do
      allow(go).to receive(:in_place_checkout).with("/repo/api-w", workspace: "api-w").and_return(nil)
      expect { command.add(kind: "go", spec: {"argument" => "fix it"}) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("go_here_unavailable")
        expect(e.details).to eq("path" => "/repo/api-w")
      }
      expect(store.snapshot["items"]).to be_empty
    end

    it "queues a go item when it can run in place" do
      expect(command.add(kind: "go", spec: {"text" => "fix it"}).first).to include("outcome" => "added", "kind" => "go")
    end
  end

  describe "#rm and #move" do
    it "removes queued items" do
      first = queue_item
      expect(command.rm(ids: [first])).to eq([{"outcome" => "removed", "id" => first, "position" => nil, "kind" => "workflow"}])
    end

    it "moves an item and reports unchanged when nothing moves" do
      queue_item
      second = queue_item
      expect(command.move(id: second, top: true).first).to include("outcome" => "moved", "position" => 1)
      expect(command.move(id: second, top: true).first).to include("outcome" => "unchanged", "position" => 1)
    end

    it "refuses a starting item" do
      id = claim_only
      expect { command.rm(ids: [id]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_starting") }
      expect { command.move(id: id, bottom: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_starting") }
    end

    it "refuses an active item" do
      id = make_current("active")
      expect { command.rm(ids: [id]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_active") }
    end
  end

  describe "#enable, #disable and #resume" do
    it "toggles the queue and reports no change the second time" do
      expect(command.enable.first["outcome"]).to eq("enabled")
      expect(command.enable.first["outcome"]).to eq("unchanged")
      expect(command.disable.first["outcome"]).to eq("disabled")
      expect(store.snapshot["enabled"]).to eq(false)
    end

    it "clears the pause and nothing else" do
      store.set_enabled(true)
      id = queue_item
      store.pause("failed_check")
      expect(command.resume.first["outcome"]).to eq("resumed")
      expect(command.resume.first["outcome"]).to eq("unchanged")
      expect(store.snapshot).to include("paused" => nil, "enabled" => true)
      expect(store.snapshot["items"].map { |i| i["id"] }).to eq([id])
    end
  end

  describe "#skip" do
    it "skips the held item, clears the pause and warns about a run still going" do
      id = make_current("held", reason: "failed_check")
      store.pause("failed_check")
      row = command.skip.first
      expect(row).to include("outcome" => "skipped", "id" => id, "run_id" => "r1")
      expect(row["next_actions"]).to eq([Workspace::NextAction.build("workflow cancel", "r1")])
      expect(row["warnings"]).to eq([{"code" => "run_still_going", "message" => "Run r1 is still going and blocks the next start until it ends."}])
      expect(store.snapshot).to include("paused" => nil, "items" => [])
      expect(history.entries.first).to include("id" => id, "outcome" => "skipped")
      expect(decisions).not_to have_received(:cancel)
    end

    it "adds no warning when the run has ended" do
      allow(run_store).to receive(:run).and_return(Workspace::WorkflowRun.from_h("id" => "r1", "state" => "completed", "workspace" => "api-w"))
      make_current("held", reason: "gate")
      expect(command.skip.first).not_to have_key("warnings")
    end

    it "refuses with item_not_held and a resume next action when nothing is held" do
      expect { command.skip }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("item_not_held")
        expect(e.details["next_actions"]).to eq([Workspace::NextAction.build("work-queue resume", "--name", "api-w")])
      }
    end

    it "refuses a queued item" do
      queued = queue_item
      expect { command.skip(id: queued) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_not_held") }
    end

    it "refuses an active item" do
      active = make_current("active")
      expect { command.skip(id: active) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_not_held") }
      expect(store.snapshot["items"].first["state"]).to eq("active")
    end

    it "refuses a starting item" do
      claim_only
      expect { command.skip }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_starting") }
    end
  end

  describe "#cancel" do
    it "cancels the current item without an id, then pauses" do
      id = make_current("active")
      rows = command.cancel
      expect(decisions).to have_received(:cancel).with("r1", actor: "person")
      expect(rows).to eq([{"outcome" => "cancelled", "id" => id, "position" => nil, "kind" => "workflow", "run_id" => "r1"}])
      expect(store.snapshot["paused"]).to include("reason" => "cancelled")
      expect(history.entries.first).to include("id" => id, "outcome" => "cancelled")
    end

    it "cancels a given held item" do
      id = make_current("held", reason: "gate")
      command.cancel(id: id[0, 4])
      expect(decisions).to have_received(:cancel).with("r1", actor: "person")
    end

    it "goes on with and_continue: no pause and a pass" do
      make_current("active")
      rows = command.cancel(and_continue: true)
      expect(rows.map { |r| r["outcome"] }).to eq(%w[cancelled started])
      expect(rows.last["position"]).to be_nil
      expect(store.snapshot["paused"]).to be_nil
      expect(advance).to have_received(:call).with(workspace: "api-w", checkout: Workspace::Commands::WorkflowStart::Here.new(workspace: "api-w", path: "/repo/api-w", caller_pane: nil))
    end

    it "leaves the item and the queue unchanged when cancelling the run raises" do
      id = make_current("active")
      allow(decisions).to receive(:cancel).and_raise(Workspace::Error.new("boom", code: "unknown_run"))
      expect { command.cancel }.to raise_error(Workspace::Error, "boom")
      expect(store.snapshot["items"].map { |i| [i["id"], i["state"]] }).to eq([[id, "active"]])
      expect(store.snapshot["paused"]).to be_nil
      expect(history.entries).to be_empty
    end

    it "refuses a queued id with item_not_active" do
      queued = queue_item
      expect { command.cancel(id: queued) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_not_active") }
    end

    it "refuses with nothing current" do
      expect { command.cancel }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_not_active") }
    end

    it "refuses a starting item and cancels nothing" do
      claim_only
      expect { command.cancel }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("item_starting") }
      expect(decisions).not_to have_received(:cancel)
    end
  end

  describe "#advance" do
    it "runs a pass in the named workspace's own root" do
      rows = command.advance(name: "other")
      expect(advance).to have_received(:call).with(workspace: "other", checkout: Workspace::Commands::WorkflowStart::Here.new(workspace: "other", path: "/repo/other", caller_pane: nil))
      expect(rows.first).to include("outcome" => "started", "position" => nil)
    end
  end

  describe "#action_extra" do
    it "names the queue and its revision" do
      queue_item
      expect(command.action_extra(name: "api-w")).to eq("queue" => "api-w", "revision" => 1)
    end
  end

  describe "reads" do
    before do
      queue_item
      queue_item
    end

    it "lists a queue with its footer facts and next actions" do
      doc = command.list
      queue = doc["queues"].first
      expect(queue).to include("workspace" => "api-w", "state" => "off", "daemon_running" => true, "revision" => 2)
      expect(queue["items"].map { |i| i["position"] }).to eq([1, 2])
      expect(queue["next_actions"]).to include(Workspace::NextAction.build("work-queue enable", "--name", "api-w"))
      expect(output.string).to include("aaaa1111").and include("off, daemon up")
    end

    it "reports paused with its reason" do
      store.set_enabled(true)
      store.pause("failed_check")
      expect(command.status["queues"].first).to include("state" => "paused", "paused_reason" => "failed_check", "queued" => 2)
      expect(output.string).to include("paused (failed_check)")
    end

    context "when the daemon is not answering" do
      let(:running) { false }

      it "warns in the document and on stderr" do
        doc = command.list
        expect(doc["warnings"].first).to include("code" => "daemon_not_running", "workspace" => "api-w")
        expect(error_output.string).to include("not answering")
        expect(command.status["warnings"].size).to eq(1)
      end
    end

    it "lists a project's workspaces without writing anything" do
      before_files = Dir.children(dir).sort
      doc = command.list(project: true)
      expect(doc["queues"].map { |q| q["workspace"] }).to eq(%w[api-w other])
      expect(Dir.children(dir).sort).to eq(before_files)
      expect(store.snapshot["revision"]).to eq(2)
      expect(command.status(project: true)["queues"].size).to eq(2)
      expect(Dir.children(dir).sort).to eq(before_files)
      expect(status_scope).to have_received(:resolve).with(name: nil, project: true, all: nil, working_dir: "/repo/api-w").at_least(:once)
    end

    it "shows one item in full with a nil log path" do
      doc = command.show(id: "bbbb")
      expect(doc["item"]).to include("id" => "bbbb2222", "position" => 2, "what" => "rpiv", "run_id" => nil)
      expect(doc["item"]["result"]["log_path"]).to be_nil
    end

    it "shows nothing active when idle" do
      expect(command.active["item"]).to be_nil
    end
  end

  describe "#active" do
    it "reports the item's real position" do
      store.set_enabled(true)
      queue_item
      id = store.transaction { |q| q.claim_next(claimed_by: {"pid" => 1, "started" => nil})["id"] }
      store.transaction { |q| q.record_run(id, claim: q.current["claim"], run_id: "r1") }
      expect(command.active["item"]).to include("id" => id, "position" => 1)
    end

    it "offers no approve for a gate with no run id" do
      store.set_enabled(true)
      queue_item
      store.transaction do |q|
        item = q.claim_next(claimed_by: {"pid" => 1, "started" => nil})
        q.record_run(item["id"], claim: item["claim"], run_id: nil)
        q.hold(item["id"], reason: "gate")
      end
      actions = command.active["next_actions"]
      expect(actions.map { |a| a["action"] }).not_to include("workflow approve")
      expect(actions.flat_map { |a| a["args"] }).not_to include(nil)
    end

    it "says a held item waits on a person and offers approve for a gate" do
      make_current("held", reason: "gate")
      doc = command.active
      expect(doc["waiting_on"]).to include("on" => "person", "reason" => "gate", "run_id" => "r1", "run_state" => "running", "step" => "s1")
      expect(doc["next_actions"].first).to eq(Workspace::NextAction.build("workflow approve", "r1"))
    end

    it "says an active item waits on its run" do
      make_current("active")
      expect(command.active["waiting_on"]).to include("on" => "run")
    end
  end

  describe "history" do
    let(:old_time) { Time.utc(2026, 1, 1) }

    before do
      history.append("id" => "h1", "kind" => "workflow", "spec" => {"workflow" => "rpiv"}, "outcome" => "succeeded", "finished_at" => "2026-01-01T00:00:00.000Z")
      history.append("id" => "h2", "kind" => "go", "spec" => {"text" => "x"}, "outcome" => "failed", "finished_at" => "2026-11-01T00:00:00.000Z")
    end

    it "lists and filters entries" do
      expect(command.history_list["entries"].map { |e| e["id"] }).to eq(%w[h1 h2])
      expect(command.history_list(state: "failed")["entries"].map { |e| e["workspace"] }).to eq(["api-w"])
    end

    it "shows one entry" do
      expect(command.history_show(id: "h1")["entry"]).to include("id" => "h1")
    end

    it "clears before a date" do
      expect(command.history_clear(before: Time.utc(2026, 6, 1), yes: true).first).to include("outcome" => "cleared", "count" => 1)
      expect(history.entries.map { |e| e["id"] }).to eq(["h2"])
    end

    it "clears all" do
      expect(command.history_clear(all: true, yes: true).first["count"]).to eq(2)
    end

    it "needs exactly one of before and all" do
      expect { command.history_clear(yes: true) }.to raise_error(Workspace::UsageError)
      expect { command.history_clear(before: old_time, all: true, yes: true) }.to raise_error(Workspace::UsageError)
    end

    it "asks on a tty and clears on yes" do
      allow(input).to receive(:tty?).and_return(true)
      expect(command.history_clear(all: true).first["outcome"]).to eq("cleared")
      expect(output.string).to include("[y/N]")
    end

    it "deletes nothing when the answer is no" do
      allow(input).to receive(:tty?).and_return(true)
      allow(input).to receive(:gets).and_return("n\n")
      expect(command.history_clear(all: true).first).to include("outcome" => "cancelled", "count" => 0)
      expect(history.entries.size).to eq(2)
    end

    it "refuses to ask under json, with no input or off a tty, with confirmation_required" do
      allow(input).to receive(:tty?).and_return(true)
      expect { command.history_clear(all: true, json: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
      input.no_input!
      expect { command.history_clear(all: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
      expect(history.entries.size).to eq(2)
    end

    it "refuses to ask off a tty" do
      expect { command.history_clear(all: true) }.to raise_error(Workspace::Error, /--yes/) { |e| expect(e.code).to eq("confirmation_required") }
      expect(history.entries.size).to eq(2)
    end

    it "carries next actions, and an add-again command for a shown entry" do
      expect(command.history_list["next_actions"].first["action"]).to eq("work-queue history show")
      expect(command.history_show(id: "h1")["next_actions"]).to eq([Workspace::NextAction.build("work-queue add", "workflow", "rpiv", "--name", "api-w")])
      expect(command.history_show(id: "h2")["next_actions"].first["args"]).to eq(%w[go x --text --name api-w])
    end

    it "reads a project's history without pruning or writing" do
      history.append("id" => "h0", "outcome" => "failed", "finished_at" => "2024-01-01T00:00:00.000Z")
      path = File.join(dir, "api-w-history.jsonl")
      before = File.read(path)
      entries = command.history_list(project: true)["entries"]
      expect(entries.map { |e| e["id"] }).not_to include("h0")
      expect(File.read(path)).to eq(before)
    end
  end
end
