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
  let(:input) { Workspace::PromptInput.new(StringIO.new("y\n")) }
  let(:ensured) { [] }
  let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:running) }
  let(:agent_ensurer) { ->(name:) { (ensured << name) && ensure_result } }
  let(:daemons_up) { {} }
  let(:agent_running) { ->(workspace) { daemons_up.fetch(workspace, false) } }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:command) do
    described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
      advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
      agent_ensurer: agent_ensurer, agent_running: agent_running, clock: clock, working_dir: "/repo/api-w", output: output, error_output: error_output, input: input)
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
    it "tells the person how to start an off queue, and not an enabled one" do
      command.add(kind: "workflow", spec: {})
      expect(output.string).to include(described_class::OFF_HINT)
      output.truncate(0)
      store.set_enabled(true)
      command.add(kind: "workflow", spec: {})
      expect(output.string).not_to include("enable")
    end

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

    it "makes sure the workspace's agent daemon runs on enable and add, and not on disable" do
      command.enable(name: "other")
      command.disable(name: "other")
      command.add(kind: "workflow", spec: {})

      expect(ensured).to eq(%w[other api-w])
    end

    context "when the agent daemon can't be started" do
      let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:failed, "no answer in 5s") }

      it "keeps the change and warns on the row and the error stream" do
        rows = command.enable
        expect(rows.first["outcome"]).to eq("enabled")
        expect(rows.first["warnings"]).to eq([{"code" => "daemon_not_started", "workspace" => "api-w",
                                               "message" => "Could not start the agent daemon of 'api-w' (no answer in 5s); the queue moves only on `workspace work-queue advance` until `workspace agentd --ensure --name api-w` starts it."}])
        expect(error_output.string).to include("Warning: Could not start the agent daemon of 'api-w' (no answer in 5s)")
        expect(store.snapshot["enabled"]).to eq(true)
      end

      it "names an unusable pipeline config, and takes a raising ensurer as a warning too" do
        invalid = described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
          advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
          agent_ensurer: ->(name:) { Workspace::Commands::EnsureAgent::Result.new(:invalid_config) }, agent_running: agent_running,
          clock: clock, working_dir: "/repo/api-w", output: output, error_output: error_output, input: input)
        raising = described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
          advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
          agent_ensurer: ->(name:) { raise Workspace::Error, "unknown workspace\nmore" }, agent_running: agent_running,
          clock: clock, working_dir: "/repo/api-w", output: output, error_output: error_output, input: input)

        expect(invalid.add(kind: "workflow", spec: {}).first["warnings"].first["message"]).to include("(its pipeline config can't be used)")
        expect(raising.enable.first["warnings"].first["message"]).to include("(unknown workspace)")
      end
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
    it "prints its warning to stderr once under the CLI's --json" do
      make_current("held", reason: "failed_check")
      err = StringIO.new
      out = StringIO.new
      invocation = Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: true, env: {})
      gated = described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] }, advance: advance, decisions: decisions,
        run_store: run_store, checkout: checkout, go: go, status_scope: status_scope, agent_ensurer: agent_ensurer, agent_running: agent_running,
        clock: clock, working_dir: "/repo/api-w", output: invocation.output, error_output: err, input: input)

      Workspace::CLI::WorkQueue.new(work_queue_command: gated, common: Workspace::CLI::Common.new).call("work-queue", ["skip", "--json"], invocation)

      expect(err.string.scan("Run r1 is still going").size).to eq(1)
      expect(JSON.parse(out.string)["warnings"].size).to eq(1)
    end

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

    it "clears an existing pause with and_continue, so the pass can start the next item" do
      make_current("held", reason: "failed_check")
      store.pause("failed_check")
      command.cancel(and_continue: true)
      expect(store.snapshot["paused"]).to be_nil
    end

    context "when the item's run has already ended" do
      let(:run_state) { "completed" }

      it "records the item cancelled without cancelling the run" do
        id = make_current("active")
        command.cancel
        expect(decisions).not_to have_received(:cancel)
        expect(history.entries.first).to include("id" => id, "outcome" => "cancelled")
      end
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
      expect(output.string).to eq("Started aaaa1111 (run r9).\n")
    end

    row_of = lambda do |outcome, reason: nil, id: "aaaa1111", run_id: "r9"|
      {"outcome" => outcome, "id" => id, "kind" => "workflow", "reason" => reason, "run_id" => run_id, "next_actions" => []}
    end

    {
      [row_of.call("unchanged", reason: "disabled", id: nil, run_id: nil)] => "Queue is off; nothing started.",
      [row_of.call("unchanged", reason: "empty", id: nil, run_id: nil)] => "Queue is empty.",
      [row_of.call("unchanged", reason: "run_going", id: nil)] => "A run is going in this workspace (run r9); nothing started.",
      [row_of.call("unchanged", reason: "starting", run_id: nil)] => "aaaa1111 is being started by another pass",
      [row_of.call("active")] => "aaaa1111 is running (run r9).",
      [row_of.call("succeeded")] => "aaaa1111 finished (run r9).",
      [row_of.call("held", reason: "gate")] => "Approve it with `workspace workflow approve r9`.",
      [row_of.call("failed", reason: "failed")] => "aaaa1111 ended failed (run r9).",
      [row_of.call("launch_failed", reason: "agent_missing", run_id: nil)] => "aaaa1111 could not start (agent_missing)",
      [row_of.call("claim_lost", reason: "claim_lost", run_id: nil)] => "aaaa1111 was taken by another pass",
      [row_of.call("interrupted", reason: "unknown_run", run_id: nil)] => "aaaa1111 was interrupted (unknown_run)"
    }.each do |rows, sentence|
      it "says #{rows.first["outcome"]}/#{rows.first["reason"]} as a sentence" do
        allow(advance).to receive(:call).and_return(rows)
        command.advance
        expect(output.string).to include(sentence)
      end
    end

    it "says a pause with its reason and the way out" do
      store.pause("failed_check")
      allow(advance).to receive(:call).and_return([row_of.call("unchanged", reason: "paused", id: nil, run_id: nil)])
      command.advance
      expect(output.string).to include("Queue is paused (failed_check); run `workspace work-queue resume`.")
    end

    it "prints the pass rows of cancel --and-continue" do
      make_current("active")
      command.cancel(and_continue: true)
      expect(output.string).to include("Cancelled").and include("Started aaaa1111 (run r9).")
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
      expect(queue).to include("workspace" => "api-w", "state" => "off", "revision" => 2)
      expect(queue["items"].map { |i| i["position"] }).to eq([1, 2])
      expect(queue["next_actions"]).to include(Workspace::NextAction.build("work-queue enable", "--name", "api-w"))
      expect(output.string).to include("aaaa1111").and include("api-w: off").and include(described_class::OFF_HINT)
    end

    it "reports paused with its reason" do
      store.set_enabled(true)
      store.pause("failed_check")
      expect(command.status["queues"].first).to include("state" => "paused", "paused_reason" => "failed_check", "queued" => 2)
      expect(output.string).to include("paused (failed_check)")
    end

    it "warns of nothing for an off queue, and says the daemon is down in the footer" do
      doc = command.list
      expect(doc["warnings"]).to eq([])
      expect(doc["queues"].first).to include("daemon_running" => false)
      expect(output.string).to include("api-w: off, daemon down")
      expect(error_output.string).to eq("")
    end

    it "warns when an enabled queue's daemon isn't answering, and offers to start it or advance by hand" do
      store.set_enabled(true)
      doc = command.list
      expect(doc["warnings"]).to eq([{"code" => "daemon_not_running", "workspace" => "api-w",
                                      "message" => "The agent daemon of 'api-w' is not answering, so its queue moves only on `workspace work-queue advance`; `workspace agentd --ensure --name api-w` starts it."}])
      expect(doc["queues"].first["next_actions"].map { |a| a["action"] }).to eq(["agentd --ensure", "work-queue advance"])
      expect(error_output.string).to include("Warning: The agent daemon of 'api-w' is not answering")
    end

    it "warns of nothing and offers no advance when an enabled queue's daemon answers" do
      store.set_enabled(true)
      daemons_up["api-w"] = true
      doc = command.status
      expect(doc["warnings"]).to eq([])
      expect(doc["queues"].first).to include("daemon_running" => true, "next_actions" => [])
      expect(output.string).to include("daemon up")
    end

    it "takes a daemon whose socket can't be looked for as down" do
      down = described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
        advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
        agent_ensurer: agent_ensurer, agent_running: ->(_workspace) { raise Workspace::Error, "socket dir is too deep" },
        clock: clock, working_dir: "/repo/api-w", output: output, error_output: error_output, input: input)

      expect(down.list["queues"].first["daemon_running"]).to be(false)
    end

    it "warns once per enabled workspace of a project whose daemon is down" do
      stores["other"].set_enabled(true)
      store.set_enabled(true)
      daemons_up["api-w"] = true
      doc = command.status(project: true)
      expect(doc["warnings"].map { |w| w["workspace"] }).to eq(["other"])
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

    it "points at history for an id that only a finished item has" do
      history.append("id" => "fin00001", "kind" => "workflow", "spec" => {}, "outcome" => "succeeded", "finished_at" => "2026-01-01T00:00:00.000Z")
      expect { command.show(id: "fin0") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_queue_item")
        expect(e.message).to include("`workspace work-queue history show fin00001`")
      }
      expect { command.show(id: "zzzz") }.to raise_error(Workspace::Error) { |e| expect(e.message).not_to include("history show") }
    end

    it "leaves the log line out when an item has no log" do
      command.show(id: "bbbb")
      expect(output.string).not_to include("log ")
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

    it "gives a project's history one show action per workspace that has entries" do
      histories["other"].append("id" => "o1", "outcome" => "succeeded", "kind" => "workflow", "spec" => {"workflow" => "rpiv"}, "finished_at" => now.iso8601(3))
      names = command.history_list(project: true)["next_actions"].map { |a| a["args"].last }
      expect(names).to eq(%w[api-w other])
    end
  end

  describe "watching" do
    let(:sleeps) { [] }
    let(:sleeper) {
      ->(seconds) {
        sleeps << seconds
        raise Interrupt if sleeps.size == 2
      }
    }
    let(:watched) do
      described_class.new(store_factory: ->(name) { stores[name] }, history_factory: ->(name) { histories[name] },
        advance: advance, decisions: decisions, run_store: run_store, checkout: checkout, go: go, status_scope: status_scope,
        agent_ensurer: agent_ensurer, agent_running: agent_running, clock: clock, watch_loop: Workspace::WatchLoop.new(output: output, sleeper: sleeper), working_dir: "/repo/api-w",
        output: output, error_output: error_output, input: input)
    end

    it "draws the list as one frame, sleeps the interval and returns exit 0 on Ctrl-C" do
      queue_item

      expect(watched.watch_list(interval: 0.5)).to eq(exit_code: 0)
      expect(output.string).to include("api-w: off, daemon down")
      expect(output.string.scan("api-w: off").size).to eq(1)
      expect(sleeps).to eq([0.5, 0.5])
    end

    it "keeps redrawing until interrupted" do
      store.set_enabled(true)
      daemons_up["api-w"] = true

      watched.watch_list
      expect(sleeps.size).to eq(2)
    end

    it "puts the daemon_not_running warning in the frame and not on the error stream" do
      store.set_enabled(true)

      watched.watch_list

      expect(output.string).to include("Warning: The agent daemon of 'api-w' is not answering")
      expect(error_output.string).to eq("")
    end

    it "draws the active item and returns exit 0" do
      make_current("held", reason: "gate")

      expect(watched.watch_active(interval: 1)).to eq(exit_code: 0)
      expect(output.string).to include("aaaa1111 held workflow")
      expect(sleeps).to eq([1, 1])
    end

    it "leaves plain list and active output and warnings as they were" do
      store.set_enabled(true)
      command.list
      command.active

      expect(output.string).not_to include("Warning:")
      expect(error_output.string).to include("Warning: The agent daemon of 'api-w' is not answering")
      expect(output.string).to include("Nothing is active in 'api-w'.")
    end
  end
end
