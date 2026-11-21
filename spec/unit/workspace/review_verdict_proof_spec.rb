require "spec_helper"
require "digest"
require "json"
require "tmpdir"

RSpec.describe Workspace::ReviewVerdictProof do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:checkout) { File.join(@dir, "app") }
  let(:hook_dir) { File.join(@dir, "events") }
  let(:round_dir) { File.join(checkout, ".workflow", "wr_1", "reviews", "plan.1.r1") }
  let(:path) { File.join(round_dir, "skeptic.md") }
  let(:relative) { ".workflow/wr_1/reviews/plan.1.r1/skeptic.md" }
  let(:log) { Workspace::HookEventLog.path_for(hook_dir, "app") }
  subject(:proof) { described_class.new(hook_dir: hook_dir) }

  before do
    FileUtils.mkdir_p([File.join(checkout, ".git"), round_dir, hook_dir])
    @seq = 0
  end

  def write_verdict(text = "reviewer: skeptic\nverdict: approve\nrevision: r1\n")
    File.write(path, text)
    Digest::SHA256.hexdigest(text)
  end

  # One hook event log line, as the daemon writes it; +seq+ goes up by one unless given.
  def line(file: log, type: "tool_finished", pane: "%9", tool: "Write", agent: "agent-1", path: relative, ok: true, sha: nil, boot: "boot-1", seq: nil, **rest)
    @seq = seq || @seq + 1
    fields = {"type" => type, "at" => "2026-11-10T12:00:00.000Z", "workspace" => "app", "pane_id" => pane, "boot_id" => boot, "seq" => @seq,
              "tool" => tool, "tool_use_id" => "toolu_#{@seq}", "agent_id" => agent, "path" => path}
    fields["ok"] = ok if type == "tool_finished"
    fields["sha256"] = sha if sha
    File.open(file, "a") { |f| f.puts(JSON.generate(fields.merge(rest).compact)) }
  end

  def proven? = proof.proven?(round_dir: round_dir, path: path, review_pane: "%9", workspace: "app")

  it "proves a verdict whose last write was a review pane sub-agent's, with the file's hash now" do
    sha = write_verdict
    line(type: "tool_started", tool: "Read", path: "README.md")
    line(sha: sha)
    line(tool: "Read", path: "plan.md")

    expect(proven?).to eq(ok: true, agent_id: "agent-1", sha256: sha, problem: nil)
  end

  it "proves a verdict against any of the round's panes, and refuses one from a pane not among them" do
    sha = write_verdict
    line(sha: sha, pane: "%9")

    expect(proof.proven?(round_dir: round_dir, path: path, review_pane: %w[%9 %11], workspace: "app")).to include(ok: true)
    expect(proof.proven?(round_dir: round_dir, path: path, review_pane: %w[%11], workspace: "app")).to include(problem: "other_pane")
  end

  it "accepts an Edit after the Write, the last write's agent and hash counting" do
    line(sha: write_verdict("first\n"))
    sha = write_verdict
    line(tool: "Edit", agent: "agent-2", sha: sha)

    expect(proven?).to include(ok: true, agent_id: "agent-2", sha256: sha)
  end

  it "skips a write that failed" do
    sha = write_verdict
    line(sha: sha)
    line(tool: "Edit", agent: "agent-2", ok: false)

    expect(proven?).to include(ok: true, agent_id: "agent-1")
  end

  it "reads the rotated file before the live one" do
    line(file: "#{log}.1", sha: write_verdict("old\n"))
    sha = write_verdict
    line(sha: sha, agent: "agent-3")

    expect(proven?).to include(ok: true, agent_id: "agent-3")
  end

  {
    "the main thread wrote it last" => ["main_thread", {agent: nil}],
    "another pane wrote it last" => ["other_pane", {pane: "%3"}],
    "the write carries no hash" => ["no_hash", {sha: :none}]
  }.each do |what, (problem, fields)|
    it "proves nothing when #{what} (#{problem})" do
      sha = write_verdict
      line(**{sha: sha}.merge(fields).reject { |_, value| value == :none })

      expect(proven?).to include(ok: false, problem: problem)
    end
  end

  it "proves nothing when the file changed after the hook hashed it (hash_mismatch)" do
    line(sha: write_verdict)
    write_verdict("reviewer: skeptic\nverdict: reject\nrevision: r1\n")

    expect(proven?).to include(ok: false, agent_id: "agent-1", problem: "hash_mismatch")
  end

  it "proves nothing with no write to the path (no_write) or no log at all (no_log)" do
    write_verdict
    line(path: ".workflow/wr_1/reviews/plan.1.r1/supportive.md", sha: "0" * 64)

    expect(proven?).to include(ok: false, problem: "no_write")
    expect(described_class.new(hook_dir: File.join(@dir, "none")).proven?(round_dir: round_dir, path: path, review_pane: "%9", workspace: "app")).to include(problem: "no_log")
    expect(described_class.new(hook_dir: nil).proven?(round_dir: round_dir, path: path, review_pane: "%9", workspace: "app")).to include(problem: "no_log")
    expect(proof.proven?(round_dir: round_dir, path: path, review_pane: "%9", workspace: "../app")).to include(problem: "no_log")
  end

  it "proves nothing when a line after the write is missing or another daemon's" do
    sha = write_verdict
    line(sha: sha)
    line(tool: "Read", path: "a.md", seq: @seq + 2)

    expect(proven?).to include(ok: false, problem: "log_gap")

    File.delete(log)
    line(sha: sha, seq: 1)
    line(tool: "Read", path: "a.md", boot: "boot-2", seq: 1)

    expect(proven?).to include(ok: false, problem: "log_gap")
  end

  it "carries seq across the rotated file into the live one" do
    sha = write_verdict
    line(file: "#{log}.1", sha: sha, seq: 7)
    line(tool: "Read", path: "a.md", seq: 8)

    expect(proven?).to include(ok: true)

    File.delete(log)
    line(tool: "Read", path: "a.md", seq: 10)

    expect(proven?).to include(ok: false, problem: "log_gap")
  end

  it "proves nothing when the file can't be read now (unreadable)" do
    sha = write_verdict
    line(sha: sha)
    File.rename(path, "#{path}.real")
    File.symlink("#{path}.real", path)

    expect(proven?).to include(ok: false, agent_id: "agent-1", problem: "unreadable")
  end

  it "does not mind a gap before the write" do
    sha = write_verdict
    line(tool: "Read", path: relative, seq: 4)
    line(sha: sha, seq: 9)
    line(tool: "Read", path: "a.md")

    expect(proven?).to include(ok: true)
  end

  it "proves nothing for a path outside the round's checkout" do
    write_verdict
    line(sha: "0" * 64)

    expect(proof.proven?(round_dir: round_dir, path: File.join(@dir, "skeptic.md"), review_pane: "%9", workspace: "app")).to include(problem: "outside_checkout")
  end

  describe "a direct round (direct: true)" do
    def direct(target: path, flag: true) = proof.proven?(round_dir: round_dir, path: target, review_pane: "%9", workspace: "app", direct: flag)

    it "proves a main-thread write of the review pane as main:<pane_id>, which a round with sub-agents refuses" do
      sha = write_verdict
      line(sha: sha, agent: nil)
      line(tool: "Read", path: "plan.md", agent: nil)

      expect(direct).to eq(ok: true, agent_id: "main:%9", sha256: sha, problem: nil)
      expect(proven?).to include(ok: false, problem: "main_thread")
    end

    it "still proves a sub-agent's write by its own id" do
      line(sha: write_verdict)

      expect(direct).to include(ok: true, agent_id: "agent-1")
    end

    it "refuses an agent id that is there but empty, and a direct: other than true" do
      line(sha: write_verdict, agent: "")

      expect(direct).to include(ok: false, problem: "main_thread")

      File.delete(log)
      line(sha: write_verdict, agent: nil)

      expect(direct(flag: "true")).to include(ok: false, problem: "main_thread")
    end

    it "refuses a main-thread write from a pane not among the round's (other_pane)" do
      line(sha: write_verdict, agent: nil, pane: "%3")

      expect(direct).to include(ok: false, problem: "other_pane")
    end

    it "refuses a main-thread write edited afterwards (hash_mismatch)" do
      line(sha: write_verdict, agent: nil)
      write_verdict("reviewer: skeptic\nverdict: reject\nrevision: r1\n")

      expect(direct).to include(ok: false, agent_id: "main:%9", problem: "hash_mismatch")
    end

    it "refuses a main-thread write followed by a missing line (log_gap)" do
      line(sha: write_verdict, agent: nil)
      line(tool: "Read", path: "a.md", agent: nil, seq: @seq + 2)

      expect(direct).to include(ok: false, problem: "log_gap")
    end

    it "refuses a main-thread write the hook did not hash, as it hashes none outside the round directory (no_hash)" do
      write_verdict
      line(agent: nil)

      expect(direct).to include(ok: false, problem: "no_hash")
    end

    it "refuses a path outside the checkout, no write, no log and an unreadable file" do
      sha = write_verdict
      line(path: ".workflow/wr_1/reviews/plan.1.r1/supportive.md", sha: "0" * 64, agent: nil)

      expect(direct).to include(ok: false, problem: "no_write")
      expect(direct(target: File.join(@dir, "skeptic.md"))).to include(problem: "outside_checkout")
      expect(described_class.new(hook_dir: File.join(@dir, "none"))
        .proven?(round_dir: round_dir, path: path, review_pane: "%9", workspace: "app", direct: true)).to include(problem: "no_log")

      line(sha: sha, agent: nil)
      File.rename(path, "#{path}.real")
      File.symlink("#{path}.real", path)

      expect(direct).to include(ok: false, problem: "unreadable")
    end
  end
end
