require "spec_helper"
require "tmpdir"
require "rbconfig"

RSpec.describe Workspace::WorkflowAlerts do
  let(:sent) { [] }
  let(:argvs) { [] }
  let(:settings) { {notify: "notify-me", workflow: %w[gate failed stalled finished]} }
  let(:alert_config) { instance_double(Workspace::AlertConfig, for_workspace: settings) }
  let(:error_output) { StringIO.new }
  subject(:alerts) { described_class.new(alert_config: alert_config, spawner: ->(argv, env, _log) { argvs << argv && sent << env }, error_output: error_output) }

  def run(state: "running", gate: nil, reason: nil, stalled: nil, attempts: 1, step: "plan")
    {"id" => "wr_1", "workspace" => "app", "current" => step, "state" => state, "reason" => reason,
     "steps" => {step => {"attempts" => Array.new(attempts) { |i| {"n" => i + 1} }, "gate" => gate}.compact},
     "sweep" => stalled && {"step" => "plan", "attempt" => attempts, "stalled" => stalled}}.compact
  end

  it "reads marks from an old run with nothing in it without raising" do
    expect(alerts.marks({})).to eq(gate: nil, failed: nil, stalled: [], finished: false)
  end

  it "says nothing for a change that started no event, and never reads the settings" do
    expect(alert_config).not_to receive(:for_workspace)
    alerts.fire(alerts.marks(run), run)
    expect(sent).to eq([])
  end

  it "fires an event once for the change that started it" do
    before = alerts.marks(run)
    waiting = run(state: "waiting", gate: {"state" => "waiting"})
    alerts.fire(before, waiting)
    alerts.fire(alerts.marks(waiting), waiting)

    expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[gate])
  end

  it "treats a failed state and a failed_check reason of one attempt as one episode" do
    stuck = run(state: "waiting", reason: {"code" => "failed_check"})
    failed = run(state: "failed")
    alerts.fire(alerts.marks(run), stuck)
    alerts.fire(alerts.marks(stuck), failed)

    expect(sent.size).to eq(1)
  end

  it "sends the failed alert when a run is held by its timeout, and says so" do
    held = run(state: "waiting", reason: {"code" => "run_timed_out"})
    alerts.fire(alerts.marks(run), held)

    expect(sent.size).to eq(1)
    expect(sent.first).to include("WORKSPACE_ALERT_EVENT" => "failed", "WORKSPACE_ALERT_REASON" => "run_timed_out")
    expect(sent.first["WORKSPACE_ALERT_TEXT"]).to include("has used its time limit")
  end

  it "fires a stall for each new cause only" do
    alerts.fire(alerts.marks(run(stalled: {"pane_gone" => "t"})), run(stalled: {"pane_gone" => "t", "agent_gone" => "t"}))

    expect(sent.map { |env| env["WORKSPACE_ALERT_CAUSE"] }).to eq(["agent_gone"])
  end

  describe "a stall with an automatic restart" do
    let(:stall) { {"pane_gone" => "t"} }
    let(:mark) { {"cause" => "pane_gone", "n" => 1, "max" => 2, "scheduled_at" => "2026-10-04T12:00:00Z", "due" => "2026-10-04T12:01:00Z"} }

    def with_mark(extra = {}, stalled: stall, recovered: nil)
      run = run(stalled: stalled)
      run["sweep"]["infra_retry"] = mark.merge(extra)
      run["sweep"]["recovered"] = recovered if recovered
      run
    end

    it "holds the stalled alert while the restart is scheduled, due, claimed or stale" do
      [{}, {"due" => "2020-01-01T00:00:00Z"}, {"claimed_at" => Time.now.utc.iso8601}, {"claimed_at" => "2020-01-01T00:00:00Z"}].each do |extra|
        expect(alerts.marks(with_mark(extra))[:stalled]).to eq([])
      end
      alerts.fire(alerts.marks(run), with_mark)
      expect(sent).to eq([])
    end

    it "fires one stalled alert when the restarts give up" do
      held = with_mark
      alerts.fire(alerts.marks(run), held)
      gave_up = with_mark({"given_up" => {"at" => "t", "reason" => "retries_spent"}})
      alerts.fire(alerts.marks(held), gave_up)
      alerts.fire(alerts.marks(gave_up), gave_up)

      expect(sent.map { |env| [env["WORKSPACE_ALERT_EVENT"], env["WORKSPACE_ALERT_CAUSE"]] }).to eq([%w[stalled pane_gone]])
    end

    it "does not hold a stall whose mark ended while the stall is still open" do
      expect(alerts.marks(with_mark({"ended" => {"at" => "t", "reason" => "resumed"}}))[:stalled]).to eq([["plan:1", "pane_gone"]])
    end

    it "sends nothing for a held stall that then recovered, ended mark or not" do
      held = with_mark
      alerts.fire(alerts.marks(run), held)
      [with_mark(recovered: {"pane_gone" => "t"}), with_mark({"ended" => {"at" => "t", "reason" => "recovered"}}, recovered: {"pane_gone" => "t"})].each do |recovered|
        alerts.fire(alerts.marks(held), recovered)
        alerts.fire(alerts.marks(recovered), recovered)
      end

      expect(sent).to eq([])
    end

    it "sends one stalled alert for a give-up, and nothing more when the stall then recovers" do
      held = with_mark
      gave_up = with_mark({"given_up" => {"at" => "t", "reason" => "retries_spent"}})
      recovered = with_mark({"given_up" => {"at" => "t", "reason" => "retries_spent"}}, recovered: {"pane_gone" => "t"})
      alerts.fire(alerts.marks(run), held)
      alerts.fire(alerts.marks(held), gave_up)
      alerts.fire(alerts.marks(gave_up), recovered)

      expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[stalled])
    end

    it "alerts for the same cause stalling again on a later attempt with no restart held" do
      recovered = with_mark(recovered: {"pane_gone" => "t"})
      alerts.fire(alerts.marks(run), recovered)
      restalled = run(stalled: stall, attempts: 2)
      alerts.fire(alerts.marks(recovered), restalled)

      expect(sent.map { |env| [env["WORKSPACE_ALERT_EVENT"], env["WORKSPACE_ALERT_CAUSE"]] }).to eq([%w[stalled pane_gone]])
    end

    it "alerts for a cause the mark does not name" do
      held = with_mark(stalled: {"pane_gone" => "t", "agent_gone" => "t"}).tap { |r| r["sweep"]["infra_retry"]["cause"] = "pane_gone" }
      expect(alerts.marks(held)[:stalled]).to eq([["plan:1", "agent_gone"]])
    end

    it "alerts as today for a stall with no restart" do
      alerts.fire(alerts.marks(run), run(stalled: stall))
      expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[stalled])
    end
  end

  it "fires a stall for a turn that failed on an API error" do
    alerts.fire(alerts.marks(run), run(stalled: {"turn_failed" => "t"}))

    expect(sent.map { |env| [env["WORKSPACE_ALERT_EVENT"], env["WORKSPACE_ALERT_CAUSE"]] }).to eq([%w[stalled turn_failed]])
  end

  it "keeps a name in the settings that the run lacks from firing" do
    settings[:workflow] = %w[gate]
    alerts.fire(alerts.marks(run), run(state: "completed"))

    expect(sent).to eq([])
  end

  it "cuts what comes from the run file before escaping, so an escape is never cut in half" do
    odd = run(state: "completed").merge("workspace" => "#{"b" * 199}​tail")
    alerts.fire(alerts.marks(run), odd)

    expect(sent.first["WORKSPACE_ALERT_WORKSPACE"]).to eq("#{"b" * 199}\\u200B")
  end

  it "escapes control characters from the run file" do
    alerts.fire(alerts.marks(run), run(state: "completed").merge("workspace" => "a\nb\e[0m"))

    expect(sent.first["WORKSPACE_ALERT_WORKSPACE"]).to eq("a\\nb\\e[0m")
  end

  it "does not alert for a retry that is coming: a backoff wait is not a failure" do
    alerts.fire(alerts.marks(run), run(state: "waiting", reason: {"code" => "retry_backoff"}))

    expect(sent).to eq([])
  end

  it "alerts again for a failure of a later attempt, after a resume, and for a stall of a new attempt" do
    first = run(state: "waiting", reason: {"code" => "failed_check"}, attempts: 1)
    resumed = run(attempts: 2)
    second = run(state: "waiting", reason: {"code" => "failed_check"}, attempts: 2)
    alerts.fire(alerts.marks(run), first)
    alerts.fire(alerts.marks(first), resumed)
    alerts.fire(alerts.marks(resumed), second)
    alerts.fire(alerts.marks(run(attempts: 1)), run(attempts: 1, stalled: {"pane_gone" => "t"}))
    alerts.fire(alerts.marks(run(attempts: 1, stalled: {"pane_gone" => "t"})), run(attempts: 2, stalled: {"pane_gone" => "t"}))

    expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[failed failed stalled stalled])
  end

  it "treats a gate or a failure on another step as a new episode within one change" do
    alerts.fire(alerts.marks(run(state: "waiting", gate: {"state" => "waiting"}, step: "plan")), run(state: "waiting", gate: {"state" => "waiting"}, step: "build"))
    alerts.fire(alerts.marks(run(state: "waiting", reason: {"code" => "failed_check"}, step: "plan")), run(state: "waiting", reason: {"code" => "failed_check"}, step: "build"))
    alerts.fire(alerts.marks(run(state: "waiting", gate: {"state" => "waiting"}, step: "plan")), run(state: "waiting", gate: {"state" => "waiting"}, step: "plan", attempts: 2))

    expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[gate failed])
  end

  it "alerts for a run that ended failed and for nothing on a cancel" do
    alerts.fire(alerts.marks(run), run(state: "cancelled"))
    expect(sent).to eq([])

    alerts.fire(alerts.marks(run), run(state: "failed"))
    expect(sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(%w[failed])
  end

  describe "#deliver" do
    it "renames a log past 1 MiB aside before the supervisor appends to it" do
      Dir.mktmpdir("ws-alerts") do |dir|
        log = File.join(dir, "state", "workflow-alerts.log")
        FileUtils.mkdir_p(File.dirname(log))
        File.write(log, "x" * (Workspace::WorkflowAlerts::MAX_LOG_BYTES + 1))
        File.write("#{log}.1", "older")
        real = described_class.new(alert_config: nil, log_path: log, timeout: 1)

        real.deliver("true", {"WORKSPACE_ALERT" => "workflow"})

        expect(File.size("#{log}.1")).to eq(Workspace::WorkflowAlerts::MAX_LOG_BYTES + 1)
        expect(File.size(log)).to be < 1000
      end
    end

    it "hands the supervisor the limit and the command as arguments, and the alert only as environment" do
      alerts.deliver("say hi", {"WORKSPACE_ALERT_TEXT" => "x"})

      expect(argvs.first.last(2)).to eq(["10", "say hi"])
      expect(argvs.first.join(" ")).not_to include("WORKSPACE_ALERT_TEXT")
      expect(sent).to eq([{"WORKSPACE_ALERT_TEXT" => "x"}])
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    # The starter exits at once; the supervisor it left behind has to stop the command after the limit.
    it "stops a hanging command after the limit, though the process that started it is long gone" do
      Dir.mktmpdir("ws-alerts") do |dir|
        pid_file = File.join(dir, "pid")
        log = File.join(dir, "log")
        starter = <<~RUBY
          $LOAD_PATH.unshift(#{File.join(PROJECT_ROOT, "lib").inspect})
          require "workspace"
          Workspace::WorkflowAlerts.new(alert_config: nil, log_path: #{log.inspect}, timeout: 1)
            .deliver("echo $$ > #{pid_file}; exec sleep 60", {"WORKSPACE_ALERT" => "workflow"})
        RUBY
        expect(system(RbConfig.ruby, "-e", starter, out: File::NULL, err: File::NULL)).to be(true)

        deadline = Time.now + 10
        sleep 0.05 until (File.exist?(pid_file) && !File.read(pid_file).strip.empty?) || Time.now > deadline
        pid = Integer(File.read(pid_file).strip)
        expect(process_alive?(pid)).to be(true)

        deadline = Time.now + 10
        sleep 0.1 while process_alive?(pid) && Time.now < deadline
        expect(process_alive?(pid)).to be(false)
        expect(File.read(log)).to include("still running after 1.0s")
      end
    end
  end

  it "reports a failure to read the settings and does not raise" do
    allow(alert_config).to receive(:for_workspace).and_raise(Workspace::Error, "cannot read")

    expect { alerts.fire(alerts.marks(run), run(state: "completed")) }.not_to raise_error
    expect(error_output.string).to include("could not send alerts for wr_1", "cannot read")
  end
end
