RSpec.describe Workspace::SessionMonitor do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:clock) { class_double(Time, now: now) }

  let(:panes) do
    [
      {id: "%1", index: 0, pid: 100, command: "zsh", cwd: "/project", title: "shell"},
      {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
    ]
  end

  subject(:monitor) do
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
      idle_after: 30, clock: clock)
  end

  before do
    allow(tmux).to receive(:pane_details).and_return(panes)
    allow(process_tree).to receive(:snapshot).and_return(snapshot)
    allow(snapshot).to receive(:find_descendant).and_return(nil)
    allow(snapshot).to receive(:find_descendant)
      .with(200, ["claude"], hash_including(include_root: true))
      .and_return({pid: 250, command: "claude", args: "claude"})
    allow(tmux).to receive(:capture_pane).and_return("output")
  end

  def pane(id)
    monitor.snapshot["panes"].find { |p| p["pane_id"] == id }
  end

  describe "#scan" do
    it "skips the tick instead of stalling when ps hangs" do
      monitor.scan
      hung_tree = Workspace::ProcessTree.new(timeout: 0.1, command: ["/bin/sleep", "30"])
      allow(process_tree).to receive(:snapshot) { hung_tree.snapshot }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      monitor.scan

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(pane("%2")["kind"]).to eq("claude")
    end
  end
end
