require "spec_helper"

RSpec.describe Workspace::ProcessHolderStopper do
  let(:terminator) { instance_double(Workspace::ProcessGroupTerminator) }
  let(:store) { instance_double(Workspace::LockStore, keep_process_holder: nil) }
  let(:error_output) { StringIO.new }
  let(:now) { [0] }
  let(:clock) { Struct.new(:now_ref) { def now = now_ref[0] }.new(now) }
  let(:holder) { {"pid" => 4242, "pgid" => 4242, "started" => "s-4242"} }
  let(:stopper) do
    described_class.new(terminator: terminator, liveness: double("liveness"), error_output: error_output, clock: clock,
      sleeper: ->(seconds) { now[0] += seconds })
  end

  before { allow(terminator).to receive(:stop_holder).and_return(:killed) }

  def stop(**opts)
    stopper.stop(store, "devenv", holder, stop_timeout: 5, retry_command: "workspace dev down", **opts)
  end

  it "keeps the lock of a group still running #{described_class::KILL_GRACE_SECONDS}s after SIGKILL by default" do
    allow(terminator).to receive(:running?).with(4242).and_return(true)

    expect(stop).to eq(:kept)
    expect(now[0]).to be_between(described_class::KILL_GRACE_SECONDS, described_class::KILL_GRACE_SECONDS + described_class::KILL_POLL_SECONDS * 2)
    expect(error_output.string).to include("still running 2s after SIGKILL")
    expect(store).to have_received(:keep_process_holder).with("devenv", holder, cleared_by: nil, clearer: nil)
  end

  it "names the run, not a blank pid, when a run holds the lock it could not keep" do
    allow(terminator).to receive(:running?).with(4242).and_return(true)
    allow(store).to receive(:keep_process_holder).and_return({"kind" => "run", "run_id" => "wr_1", "worktree" => "/src/app-a"})

    expect(stop).to eq(:kept)
    expect(error_output.string).to include("Could not keep devenv lock for process group 4242: it is now held by run wr_1 (/src/app-a)")
  end

  it "reports the result and the reason without touching the store" do
    allow(terminator).to receive(:running?).with(4242).and_return(true)

    expect(stopper.stop_group(holder, stop_timeout: 5, kill_grace: 3)).to eq([:killed, "it was still running 3s after SIGKILL"])
    expect(store).not_to have_received(:keep_process_holder)
    expect(error_output.string).to eq("")
  end

  it "waits the given kill_grace instead" do
    allow(terminator).to receive(:running?).with(4242).and_return(true)

    expect(stop(kill_grace: 7)).to eq(:kept)
    expect(now[0]).to be_between(7, 7 + described_class::KILL_POLL_SECONDS * 2)
    expect(error_output.string).to include("still running 7s after SIGKILL")
  end

  it "reports a group gone within a longer kill_grace as killed" do
    polls = [true] * 30 + [false]
    allow(terminator).to receive(:running?).with(4242) { polls.shift }

    expect(stop(kill_grace: 5)).to eq(:killed)
    expect(store).not_to have_received(:keep_process_holder)
  end
end
