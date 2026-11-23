require "spec_helper"

RSpec.describe Workspace::WorkflowAlerts do
  let(:sent) { [] }
  let(:settings) { {notify: "notify-me", workflow: %w[gate failed stalled finished]} }
  let(:alert_config) { instance_double(Workspace::AlertConfig, for_workspace: settings) }
  subject(:alerts) { described_class.new(alert_config: alert_config, spawner: ->(_argv, env, _log) { sent << env }, error_output: StringIO.new) }

  def sibling_run(current: "lint", gates: [], failed: [])
    ids = %w[lint spec]
    definition = {"steps" => ids.map { |id| {"id" => id, "group" => "checks"} }}
    steps = ids.to_h do |id|
      state = {"attempts" => [{"n" => 1}]}
      state["gate"] = {"state" => "waiting"} if gates.include?(id)
      state["reason"] = {"code" => "failed_check"} if failed.include?(id)
      [id, state]
    end
    {"id" => "wr_1", "workspace" => "app", "current" => current, "state" => "waiting", "definition" => definition, "steps" => steps}
  end

  it "keeps the marks of a run with no group exactly as they were: no sibling key" do
    run = {"id" => "wr_1", "workspace" => "app", "current" => "plan", "state" => "running", "steps" => {"plan" => {"attempts" => [{"n" => 1}]}}}

    expect(alerts.marks(run)).to eq(gate: nil, failed: nil, stalled: [], finished: false)
  end

  it "marks each sibling on its own" do
    marks = alerts.marks(sibling_run(gates: %w[lint spec]))

    expect(marks[:siblings]).to eq("lint" => {gate: true, failed: nil}, "spec" => {gate: true, failed: nil})
  end

  it "sends two gate alerts when two siblings gate at once, each naming its own step" do
    before = alerts.marks(sibling_run)
    alerts.fire(before, sibling_run(gates: %w[lint spec]))

    expect(sent.map { |env| [env["WORKSPACE_ALERT_EVENT"], env["WORKSPACE_ALERT_STEP"]] }).to contain_exactly(%w[gate lint], %w[gate spec])
  end

  it "does not repeat a sibling's alert on a later change, and alerts the sibling that gates later" do
    gated = sibling_run(gates: %w[lint])
    alerts.fire(alerts.marks(sibling_run), gated)
    both = sibling_run(gates: %w[lint spec])
    alerts.fire(alerts.marks(gated), both)
    alerts.fire(alerts.marks(both), both)

    expect(sent.map { |env| env["WORKSPACE_ALERT_STEP"] }).to eq(%w[lint spec])
  end

  it "sends a failed alert for a sibling that is not the cursor, with its own reason" do
    alerts.fire(alerts.marks(sibling_run), sibling_run(failed: %w[spec]))

    expect(sent.size).to eq(1)
    expect(sent.first).to include("WORKSPACE_ALERT_EVENT" => "failed", "WORKSPACE_ALERT_STEP" => "spec", "WORKSPACE_ALERT_REASON" => "failed_check")
    expect(sent.first["WORKSPACE_ALERT_TEXT"]).to eq("app: workflow run wr_1 failed at spec")
  end

  it "sends no failed alert for siblings whose group move waits out its backoff, and one each once it is blocked" do
    waiting = sibling_run(current: "spec")
    %w[lint spec].each { |id| waiting["steps"][id]["reason"] = {"code" => "retry_backoff"} }
    waiting["steps"]["lint"]["pending_move"] = {"group" => "checks", "to" => "plan", "until" => "2026-11-10T12:01:00Z"}
    alerts.fire(alerts.marks(sibling_run), waiting)
    expect(sent).to eq([])

    alerts.fire(alerts.marks(waiting), sibling_run(current: "spec", failed: %w[lint spec]))
    expect(sent.map { |env| [env["WORKSPACE_ALERT_EVENT"], env["WORKSPACE_ALERT_STEP"]] }).to contain_exactly(%w[failed lint], %w[failed spec])
  end

  it "sends one alert, not two, for the sibling the run's own mark already names" do
    alerts.fire(alerts.marks(sibling_run), sibling_run(failed: %w[lint]))

    expect(sent.map { |env| env["WORKSPACE_ALERT_STEP"] }).to eq(%w[lint])
  end

  it "shapes a single sibling's alert like an ungrouped run's" do
    alerts.fire(alerts.marks(sibling_run), sibling_run(gates: %w[lint]))
    plain = {"id" => "wr_1", "workspace" => "app", "current" => "plan", "state" => "waiting", "steps" => {"plan" => {"attempts" => [{"n" => 1}], "gate" => {"state" => "waiting"}}}}
    alerts.fire(alerts.marks(plain.merge("state" => "running", "steps" => {"plan" => {"attempts" => [{"n" => 1}]}})), plain)

    expect(sent.first.keys).to eq(sent.last.keys)
    expect(sent.first["WORKSPACE_ALERT_TEXT"]).to eq("app: workflow run wr_1 is waiting for you at lint")
  end
  describe "#unreadable" do
    let(:path) { "/state/.workflows/wr_bad.json" }

    before { settings[:workflow] = %w[gate unreadable_run] }

    it "sends the event with the run id from the file name and reads the global layer" do
      alerts.unreadable(path)

      expect(alert_config).to have_received(:for_workspace).with("")
      expect(sent.size).to eq(1)
      expect(sent.first).to include("WORKSPACE_ALERT" => "workflow", "WORKSPACE_ALERT_EVENT" => "unreadable_run", "WORKSPACE_ALERT_RUN_ID" => "wr_bad")
      expect(sent.first["WORKSPACE_ALERT_TEXT"]).to include(path, "locks stay held", "workspace lock clear NAME")
    end

    it "escapes the path" do
      alerts.unreadable("/state/wr\e[31m.json")

      expect(sent.first["WORKSPACE_ALERT_TEXT"]).not_to include("\e")
    end

    it "sends nothing when alerts.workflow does not name it" do
      settings[:workflow] = %w[gate]
      alerts.unreadable(path)

      expect(sent).to be_empty
    end

    it "sends nothing without a notify command" do
      settings[:notify] = nil
      alerts.unreadable(path)

      expect(sent).to be_empty
    end
  end
end
