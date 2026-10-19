require "tmpdir"

RSpec.describe Workspace::SpineOwnerReport do
  let(:notes) { Dir.mktmpdir }
  let(:spine) { File.join(notes, "spine") }
  let(:recorded) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog).tap do |log|
      allow(log).to receive(:record) { |**args| recorded << args[:data] && true }
    end
  end
  let(:report) { described_class.new(workspace: "ws", dir_resolver: ->(_) { notes }, event_log: event_log) }

  before { FileUtils.mkdir_p(spine) }

  after { FileUtils.remove_entry(notes) }

  def stage(name, status:, owner: nil, check: nil, body: "x")
    lines = ["---", "spine: 1", "status: #{status}"]
    lines << "owner: #{owner}" if owner
    lines << "check: #{check}" if check
    File.write(File.join(spine, name), (lines + ["---", body]).join("\n"))
  end

  it "reports an in-progress stage at every turn end of its owner pane" do
    stage("10-research.md", status: "in_progress", owner: "%5")

    2.times { expect(report.turn_ended("%5")).to eq(1) }

    expect(recorded).to eq([{"workspace" => "ws", "path" => "research", "change" => "owner_finished", "owner" => "%5", "state" => "in_progress"}] * 2)
  end

  it "writes nothing for a pane that owns no stage, or a stage that is not started" do
    stage("10-research.md", status: "in_progress", owner: "%5")
    stage("20-plan.md", status: "not_started", owner: "%6")

    expect(report.turn_ended("%7")).to eq(0)
    expect(report.turn_ended("%6")).to eq(0)
    expect(report.turn_ended("")).to eq(0)
    expect(recorded).to eq([])
  end

  it "does not report a completed stage at a Stop, so a restart or a reused pane id repeats nothing" do
    stage("10-research.md", status: "completed", owner: "%5")

    expect(report.turn_ended("%5")).to eq(0)
  end

  it "reports a completed stage from the watcher, as checking while its check is pending" do
    expect(report.stage_completed("plan", "%5", "required")).to be(true)
    expect(report.stage_completed("research", "%5", nil)).to be(true)
    expect(report.stage_completed("none", "", nil)).to be(false)

    expect(recorded.map { |d| [d["path"], d["state"]] }).to eq([%w[plan checking], %w[research completed]])
  end

  it "writes nothing when the notes directory is unknown" do
    nowhere = described_class.new(workspace: "ws", dir_resolver: ->(_) {}, event_log: event_log)

    expect(nowhere.turn_ended("%5")).to eq(0)
  end
end
