require "spec_helper"
require "timeout"

# Returns each canned capture in turn, repeating the last one forever.
class ScriptedTmux
  def initialize(captures)
    @captures = captures
    @mutex = Mutex.new
  end

  def capture_pane(_session, _pane, **_opts)
    @mutex.synchronize { (@captures.size > 1) ? @captures.shift : @captures.first }
  end
end

RSpec.describe Workspace::SentinelPoller do
  let(:error_output) { StringIO.new }

  # Runs the poller against a canned sequence of pane captures. The first entry
  # is what the pane held when the poller started.
  def poll(captures, timeout: 0.5)
    poller = described_class.new(
      tmux: ScriptedTmux.new(captures), session_name: "myapp", pane: 0,
      poll_interval: 0.01, error_output: error_output
    )
    summary = Queue.new
    poller.start { |text| summary << text }
    begin
      Timeout.timeout(timeout) { summary.pop }
    rescue Timeout::Error
      nil
    ensure
      poller.stop
    end
  end

  it "reports the summary once the sentinel appears" do
    expect(poll(["still working\n", "still working\nWORKSPACE_DONE: PR #123 opened\n"]))
      .to eq("PR #123 opened")
  end

  it "ignores a sentinel the pane already held before it started watching" do
    expect(poll(["WORKSPACE_DONE: from the previous work item\n"])).to be_nil
  end

  it "ignores the sentinel quoted mid-line rather than printed on its own" do
    expect(poll(["", "$ echo WORKSPACE_DONE: not really\n"])).to be_nil
  end

  it "keeps polling when the pane cannot be captured" do
    expect(poll([nil, nil, "WORKSPACE_DONE: recovered\n"])).to eq("recovered")
  end

  it "treats a bare sentinel with no summary as completion" do
    expect(poll(["", "WORKSPACE_DONE:\n"])).to eq("")
  end

  it "reports to the error stream when polling dies unexpectedly" do
    tmux = Object.new
    def tmux.capture_pane(*, **) = raise("tmux exploded")
    poller = described_class.new(
      tmux: tmux, session_name: "myapp", pane: 0, poll_interval: 0.01, error_output: error_output
    )
    poller.start { |_| }.join(1)

    expect(error_output.string).to include("tmux exploded")
  end

  it "does not kill the calling thread when stopped from inside its callback" do
    poller = described_class.new(
      tmux: ScriptedTmux.new(["", "WORKSPACE_DONE: done\n"]),
      session_name: "myapp", pane: 0, poll_interval: 0.01, error_output: error_output
    )
    reached_end = Queue.new
    poller.start do |_summary|
      poller.stop
      reached_end << :finished
    end

    expect(Timeout.timeout(1) { reached_end.pop }).to eq(:finished)
  end
end
