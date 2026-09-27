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
  def poll(captures, timeout: 0.5, token: nil)
    poller = described_class.new(
      tmux: ScriptedTmux.new(captures), session_name: "myapp", pane: 0, token: token,
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

  describe "with a dispatch token" do
    it "reports the summary once the sentinel carrying its token appears" do
      expect(poll(["still working\n", "still working\nWORKSPACE_DONE:ab12 PR #123 opened\n"], token: "ab12"))
        .to eq("PR #123 opened")
    end

    it "ignores a sentinel without its token, whatever printed it" do
      expect(poll(["", "WORKSPACE_DONE: a test's output\nWORKSPACE_DONE:zz99 another stage\n"], token: "ab12"))
        .to be_nil
    end

    it "does not take a longer token that merely starts with its own" do
      expect(poll(["", "WORKSPACE_DONE:ab123 not mine\n"], token: "ab12")).to be_nil
    end

    it "sees its sentinel once the pane's history is full and the line count stops growing" do
      full = Array.new(50) { |i| "line #{i}\n" }.join
      scrolled = Array.new(49) { |i| "line #{i + 1}\n" }.join + "WORKSPACE_DONE:ab12 done\n"

      expect(poll([full, full, scrolled], token: "ab12")).to eq("done")
    end

    it "sees a sentinel the pane already held, since only this dispatch can have printed it" do
      expect(poll(["WORKSPACE_DONE:ab12 finished while the agent was down\n"], token: "ab12"))
        .to eq("finished while the agent was down")
    end

    it "does not mistake its own instruction, wrapped onto a line of its own, for the sentinel" do
      wrapped = described_class.instruction("ab12").delete_prefix("When you are done, print a single line: ")
      expect(poll(["", "#{wrapped}\n"], token: "ab12")).to be_nil
    end

    it "ignores a bare sentinel, which is how the instruction reads when wrapped just after the marker" do
      expect(poll(["", "WORKSPACE_DONE:ab12\n"], token: "ab12")).to be_nil
    end

    it "ignores a sentinel followed by only the start of the placeholder" do
      expect(poll(["", "  WORKSPACE_DONE:ab12 <one-line\n  summary>\n"], token: "ab12")).to be_nil
    end

    it "still finds the stage's real sentinel below a wrapped echo of the instruction" do
      expect(poll(["", "WORKSPACE_DONE:ab12\n<one-line summary>\nWORKSPACE_DONE:ab12 all done\n"], token: "ab12"))
        .to eq("all done")
    end
  end

  describe "with a deadline" do
    let(:deadline) { Time.utc(2026, 9, 27, 12, 0, 0) }

    # Runs one poller to its end and says which way it ended.
    def outcome(captures, now:)
      poller = described_class.new(
        tmux: ScriptedTmux.new(captures), session_name: "myapp", pane: 0, token: "ab12",
        deadline: deadline, clock: -> { now }, poll_interval: 0.01, error_output: error_output
      )
      result = Queue.new
      poller.start(on_timeout: -> { result << :timed_out }) { |summary| result << [:done, summary] }
      Timeout.timeout(1) { result.pop }
    ensure
      poller.stop
    end

    it "gives up once the deadline passes without a sentinel" do
      expect(outcome(["still working\n"], now: deadline)).to eq(:timed_out)
    end

    it "keeps waiting while the deadline is still ahead" do
      captures = ["", "", "WORKSPACE_DONE:ab12 made it\n"]
      expect(outcome(captures, now: deadline - 1)).to eq([:done, "made it"])
    end

    it "counts a sentinel already printed when it finds the deadline has passed" do
      expect(outcome(["WORKSPACE_DONE:ab12 finished while no one watched\n"], now: deadline + 60))
        .to eq([:done, "finished while no one watched"])
    end
  end

  describe ".instruction" do
    it "tells the stage the exact line to print" do
      expect(described_class.instruction("ab12"))
        .to eq("When you are done, print a single line: WORKSPACE_DONE:ab12 <one-line summary>")
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

  it "ignores a bare sentinel with no summary" do
    expect(poll(["", "WORKSPACE_DONE:\n"])).to be_nil
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

  it "hands the failure message to on_error when polling dies unexpectedly" do
    tmux = Object.new
    def tmux.capture_pane(*, **) = raise("tmux exploded")
    poller = described_class.new(
      tmux: tmux, session_name: "myapp", pane: 0, poll_interval: 0.01, error_output: error_output
    )
    failures = Queue.new
    poller.start(on_error: ->(message) { failures << message }) { |_| }

    expect(Timeout.timeout(1) { failures.pop }).to eq("tmux exploded")
  end

  it "does not call on_error when the stage completes normally" do
    poller = described_class.new(
      tmux: ScriptedTmux.new(["", "WORKSPACE_DONE: done\n"]),
      session_name: "myapp", pane: 0, poll_interval: 0.01, error_output: error_output
    )
    failures = []
    summaries = Queue.new
    poller.start(on_error: ->(message) { failures << message }) { |summary| summaries << summary }

    expect(Timeout.timeout(1) { summaries.pop }).to eq("done")
    expect(failures).to be_empty
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
