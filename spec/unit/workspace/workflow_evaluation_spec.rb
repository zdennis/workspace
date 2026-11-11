require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowEvaluation do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:dir) { Dir.mktmpdir("evaluation") }
  let(:artifacts) { File.join(dir, ".workflow", "wr_1") }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:progress) { RecordingProgress.new }
  let(:panes) { RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}) }
  let(:checker) { RecordingChecker.new }
  let(:require_check) { RecordingRequire.new }
  let(:guard) { RecordingGuard.new }
  let(:commands) { RecordingCommandsConfig.new(test: "rake test") }
  let(:inbox) { RecordingInbox.new }

  after { FileUtils.rm_rf(dir) }

  def evaluation(**overrides)
    described_class.new(change: change, store: store, progress: progress, panes: panes, checker: checker, require_check: require_check,
      guard: guard, commands_config: commands, inbox_for: ->(_workspace) { inbox }, clock: -> { now }, **overrides)
  end

  def step(**overrides)
    {"id" => "plan", "produces" => ["plan.md"]}.merge(overrides)
  end

  def run_hash(definition_step: step, state: "running", **overrides)
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => dir, "artifacts_dir" => artifacts,
     "state" => "running", "current" => "plan", "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => nil,
     "definition" => {"id" => "flow", "max_attempts" => 5, "steps" => [definition_step]},
     "steps" => {"plan" => {"state" => state, "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00.000Z"}]}}}.merge(overrides)
  end

  def stored(hash = run_hash)
    store.runs["wr_1"] = hash
  end

  def produce(name = "plan.md", at: now)
    FileUtils.mkdir_p(artifacts)
    path = File.join(artifacts, name)
    File.write(path, "done\n")
    File.utime(at, at, path)
    path
  end

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def ctx = Workspace::WorkflowRunChange::Context.new

  describe "#report" do
    it "stores the agent's report on the attempt and answers a Reported value" do
      stored

      reported = evaluation.report("wr_1", status: "fail", summary: "tests fail", code: "flaky")

      expect(reported).to be_a(described_class::Reported)
      expect(reported).to be_frozen
      expect(reported.to_h).to eq(run_id: "wr_1", step: "plan", attempt: 1,
        reported: {"status" => "fail", "summary" => "tests fail", "code" => "flaky", "at" => "2026-11-10T12:00:00Z"})
      expect(store.runs["wr_1"]["steps"]["plan"]["attempts"].last["reported"]).to eq(reported.reported)
      expect(change.events).to eq([["wr_1", "step_reported", {"step" => "plan", "attempt" => 1, "status" => "fail"}]])
    end

    it "leaves out a code the agent did not give" do
      stored

      expect(evaluation.report("wr_1", status: "pass").reported).to eq("status" => "pass", "summary" => nil, "at" => "2026-11-10T12:00:00Z")
    end

    it "refuses a step that is not being worked on" do
      stored(run_hash(state: "passed"))

      expect { evaluation.report("wr_1", status: "pass") }.to raise_error(Workspace::Error) { |error|
        expect(error.code).to eq("step_not_running")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "state" => "passed")
      }
      expect(change.events).to be_empty
    end
  end

  describe "#turn_ended" do
    it "decides nothing for a parked run, another pane, or a turn that began before the attempt" do
      stored(run_hash("parked" => {"id" => "p1"}))
      expect(evaluation.turn_ended("wr_1")).to be_a(Workspace::WorkflowRun)
      stored
      evaluation.turn_ended("wr_1", pane: "%9")
      evaluation.turn_ended("wr_1", turn_started: Time.utc(2026, 11, 10, 10))
      evaluation.turn_ended("wr_1", stopped_at: Time.utc(2026, 11, 10, 10))

      expect(store.runs["wr_1"]["reason"]).to be_nil
      expect(progress.calls).to be_empty
    end

    it "holds the step on turn_ended_incomplete when a file it produces is missing" do
      stored

      run = evaluation.turn_ended("wr_1", pane: "%3")

      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "turn_ended_incomplete", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "missing" => [File.join(artifacts, "plan.md")], "stale" => []})
      expect(run.step("plan").state).to eq("running")
    end

    it "counts a file an earlier attempt left as stale" do
      stored
      path = produce(at: Time.utc(2026, 11, 10, 10))

      expect(evaluation.turn_ended("wr_1").reason["details"]).to include("missing" => [], "stale" => [path])
    end

    it "holds a turn that ended with background tasks on turn_ended_background" do
      stored

      run = evaluation.turn_ended("wr_1", background: [{"id" => "b1", "type" => "bash"}])

      expect(run.reason).to include("code" => "turn_ended_background", "seen_at" => "2026-11-10T12:00:00Z")
      expect(run.reason["details"]["tasks"]).to eq([{"id" => "b1", "type" => "bash"}])
    end

    it "fails the step with the agent's word when it reported fail" do
      stored(run_hash.tap { |run| run["steps"]["plan"]["attempts"].last["reported"] = {"status" => "fail", "summary" => "no", "code" => "flaky"} })

      run = evaluation.turn_ended("wr_1")

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "reported", "summary" => "no", "code" => "flaky", "code_source" => "agent"}]])
      expect(run.step("plan").state).to eq("failed")
    end

    it "passes a step with its files and no status check" do
      stored
      produce

      run = evaluation.turn_ended("wr_1")

      expect(progress.calls).to eq([[:pass_step, "plan"]])
      expect(run.step("plan").state).to eq("passed")
      expect(checker.calls).to be_empty
    end

    it "runs the status check outside the lock and passes the step when it exits 0" do
      stored(run_hash(definition_step: step("status" => {"command" => "test", "timeout" => 60})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")

      run = evaluation.turn_ended("wr_1")

      expect(change.calls.size).to eq(2)
      expect(checker.calls).to eq([[:call, {command: "rake test", cwd: dir, timeout: 60, log: log, env: Workspace::WorkflowCheck.env_for(run)}]])
      expect(checker.stop_answers).to eq([false])
      expect(commands.calls).to eq([[:for_project, "app"]])
      expect(run.step("plan").last_attempt.check).to eq("started_at" => "2026-11-10T12:00:00Z", "log" => log, "command" => "rake test",
        "ended_at" => "2026-11-10T12:00:00Z", "exit_code" => 0, "timed_out" => false)
      expect(change.events).to eq([["wr_1", "check_finished", {"step" => "plan", "attempt" => 1, "exit_code" => 0}]])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "fails the step on a failed check, with the code its log names when the step lets it" do
      stored(run_hash(definition_step: step("status" => {"run" => "make check", "report_code" => true})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "lots of output\ncode: plan_edited\n\n")
      checker = RecordingChecker.new(result: {exit_code: 1, timed_out: false, error: nil})

      evaluation(checker: checker).turn_ended("wr_1")

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "check", "exit_code" => 1, "timed_out" => false, "log" => log,
                                                          "code" => "plan_edited", "code_source" => "check"}]])
    end

    it "keeps the engine's code when the log names one the engine hands out itself" do
      stored(run_hash(definition_step: step("status" => {"run" => "make check", "report_code" => true})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "code: check_timed_out\n")

      evaluation(checker: RecordingChecker.new(result: {exit_code: 2, timed_out: false, error: nil})).turn_ended("wr_1")

      expect(progress.calls.last[2]).to include("code" => "check_failed", "code_source" => "engine")
    end

    it "fails the step without running anything when the project's command is not set" do
      stored(run_hash(definition_step: step("status" => {"command" => "lint"})))
      produce

      evaluation(commands_config: RecordingCommandsConfig.new).turn_ended("wr_1")

      expect(checker.calls).to be_empty
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "check", "timed_out" => false, "error" => "the project's lint command is not set",
                                                          "log" => File.join(artifacts, "steps", "plan.1.check.log"), "code" => "check_error", "code_source" => "engine"}]])
    end
  end

  describe "#evaluate" do
    it "answers a new run and leaves the run given alone" do
      given = run_hash
      before = deep_copy(given)

      run = evaluation.evaluate(given, ctx: ctx)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(before)
      expect(run.reason["code"]).to eq("turn_ended_incomplete")
    end

    it "drops the attempt's delivery mark and old proofs" do
      given = run_hash.tap { |run| run["steps"]["plan"]["attempts"].last.merge!("delivery" => "delivering", "proofs" => [{"index" => 0}]) }

      attempt = evaluation.evaluate(given, ctx: ctx).step("plan").last_attempt

      expect(attempt.delivery).to be_nil
      expect(attempt.proofs).to be_nil
    end

    it "fails a guarded step the guard finds changed" do
      guard = RecordingGuard.new(found: {"code" => "head_moved", "base_sha" => "a" * 40, "head" => "b" * 40})

      evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "unchanged")), ctx: ctx)

      expect(guard.calls.map(&:first)).to eq(%i[check config_change])
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "guard", "guard" => "head_moved", "base_sha" => "a" * 40, "head" => "b" * 40,
                                                          "code" => "head_moved", "code_source" => "engine"}]])
    end

    it "fails as a check error when the guard can't run" do
      guard = RecordingGuard.new
      allow(guard).to receive(:check).and_raise(IOError)

      evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "unchanged")), ctx: ctx)

      expect(progress.calls.last[2]).to eq("cause" => "check", "error" => "the guard could not run (IOError)", "code" => "check_error", "code_source" => "engine")
    end

    it "warns of a changed config once on the attempt, in its history and the inbox, and goes on" do
      guard = RecordingGuard.new(config: {"code" => "config_changed", "reading" => "r2"})
      produce

      run = evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "config")).merge("guard_config_seen" => "r1"), ctx: ctx)

      expect(guard.calls.last).to eq([:config_change, dir, {seen: "r1"}])
      expect(run.guard_config_seen).to eq("r2")
      expect(run.step("plan").last_attempt.warnings).to eq([{"code" => "config_changed", "at" => "2026-11-10T12:00:00Z",
                                                             "message" => "the repository's config, attributes or replace refs changed; the run went on"}])
      expect(change.events).to eq([["wr_1", "guard_warning", {"step" => "plan", "attempt" => 1, "code" => "config_changed", "inbox" => true}]])
      record, options = inbox.calls.last[1..]
      expect(record).to include("dedupe_key" => "workflow-guard:wr_1:config_changed", "links" => {"run_id" => "wr_1", "step" => "plan", "attempt" => 1})
      expect(options).to eq(reopen: true)
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "clears the reading warned of once the config is back at the base" do
      guard = RecordingGuard.new(config: {"code" => nil})

      run = evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "config")).merge("guard_config_seen" => "r1"), ctx: ctx)

      expect(run.to_h).not_to have_key("guard_config_seen")
      expect(inbox.calls).to be_empty
    end

    it "fails the step on an unmet require proof" do
      produce
      require_check = RecordingRequire.new(checks: [{"proof" => "commits", "code" => "require_commits", "detail" => "no commit", "required" => 1, "found" => 0}])

      evaluation(require_check: require_check).evaluate(run_hash(definition_step: step("require" => [{"commits" => 1}])), ctx: ctx)

      expect(require_check.calls).to eq([[:check, "plan", 1, {from: 0}]])
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "require", "require" => "commits", "detail" => "no commit", "required" => 1, "found" => 0,
                                                          "code" => "require_commits", "code_source" => "engine"}]])
    end

    it "records a skipped proof as ended and checks on from the next entry" do
      produce
      require_check = RecordingRequire.new(checks: [{"skipped" => {"index" => 0, "proof" => "command", "skipped" => true}}, nil])

      run = evaluation(require_check: require_check).evaluate(run_hash(definition_step: step("require" => [{"command" => "lint"}, {"commits" => 1}])), ctx: ctx)

      expect(require_check.calls.map(&:last)).to eq([{from: 0}, {from: 1}])
      expect(run.step("plan").last_attempt.proofs).to eq([{"index" => 0, "proof" => "command", "skipped" => true,
                                                           "started_at" => "2026-11-10T12:00:00Z", "ended_at" => "2026-11-10T12:00:00Z"}])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "takes the step to checking for a proof that runs outside the lock, and registers it on the context" do
      produce
      pending = {"index" => 0, "proof" => "command", "token" => "t1", Workspace::WorkflowRequire::FACTS_KEY => {"head" => "abc"}}
      context = ctx

      run = evaluation(require_check: RecordingRequire.new(checks: [{"outside" => pending}])).evaluate(run_hash(definition_step: step("require" => [{"command" => "lint"}])), ctx: context)

      expect(run.step("plan").state).to eq("checking")
      expect(run.state).to eq("running")
      expect(run.step("plan").last_attempt.proofs).to eq([{"index" => 0, "proof" => "command", "token" => "t1", "started_at" => "2026-11-10T12:00:00Z"}])
      expect(context.check).to eq("step" => "plan", "attempt" => 1, "cwd" => dir, "proof" => pending)
      expect(progress.calls).to be_empty
    end
  end

  describe "#finish_check" do
    let(:pending) { {"index" => 0, "proof" => "command", "token" => "t1"} }
    let(:check) { {"step" => "plan", "attempt" => 1, "cwd" => dir, "proof" => pending} }

    def checking_run
      run_hash(definition_step: step("require" => [{"command" => "lint"}]), state: "checking").tap do |run|
        run["steps"]["plan"]["attempts"].last["proofs"] = [pending.merge("started_at" => "2026-11-10T11:30:00Z")]
      end
    end

    it "runs a proof, records its result, and goes on to the status check or the pass" do
      stored(checking_run)
      require_check = RecordingRequire.new(outside: {"record" => {"exit_code" => 0}, "unmet" => nil})

      run = evaluation(require_check: require_check).finish_check("wr_1", check)

      expect(require_check.calls).to eq([[:run_outside, pending, {cwd: dir}], [:check, "plan", 1, {from: 1}]])
      expect(run.step("plan").last_attempt.proofs.last).to include("token" => "t1", "exit_code" => 0, "ended_at" => "2026-11-10T12:00:00Z")
      expect(change.events).to eq([["wr_1", "proof_finished", {"step" => "plan", "attempt" => 1, "proof" => "command", "passed" => true}]])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "fails the step on a proof found unmet outside the lock" do
      stored(checking_run)
      unmet = {"proof" => "command", "code" => "require_command", "detail" => "lint failed", "exit_code" => 1}

      evaluation(require_check: RecordingRequire.new(outside: {"record" => {"exit_code" => 1}, "unmet" => unmet})).finish_check("wr_1", check)

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "require", "require" => "command", "detail" => "lint failed", "exit_code" => 1,
                                                          "code" => "require_command", "code_source" => "engine"}]])
    end

    it "drops a result the run moved on from" do
      stored(checking_run.merge("current" => "plan").tap { |run| run["steps"]["plan"]["state"] = "failed" })

      run = evaluation.finish_check("wr_1", check)

      expect(run.step("plan").state).to eq("failed")
      expect(change.events).to be_empty
      expect(progress.calls).to be_empty
    end

    it "answers the stored run when it was cancelled while the check ran" do
      stored(checking_run)
      change = RecordingRunChange.new(store.runs, finished: ["wr_1"])

      run = evaluation(change: change).finish_check("wr_1", check)

      expect(run).to eq(Workspace::WorkflowRun.from_h(checking_run))
      expect(store.calls.last).to eq([:run, "wr_1"])
    end

    it "tells the check to stop once the run no longer waits for it" do
      stored(checking_run.merge("state" => "cancelled").tap { |run| run["steps"]["plan"]["attempts"].last["check"] = {"started_at" => "2026-11-10T11:30:00Z", "log" => "/tmp/x.log"} })
      checker = RecordingChecker.new
      status_check = {"step" => "plan", "attempt" => 1, "command" => "rake", "timeout" => 5, "log" => "/tmp/x.log", "cwd" => dir, "role" => "test"}

      evaluation(checker: checker).finish_check("wr_1", status_check)

      expect(checker.stop_answers).to eq([true])
    end
  end
end
