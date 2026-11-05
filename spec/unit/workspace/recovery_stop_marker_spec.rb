require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::RecoveryStopMarker do
  let(:dir) { Dir.mktmpdir("ws-recovery-marker") }
  let(:now) { [Time.utc(2026, 10, 30, 12, 0, 0)] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
  let(:marker) { described_class.new(state_dir: dir, clock: clock) }

  after { FileUtils.remove_entry(dir) }

  it "reads a marked session as marked, and another as not" do
    expect(marker.mark("sess-1")).to be(true)

    expect(marker.marked?("sess-1")).to be(true)
    expect(marker.marked?("sess-2")).to be(false)
    expect(File.exist?(File.join(dir, "agent-recovery", "stopping", "sess-1"))).to be(true)
  end

  it "reads a cleared session as not marked, and clearing an unmarked one is harmless" do
    marker.mark("sess-1")
    marker.clear("sess-1")
    marker.clear("sess-1")

    expect(marker.marked?("sess-1")).to be(false)
  end

  it "reads a marker older than five minutes as unset" do
    marker.mark("sess-1")
    now[0] += 299
    expect(marker.marked?("sess-1")).to be(true)
    now[0] += 2
    expect(marker.marked?("sess-1")).to be(false)
  end

  it "is seen by another object on the same directory" do
    marker.mark("sess-1")

    expect(described_class.new(state_dir: dir, clock: clock).marked?("sess-1")).to be(true)
  end

  it "refuses ids that are not plain file names" do
    ["", nil, "../x", "a/b", ".hidden"].each do |id|
      expect(marker.mark(id)).to be(false)
      expect(marker.marked?(id)).to be(false)
    end
    expect(Dir.exist?(File.join(dir, "agent-recovery"))).to be(false)
  end
end
