RSpec.describe Workspace::ProcessTree do
  # Columns as macOS `ps -axo pid=,ppid=,lstart=,comm=,args=` actually emits
  # them: lstart is always five whitespace-separated tokens, comm is
  # truncated at 16 characters (so any absolute path is mangled there and
  # only argv[0] is trustworthy).
  let(:ps_output) do
    <<~PS
      1     0 Thu Jan  1 00:00:00 1970 launchd         /sbin/launchd
      100   1 Fri Sep 25 08:00:00 2026 zsh             -zsh
      200 100 Fri Sep 25 08:00:01 2026 /private/tmp/cla /private/tmp/fakebin/claude --fork-session
      300 200 Fri Sep 25 08:00:02 2026 node            node /opt/helper.js
      400   1 Fri Sep 25 08:00:03 2026 claude bg-pty-ho claude bg-pty-host --bg-pty-host /tmp/x.sock
      500 100 Fri Sep 25 08:00:04 2026 /Users/zdennis/. /Users/zdennis/.local/share/claude/versions/2.1.282 --session-id abc
      600 100 Fri Sep 25 08:00:05 2026 claude          claude daemon run --origin transient
      700 600 Fri Sep 25 08:00:06 2026 bash            bash -c sleep 1
    PS
  end

  subject(:tree) { described_class.new }

  before do
    allow(Open3).to receive(:capture3)
      .with({"LC_ALL" => "C", "TZ" => "UTC"}, "ps", "-axo", "pid=,ppid=,lstart=,comm=,args=")
      .and_return([ps_output, "", instance_double(Process::Status, success?: true)])
  end

  describe "lstart parsing" do
    it "captures the five-token start time alongside the other columns" do
      expect(tree.snapshot.find(200)).to include(pid: 200, ppid: 100, lstart: "Fri Sep 25 08:00:01 2026")
    end
  end

  describe "#snapshot" do
    it "raises when ps fails, rather than reporting every process as exited" do
      allow(Open3).to receive(:capture3)
        .and_return(["", "ps: fork failed", instance_double(Process::Status, success?: false)])

      expect { tree.snapshot }.to raise_error(Workspace::Error, /ps failed/)
    end
  end

  describe "#descendants" do
    it "walks the whole subtree, not just direct children" do
      expect(tree.snapshot.descendants(100).map { |p| p[:pid] }).to contain_exactly(200, 300, 500, 600, 700)
    end

    it "excludes the root itself" do
      expect(tree.snapshot.descendants(100).map { |p| p[:pid] }).not_to include(100)
    end

    it "returns nothing for a leaf" do
      expect(tree.snapshot.descendants(300)).to be_empty
    end
  end

  describe "#find_descendant" do
    it "matches on argv[0] when comm is truncated" do
      expect(tree.snapshot.find_descendant(100, ["claude"])[:pid]).to eq(200)
    end

    it "matches a versioned install by path segment" do
      expect(tree.snapshot.find_descendant(500, ["claude"], include_root: true)[:pid]).to eq(500)
    end

    it "skips processes whose arguments mark them as background helpers" do
      found = tree.snapshot.find_descendant(100, ["claude"], exclude: ["daemon run"])

      expect(found[:pid]).to eq(200)
      expect(tree.snapshot.find_descendant(600, ["claude"], exclude: ["daemon run"], include_root: true))
        .to be_nil
    end

    it "does not consider the root unless asked" do
      expect(tree.snapshot.find_descendant(200, ["claude"])).to be_nil
      expect(tree.snapshot.find_descendant(200, ["claude"], include_root: true)[:pid]).to eq(200)
    end

    it "returns nil when nothing matches" do
      expect(tree.snapshot.find_descendant(100, ["codex"])).to be_nil
    end
  end

  describe "#ancestors" do
    it "walks the ppid chain to the root, nearest first" do
      expect(tree.snapshot.ancestors(300).map { |p| p[:pid] }).to eq([200, 100, 1])
    end

    it "excludes the starting process itself" do
      expect(tree.snapshot.ancestors(300)).not_to include(hash_including(pid: 300))
    end

    it "returns nothing for a process with no known parent" do
      expect(tree.snapshot.ancestors(1)).to be_empty
    end
  end

  describe "#find_ancestor" do
    it "finds the nearest matching ancestor" do
      expect(tree.snapshot.find_ancestor(300, ["claude"])[:pid]).to eq(200)
    end

    it "skips ancestors whose arguments mark them as background helpers" do
      expect(tree.snapshot.find_ancestor(700, ["claude"], exclude: ["daemon run"])).to be_nil
    end

    it "returns nil when no ancestor matches" do
      expect(tree.snapshot.find_ancestor(300, ["codex"])).to be_nil
    end
  end

  describe "background-helper markers" do
    def snapshot_of(*entries)
      Workspace::ProcessTree::Snapshot.new(entries.map do |pid, ppid, args|
        {pid: pid, ppid: ppid, lstart: "start-#{pid}", command: args.split.first, args: args}
      end)
    end

    it "match only the leading subcommand, not the same words later in the arguments" do
      snapshot = snapshot_of([10, 1, "claude -p clean up stale bg-spare helpers"], [11, 10, "bash"])

      expect(snapshot.find_ancestor(11, ["claude"], exclude: ["bg-spare"])[:pid]).to eq(10)
    end

    it "apply a per-name Hash only to processes matched as that name" do
      snapshot = snapshot_of([5, 1, "claude daemon run"], [10, 5, "codex daemon run"], [11, 10, "bash"])
      exclude = {"claude" => ["daemon run"], "codex" => []}

      expect(snapshot.find_ancestor(11, ["claude", "codex"], exclude: exclude)[:pid]).to eq(10)
      expect(snapshot.find_ancestor(10, ["claude", "codex"], exclude: exclude)).to be_nil
    end
  end
end
