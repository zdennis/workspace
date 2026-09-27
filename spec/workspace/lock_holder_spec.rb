require "spec_helper"

RSpec.describe Workspace::LockHolder do
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:provider) { Workspace::AgentProvider.find("claude") }
  let(:env) { {} }

  subject(:holder) { described_class.new(process_tree: process_tree, providers: [provider], env: env) }

  before { allow(process_tree).to receive(:snapshot).and_return(snapshot) }

  describe "#current" do
    context "inside tmux" do
      let(:env) { {"TMUX_PANE" => "%12"} }

      it "falls back to walking down from the pane's process when no ancestor is an agent" do
        allow(snapshot).to receive(:find_ancestor).and_return(nil)
        allow(Open3).to receive(:capture3)
          .with("tmux", "display-message", "-p", "-t", "%12", "#" + "{pane_pid}")
          .and_return(["4200\n", "", instance_double(Process::Status, success?: true)])
        allow(snapshot).to receive(:find_descendant)
          .with(4200, ["claude"], exclude: provider.background_markers, include_root: true)
          .and_return({pid: 4411, ppid: 4200, lstart: "Sat Sep 26 09:12:03 2026", command: "claude", args: "claude"})

        result = holder.current

        expect(result).to eq(kind: "agent", pid: 4411, started: "Sat Sep 26 09:12:03 2026", pane: "%12", worktree: Dir.pwd)
      end

      it "prefers the nearest agent ancestor without asking tmux for the pane" do
        allow(Open3).to receive(:capture3)
        allow(snapshot).to receive(:find_ancestor)
          .with(Process.pid, ["claude"], exclude: provider.background_markers)
          .and_return({pid: 999, ppid: 1, lstart: "start-999", command: "claude", args: "claude"})

        expect(holder.current).to include(pid: 999, started: "start-999")
        expect(Open3).not_to have_received(:capture3)
      end
    end

    context "outside tmux" do
      let(:env) { {} }

      it "walks ancestors to find the nearest matching agent process" do
        allow(snapshot).to receive(:find_ancestor)
          .with(Process.pid, ["claude"], exclude: provider.background_markers)
          .and_return({pid: 555, ppid: 1, lstart: "start-555", command: "claude", args: "claude"})

        result = holder.current

        expect(result).to eq(kind: "agent", pid: 555, started: "start-555", pane: nil, worktree: Dir.pwd)
      end

      it "returns nil when no agent process can be found" do
        allow(snapshot).to receive(:find_ancestor).and_return(nil)

        expect(holder.current).to be_nil
      end
    end
  end

  describe "#current with the default provider registry" do
    subject(:holder) { described_class.new(process_tree: process_tree, env: env) }

    let(:env) { {} }
    let(:snapshot) { Workspace::ProcessTree::Snapshot.new(processes) }

    def process(pid, ppid, args)
      {pid: pid, ppid: ppid, lstart: "start-#{pid}", command: args.split.first, args: args}
    end

    context "when the calling agent is not Claude Code" do
      let(:processes) do
        [
          process(1, 0, "launchd"),
          process(700, 1, "codex"),
          process(701, 700, "/bin/zsh -c workspace lock"),
          process(Process.pid, 701, "ruby bin/workspace lock")
        ]
      end

      it "resolves to that agent's process" do
        expect(holder.current).to include(pid: 700, started: "start-700")
      end
    end

    context "when the calling agent is Claude Code" do
      let(:processes) do
        [
          process(1, 0, "launchd"),
          process(800, 1, "claude"),
          process(801, 800, "claude daemon run"),
          process(Process.pid, 800, "ruby bin/workspace lock")
        ]
      end

      it "still resolves to the claude process, skipping its background helpers" do
        expect(holder.current).to include(pid: 800, started: "start-800")
      end
    end

    context "when a second agent was launched from inside another in the same pane" do
      let(:env) { {"TMUX_PANE" => "%12"} }
      let(:processes) do
        [
          process(1, 0, "launchd"),
          process(4200, 1, "-zsh"),
          process(4300, 4200, "claude"),
          process(4350, 4300, "/bin/zsh -c codex"),
          process(4400, 4350, "codex"),
          process(Process.pid, 4400, "ruby bin/workspace lock")
        ]
      end

      before do
        allow(Open3).to receive(:capture3)
          .with("tmux", "display-message", "-p", "-t", "%12", "#" + "{pane_pid}")
          .and_return(["4200\n", "", instance_double(Process::Status, success?: true)])
      end

      it "resolves to the nearest agent above the caller, not the outermost one in the pane" do
        expect(holder.current).to include(pid: 4400, started: "start-4400", pane: "%12")
      end
    end

    context "when the caller has no agent ancestor inside tmux" do
      let(:env) { {"TMUX_PANE" => "%12"} }
      let(:processes) do
        [
          process(1, 0, "launchd"),
          process(4200, 1, "-zsh"),
          process(4300, 4200, "claude"),
          process(Process.pid, 1, "ruby bin/workspace lock")
        ]
      end

      before do
        allow(Open3).to receive(:capture3)
          .with("tmux", "display-message", "-p", "-t", "%12", "#" + "{pane_pid}")
          .and_return(["4200\n", "", instance_double(Process::Status, success?: true)])
      end

      it "falls back to the agent running in the pane" do
        expect(holder.current).to include(pid: 4300, started: "start-4300")
      end
    end
  end

  describe "#start_time" do
    it "returns the process's lstart" do
      allow(snapshot).to receive(:find).with(123).and_return({pid: 123, lstart: "start-123"})

      expect(holder.start_time(123)).to eq("start-123")
    end

    it "returns nil for an unknown pid" do
      allow(snapshot).to receive(:find).with(123).and_return(nil)

      expect(holder.start_time(123)).to be_nil
    end
  end

  describe "#alive?" do
    it "is true when the pid is running with a matching start time" do
      allow(snapshot).to receive(:find).with(100).and_return({pid: 100, lstart: "start-100"})

      expect(holder.alive?(pid: 100, started: "start-100")).to be true
    end

    it "is false when the pid is not running" do
      allow(snapshot).to receive(:find).with(100).and_return(nil)

      expect(holder.alive?(pid: 100, started: "start-100")).to be false
    end

    it "is false when the pid was reused (start time no longer matches)" do
      allow(snapshot).to receive(:find).with(100).and_return({pid: 100, lstart: "different-start"})

      expect(holder.alive?(pid: 100, started: "start-100")).to be false
    end

    it "is false for a nil pid" do
      expect(holder.alive?(pid: nil, started: "start-100")).to be false
    end

    it "raises when the process table cannot be read" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")

      expect { holder.alive?(pid: 100, started: "start-100") }.to raise_error(Workspace::Error)
    end
  end

  describe "#within_snapshot" do
    it "answers every check inside the block from one snapshot" do
      allow(snapshot).to receive(:find).and_return({pid: 100, lstart: "start-100"})

      holder.within_snapshot do
        holder.alive?(pid: 100, started: "start-100")
        holder.alive?(pid: 100, started: "start-100")
        holder.start_time(100)
      end

      expect(process_tree).to have_received(:snapshot).once
    end

    it "takes a fresh snapshot for each check outside a block" do
      allow(snapshot).to receive(:find).and_return(nil)

      holder.alive?(pid: 100, started: "start-100")
      holder.alive?(pid: 100, started: "start-100")

      expect(process_tree).to have_received(:snapshot).twice
    end

    it "does not retry a failed snapshot within the block" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")

      holder.within_snapshot do
        2.times { expect { holder.alive?(pid: 100, started: "s") }.to raise_error(Workspace::Error) }
      end

      expect(process_tree).to have_received(:snapshot).once
    end
  end
end
