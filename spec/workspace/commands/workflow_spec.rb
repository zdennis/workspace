require "spec_helper"
require "stringio"
require "json"
require "tmpdir"

RSpec.describe Workspace::Commands::Workflow do
  let(:catalog) { instance_double(Workspace::WorkflowCatalog) }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:status) { instance_double(Workspace::WorkflowStatus) }
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:output) { StringIO.new }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for: "app", pane_details: []) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:lock_holder) { instance_double(Workspace::LockHolder) }
  subject(:command) do
    described_class.new(catalog: catalog, engine: engine, status: status, store: store, panes: panes, files: nil, run_files: nil,
      tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, pid: 4242,
      clock: -> { Time.utc(2026, 10, 4, 13, 0, 0) }, output: output)
  end

  let(:definition) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      title: Flow
      description: Plan, then verify.
      inputs:
        task: {description: What to build, required: true}
        spec:
      steps:
        plan:
          prompt: Plan.
          produces: [plan.md]
          gate: approve
        verify:
          prompt: Verify.
          uses: [test-db]
          status: {command: test}
          context: continue
          on_fail: {goto: plan, max: 2}
    YAML
  end

  def shown(overrides = {})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "state" => "running",
     "current" => {"step" => "plan", "attempt" => 1, "state" => "running", "reason" => nil, "flags" => []}}.merge(overrides)
  end

  def reason(code, details, actions = [])
    {"code" => code, "since" => "2026-10-04T12:00:00Z", "details" => details, "actions" => actions}
  end

  def json
    JSON.parse(output.string)
  end

  describe "#show" do
    it "lists the definitions, marking one that is not valid" do
      allow(catalog).to receive(:list).and_return([
        {"id" => "bad", "title" => "bad", "source" => "global", "path" => "/defs/bad.yml", "problems" => ["steps must be a mapping"]},
        {"id" => "rpiv", "title" => "Research, Plan, Implement, Verify", "source" => "builtin", "path" => "/lib/rpiv.yml", "problems" => []}
      ])

      command.show

      expect(output.string).to eq(
        "bad              global   bad  INVALID: steps must be a mapping\n" \
        "rpiv             builtin  Research, Plan, Implement, Verify\n"
      )
    end

    it "lists the definitions as one document" do
      entries = [{"id" => "rpiv", "title" => "RPIV", "source" => "builtin", "path" => "/lib/rpiv.yml", "problems" => []}]
      allow(catalog).to receive(:list).and_return(entries)

      command.show(json: true)

      expect(json).to eq("schema_version" => 1, "ok" => true, "workflows" => entries)
    end

    it "says so when there are none" do
      allow(catalog).to receive(:list).and_return([])

      command.show

      expect(output.string).to eq("No workflows.\n")
    end

    it "prints one definition: where it came from, its inputs and what each step does" do
      allow(catalog).to receive(:find).with("flow").and_return(definition)

      command.show(id: "flow")

      expect(output.string).to eq(<<~TEXT)
        flow: Flow (global, /defs/flow.yml)
        Plan, then verify.
        Inputs:
          task (required): What to build
          spec
        Steps:
          plan         produces plan.md; gate: approve
          verify       uses test-db; check; on fail: back to plan, 2 time(s); continues the conversation
      TEXT
    end

    it "prints one definition as a document, with its source, path and hash" do
      allow(catalog).to receive(:find).with("flow").and_return(definition)

      command.show(id: "flow", json: true)

      expect(json).to eq("schema_version" => 1, "ok" => true,
        "workflow" => definition.to_h.merge("source" => "global", "path" => "/defs/flow.yml", "sha256" => definition.sha256))
    end
  end

  describe "#run" do
    before { allow(catalog).to receive(:find).with("flow").and_return(definition) }

    it "starts the run in the workspace's Claude pane and reports where it stands" do
      allow(panes).to receive(:default_pane).with("app").and_return("%5")
      allow(engine).to receive(:start).and_return("id" => "wr_1", "workspace" => "app")
      allow(status).to receive(:run).with("wr_1").and_return("runs" => [shown], "warnings" => [])

      row = command.run(id: "flow", workspace: "app", worktree: "/src/app", inputs: {"task" => "X-1"}, note: "Small.")

      expect(engine).to have_received(:start).with(definition: definition, workspace: "app", worktree: "/src/app", inputs: {"task" => "X-1"}, pane: "%5", note: "Small.")
      expect(row).to eq("workspace" => "app", "outcome" => "started", "reason" => nil, "message" => nil, "run" => shown)
      expect(output.string).to eq("wr_1  flow  app  running  step plan (attempt 1), running\n")
    end

    it "resolves a pane the caller named" do
      allow(panes).to receive(:locate).with("app", "0.1").and_return("%7")
      allow(engine).to receive(:start).and_return("id" => "wr_1", "workspace" => "app")
      allow(status).to receive(:run).and_return("runs" => [shown], "warnings" => [])

      command.run(id: "flow", workspace: "app", worktree: "/src/app", pane: "0.1")

      expect(engine).to have_received(:start).with(hash_including(pane: "%7"))
    end

    it "reports a run whose first step could not be started as failed, with why and what to do" do
      allow(panes).to receive(:default_pane).and_return("%5")
      allow(engine).to receive(:start).and_return("id" => "wr_1", "workspace" => "app")
      stuck = shown("state" => "waiting", "current" => {"step" => "plan", "attempt" => 1, "state" => "waiting", "flags" => [],
                                                        "reason" => reason("pane_gone", {"kind" => "dispatch", "step" => "plan", "pane" => "%5", "workspace" => "app", "message" => "no pane %5"},
                                                          [{"action" => "workflow resume", "args" => ["wr_1"], "needs" => []}])})
      allow(status).to receive(:run).and_return("runs" => [stuck], "warnings" => [])

      row = command.run(id: "flow", workspace: "app", worktree: "/src/app")

      expect(row).to include("outcome" => "failed", "reason" => "pane_gone", "message" => "no pane %5")
      expect(output.string).to eq(
        "wr_1  flow  app  waiting  step plan (attempt 1), waiting\n" \
        "  pane_gone: pane %5 of app is not running: no pane %5\n" \
        "    workspace workflow resume wr_1\n"
      )
    end

    it "only checks with dry_run: no daemon is started and no run is made" do
      allow(panes).to receive(:default_pane).with("app", start_daemon: false).and_return(nil)
      allow(engine).to receive(:preflight).with(definition: definition, workspace: "app", worktree: "/src/app", inputs: {"task" => "X"}, pane: nil)
        .and_return("workflow" => "flow", "step" => "plan", "inputs" => {"task" => "X", "spec" => ""}, "packs" => ["play/binding"])

      row = command.run(id: "flow", workspace: "app", worktree: "/src/app", inputs: {"task" => "X"}, dry_run: true)

      expect(row).to eq("workspace" => "app", "outcome" => "dry_run", "reason" => nil, "message" => nil, "workflow" => "flow", "step" => "plan", "pane" => nil,
        "inputs" => {"task" => "X", "spec" => ""}, "packs" => ["play/binding"])
      expect(output.string).to eq("Would start flow in app at step plan (its agent daemon is not running; starting the run starts it and picks the Claude pane).\n")
    end

    it "names the pane a dry run would use when the daemon is up" do
      allow(panes).to receive(:default_pane).with("app", start_daemon: false).and_return("%5")
      allow(engine).to receive(:preflight).and_return("step" => "plan", "inputs" => {}, "packs" => [])

      command.run(id: "flow", workspace: "app", worktree: "/src/app", dry_run: true)

      expect(output.string).to eq("Would start flow in app at step plan in pane %5.\n")
    end
  end

  describe "#show with an entry that has no source it could be read from" do
    it "lists it without raising" do
      allow(catalog).to receive(:list).and_return([
        {"id" => "mine", "title" => "mine", "source" => "global", "path" => "/defs/mine.yml", "problems" => ["/defs/mine.yml is a link to a file that is not there"]}
      ])

      command.show

      expect(output.string).to eq("mine             global   mine  INVALID: /defs/mine.yml is a link to a file that is not there\n")
    end
  end

  describe "#status" do
    let(:gate) do
      shown("state" => "waiting", "current" => {"step" => "plan", "attempt" => 1, "state" => "passed", "flags" => ["timed_out"],
                                                "reason" => reason("waiting_you", {"kind" => "gate", "step" => "plan", "artifacts" => ["/src/app/.workflow/wr_1/plan.md"]},
                                                  [{"action" => "workflow approve", "args" => ["wr_1"], "needs" => []},
                                                    {"action" => "workflow reject", "args" => ["wr_1"], "needs" => [{"name" => "note", "flag" => "--note"}]},
                                                    {"action" => "ask answer", "args" => ["a1", "--name", "app"], "needs" => [{"name" => "answer", "flag" => nil}]}])})
    end

    it "prints each run with its step, and why it is not moving with the commands that resolve it" do
      allow(status).to receive(:runs).with(workspace: "app", all: false).and_return("runs" => [gate], "warnings" => ["The daemon did not answer."])

      command.status(workspace: "app")

      expect(output.string).to eq(<<~TEXT)
        wr_1  flow  app  waiting  step plan (attempt 1), passed
          waiting_you: step plan passed and waits for approval (/src/app/.workflow/wr_1/plan.md)
          flag: timed_out
            workspace workflow approve wr_1
            workspace workflow reject wr_1 --note NOTE
            workspace ask answer a1 --name app -- ANSWER
        Warning: The daemon did not answer.
      TEXT
    end

    it "words every reason for a person" do
      texts = {
        reason("waiting_lock", {"resource" => "test-db", "position" => 1, "total" => 2, "holder" => {"run_id" => "wr_9", "step" => "verify", "workspace" => "app.b"}}) =>
          "waiting_lock: queued for test-db, 1 of 2, held by run wr_9 (step verify) in app.b",
        reason("waiting_lock", {"resource" => "devenv", "position" => 2, "total" => 3, "holder" => {"pid" => 4242, "kind" => "process", "worktree" => "/src/app-tax"}}) =>
          "waiting_lock: queued for devenv, 2 of 3, held by the dev environment in /src/app-tax (pid 4242)",
        reason("waiting_lock", {"resource" => "test-db", "position" => 1, "total" => 1, "holder" => {"pid" => 77, "kind" => "agent", "worktree" => "/src/app"}}) =>
          "waiting_lock: queued for test-db, 1 of 1, held by an agent in /src/app (pid 77)",
        reason("waiting_you", {"kind" => "prompt", "pane" => "%5", "message" => "Claude needs your permission"}) =>
          "waiting_you: pane %5 is waiting for an answer: Claude needs your permission",
        reason("waiting_you", {"kind" => "ask", "ask" => "a1", "question" => "Postgres or sqlite?"}) =>
          "waiting_you: open question a1: Postgres or sqlite?",
        reason("waiting_you", {"kind" => "dispatch", "step" => "plan", "error" => "pane_busy", "message" => "pane %5 did not go quiet"}) =>
          "waiting_you: step plan could not be started (pane_busy): pane %5 did not go quiet",
        reason("waiting_you", {"kind" => "delivery", "step" => "plan", "attempt" => 1, "pane" => "%5"}) =>
          "waiting_you: step plan's line was on its way to pane %5 when the process typing it stopped; the agent may not have it",
        reason("turn_ended_incomplete", {"missing" => ["/a/plan.md", "/a/risks.md"]}) =>
          "turn_ended_incomplete: the turn ended without /a/plan.md, /a/risks.md",
        reason("turn_ended_incomplete", {"missing" => [], "stale" => ["/a/plan.md"]}) =>
          "turn_ended_incomplete: the turn ended with /a/plan.md left by an earlier attempt and not written again",
        reason("failed_check", {"step" => "verify", "cause" => "check", "exit_code" => 1, "log" => "/a/verify.1.check.log"}) =>
          "failed_check: step verify's check exited 1; log: /a/verify.1.check.log",
        reason("failed_check", {"step" => "verify", "cause" => "check", "timed_out" => true, "log" => "/a/v.log"}) =>
          "failed_check: step verify's check ran past its time limit; log: /a/v.log",
        reason("failed_check", {"step" => "verify", "cause" => "reported", "summary" => "two specs red"}) =>
          "failed_check: step verify was reported failed: two specs red",
        reason("pane_gone", {"pane" => "%5", "workspace" => "app"}) => "pane_gone: pane %5 of app is not running"
      }
      texts.each do |each_reason, text|
        output.truncate(0)
        output.rewind
        allow(status).to receive(:runs).and_return("runs" => [shown("current" => shown["current"].merge("reason" => each_reason))], "warnings" => [])

        command.status

        expect(output.string.lines[1]).to eq("  #{text}\n")
      end
    end

    it "prints a finished run without a step" do
      allow(status).to receive(:run).with("wr_1").and_return("runs" => [shown("state" => "completed")], "warnings" => [])

      command.status(run: "wr_1")

      expect(output.string).to eq("wr_1  flow  app  completed\n")
    end

    it "says when no run is going, in a workspace or at all" do
      allow(status).to receive(:runs).and_return("runs" => [], "warnings" => [])

      command.status(workspace: "app")
      command.status(all: true)

      expect(output.string).to eq("No workflow runs in app still going.\nNo workflow runs.\n")
    end

    it "prints one document with the time it was made" do
      allow(status).to receive(:runs).with(workspace: nil, all: true).and_return("runs" => [gate], "warnings" => [])

      command.status(all: true, json: true)

      expect(json).to eq("schema_version" => 1, "ok" => true, "generated_at" => "2026-10-04T13:00:00Z", "runs" => [gate], "warnings" => [])
    end
  end

  describe "moving a run" do
    let(:stored) do
      {"id" => "wr_1", "workspace" => "app", "state" => "running", "current" => "plan", "pane" => "%5", "reason" => nil,
       "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1}]}}}
    end

    before do
      allow(status).to receive(:run).with("wr_1").and_return("runs" => [shown], "warnings" => [])
      allow(store).to receive(:find).with("wr_1") { stored }
      allow(panes).to receive_messages(alive?: true, pane_of: "%5", idle?: false)
      allow(engine).to receive(:refuse_resume)
      allow(engine).to receive(:resume).and_return("id" => "wr_1", "workspace" => "app")
    end

    it "resumes a run whose pane is still there, in that pane" do
      row = command.resume(run: "wr_1", from: "plan", note: "Again.")

      expect(engine).to have_received(:resume).with("wr_1", from: "plan", note: "Again.", pane: nil, turn_over: nil)
      expect(row).to include("outcome" => "resumed", "message" => nil, "run" => shown)
    end

    it "moves a run whose pane is gone to the workspace's Claude pane, or to the pane the caller names" do
      allow(panes).to receive(:alive?).with("wr_1").and_return(false)
      allow(panes).to receive(:default_pane).with("app").and_return("%9")
      allow(panes).to receive(:locate).with("app", "0.2").and_return("%8")

      command.resume(run: "wr_1")
      command.resume(run: "wr_1", pane: "0.2")

      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: "%9", turn_over: nil).ordered
      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: "%8", turn_over: nil).ordered
    end

    it "moves a run whose step could not be started because its pane was gone" do
      stored.merge!("state" => "waiting", "reason" => {"code" => "pane_gone", "details" => {"kind" => "dispatch"}})
      stored["steps"]["plan"]["state"] = "waiting"
      allow(panes).to receive(:default_pane).with("app").and_return("%9")

      command.resume(run: "wr_1")

      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: "%9", turn_over: nil)
    end

    it "keeps a run that was never bound (it waits for its first lock) in the pane it was started in, and starts no daemon" do
      stored.merge!("state" => "waiting", "pane" => "%7", "reason" => {"code" => "waiting_lock", "details" => {}})
      stored["steps"]["plan"] = {"state" => "waiting", "attempts" => []}
      allow(panes).to receive_messages(pane_of: nil, alive?: false)
      allow(panes).to receive(:default_pane)

      command.resume(run: "wr_1")

      expect(panes).not_to have_received(:default_pane)
      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: nil, turn_over: nil)
    end

    it "refuses what the engine would refuse before it looks for a pane or starts a daemon" do
      allow(panes).to receive(:alive?).with("wr_1").and_return(false)
      allow(panes).to receive(:default_pane)
      allow(panes).to receive(:locate)
      allow(engine).to receive(:refuse_resume).with(stored, from: "deploy").and_raise(Workspace::UsageError, "No step \"deploy\"")

      expect { command.resume(run: "wr_1", from: "deploy", pane: "0.2") }.to raise_error(Workspace::UsageError)

      expect(panes).not_to have_received(:default_pane)
      expect(panes).not_to have_received(:locate)
      expect(engine).not_to have_received(:resume)
    end

    it "has the engine decide a step that reads running when the daemon says its pane's agent is idle" do
      allow(panes).to receive(:idle?).with("app", "%5").and_return(true)

      command.resume(run: "wr_1")

      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: nil, turn_over: {"step" => "plan", "attempt" => 1})
    end

    it "asks about the pane the run is bound to now, wherever `restore` moved it, and the pane it was started in when it is bound to none" do
      allow(panes).to receive(:pane_of).with("wr_1").and_return("%7")
      command.resume(run: "wr_1")
      expect(panes).to have_received(:idle?).with("app", "%7")

      allow(panes).to receive(:pane_of).with("wr_1").and_return(nil)
      command.resume(run: "wr_1")
      expect(panes).to have_received(:idle?).with("app", "%5")
    end

    it "does not ask whether the pane is idle for a step with a reason, a named step, or a step that is not running" do
      allow(panes).to receive(:idle?).and_return(true)

      command.resume(run: "wr_1", from: "plan")
      stored["reason"] = {"code" => "turn_ended_incomplete", "details" => {}}
      command.resume(run: "wr_1")
      stored["reason"] = nil
      stored["steps"]["plan"]["state"] = "checking"
      command.resume(run: "wr_1")

      expect(panes).not_to have_received(:idle?)
      expect(engine).to have_received(:resume).with("wr_1", hash_including(turn_over: nil)).exactly(3).times
    end

    it "says nothing was done, and why, when an agent is working on the step" do
      allow(engine).to receive(:resume).and_return("id" => "wr_1", "workspace" => "app", "unchanged" => "an agent is working on step plan")

      row = command.resume(run: "wr_1")

      # The daemon was asked about the run's pane, said its agent is working, and the engine was not told the turn is over.
      expect(panes).to have_received(:idle?).with("app", "%5")
      expect(engine).to have_received(:resume).with("wr_1", from: nil, note: nil, pane: nil, turn_over: nil)
      expect(row).to include("outcome" => "unchanged", "reason" => nil, "message" => "Nothing was done: an agent is working on step plan.")
      expect(output.string.lines.last).to eq("Nothing was done: an agent is working on step plan.\n")
    end

    it "leaves a finished run to the engine, which refuses it, and looks nothing up for it" do
      stored["state"] = "completed"
      allow(panes).to receive(:alive?).with("wr_1").and_return(false)
      allow(panes).to receive(:default_pane)
      allow(engine).to receive(:resume).and_raise(Workspace::Error.new("finished", code: "run_not_active"))

      expect { command.resume(run: "wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_not_active") }
      expect(panes).not_to have_received(:default_pane)
      expect(engine).not_to have_received(:refuse_resume)
    end

    # The engine runs the guard under the run's lock, after its own step checks; this one does the same.
    def guarded(verb)
      allow(engine).to receive(verb) do |_id, guard:, **|
        guard.call(stored)
        {"id" => "wr_1", "workspace" => "app"}
      end
    end

    def process(pid, ppid)
      {pid: pid, ppid: ppid, lstart: "start-#{pid}", command: "proc"}
    end

    # This process (4242) under a shell (300) under the pane's own shell (200) when +under+; else under 999.
    def tree(under: true)
      ancestors = under ? [process(300, 200), process(200, 1)] : [process(999, 1)]
      snapshot = instance_double(Workspace::ProcessTree::Snapshot)
      allow(snapshot).to receive(:ancestors).with(4242).and_return(ancestors)
      allow(process_tree).to receive(:snapshot).and_return(snapshot)
    end

    before do
      allow(panes).to receive(:run_on).and_return(nil)
      allow(tmux).to receive(:pane_details).with("app", window: nil).and_return([{id: "%5", window: 0, index: 1, pid: 200}, {id: "%6", window: 0, index: 2, pid: 210}])
      tree(under: false)
    end

    it "cancels and rejects, handing the engine the step and attempt the caller saw" do
      allow(engine).to receive(:cancel).with("wr_1").and_return("id" => "wr_1", "workspace" => "app")
      allow(engine).to receive(:reject).with("wr_1", note: "Too big.", to: "plan", step: "plan", attempt: 2, guard: kind_of(Proc))
        .and_return("id" => "wr_1", "workspace" => "app")

      expect(command.cancel(run: "wr_1")).to include("outcome" => "cancelled")
      expect(command.reject(run: "wr_1", note: "Too big.", to: "plan", step: "plan", attempt: 2)).to include("outcome" => "rejected")
    end

    it "approves a gate from a terminal, or from a pane bound to nothing, handing the engine what the caller saw" do
      guarded(:approve)

      expect(command.approve(run: "wr_1", note: "Go.")).to include("outcome" => "approved")
      expect(command.approve(run: "wr_1", note: "Go.", step: "plan", attempt: 1, note_sha256: "a" * 64, caller_pane: "%3")).to include("outcome" => "approved")
      expect(engine).to have_received(:approve).with("wr_1", note: "Go.", step: "plan", attempt: 1, note_sha256: "a" * 64, guard: kind_of(Proc))
    end

    it "refuses to approve or reject from a pane a run is bound to, so an agent doesn't pass its own gate" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      guarded(:approve)
      guarded(:reject)

      expect { command.approve(run: "wr_1", caller_pane: "%5") }
        .to raise_error(Workspace::Error, /A gate is passed by a person: this pane \(%5\) is bound to workflow run wr_1, so `workflow approve` is refused here/) { |error|
          expect(error.code).to eq("bound_pane")
          expect(error.details).to eq("pane" => "%5", "run_id" => "wr_1")
        }
      expect { command.reject(run: "wr_1", note: "No.", caller_pane: "%5") }
        .to raise_error(Workspace::Error, /so `workflow reject` is refused here/) { |error| expect(error.code).to eq("bound_pane") }
    end

    it "refuses approve and reject from a process under the run's pane, with TMUX_PANE unset or another pane's, naming the agent" do
      tree(under: true)
      allow(lock_holder).to receive(:current).and_return(kind: "agent", pid: 300, started: "start-300", pane: nil, worktree: "/src/app")
      guarded(:approve)
      guarded(:reject)

      [-> { command.approve(run: "wr_1") }, -> { command.approve(run: "wr_1", caller_pane: "%6") },
        -> { command.reject(run: "wr_1", note: "No.") }].each do |call|
        expect(&call).to raise_error(Workspace::Error, /this process runs under pane %5, which workflow run wr_1 is bound to/) { |error|
          expect(error.code).to eq("bound_pane")
          expect(error.details).to eq("pane" => "%5", "run_id" => "wr_1", "agent" => {"pid" => 300, "started" => "start-300"})
        }
      end
    end

    it "checks the pane the run is bound to now, else the one it was started in" do
      allow(panes).to receive(:pane_of).with("wr_1").and_return("%6")
      tree(under: true)
      guarded(:approve)

      # The run moved to %6 (pid 210); this process is under %5's shell, not %6's.
      expect(command.approve(run: "wr_1")).to include("outcome" => "approved")

      allow(panes).to receive(:pane_of).with("wr_1").and_return(nil)
      allow(lock_holder).to receive(:current).and_return(nil)
      expect { command.approve(run: "wr_1") }.to raise_error(Workspace::Error) { |error|
        expect(error.details).to eq("pane" => "%5", "run_id" => "wr_1", "agent" => nil)
      }
    end

    it "runs only the TMUX_PANE check when tmux or the process table can't be read" do
      guarded(:approve)
      allow(tmux).to receive(:pane_details).and_return([])
      expect(command.approve(run: "wr_1")).to include("outcome" => "approved")

      allow(tmux).to receive(:pane_details).and_raise(Errno::ENOENT)
      expect(command.approve(run: "wr_1")).to include("outcome" => "approved")

      allow(tmux).to receive(:pane_details).and_return([{id: "%5", window: 0, index: 1, pid: 200}])
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")
      expect(command.approve(run: "wr_1")).to include("outcome" => "approved")

      allow(process_tree).to receive(:snapshot).and_raise(Errno::ENOENT, "ps")
      expect(command.approve(run: "wr_1")).to include("outcome" => "approved")
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      expect { command.approve(run: "wr_1", caller_pane: "%5") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("bound_pane") }
    end

    it "refuses `resume --from` at a waiting gate from a pane a run is bound to, and allows it elsewhere" do
      stored["state"] = "waiting"
      stored["steps"]["plan"] = {"state" => "passed", "attempts" => [{"n" => 1}], "gate" => {"state" => "waiting"}}
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      allow(panes).to receive(:run_on).with("%3").and_return(nil)

      expect { command.resume(run: "wr_1", from: "verify", caller_pane: "%5") }
        .to raise_error(Workspace::Error, /so `workflow resume --from` is refused here/) { |error| expect(error.code).to eq("bound_pane") }
      expect(engine).not_to have_received(:resume)

      command.resume(run: "wr_1", from: "verify", caller_pane: "%3")
      command.resume(run: "wr_1", from: "verify")
      expect(engine).to have_received(:resume).twice
    end

    it "lets the run's own pane resume from a step when the run is not at a gate" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")

      command.resume(run: "wr_1", from: "plan", caller_pane: "%5")

      expect(engine).to have_received(:resume)
    end
  end

  describe "#advance" do
    it "tells the engine a turn ended in a pane, or takes the timer's look" do
      allow(engine).to receive(:turn_ended)
      allow(engine).to receive(:tick)

      command.advance(run: "wr_1", turn_ended: true, pane: "%5")
      command.advance(run: "wr_1", turn_ended: true, pane: "%5", turn_started: Time.utc(2026, 10, 4, 12))
      command.advance(run: "wr_1")

      expect(engine).to have_received(:turn_ended).with("wr_1", pane: "%5", turn_started: nil)
      expect(engine).to have_received(:turn_ended).with("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 12))
      expect(engine).to have_received(:tick).with("wr_1")
      expect(output.string).to eq("")
    end
  end

  describe "#step_done" do
    it "records the report for the run this pane is bound to and tells the agent to end its turn" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      allow(engine).to receive(:report).with("wr_1", status: "fail", summary: "Two specs red.")
        .and_return("run_id" => "wr_1", "step" => "verify", "attempt" => 2,
          "reported" => {"status" => "fail", "summary" => "Two specs red.", "at" => "2026-10-04T12:00:00Z"})
      allow(store).to receive(:find).with("wr_1").and_return("workspace" => "app")

      row = command.step_done(pane: "%5", status: "fail", summary: "Two specs red.")

      expect(row).to eq("workspace" => "app", "outcome" => "recorded", "reason" => nil, "message" => nil, "run_id" => "wr_1", "step" => "verify",
        "attempt" => 2, "reported" => {"status" => "fail", "summary" => "Two specs red."})
      expect(output.string).to eq("Recorded fail for step verify (attempt 2) of run wr_1. End your turn now; the step is decided when the turn ends.\n")
    end

    it "refuses a status other than pass or fail" do
      expect { command.step_done(pane: "%5", status: "done") }.to raise_error(Workspace::UsageError, '--status must be pass or fail, got "done".')
    end

    it "refuses outside a run's pane, and outside tmux" do
      allow(panes).to receive(:run_on).with("%5").and_return(nil)

      expect { command.step_done(pane: "%5") }.to raise_error(Workspace::Error, "This pane is not bound to a workflow run.") { |error|
        expect(error.code).to eq("not_bound")
      }
      expect { command.step_done(pane: nil) }.to raise_error(Workspace::Error, "This pane is not bound to a workflow run (not inside tmux).")
      expect { command.step_status(pane: "") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("not_bound") }
    end
  end

  describe "#step_status" do
    around do |example|
      Dir.mktmpdir("wf-step") do |dir|
        @dir = dir
        example.run
      end
    end

    let(:run) do
      {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "current" => "plan", "artifacts_dir" => @dir,
       "definition" => definition.to_h,
       "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00Z",
                                                                    "prompt_file" => "#{@dir}/steps/plan.1.prompt.md",
                                                                    "reported" => {"status" => "pass", "summary" => "Plan written.", "at" => "2026-10-04T12:10:00Z"}}]}}}
    end

    before do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      allow(store).to receive(:find).with("wr_1").and_return(run)
    end

    it "prints the step this pane is on, and whether the files it must leave exist" do
      command.step_status(pane: "%5")

      expect(output.string).to eq(<<~TEXT)
        Step plan (attempt 1, running) of workflow run wr_1 (flow) in app.
        Instructions: #{@dir}/steps/plan.1.prompt.md
        Must be written by the time your turn ends: #{@dir}/plan.md (missing)
        Reported: pass (Plan written.)
      TEXT
    end

    it "prints it as one document, the report as `step done` gives it" do
      File.write(File.join(@dir, "plan.md"), "plan\n")
      File.utime(Time.utc(2026, 10, 4, 12, 5), Time.utc(2026, 10, 4, 12, 5), File.join(@dir, "plan.md"))

      command.step_status(pane: "%5", json: true)

      expect(json).to eq("schema_version" => 1, "ok" => true, "step" => {
        "run_id" => "wr_1", "workflow" => "flow", "workspace" => "app", "step" => "plan", "attempt" => 1, "state" => "running",
        "instructions" => "#{@dir}/steps/plan.1.prompt.md", "artifacts_dir" => @dir,
        "produces" => [{"path" => "#{@dir}/plan.md", "exists" => true, "current" => true}], "check" => false,
        "reported" => {"status" => "pass", "summary" => "Plan written."}
      })
    end

    it "says a file an earlier attempt left has to be written again" do
      File.write(File.join(@dir, "plan.md"), "plan\n")
      File.utime(Time.utc(2026, 10, 4, 11, 0), Time.utc(2026, 10, 4, 11, 0), File.join(@dir, "plan.md"))

      command.step_status(pane: "%5")

      expect(output.string).to include("Must be written by the time your turn ends: #{@dir}/plan.md (left by an earlier attempt; write it again)\n")
      output.truncate(0)
      output.rewind
      command.step_status(pane: "%5", json: true)
      expect(json["step"]["produces"]).to eq([{"path" => "#{@dir}/plan.md", "exists" => true, "current" => false}])
    end

    it "says a check will run for a step that has one" do
      run["current"] = "verify"
      run["steps"]["verify"] = {"state" => "running", "attempts" => [{"n" => 1}]}

      command.step_status(pane: "%5")

      expect(output.string).to eq("Step verify (attempt 1, running) of workflow run wr_1 (flow) in app.\nWhen your turn ends, the runner runs the step's check.\n")
    end
  end

  describe "#show with source" do
    let(:error_output) { StringIO.new }
    let(:global_dir) { File.join(dir, "global") }
    let(:builtin_dir) { File.join(dir, "builtin") }
    let(:dir) { Dir.mktmpdir }
    let(:real_catalog) do
      Workspace::WorkflowCatalog.new(config: instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir))
    end
    let(:valid) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }
    subject(:command) do
      described_class.new(catalog: real_catalog, engine: engine, status: status, store: store, panes: panes, files: nil, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, error_output: error_output)
    end

    before { FileUtils.mkdir_p([global_dir, builtin_dir]) }

    after { FileUtils.remove_entry(dir) }

    it "answers a global file's bytes with their sha256, and the definition's fields" do
      File.write(File.join(global_dir, "flow.yml"), valid)

      command.show(id: "flow", json: true, source: true)

      expect(json["workflow"]).to include("id" => "flow", "source" => "global", "path" => File.join(global_dir, "flow.yml"), "text" => valid,
        "sha256" => Digest::SHA256.hexdigest(valid), "problems" => [], "title" => "Flow")
      expect(json["workflow"]["steps"].map { |step| step["id"] }).to eq(["plan"])
    end

    it "works the same for a preset" do
      File.write(File.join(builtin_dir, "rpiv.yml"), valid)

      command.show(id: "rpiv", json: true, source: true)

      expect(json["workflow"]).to include("id" => "rpiv", "source" => "builtin", "text" => valid, "sha256" => Digest::SHA256.hexdigest(valid), "problems" => [])
    end

    it "answers an invalid global file: its text, the raw-byte sha and every problem, with no definition fields" do
      bad = "title: Flow\nbogus: 1\nmax_attempts: 0\nsteps:\n  plan:\n    nope: 1\n"
      File.write(File.join(global_dir, "bad.yml"), bad)

      command.show(id: "bad", json: true, source: true)

      expect(json["ok"]).to eq(true)
      expect(json["workflow"]).to include("text" => bad, "sha256" => Digest::SHA256.hexdigest(bad))
      expect(json["workflow"]["problems"].size).to be >= 3
      expect(json["workflow"]).not_to have_key("steps")
      expect { command.show(id: "bad") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
    end

    it "gives text null for bytes that are not UTF-8, with the sha of the raw bytes" do
      bytes = (+"title: \xFF\xFE").b
      File.binwrite(File.join(global_dir, "bin.yml"), bytes)

      command.show(id: "bin", json: true, source: true)

      expect(json["workflow"]).to include("text" => nil, "sha256" => Digest::SHA256.hexdigest(bytes))
      expect(json["workflow"]["problems"]).not_to be_empty
    end

    it "prints the text alone for a person, and the problems to stderr" do
      File.write(File.join(global_dir, "bad.yml"), "steps: 1\n")

      command.show(id: "bad", source: true)

      expect(output.string).to eq("steps: 1\n")
      expect(error_output.string).to start_with("bad: ")
    end

    it "raises unknown_workflow for an id with no file" do
      expect { command.show(id: "nope", source: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workflow") }
    end
  end

  describe "#files" do
    around do |example|
      Dir.mktmpdir("wf-files") do |dir|
        @root = File.realpath(dir)
        @runs = File.join(@root, "runs")
        example.run
      end
    end

    let(:real_store) do
      Workspace::WorkflowRunStore.new(dir: @runs, archive_dir: File.join(@root, "archive"), id_generator: -> { "wr_2610250930abcd" })
    end
    let(:files_command) do
      described_class.new(catalog: catalog, engine: engine, status: status, store: real_store, panes: panes, files: nil, run_files: Workspace::WorkflowRunFiles.new, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output)
    end
    let(:artifacts) { File.join(@root, "app", ".workflow", "wr_2610250930abcd") }

    # The run the docs' example (docs/README.workflow.md, "workflow files --json") shows.
    def fixture_run
      FileUtils.mkdir_p(File.join(artifacts, "steps"))
      File.write(File.join(artifacts, "steps", "research.1.prompt.md"), "prompt text\n")
      File.write(File.join(artifacts, "steps", "research.1.check.log"), "ok\n")
      File.write(File.join(artifacts, "research.md"), "# Research\n")
      File.write(File.join(@root, "big.bin"), "x" * 5000)
      File.symlink(File.join(@root, "big.bin"), File.join(artifacts, "notes.md"))
      real_store.create("workflow" => "rpiv", "workspace" => "app", "worktree" => File.join(@root, "app"), "state" => "running", "current" => "research",
        "artifacts_dir" => artifacts,
        "steps" => {"research" => {"state" => "running", "attempts" => [{"n" => 1, "prompt_file" => File.join(artifacts, "steps", "research.1.prompt.md"), "check" => {"log" => File.join(artifacts, "steps", "research.1.check.log")}}]}},
        "definition" => {"steps" => [{"id" => "research", "produces" => ["research.md", "plan.md", "notes.md", "../../../outside.md"]}]})
    end

    it "prints the documented JSON for the fixture run" do
      fixture_run

      files_command.files(run: "wr_2610250930abcd", json: true)

      shown = JSON.parse(output.string.gsub(File.join(@root, "app"), "/work/app"))
      expect(shown["files"].map { |row| row["kind"] }).to eq(%w[prompt check_log produces produces produces])
      docs = File.read(File.expand_path("../../../docs/README.workflow.md", __dir__))
      example = docs[/<!-- workflow-files-example -->\n```json\n(.*?)\n```/m, 1]
      expect(JSON.parse(example)).to eq(shown)
    end

    it "prints one line per file" do
      fixture_run

      files_command.files(run: "wr_2610250930abcd")

      expect(output.string.gsub(@root, "").lines.map(&:chomp)).to eq([
        "prompt     research  attempt 1  12 bytes  /app/.workflow/wr_2610250930abcd/steps/research.1.prompt.md",
        "check_log  research  attempt 1  3 bytes  /app/.workflow/wr_2610250930abcd/steps/research.1.check.log",
        "produces   research  -  11 bytes  /app/.workflow/wr_2610250930abcd/research.md",
        "produces   research  -  missing  /app/.workflow/wr_2610250930abcd/plan.md",
        "produces   research  -  link  /app/.workflow/wr_2610250930abcd/notes.md"
      ])
    end

    it "says so when a run records no files" do
      real_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "research", "worktree" => File.join(@root, "app"), "definition" => {"steps" => [{"id" => "research", "produces" => []}]}, "steps" => {"research" => {"attempts" => []}})

      files_command.files(run: "wr_2610250930abcd")

      expect(output.string).to eq("No files recorded for wr_2610250930abcd.\n")
    end

    it "uses the default artifacts directory for a run without one" do
      FileUtils.mkdir_p(artifacts)
      File.write(File.join(artifacts, "research.md"), "# Research\n")
      real_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "research", "worktree" => File.join(@root, "app"), "steps" => {"research" => {"attempts" => []}}, "definition" => {"steps" => [{"id" => "research", "produces" => ["research.md"]}]})

      files_command.files(run: "wr_2610250930abcd", json: true)

      expect(json).to include("artifacts_dir" => artifacts, "files" => [include("exists" => true, "bytes" => 11)])
    end

    it "answers a null artifacts_dir and no files for a run with neither artifacts_dir nor worktree" do
      real_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "research", "steps" => {"research" => {"attempts" => []}}, "definition" => {"steps" => [{"id" => "research", "produces" => ["research.md"]}]})

      files_command.files(run: "wr_2610250930abcd", json: true)

      expect(json).to include("artifacts_dir" => nil, "files" => [])
    end

    it "refuses an unknown run with unknown_run" do
      expect { files_command.files(run: "wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
    end
  end

  describe "#events" do
    around do |example|
      Dir.mktmpdir("wf-events") do |dir|
        @runs = File.join(dir, "runs")
        example.run
      end
    end

    let(:real_store) do
      Workspace::WorkflowRunStore.new(dir: @runs, archive_dir: File.join(File.dirname(@runs), "archive"),
        clock: -> { Time.utc(2026, 10, 25, 9, 30, 0) }, id_generator: -> { "wr_2610250930abcd" })
    end
    let(:events_command) do
      described_class.new(catalog: catalog, engine: engine, status: status, store: real_store, panes: panes, files: nil, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output)
    end

    # The run the docs' example (docs/README.workflow.md, "workflow events --json") shows.
    def fixture_run
      real_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "research", "steps" => {"research" => {"state" => "running", "attempts" => []}}, "definition" => {"steps" => [{"id" => "research"}]})
      real_store.record_event("wr_2610250930abcd", "run_started", "workflow" => "rpiv")
      real_store.record_event("wr_2610250930abcd", "step_dispatched", "step" => "research", "attempt" => 1)
      File.open(real_store.events_path("wr_2610250930abcd"), "a") { |file| file.write("not an object\n") }
      real_store.record_event("wr_2610250930abcd", "step_done", "step" => "research", "attempt" => 1, "status" => "pass")
    end

    it "prints the documented JSON for the fixture run" do
      fixture_run

      events_command.events(run: "wr_2610250930abcd", since: 1, json: true)

      expect(json).to eq(
        "schema_version" => 1, "ok" => true, "run" => "wr_2610250930abcd",
        "events" => [
          {"n" => 2, "ts" => "2026-10-25T09:30:00Z", "type" => "step_dispatched", "step" => "research", "attempt" => 1},
          {"n" => 4, "ts" => "2026-10-25T09:30:00Z", "type" => "step_done", "step" => "research", "attempt" => 1, "status" => "pass"}
        ],
        "truncated" => false, "next_since" => 4,
        "warnings" => ["Line 3 of the history is not a JSON object; skipped."]
      )
      docs = File.read(File.expand_path("../../../docs/README.workflow.md", __dir__))
      example = docs[/<!-- workflow-events-example -->\n```json\n(.*?)\n```/m, 1]
      expect(JSON.parse(example)).to eq(json)
    end

    it "prints one line per event, then the warnings" do
      fixture_run

      events_command.events(run: "wr_2610250930abcd")

      expect(output.string.lines.map(&:chomp)).to eq([
        "   1  2026-10-25T09:30:00Z  run_started  workflow=rpiv",
        "   2  2026-10-25T09:30:00Z  step_dispatched  step=research  attempt=1",
        "   4  2026-10-25T09:30:00Z  step_done  step=research  attempt=1  status=pass",
        "Warning: Line 3 of the history is not a JSON object; skipped."
      ])
    end

    it "keeps a note with a line break on its event's one line" do
      real_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "plan", "steps" => {"plan" => {"state" => "running", "attempts" => []}}, "definition" => {"steps" => [{"id" => "plan"}]})
      real_store.record_event("wr_2610250930abcd", "gate_rejected", "step" => "plan", "to" => "plan", "note" => "Too big.\nSplit it.")

      events_command.events(run: "wr_2610250930abcd")

      expect(output.string).to eq(%(   1  2026-10-25T09:30:00Z  gate_rejected  step=plan  to=plan  note="Too big.\\nSplit it."\n))
    end

    it "says so when there is nothing after since, and how to continue when capped" do
      fixture_run
      events_command.events(run: "wr_2610250930abcd", since: 4)
      expect(output.string).to eq("No events after line 4 for wr_2610250930abcd.\n")

      allow(real_store).to receive(:events).and_return("events" => [{"n" => 1, "ts" => "t", "type" => "a"}], "truncated" => true, "next_since" => 1, "warnings" => [])
      output.truncate(0)
      events_command.events(run: "wr_2610250930abcd")
      expect(output.string).to end_with("More events follow: pass --since 1.\n")
    end

    it "refuses an unknown run with unknown_run" do
      expect { events_command.events(run: "wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
    end
  end

  describe "#validate" do
    let(:input) { StringIO.new }
    let(:dir) { Dir.mktmpdir }
    subject(:command) do
      described_class.new(catalog: catalog, engine: engine, status: status, store: store, panes: panes, files: nil, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: input)
    end

    after { FileUtils.remove_entry(dir) }

    def write(name, text)
      File.join(dir, name).tap { |path| File.write(path, text) }
    end

    let(:valid) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }

    it "answers the checked definition for a valid file, named for its file, and writes nothing" do
      path = write("flow.yml", valid)

      command.validate(path: path, json: true)

      expect(json).to include("ok" => true, "schema_version" => 1)
      expect(json["workflow"]).to include("id" => "flow", "source" => "file", "path" => path, "sha256" => Digest::SHA256.hexdigest(valid))
      expect(json["workflow"]["steps"].map { |step| step["id"] }).to eq(["plan"])
      expect(Dir.children(dir)).to eq(["flow.yml"])
    end

    it "reads stdin for -, checked as the placeholder id stdin" do
      input.string = valid

      command.validate(path: "-", json: true)

      expect(json["workflow"]).to include("id" => "stdin", "source" => "stdin", "path" => nil)
    end

    it "takes the id from a string id: key, and --id over both" do
      input.string = "id: ship\n#{valid}"
      command.validate(path: "-", json: true)
      expect(json["workflow"]["id"]).to eq("ship")

      output.truncate(0)
      output.rewind
      input.string = valid
      command.validate(path: "-", id: "other", json: true)
      expect(json["workflow"]["id"]).to eq("other")
    end

    it "prints a line for a person" do
      command.validate(path: write("flow.yml", valid))

      expect(output.string).to eq("flow: valid (1 steps)\n")
    end

    it "uses the placeholder when the file's name is not an id" do
      command.validate(path: write("Bad Name.yml", valid), json: true)

      expect(json["workflow"]["id"]).to eq("file")
    end

    it "fails an --id that differs from the file's id: key" do
      input.string = "id: ship\n#{valid}"

      expect { command.validate(path: "-", id: "other") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_workflow")
        expect(e.details["problems"]).to include(a_string_matching(/id must be "other"/))
      }
    end

    it "lists every problem at once" do
      input.string = "title: Flow\nbogus: 1\nmax_attempts: 0\nsteps:\n  plan:\n    nope: 1\n"

      expect { command.validate(path: "-") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_workflow")
        expect(e.details["problems"].size).to be >= 3
        expect(e.details["path"]).to be_nil
      }
    end

    it "fails text that is not YAML or not UTF-8 with the same code" do
      input.string = "a: [unclosed"
      expect { command.validate(path: "-") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }

      input.string = (+"title: \xFF\xFE").b
      expect { command.validate(path: "-") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_workflow")
        expect(e.details["problems"]).to include("the file is not valid UTF-8 text")
      }
    end

    it "reads a relative prompt_file beside the file, and from the current directory for stdin" do
      File.write(File.join(dir, "p.md"), "Do it.")
      text = "title: Flow\nsteps:\n  plan:\n    prompt_file: p.md\n"

      command.validate(path: write("flow.yml", text), json: true)
      expect(json["workflow"]["steps"].first["prompt"]).to eq("Do it.")

      input.string = text
      Dir.chdir(Dir.mktmpdir) { expect { command.validate(path: "-") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") } }
      input.string = text
      Dir.chdir(dir) { expect { command.validate(path: "-") }.not_to raise_error }
    end

    it "refuses a PATH that can't be read as a usage error" do
      expect { command.validate(path: File.join(dir, "nope.yml")) }.to raise_error(Workspace::UsageError, /Can't read .*nope\.yml: No such file or directory\z/)
    end
  end

  describe "#add" do
    let(:input) { StringIO.new }
    let(:dir) { Dir.mktmpdir }
    let(:global_dir) { File.join(dir, "home", ".config", "workspace", "workflows") }
    let(:builtin_dir) { File.join(dir, "lib", "workflows") }
    let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir) }
    let(:real_catalog) { Workspace::WorkflowCatalog.new(config: config) }
    let(:files) { Workspace::WorkflowFiles.new(config: config, catalog: real_catalog) }
    let(:valid) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }
    let(:target) { File.join(global_dir, "flow.yml") }
    subject(:command) do
      described_class.new(catalog: real_catalog, files: files, engine: engine, status: status, store: store, panes: panes, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: input)
    end

    after { FileUtils.remove_entry(dir) }

    def write(name, text)
      File.join(dir, name).tap { |path| File.write(path, text) }
    end

    def code_of
      yield
      nil
    rescue Workspace::Error => e
      e.code
    end

    it "checks a file and writes it as the user's ID.yml, answering added with its path and sha256" do
      row = command.add(id: "flow", path: write("draft.yml", valid))

      expect(row).to eq("workspace" => nil, "outcome" => "added", "reason" => nil, "message" => "Added workflow flow at #{target}.",
        "workflow" => "flow", "path" => target, "sha256" => Digest::SHA256.hexdigest(valid))
      expect(File.read(target)).to eq(valid)
      expect(real_catalog.find("flow").source).to eq("global")
    end

    it "reads stdin for -" do
      input.string = valid

      expect(command.add(id: "flow", path: "-")["outcome"]).to eq("added")
      expect(File.read(target)).to eq(valid)
    end

    it "writes nothing under dry_run" do
      row = command.add(id: "flow", path: write("draft.yml", valid), dry_run: true)

      expect(row).to include("outcome" => "dry_run", "path" => target, "sha256" => Digest::SHA256.hexdigest(valid))
      expect(File.exist?(target)).to be(false)
    end

    it "refuses workflow_exists over a user's file, also under dry_run, leaving its bytes" do
      FileUtils.mkdir_p(global_dir)
      File.write(target, "mine\n")
      path = write("draft.yml", valid)

      expect(code_of { command.add(id: "flow", path: path) }).to eq("workflow_exists")
      expect(code_of { command.add(id: "flow", path: path, dry_run: true) }).to eq("workflow_exists")
      expect(File.read(target)).to eq("mine\n")
    end

    it "writes nothing for text that doesn't pass, listing every problem" do
      path = write("draft.yml", "title: Flow\nbogus: 1\nsteps:\n  plan:\n    nope: 1\n")

      expect { command.add(id: "flow", path: path) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_workflow")
        expect(e.details["problems"].size).to be >= 2
      }
      expect(File.exist?(global_dir)).to be(false)
    end

    it "refuses an id: in the text that differs from ID as invalid_workflow" do
      path = write("draft.yml", "id: other\n#{valid}")

      expect(code_of { command.add(id: "flow", path: path) }).to eq("invalid_workflow")
      expect(File.exist?(global_dir)).to be(false)
    end

    it "refuses a bad ID before it reads the text or builds a path" do
      input.string = valid
      expect(File).not_to receive(:open)

      expect(code_of { command.add(id: "../flow", path: "-") }).to eq("invalid_workflow")
      expect(input.read).to eq(valid)
      expect(File.exist?(global_dir)).to be(false)
    end

    it "shadows a preset of the same id and leaves the preset's file alone" do
      FileUtils.mkdir_p(builtin_dir)
      preset = File.join(builtin_dir, "rpiv.yml")
      File.write(preset, "title: Preset\nsteps:\n  plan:\n    prompt: Preset.\n")
      before = File.binread(preset)

      row = command.add(id: "rpiv", path: write("draft.yml", valid))

      expect(row["message"]).to include("shadows the preset")
      expect(File.binread(preset)).to eq(before)
      expect(Dir.children(builtin_dir)).to eq(["rpiv.yml"])
      expect(real_catalog.find("rpiv").to_h["title"]).to eq("Flow")
    end

    it "reads a relative prompt_file: from the workflows directory, where the file will load" do
      FileUtils.mkdir_p(global_dir)
      File.write(File.join(global_dir, "plan.md"), "Plan it.")
      File.write(File.join(dir, "elsewhere.md"), "x")
      text = "title: Flow\nsteps:\n  plan:\n    prompt_file: plan.md\n"

      expect(command.add(id: "flow", path: write("draft.yml", text))["outcome"]).to eq("added")
      expect(code_of { command.add(id: "other", path: write("other.yml", text.sub("plan.md", "elsewhere.md"))) }).to eq("invalid_workflow")
    end
  end

  describe "#update" do
    let(:input) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:dir) { Dir.mktmpdir }
    let(:global_dir) { File.join(dir, "home", ".config", "workspace", "workflows") }
    let(:builtin_dir) { File.join(dir, "lib", "workflows") }
    let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir) }
    let(:real_catalog) { Workspace::WorkflowCatalog.new(config: config) }
    let(:files) { Workspace::WorkflowFiles.new(config: config, catalog: real_catalog) }
    let(:old_text) { "title: Old\nsteps:\n  plan:\n    prompt: Old.\n" }
    let(:valid) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }
    let(:target) { File.join(global_dir, "flow.yml") }
    subject(:command) do
      described_class.new(catalog: real_catalog, files: files, engine: engine, status: status, store: store, panes: panes, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: input, error_output: error_output)
    end

    before do
      FileUtils.mkdir_p([global_dir, builtin_dir])
      File.write(target, old_text)
    end

    after { FileUtils.remove_entry(dir) }

    def write(name, text)
      File.join(dir, name).tap { |path| File.write(path, text) }
    end

    def sha(text)
      Digest::SHA256.hexdigest(text.b)
    end

    def code_of
      yield
      nil
    rescue Workspace::Error => e
      e.code
    end

    it "replaces the file, answering updated with its path and the new sha256" do
      row = command.update(id: "flow", path: write("draft.yml", valid), if_sha256: sha(old_text))

      expect(row).to eq("workspace" => nil, "outcome" => "updated", "reason" => nil, "message" => "Updated workflow flow at #{target}.",
        "workflow" => "flow", "path" => target, "sha256" => sha(valid))
      expect(File.read(target)).to eq(valid)
    end

    it "reads stdin for -" do
      input.string = valid

      expect(command.update(id: "flow", path: "-", if_sha256: sha(old_text))["outcome"]).to eq("updated")
      expect(File.read(target)).to eq(valid)
    end

    it "writes nothing under dry_run" do
      row = command.update(id: "flow", path: write("draft.yml", valid), if_sha256: sha(old_text), dry_run: true)

      expect(row).to include("outcome" => "dry_run", "sha256" => sha(valid))
      expect(File.read(target)).to eq(old_text)
    end

    it "refuses stale_workflow for another sha, with the current sha256 in the details, and leaves the bytes" do
      before = File.binread(target)

      expect { command.update(id: "flow", path: write("draft.yml", valid), if_sha256: "f" * 64) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("stale_workflow")
        expect(e.details["sha256"]).to eq(sha(old_text))
      }
      expect(File.binread(target)).to eq(before)
    end

    it "writes nothing for text that doesn't pass, before it looks at the sha" do
      path = write("draft.yml", "title: Flow\nbogus: 1\nsteps:\n  plan:\n    nope: 1\n")

      expect(code_of { command.update(id: "flow", path: path, if_sha256: "f" * 64) }).to eq("invalid_workflow")
      expect(File.read(target)).to eq(old_text)
    end

    it "refuses an id: in the text that differs from ID" do
      expect(code_of { command.update(id: "flow", path: write("draft.yml", "id: other\n#{valid}"), if_sha256: sha(old_text)) }).to eq("invalid_workflow")
    end

    it "refuses builtin_workflow for a preset with no file of the user's, leaving the preset" do
      preset = File.join(builtin_dir, "rpiv.yml")
      File.write(preset, old_text)

      expect(code_of { command.update(id: "rpiv", path: write("draft.yml", valid), if_sha256: sha(old_text)) }).to eq("builtin_workflow")
      expect(File.binread(preset)).to eq(old_text)
      expect(Dir.children(global_dir)).not_to include("rpiv.yml")
    end

    it "refuses unknown_workflow when nothing has the id" do
      expect(code_of { command.update(id: "nope", path: write("draft.yml", valid), if_sha256: sha(old_text)) }).to eq("unknown_workflow")
    end

    it "refuses a bad ID before it reads the text" do
      input.string = valid

      expect(code_of { command.update(id: "../flow", path: "-", if_sha256: "f" * 64) }).to eq("invalid_workflow")
      expect(input.read).to eq(valid)
    end

    it "reads a relative prompt_file: from the workflows directory" do
      File.write(File.join(global_dir, "plan.md"), "Plan it.")
      text = "title: Flow\nsteps:\n  plan:\n    prompt_file: plan.md\n"

      expect(command.update(id: "flow", path: write("draft.yml", text), if_sha256: sha(old_text))["outcome"]).to eq("updated")
    end

    describe "replacing a file that does not pass the checks" do
      def broken_sha_from_show(id)
        output.truncate(0)
        output.rewind
        command.show(id: id, json: true, source: true)
        JSON.parse(output.string)["workflow"]["sha256"]
      end

      def broken_sha_from_list(id)
        output.truncate(0)
        output.rewind
        command.show(json: true)
        JSON.parse(output.string)["workflows"].find { |row| row["id"] == id }["sha256"]
      end

      {"invalid YAML structure" => "title: Flow\nbogus: 1\nmax_attempts: 0\nsteps:\n  plan:\n    nope: 1\n",
       "bytes that are not UTF-8" => (+"title: \xFF\xFE\nsteps: [").b}.each do |label, bytes|
        context "with #{label}" do
          before { File.binwrite(File.join(global_dir, "broken.yml"), bytes) }

          it "updates with the sha256 from show --source --json" do
            sha = broken_sha_from_show("broken")
            expect(sha).to eq(Digest::SHA256.hexdigest(bytes))

            row = command.update(id: "broken", path: write("fixed.yml", valid), if_sha256: sha)

            expect(row["outcome"]).to eq("updated")
            expect(File.binread(File.join(global_dir, "broken.yml"))).to eq(valid)
            expect(real_catalog.find("broken").to_h["title"]).to eq("Flow")
          end

          it "updates with the sha256 from the list" do
            row = command.update(id: "broken", path: write("fixed.yml", valid), if_sha256: broken_sha_from_list("broken"))

            expect(row["outcome"]).to eq("updated")
            expect(File.binread(File.join(global_dir, "broken.yml"))).to eq(valid)
          end
        end
      end
    end
  end

  describe "#remove" do
    let(:input) { StringIO.new }
    let(:dir) { Dir.mktmpdir }
    let(:global_dir) { File.join(dir, "home", ".config", "workspace", "workflows") }
    let(:builtin_dir) { File.join(dir, "lib", "workflows") }
    let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir) }
    let(:real_catalog) { Workspace::WorkflowCatalog.new(config: config) }
    let(:files) { Workspace::WorkflowFiles.new(config: config, catalog: real_catalog) }
    let(:target) { File.join(global_dir, "flow.yml") }
    let(:body) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }
    subject(:command) do
      described_class.new(catalog: real_catalog, files: files, engine: engine, status: status, store: store, panes: panes, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: input)
    end

    before do
      FileUtils.mkdir_p([global_dir, builtin_dir])
      File.write(target, body)
    end

    after { FileUtils.remove_entry(dir) }

    it "removes the file with yes, answering removed with its path, and asks nothing" do
      row = command.remove(id: "flow", yes: true)

      expect(row).to eq("workspace" => nil, "outcome" => "removed", "reason" => nil, "message" => "Removed workflow flow at #{target}.", "workflow" => "flow", "path" => target)
      expect(File.exist?(target)).to be(false)
      expect(output.string).not_to include("[y/N]")
    end

    it "answers dry_run with no yes and deletes nothing" do
      row = command.remove(id: "flow", dry_run: true)

      expect(row).to include("outcome" => "dry_run", "message" => "Would remove workflow flow at #{target}.")
      expect(File.read(target)).to eq(body)
    end

    it "says the preset is in effect again" do
      File.write(File.join(builtin_dir, "flow.yml"), body)
      row = command.remove(id: "flow", yes: true)
      expect(row["message"]).to eq("Removed workflow flow at #{target}; the preset of the same id is in effect again.")
    end

    it "prompts, and removes on y" do
      input.string = "y\n"
      expect(command.remove(id: "flow")).to include("outcome" => "removed")
      expect(output.string).to include("Remove workflow flow (#{target})? [y/N] ")
    end

    it "answers nothing on a declined prompt and keeps the file" do
      input.string = "n\n"
      expect(command.remove(id: "flow")).to be_nil
      expect(output.string).to include("Cancelled.")
      expect(File.exist?(target)).to be(true)
    end

    it "refuses with confirmation_required under no-input, before touching anything" do
      guarded = Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true)
      cmd = described_class.new(catalog: real_catalog, files: files, engine: engine, status: status, store: store, panes: panes, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: guarded)
      expect { cmd.remove(id: "flow") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
      expect(File.exist?(target)).to be(true)
      expect(File.exist?(File.join(global_dir, ".flow.yml.lock"))).to be(false)
    end

    it "refuses a bad id before prompting, and a missing file or a lone preset after yes" do
      expect { command.remove(id: "../x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
      expect(output.string).to eq("")
      expect { command.remove(id: "nope", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workflow") }
      File.write(File.join(builtin_dir, "rpiv.yml"), body)
      expect { command.remove(id: "rpiv", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("builtin_workflow") }
    end

    it "names an unknown id or a lone preset before any prompt, even under no-input" do
      File.write(File.join(builtin_dir, "rpiv.yml"), body)
      guarded = Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true)
      cmd = described_class.new(catalog: real_catalog, files: files, engine: engine, status: status, store: store, panes: panes, run_files: nil, tmux: tmux, process_tree: process_tree, lock_holder: lock_holder, output: output, input: guarded)
      expect { cmd.remove(id: "nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workflow") }
      expect { cmd.remove(id: "rpiv") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("builtin_workflow") }
      expect(output.string).to eq("")
    end

    it "removes a broken file" do
      File.write(target, "not: [valid")
      expect(command.remove(id: "flow", yes: true)).to include("outcome" => "removed")
    end
  end
end
