require "tmpdir"

RSpec.describe Workspace::WorkQueueAdvance do
  let(:dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 11, 20, 12, 0, 0) }
  let(:clock) { double("clock", now: now) }
  let(:ids) { %w[aaaa1111 bbbb2222 cccc3333].each }
  let(:history) { Workspace::WorkQueueHistory.new(path: File.join(dir, "history.jsonl"), clock: clock) }
  let(:store) { Workspace::WorkQueueStore.new(path: File.join(dir, "work-queue.json"), history: history, clock: clock, id_generator: -> { ids.next }) }
  let(:run_store) { fake_runs.new }
  let(:lock_holder) { double("lock_holder", start_time: "Fri Nov 20 11:00:00 2026", holder_alive?: false) }
  let(:status) { double("status", run: {"runs" => [{"current" => {"reason" => {"actions" => [{"action" => "workflow resume", "args" => ["r1"], "needs" => []}]}}}]}) }
  let(:started) { [] }
  let(:starter) do
    lambda do |item, workspace:, checkout:, note:|
      started << {item: item, workspace: workspace, checkout: checkout, note: note}
      run_store.add("id" => "run-#{started.size}", "state" => "running", "workspace" => workspace, "note" => note)
      "run-#{started.size}"
    end
  end
  let(:starters) { {"workflow" => starter, "go" => starter} }
  let(:checkout) { Workspace::Commands::WorkflowStart::Here.new(workspace: "api-w", path: "/repo/api-w", caller_pane: nil) }
  let(:advance) { described_class.new(store_factory: ->(name) { (name == "api-w") ? store : raise("wrong workspace") }, run_store: run_store, starters: starters, lock_holder: lock_holder, status: status, clock: clock) }

  after { FileUtils.remove_entry(dir) }

  let(:fake_runs) do
    Class.new do
      def initialize
        @runs = {}
        @finished = []
      end

      def add(hash)
        run = {"current" => "s1", "steps" => {"s1" => {"state" => "running"}}}.merge(hash)
        @runs[run["id"]] = Workspace::WorkflowRun.from_h(run)
      end

      def archive(id)
        @finished << @runs.delete(id)
      end

      def run(id)
        @runs[id] || @finished.find { |r| r.id == id } || raise(Workspace::Error.new("no run #{id}", code: "unknown_run"))
      end

      def going
        @runs.values.reject { |r| Workspace::WorkflowRunStore::TERMINAL_STATES.include?(r.state) }
      end

      def unarchived = @runs.values

      def finished_since(_time) = @finished

      def delete(id) = @runs.delete(id)
    end
  end

  def pass
    advance.call(workspace: "api-w", checkout: checkout)
  end

  def add(kind = "workflow", **options)
    store.add(kind: kind, spec: {"workflow" => "rpiv"}, **options)[1]["id"]
  end

  def enabled_queue(count = 1, **options)
    store.set_enabled(true)
    Array.new(count) { add(**options) }
  end

  def item(id)
    store.snapshot["items"].find { |i| i["id"] == id }
  end

  def actions(row)
    row["next_actions"].map { |a| [a["action"], *a["args"]] }
  end

  def with_run(id, state: "waiting", step: {"state" => "failed"}, **extra)
    run_store.add({"id" => id, "state" => state, "workspace" => "api-w", "steps" => {"s1" => step}}.merge(extra.transform_keys(&:to_s)))
  end

  def started_item(run_state = "running", **run)
    first = enabled_queue(2).first
    pass
    with_run("run-1", state: run_state, **run)
    first
  end

  describe "starting an item" do
    it "claims the first item, starts it outside the lock and records the run" do
      first, second = enabled_queue(2)
      rows = pass
      expect(rows).to eq([{"outcome" => "started", "id" => first, "kind" => "workflow", "reason" => nil, "run_id" => "run-1",
                           "next_actions" => [{"action" => "workflow status", "args" => ["run-1"], "needs" => []}]}])
      call = started.first
      expect(call[:workspace]).to eq("api-w")
      expect(call[:checkout]).to eq(checkout)
      expect(call[:item]["state"]).to eq("starting")
      expect(call[:note]).to eq("Started by work-queue item #{first} (claim #{call[:item]["claim"]})")
      expect(item(first)).to include("state" => "active", "result" => include("run_id" => "run-1"))
      expect(item(first).keys).not_to include("claim", "claimed_at", "claimed_by")
      expect(item(second)["state"]).to eq("queued")
    end

    it "writes the claim fields while the starter runs" do
      first = enabled_queue.first
      seen = nil
      starters["workflow"] = lambda do |_item, **|
        seen = item(first)
        "run-9"
      end
      pass
      expect(seen).to include("state" => "starting", "claimed_at" => "2026-11-20T12:00:00.000Z",
        "claimed_by" => {"pid" => Process.pid, "started" => "Fri Nov 20 11:00:00 2026"})
      expect(seen["claim"]).to match(/\A\h{16}\z/)
    end

    it "claims with no start time when the process table can't be read" do
      allow(lock_holder).to receive(:start_time).and_raise(Workspace::Error, "ps failed")
      first = enabled_queue.first
      seen = nil
      starters["workflow"] = ->(_item, **) { (seen = item(first)) && "run-9" }
      pass
      expect(seen["claimed_by"]).to eq("pid" => Process.pid, "started" => nil)
    end
  end

  describe "refusing to start" do
    it "refuses a disabled queue, the toggle unset included" do
      add
      expect(pass).to eq([{"outcome" => "unchanged", "id" => nil, "kind" => nil, "reason" => "disabled", "run_id" => nil,
                           "next_actions" => [{"action" => "work-queue enable", "args" => ["--name", "api-w"], "needs" => []}]}])
      store.set_enabled(false)
      expect(pass.first["reason"]).to eq("disabled")
      expect(started).to be_empty
    end

    it "refuses a paused queue" do
      enabled_queue
      store.pause("failed_check")
      row = pass.first
      expect(row).to include("outcome" => "unchanged", "reason" => "paused")
      expect(actions(row)).to eq([["work-queue resume", "--name", "api-w"]])
    end

    it "refuses an empty queue" do
      store.set_enabled(true)
      expect(pass).to eq([{"outcome" => "unchanged", "id" => nil, "kind" => nil, "reason" => "empty", "run_id" => nil, "next_actions" => []}])
    end

    it "refuses while a run is going in the workspace, and not for one in another" do
      first = enabled_queue.first
      with_run("other", state: "running", workspace: "web-w")
      with_run("mine", state: "waiting")
      row = pass.first
      expect(row).to include("outcome" => "unchanged", "reason" => "run_going", "run_id" => "mine")
      expect(actions(row)).to eq([["workflow status", "mine"]])
      expect(item(first)["state"]).to eq("queued")
    end
  end

  describe "reading the current item's run" do
    it "finishes a completed run as succeeded and starts the next in the same pass" do
      first = started_item("completed")
      second = item(store.snapshot["items"].last["id"])["id"]
      rows = pass
      expect(rows.map { |r| [r["outcome"], r["id"], r["run_id"]] }).to eq([["succeeded", first, "run-1"], ["started", second, "run-2"]])
      expect(history.entries.map { |e| [e["id"], e["outcome"]] }).to eq([[first, "succeeded"]])
      expect(store.snapshot["paused"]).to be_nil
    end

    %w[failed cancelled].each do |state|
      it "finishes a #{state} run and pauses" do
        first = started_item(state)
        rows = pass
        expect(rows.first).to include("outcome" => state, "id" => first, "reason" => state)
        expect(actions(rows.first)).to eq([["work-queue resume", "--name", "api-w"]])
        expect(rows.last).to include("outcome" => "unchanged", "reason" => "paused")
        expect(store.snapshot["paused"]["reason"]).to eq(state)
        expect(history.entries.first["outcome"]).to eq(state)
      end

      it "finishes a #{state} run and goes on with on_fail continue" do
        store.set_enabled(true)
        add(on_fail: "continue")
        add
        pass
        with_run("run-1", state: state)
        rows = pass
        expect(rows.map { |r| r["outcome"] }).to eq([state, "started"])
        expect(store.snapshot["paused"]).to be_nil
      end
    end

    it "holds a live park with the run's status actions" do
      first = started_item(parked: {"expires_at" => (now + 60).iso8601})
      row = pass.first
      expect(row).to include("outcome" => "held", "id" => first, "reason" => "parked", "run_id" => "run-1")
      expect(actions(row)).to eq([["workflow resume", "r1"]])
      expect(status).to have_received(:run).with("run-1")
      expect(item(first)).to include("state" => "held", "reason" => "parked")
      expect(store.snapshot["paused"]).to be_nil
    end

    it "reads the park's status actions with the queue's lock released" do
      started_item(parked: {"expires_at" => (now + 60).iso8601})
      free = nil
      allow(status).to receive(:run) do
        File.open("#{store.path}.lock", File::RDWR | File::CREAT) { |f| free = f.flock(File::LOCK_EX | File::LOCK_NB) }
        {"runs" => []}
      end
      pass
      expect(free).to eq(0)
    end

    it "falls back to workflow status when the park's status has no actions" do
      allow(status).to receive(:run).and_return({"runs" => [{"current" => {"reason" => nil}}]})
      started_item(parked: {"expires_at" => (now + 60).iso8601})
      expect(actions(pass.first)).to eq([["workflow status", "run-1"]])
    end

    it "holds a parked run that also carries failed_check as parked, without a pause" do
      started_item(parked: {"expires_at" => (now + 60).iso8601}, reason: {"code" => "failed_check"})
      expect(pass.first["reason"]).to eq("parked")
      expect(store.snapshot["paused"]).to be_nil
    end

    it "reads an expired park by the run's other facts" do
      first = started_item(parked: {"expires_at" => (now - 60).iso8601})
      row = pass.first
      expect(row).to include("outcome" => "active", "id" => first)
      expect(item(first)["state"]).to eq("active")
    end

    it "holds a run at a gate with a workflow approve next_action" do
      first = started_item(step: {"state" => "passed", "gate" => {"state" => "waiting"}})
      row = pass.first
      expect(row).to include("outcome" => "held", "reason" => "gate", "run_id" => "run-1")
      expect(actions(row)).to eq([["workflow approve", "run-1"]])
      expect(item(first)).to include("state" => "held", "reason" => "gate")
      expect(store.snapshot["paused"]).to be_nil
    end

    %w[failed_check budget_spent run_timed_out].each do |code|
      it "holds a run waiting on #{code} and pauses the queue" do
        first = started_item(reason: {"code" => code})
        row = pass.first
        expect(row).to include("outcome" => "held", "id" => first, "reason" => code)
        expect(actions(row)).to eq([["workflow status", "run-1"], ["work-queue skip", first, "--name", "api-w"]])
        expect(store.snapshot["paused"]["reason"]).to eq(code)
      end
    end

    it "keeps a paused run, or one waiting on dispatch, active" do
      first = started_item(paused: {"since" => now.iso8601})
      expect(pass.first).to include("outcome" => "active", "run_id" => "run-1")
      with_run("run-1", state: "waiting", reason: {"code" => "waiting_lock"})
      expect(pass.first["outcome"]).to eq("active")
      expect(item(first)["state"]).to eq("active")
    end

    it "puts a held item back to active once the run moves on" do
      first = started_item(step: {"state" => "passed", "gate" => {"state" => "waiting"}})
      pass
      with_run("run-1", state: "running", step: {"state" => "running"})
      expect(pass.first["outcome"]).to eq("active")
      expect(item(first)).to include("state" => "active", "reason" => nil)
    end

    it "finishes an item whose run has gone as interrupted and pauses" do
      first = started_item
      run_store.delete("run-1")
      row = pass.first
      expect(row).to include("outcome" => "interrupted", "id" => first, "reason" => "unknown_run")
      expect(store.snapshot["paused"]["reason"]).to eq("unknown_run")
    end

    it "finishes a failure-paused item succeeded when its run completes, but starts nothing" do
      first = started_item(reason: {"code" => "failed_check"})
      pass
      with_run("run-1", state: "completed", step: {"state" => "passed"})
      rows = pass
      expect(rows.first).to include("outcome" => "succeeded", "id" => first)
      expect(rows.last).to include("outcome" => "unchanged", "reason" => "paused")
      expect(actions(rows.last)).to eq([["work-queue resume", "--name", "api-w"]])
      expect(started.size).to eq(1)
    end

    it "reconciles a disabled queue's current item" do
      first = started_item("completed")
      store.set_enabled(false)
      rows = pass
      expect(rows.map { |r| [r["outcome"], r["reason"]] }).to eq([["succeeded", nil], ["unchanged", "disabled"]])
      expect(history.entries.map { |e| e["id"] }).to eq([first])
    end
  end

  describe "a starting item left by another pass" do
    def leave_starting
      enabled_queue(2)
      claim = nil
      store.transaction { |q| claim = q.claim_next(claimed_by: {"pid" => 999_999, "started" => "then"})["claim"] }
      claim
    end

    it "changes nothing while its holder is alive" do
      leave_starting
      allow(lock_holder).to receive(:holder_alive?).with(pid: 999_999, started: "then").and_return(true)
      revision = store.snapshot["revision"]
      expect(pass).to eq([{"outcome" => "unchanged", "id" => "aaaa1111", "kind" => "workflow", "reason" => "starting", "run_id" => nil,
                           "next_actions" => [{"action" => "work-queue status", "args" => ["--name", "api-w"], "needs" => [],
                                               "why" => "Item aaaa1111 is being started by another pass; run advance again once its start has landed."}]}])
      expect(store.snapshot).to include("revision" => revision, "paused" => nil)
      expect(started).to be_empty
    end

    it "counts the holder alive when the process table can't be read" do
      leave_starting
      allow(lock_holder).to receive(:holder_alive?).and_raise(Workspace::Error, "ps failed")
      expect(pass.first["reason"]).to eq("starting")
      expect(store.snapshot["paused"]).to be_nil
    end

    it "takes the run a dead holder started as active and reads it in the same pass" do
      claim = leave_starting
      run_store.add("id" => "found", "state" => "waiting", "workspace" => "api-w", "note" => "Started by work-queue item aaaa1111 (claim #{claim})",
        "steps" => {"s1" => {"state" => "passed", "gate" => {"state" => "waiting"}}})
      row = pass.first
      expect(row).to include("outcome" => "held", "id" => "aaaa1111", "reason" => "gate", "run_id" => "found")
      expect(item("aaaa1111")).to include("state" => "held", "result" => include("run_id" => "found"))
      expect(started).to be_empty
    end

    it "finds the dead holder's run among the finished ones" do
      claim = leave_starting
      run_store.add("id" => "done", "state" => "completed", "workspace" => "api-w", "note" => "Started by work-queue item aaaa1111 (claim #{claim})")
      run_store.archive("done")
      expect(pass.map { |r| r["outcome"] }).to eq(%w[succeeded started])
    end

    it "finishes the item interrupted when no run carries its claim, and resume then starts the next once" do
      leave_starting
      run_store.add("id" => "other", "state" => "completed", "workspace" => "api-w", "note" => "Started by work-queue item aaaa1111 (claim nope)")
      rows = pass
      expect(rows.first).to include("outcome" => "interrupted", "id" => "aaaa1111", "reason" => "interrupted")
      expect(actions(rows.first)).to eq([["work-queue history show", "aaaa1111", "--name", "api-w"], ["work-queue resume", "--name", "api-w"]])
      expect(rows.last["reason"]).to eq("paused")
      expect(history.entries.first["outcome"]).to eq("interrupted")
      store.resume
      expect(pass.map { |r| [r["outcome"], r["id"]] }).to eq([["started", "bbbb2222"]])
      expect(store.snapshot["paused"]).to be_nil
      expect(started.size).to eq(1)
    end
  end

  describe "the item changing during the start" do
    it "writes nothing over a removed item, pauses with claim_lost and reports the run id" do
      first = enabled_queue.first
      starters["workflow"] = lambda do |_item, **|
        store.transaction { |q| q.items.clear }
        "run-7"
      end
      row = pass.first
      expect(row).to include("outcome" => "claim_lost", "id" => first, "reason" => "claim_lost", "run_id" => "run-7")
      expect(actions(row)).to eq([["workflow status", "run-7"], ["work-queue resume", "--name", "api-w"]])
      expect(store.snapshot).to include("items" => [], "paused" => include("reason" => "claim_lost"))
    end

    it "leaves an item carrying another claim as it is" do
      first = enabled_queue.first
      starters["workflow"] = lambda do |_item, **|
        store.transaction { |q| q.items.first["claim"] = "someone-else" }
        "run-7"
      end
      expect(pass.first["reason"]).to eq("claim_lost")
      expect(item(first)).to include("state" => "starting", "claim" => "someone-else")
      expect(history.entries).to be_empty
    end
  end

  describe "a start that raises" do
    def fail_with(error)
      starters["workflow"] = ->(_item, **) { raise error }
      first = enabled_queue.first
      [first, pass]
    end

    it "finishes the item launch_failed with the error's code and pauses" do
      first, rows = fail_with(Workspace::Error.new("no such workflow", code: "unknown_workflow"))
      expect(rows.first).to include("outcome" => "launch_failed", "id" => first, "reason" => "unknown_workflow")
      expect(actions(rows.first)).to eq([["work-queue history show", first, "--name", "api-w"], ["work-queue resume", "--name", "api-w"]])
      expect(history.entries.first).to include("outcome" => "launch_failed", "reason" => "unknown_workflow", "result" => include("error" => "no such workflow"))
      expect(store.snapshot).to include("items" => [], "paused" => include("reason" => "launch_failed"))
    end

    it "gives usage_error for a UsageError with no code" do
      expect(fail_with(Workspace::UsageError.new("bad")).last.first["reason"]).to eq("usage_error")
    end

    it "gives start_failed for a Workspace::Error with no code" do
      expect(fail_with(Workspace::Error.new("broke")).last.first["reason"]).to eq("start_failed")
    end

    it "records the go task route as run_going" do
      go = double("go", call: {"decision" => {"route" => "task"}})
      real = Workspace::WorkQueueStarters.new(workflow: nil, workflow_start: nil, go: go, workflow_project: nil, catalog: nil).to_h
      starters["go"] = real["go"]
      store.set_enabled(true)
      first = store.add(kind: "go", spec: {"argument" => "do it", "text" => true})[1]["id"]
      row = pass.first
      expect(row).to include("outcome" => "launch_failed", "id" => first, "kind" => "go", "reason" => "run_going")
      expect(store.snapshot["paused"]["reason"]).to eq("launch_failed")
    end

    it "takes a run the starter made before it raised, and does not finish the item" do
      starters["workflow"] = lambda do |_item, workspace:, note:, **|
        run_store.add("id" => "made", "state" => "waiting", "workspace" => workspace, "note" => note,
          "steps" => {"s1" => {"state" => "passed", "gate" => {"state" => "waiting"}}})
        raise Workspace::Error.new("dispatch failed", code: "dispatch_failed")
      end
      first = enabled_queue.first
      row = pass.first
      expect(row).to include("outcome" => "held", "id" => first, "reason" => "gate", "run_id" => "made")
      expect(item(first)).to include("state" => "held", "result" => include("run_id" => "made"))
      expect(item(first).keys).not_to include("claim")
      expect(history.entries).to be_empty
      expect(store.snapshot["paused"]).to be_nil
    end

    it "takes a running run the starter made before it raised as active" do
      starters["workflow"] = lambda do |_item, workspace:, note:, **|
        run_store.add("id" => "made", "state" => "running", "workspace" => workspace, "note" => note)
        raise Workspace::Error, "late failure"
      end
      first = enabled_queue.first
      expect(pass.first).to include("outcome" => "active", "id" => first, "run_id" => "made")
    end

    it "finishes an item of a kind with no starter as launch_failed" do
      store.set_enabled(true)
      store.add(kind: "notify", spec: {})
      expect(pass.first).to include("outcome" => "launch_failed", "reason" => "unknown_kind")
    end
  end
end
