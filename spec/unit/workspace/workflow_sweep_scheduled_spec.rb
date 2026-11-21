require "spec_helper"
require "tmpdir"

# Holds run hashes as the store would, and records what the sweep asks the engine.
class ScheduledSweepFakeEngine
  attr_reader :calls, :runs

  def initialize
    @runs = {}
    @calls = []
  end

  def going = @runs.values.map { |each| Workspace::WorkflowRun.from_h(each) }

  def run(id) = Workspace::WorkflowRun.from_h(@runs.fetch(id))

  def unreadable = []

  def redeliver(run_id, **kw)
    @calls << [:redeliver, run_id, kw]
    :redelivered
  end

  def note_stall(run_id, **kw)
    @calls << [:note_stall, run_id, kw]
    :recorded
  end

  def note_recovery(run_id, **kw)
    @calls << [:note_recovery, run_id, kw]
    :recorded
  end

  def redeliveries = @calls.count { |each| each.first == :redeliver }
end

# The launchd sweep (`workflow sweep --scheduled`) runs without access to iCloud Drive, where notes often live, so a
# review round's revision command hangs there and each redelivery it makes is spent for nothing. While the
# workspace's agent daemon is up, the daemon's own sweep (started from tmux, with that access) owns the run: the
# scheduled sweep leaves it alone with reason `daemon_owns`. With the daemon down it acts as before, and a sweep
# without the flag is unchanged.
RSpec.describe Workspace::WorkflowSweep, "scheduled by launchd" do
  let(:now) { Time.utc(2026, 11, 21, 12, 0, 0) }
  let(:engine) { ScheduledSweepFakeEngine.new }
  let(:panes) { FakeWorkflowPanes.new }
  let(:reviews) { instance_double(Workspace::WorkflowReviewSweep, orphan_rows: []) }
  let(:sweep) do
    described_class.new(store: engine, engine: engine, panes: panes, interrupter: ->(*) {}, reviews: reviews, clock: -> { now })
  end

  # A run whose step's line was not delivered (the pane was busy) ten minutes ago, so its first redelivery is due.
  before do
    engine.runs["wr_1"] = {
      "id" => "wr_1", "workspace" => "app", "state" => "waiting", "current" => "build", "pane" => "%5",
      "reason" => {"code" => "waiting_you", "details" => {"kind" => "dispatch", "error" => "pane_busy"}},
      "definition" => {"redeliver" => 3, "steps" => [{"id" => "build", "prompt" => "Build it."}]},
      "steps" => {"build" => {"state" => "waiting", "attempts" => [
        {"n" => 1, "started_at" => (now - 660).utc.iso8601, "ended_at" => (now - 600).utc.iso8601, "outcome" => "not_delivered"}
      ]}}
    }
    panes.bind(workspace: "app", pane: "%5", run_id: "wr_1")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "idle", "idle_seconds" => 600}
  end

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  it "leaves the run to a running daemon and spends no redelivery" do
    panes.daemon = true

    row = only_row(sweep.call(scheduled: true))

    expect(row).to include("outcome" => "nothing", "reason" => "daemon_owns", "run_id" => "wr_1")
    expect(engine.redeliveries).to eq(0)
  end

  it "acts as before when the daemon is down" do
    panes.daemon = false

    row = only_row(sweep.call(scheduled: true))

    expect(row).to include("outcome" => "respawned", "cause" => "daemon_down")
    expect(panes.respawns).not_to be_empty
  end

  it "redelivers as before without the flag" do
    panes.daemon = true

    row = only_row(sweep.call)

    expect(row).to include("outcome" => "redelivered", "cause" => "undelivered")
    expect(engine.redeliveries).to eq(1)
  end
end

RSpec.describe Workspace::SweepSchedule, "launchd command" do
  around do |example|
    Dir.mktmpdir("sweep-scheduled") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  it "runs the sweep with --scheduled, so a running daemon keeps its runs" do
    agents_dir = File.join(@dir, "LaunchAgents")
    source = instance_double(Workspace::SkillSource, executable: File.join(@dir, "bin", "workspace"))
    launchctl = ->(args) { (args.first == "print") ? ["Could not find service", 1] : ["", 0] }
    described_class.new(agents_dir: agents_dir, launchctl: launchctl, source: source, ruby: "/usr/local/ruby/bin/ruby",
      which: ->(_) {}, uid: 501, log_path: File.join(@dir, "state", "sweep.log")).install
    text = File.read(File.join(agents_dir, "com.workspace.workflow-sweep.plist"))

    expect(text).to include("<string>sweep</string>\n    <string>--scheduled</string>"),
      "the launchd entry runs `workflow sweep` without --scheduled"
  end
end
