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
  subject(:command) do
    described_class.new(catalog: catalog, engine: engine, status: status, store: store, panes: panes,
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

    it "cancels and rejects" do
      allow(engine).to receive(:cancel).with("wr_1").and_return("id" => "wr_1", "workspace" => "app")
      allow(engine).to receive(:reject).with("wr_1", note: "Too big.", to: "plan").and_return("id" => "wr_1", "workspace" => "app")

      expect(command.cancel(run: "wr_1")).to include("outcome" => "cancelled")
      expect(command.reject(run: "wr_1", note: "Too big.", to: "plan")).to include("outcome" => "rejected")
    end

    it "approves a gate from a terminal, or from a pane bound to nothing" do
      allow(engine).to receive(:approve).with("wr_1", note: "Go.").and_return("id" => "wr_1", "workspace" => "app")
      allow(panes).to receive(:run_on).with("%3").and_return(nil)

      expect(command.approve(run: "wr_1", note: "Go.")).to include("outcome" => "approved")
      expect(command.approve(run: "wr_1", note: "Go.", caller_pane: "%3")).to include("outcome" => "approved")
    end

    it "refuses to approve from a pane a run is bound to, so an agent doesn't pass its own gate" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      allow(engine).to receive(:approve)

      expect { command.approve(run: "wr_1", caller_pane: "%5") }
        .to raise_error(Workspace::Error, /A gate is passed by a person: this pane \(%5\) is bound to workflow run wr_1, so `workflow approve` is refused here/) { |error|
          expect(error.code).to eq("bound_pane")
          expect(error.details).to eq("pane" => "%5", "run_id" => "wr_1")
        }
      expect(engine).not_to have_received(:approve)
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
end
