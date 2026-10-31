require "spec_helper"

RSpec.describe Workspace::AgentStopper do
  def proc_entry(pid, ppid, args, lstart: "Mon Oct 26 10:00:00 2026")
    {pid: pid, ppid: ppid, lstart: lstart, command: args.split.first, args: args}
  end

  def snapshot(*entries)
    Workspace::ProcessTree::Snapshot.new(entries)
  end

  let(:detector) { Workspace::AgentDetector.new }
  let(:signals) { [] }
  let(:signaller) { ->(signal, pid) { signals << [signal, pid] } }
  let(:group_ids) { [10, 10] }
  let(:group_reader) { ->(_pid) { group_ids } }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:stopper) { described_class.new(process_tree: process_tree, signaller: signaller, group_reader: group_reader) }

  let(:unwrapped) { snapshot(proc_entry(10, 1, "-zsh"), proc_entry(20, 10, "claude --resume")) }
  let(:wrapper) do
    snapshot(proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "/bin/sh /Users/z/bin/claude-dev"), proc_entry(20, 15, "claude --resume"))
  end

  describe "#find_agent" do
    it "finds the agent below the shell in an unwrapped pane" do
      expect(stopper.find_agent(pane_pid: 10, detector: detector, tree: unwrapped)).to eq(pid: 20, started: "Mon Oct 26 10:00:00 2026")
    end

    it "finds the agent, not the wrapper, in a wrapper pane" do
      expect(stopper.find_agent(pane_pid: 10, detector: detector, tree: wrapper)[:pid]).to eq(20)
    end

    it "finds an agent run under a configured alias" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(20, 10, "claude-dev --resume"))
      aliased = Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]})
      expect(stopper.find_agent(pane_pid: 10, detector: aliased, tree: tree)[:pid]).to eq(20)
    end

    it "answers nil when no agent runs" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(20, 10, "vim"))
      expect(stopper.find_agent(pane_pid: 10, detector: detector, tree: tree)).to be_nil
    end

    it "finds the agent when the pane's own process is the agent" do
      tree = snapshot(proc_entry(10, 1, "claude"))
      expect(stopper.find_agent(pane_pid: 10, detector: detector, tree: tree)[:pid]).to eq(10)
    end
  end

  describe "#restartable?" do
    it "is true for an unwrapped pane" do
      expect(stopper.restartable?(pid: 20, pane_pid: 10, tree: unwrapped)).to be true
    end

    it "is true for a wrapper pane" do
      expect(stopper.restartable?(pid: 20, pane_pid: 10, tree: wrapper)).to be true
    end

    it "is false when a non-shell sits between" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "node server.js"), proc_entry(20, 15, "claude"))
      expect(stopper.restartable?(pid: 20, pane_pid: 10, tree: tree)).to be false
    end

    it "is false when the chain misses the pane pid" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(30, 1, "-zsh"), proc_entry(20, 30, "claude"))
      expect(stopper.restartable?(pid: 20, pane_pid: 10, tree: tree)).to be false
    end
  end

  describe "#stop" do
    let(:started) { "Mon Oct 26 10:00:00 2026" }

    it "sends INT once to the agent pid" do
      allow(process_tree).to receive(:snapshot).and_return(wrapper)
      expect(stopper.stop(pid: 20, started: started)).to eq(:signalled)
      expect(signals).to eq([["INT", 20]])
    end

    it "refuses a reused pid" do
      allow(process_tree).to receive(:snapshot).and_return(wrapper)
      expect(stopper.stop(pid: 20, started: "Tue Oct 27 09:00:00 2026")).to eq(:stale)
      expect(signals).to be_empty
    end

    it "answers not_running for a gone pid" do
      allow(process_tree).to receive(:snapshot).and_return(snapshot(proc_entry(10, 1, "-zsh")))
      expect(stopper.stop(pid: 20, started: started)).to eq(:not_running)
      expect(signals).to be_empty
    end

    it "answers not_running when the process exits before the signal" do
      allow(process_tree).to receive(:snapshot).and_return(wrapper)
      gone = described_class.new(process_tree: process_tree, signaller: ->(*) { raise Errno::ESRCH })
      expect(gone.stop(pid: 20, started: started)).to eq(:not_running)
    end

    it "never signals the pane's shell and sends only INT" do
      allow(process_tree).to receive(:snapshot).and_return(wrapper)
      agent = stopper.find_agent(pane_pid: 10, detector: detector, tree: wrapper)
      stopper.stop(**agent)
      expect(signals.map(&:first).uniq).to eq(["INT"])
      expect(signals.map(&:last)).not_to include(10, 15)
    end
  end

  describe "#pane_clear?" do
    def clear?(tree, command: "zsh")
      stopper.pane_clear?(pane_pid: 10, command: command, detector: detector, tree: tree)
    end

    it "is false with a live agent under a wrapper" do
      expect(clear?(wrapper)).to be false
    end

    it "is false with a wrapper still exiting that holds the terminal" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "/bin/sh /Users/z/bin/claude-dev"))
      reader = ->(_pid) { [10, 15] }
      expect(described_class.new(process_tree: process_tree, group_reader: reader)
        .pane_clear?(pane_pid: 10, command: "zsh", detector: detector, tree: tree)).to be false
    end

    context "when the reader fails" do
      let(:group_ids) { nil }

      it "is false" do
        expect(clear?(snapshot(proc_entry(10, 1, "-zsh")))).to be false
      end
    end

    it "is true with a helper and a background job under a shell that holds the terminal" do
      tree = snapshot(proc_entry(10, 1, "-zsh"), proc_entry(30, 10, "claude daemon run"), proc_entry(31, 10, "sleep 100"))
      expect(clear?(tree)).to be true
    end

    it "is false when the pane's command is not a shell" do
      expect(clear?(snapshot(proc_entry(10, 1, "vim")), command: "vim")).to be false
    end
  end

  describe "DEFAULT_GROUP_READER" do
    it "reads the groups of a real process" do
      ids = described_class::DEFAULT_GROUP_READER.call(Process.pid)

      expect(ids.first).to eq(Process.getpgrp)
      expect(ids.size).to eq(2)
    end

    it "answers nil when ps runs past its limit" do
      allow(Workspace::TimedProcess).to receive(:run).and_raise(Timeout::Error)

      expect(described_class::DEFAULT_GROUP_READER.call(Process.pid)).to be_nil
    end
  end
end
