require "spec_helper"

RSpec.describe Workspace::LockHolder, "adversarial identity resolution" do
  subject(:holder) { described_class.new(process_tree: process_tree, env: {}) }

  let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new(processes)) }

  def process(pid, ppid, args)
    {pid: pid, ppid: ppid, lstart: "start-#{pid}", command: args.split.first, args: args}
  end

  context "when a nested Codex session's prompt mentions a Claude helper marker" do
    let(:processes) do
      [
        process(1, 0, "launchd"),
        process(600, 1, "claude"),
        process(650, 600, "/bin/zsh -c codex"),
        process(700, 650, "codex restart the daemon run by launchd"),
        process(750, 700, "/bin/zsh -lc workspace lock acquire edit"),
        process(Process.pid, 750, "ruby bin/workspace lock acquire edit")
      ]
    end

    it "LH1: resolves to the Codex process, not the outer Claude (Claude-only markers must not disqualify other providers)" do
      expect(holder.current).to include(pid: 700, started: "start-700")
    end
  end

  context "when a nested `claude -p` prompt contains a background-helper marker" do
    let(:processes) do
      [
        process(1, 0, "launchd"),
        process(600, 1, "claude"),
        process(650, 600, "/bin/zsh -c claude -p 'clean up stale bg-spare helpers'"),
        process(700, 650, "claude -p clean up stale bg-spare helpers"),
        process(750, 700, "/bin/zsh -c workspace session-event"),
        process(Process.pid, 750, "ruby bin/workspace session-event")
      ]
    end

    it "LH2: resolves to the inner claude, not the outer one (markers must match the helper subcommand, not prompt text)" do
      expect(holder.current).to include(pid: 700, started: "start-700")
    end
  end
end
