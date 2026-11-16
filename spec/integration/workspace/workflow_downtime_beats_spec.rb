require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowNudger, "with a real downtime object" do
  it "records one span when the clock jumps past the downtime threshold between ticks" do
    Dir.mktmpdir do |dir|
      now = [Time.utc(2026, 10, 4, 12, 0, 0)]
      downtime = Workspace::WorkflowDowntime.new(heartbeat_path: File.join(dir, "heartbeat"), downtime_path: File.join(dir, "downtime.jsonl"),
        downtime_after: -> { 120 }, clock: -> { now.first })
      store = instance_double(Workspace::WorkflowRunStore, going: [], unreadable: [])
      nudger = described_class.new(store: store, panes: nil, executable: "x", log_path: ->(w) { w }, spawner: ->(*) {},
        downtime: downtime, clock: -> { now.first })
      reviews = instance_double(Workspace::WorkflowReviewSweep, orphan_rows: [])
      sweep = Workspace::WorkflowSweep.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, downtime: downtime)

      nudger.tick("app")
      now[0] += 9 * 3600
      nudger.tick("app")
      now[0] += 30
      sweep.call

      lines = File.readlines(File.join(dir, "downtime.jsonl"))
      expect(lines.size).to eq(1)
      expect(JSON.parse(lines.first).values_at("from", "to")).to eq(["2026-10-04T12:00:00.000Z", "2026-10-04T21:00:00.000Z"])
    end
  end
end
