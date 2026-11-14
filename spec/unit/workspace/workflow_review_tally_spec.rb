require "spec_helper"
require "digest"
require "tmpdir"

RSpec.describe Workspace::WorkflowReviewTally do
  # Answers each verdict path from +answers+ (default: proven, by a sub-agent named after the file, with the file's hash now).
  proof_stub = Class.new do
    attr_reader :calls

    def initialize(answers = {})
      @answers = answers
      @calls = []
    end

    def proven?(round_dir:, path:, review_pane:, workspace:)
      @calls << [File.basename(path), review_pane, workspace]
      @answers.fetch(File.basename(path, ".md")) do
        {ok: true, agent_id: "agent-#{File.basename(path, ".md")}", sha256: Digest::SHA256.file(path).hexdigest, problem: nil}
      end
    end
  end
  before { stub_const("ProofStub", proof_stub) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:artifacts) { File.join(@dir, "app", ".workflow", "wr_1") }
  let(:round_dir) { File.join(artifacts, "reviews", "plan.2.r1") }
  let(:review) { {"from" => %w[skeptic supportive implementer], "need" => 2, "must" => ["skeptic"]} }
  let(:step) { {"id" => "plan", "review" => review} }
  let(:round) { {"round" => 1, "pane" => "%9", "revision" => "rev1", "started_at" => "2026-11-10T11:30:00.000Z"} }
  let(:proof) { ProofStub.new }
  subject(:tally) { described_class.new(proof: proof) }

  def run_hash
    {"id" => "wr_1", "workspace" => "app", "worktree" => File.join(@dir, "app"), "artifacts_dir" => artifacts, "current" => "plan",
     "steps" => {"plan" => {"state" => "reviewing", "attempts" => [{"n" => 1}, {"n" => 2}]}}}
  end

  def verdict(reviewer, verdict, revision: "rev1", name: reviewer, body: "Because.\n")
    FileUtils.mkdir_p(round_dir)
    File.write(File.join(round_dir, "#{name}.md"), (described_class.header_lines(reviewer: reviewer, verdict: verdict, revision: revision) + ["", body]).join("\n"))
  end

  def call = tally.call(run: run_hash, step: step, round: round)

  def row(result, name) = result[:reviews].find { |each| each["reviewer"] == name }

  describe ".header_lines" do
    it "round-trips through .parse" do
      lines = described_class.header_lines(reviewer: "skeptic", verdict: "reject", revision: "abc123")

      expect(lines).to eq(["reviewer: skeptic", "verdict: reject", "revision: abc123"])
      expect(described_class.parse((lines + ["", "Free text.", "verdict: approve"]).join("\r\n"))).to eq("reviewer" => "skeptic", "verdict" => "reject", "revision" => "abc123")
      expect(described_class::HEADER_KEYS).to eq(%w[reviewer verdict revision])
      expect(described_class::VERDICTS).to eq(%w[approve reject])
    end

    it "refuses a verdict it does not know and a value that is not one line" do
      expect { described_class.header_lines(reviewer: "skeptic", verdict: "maybe", revision: "r") }.to raise_error(ArgumentError, /verdict/)
      expect { described_class.header_lines(reviewer: "a\nverdict: approve", verdict: "approve", revision: "r") }.to raise_error(ArgumentError, /reviewer/)
      expect { described_class.header_lines(reviewer: "skeptic", verdict: "approve", revision: " ") }.to raise_error(ArgumentError, /revision/)
    end

    it "parses nothing whose first lines are not the header in order" do
      expect(described_class.parse("verdict: approve\nreviewer: skeptic\nrevision: r\n")).to be_nil
      expect(described_class.parse("reviewer: skeptic\nverdict: approve\n")).to be_nil
      expect(described_class.parse("reviewer:\nverdict: approve\nrevision: r\n")).to be_nil
      expect(described_class.parse("reviewer: skeptic\nverdict: approve\nrevision: r\xFF\n")).to be_nil
    end
  end

  describe "#call" do
    it "approves once need is met and every must is among the approvals, each row counted and proven" do
      verdict("skeptic", "approve")
      verdict("supportive", "approve")
      verdict("implementer", "reject")

      result = call

      expect(result).to include(outcome: :approved, approvals: 2, need: 2, must: ["skeptic"])
      expect(result).not_to have_key(:problem)
      expect(row(result, "skeptic")).to eq("reviewer" => "skeptic", "path" => "reviews/plan.2.r1/skeptic.md", "verdict" => "approve", "revision" => "rev1",
        "agent_id" => "agent-skeptic", "sha256" => Digest::SHA256.file(File.join(round_dir, "skeptic.md")).hexdigest, "counted" => true, "problem" => nil)
      expect(proof.calls).to contain_exactly(["skeptic.md", "%9", "app"], ["supportive.md", "%9", "app"], ["implementer.md", "%9", "app"])
    end

    it "approves with a verdict missing when the rest already decide it" do
      verdict("skeptic", "approve")
      verdict("supportive", "approve")

      result = call

      expect(result[:outcome]).to eq(:approved)
      expect(row(result, "implementer")).to include("counted" => false, "problem" => "missing")
    end

    it "rejects when a must reviewer rejects" do
      verdict("skeptic", "reject")
      verdict("supportive", "approve")
      verdict("implementer", "approve")

      expect(call).to include(outcome: :rejected, approvals: 2)
    end

    it "rejects when the verdicts not counted could not bring the approvals to need" do
      verdict("skeptic", "approve")
      verdict("supportive", "reject")
      verdict("implementer", "reject")

      expect(call).to include(outcome: :rejected, approvals: 1)
    end

    it "is incomplete, never rejected, while a missing or broken verdict could still decide it" do
      verdict("skeptic", "approve")
      verdict("supportive", "reject")

      result = call

      expect(result[:outcome]).to eq(:incomplete)
      expect(result).to include(problem: "no counted verdict from implementer (missing)", approvals: 1)
    end

    {
      "a link" => ["symlink", ->(t) { File.symlink(File.join(Dir.tmpdir, "elsewhere.md"), File.join(t.round_dir, "skeptic.md")) }],
      "an empty file" => ["empty", ->(t) { File.write(File.join(t.round_dir, "skeptic.md"), "") }],
      "a directory" => ["not_regular_file", ->(t) { Dir.mkdir(File.join(t.round_dir, "skeptic.md")) }],
      "a file with no header" => ["bad_header", ->(t) { File.write(File.join(t.round_dir, "skeptic.md"), "I approve.\n") }],
      "a wrong reviewer line" => ["wrong_reviewer", ->(t) { t.verdict("supportive", "approve", name: "skeptic") }],
      "a verdict naming another revision" => ["wrong_revision", ->(t) { t.verdict("skeptic", "approve", revision: "rev0") }],
      "a verdict it does not know" => ["bad_verdict", ->(t) { File.write(File.join(t.round_dir, "skeptic.md"), "reviewer: skeptic\nverdict: fine\nrevision: rev1\n") }]
    }.each do |what, (problem, make)|
      it "does not count #{what} (#{problem})" do
        FileUtils.mkdir_p(round_dir)
        verdict("supportive", "approve")
        verdict("implementer", "approve")
        make.call(self)

        result = call

        expect(row(result, "skeptic")).to include("counted" => false, "problem" => problem)
        expect(result[:outcome]).to eq(:incomplete)
      end
    end

    it "does not count a verdict the proof does not prove, nor one whose bytes changed after it was read" do
      verdict("skeptic", "approve")
      verdict("supportive", "approve")
      verdict("implementer", "approve")
      proof = ProofStub.new("skeptic" => {ok: false, agent_id: nil, sha256: nil, problem: "main_thread"},
        "supportive" => {ok: true, agent_id: "agent-s", sha256: "0" * 64, problem: nil})

      result = described_class.new(proof: proof).call(run: run_hash, step: step, round: round)

      expect(row(result, "skeptic")).to include("counted" => false, "problem" => "main_thread")
      expect(row(result, "supportive")).to include("counted" => false, "problem" => "changed", "agent_id" => "agent-s")
      expect(result).to include(outcome: :incomplete, approvals: 1, problem: "no counted verdict from skeptic (main_thread), supportive (changed)")
    end

    it "counts none of the verdicts one sub-agent wrote for two reviewers" do
      verdict("skeptic", "approve")
      verdict("supportive", "approve")
      verdict("implementer", "approve")
      same = ->(name) { {ok: true, agent_id: "agent-1", sha256: Digest::SHA256.file(File.join(round_dir, "#{name}.md")).hexdigest, problem: nil} }
      proof = ProofStub.new("skeptic" => same.call("skeptic"), "supportive" => same.call("supportive"))

      result = described_class.new(proof: proof).call(run: run_hash, step: step, round: round)

      expect(row(result, "skeptic")).to include("counted" => false, "problem" => "same_agent")
      expect(row(result, "supportive")).to include("counted" => false, "problem" => "same_agent")
      expect(row(result, "implementer")).to include("counted" => true)
      expect(result[:outcome]).to eq(:incomplete)
    end

    it "counts nothing in a round directory reached through a link" do
      FileUtils.mkdir_p(File.join(@dir, "real"))
      FileUtils.mkdir_p(artifacts)
      File.symlink(File.join(@dir, "real"), File.join(artifacts, "reviews"))
      verdict("skeptic", "approve")
      verdict("supportive", "approve")

      result = call

      expect(result[:reviews].map { |each| each["problem"] }.uniq).to eq(["round_dir_link"])
      expect(result[:outcome]).to eq(:incomplete)
      expect(proof.calls).to be_empty
    end

    it "counts nothing for a round with no review pane or no revision" do
      verdict("skeptic", "approve")

      expect(tally.call(run: run_hash, step: step, round: round.except("pane"))[:reviews].map { |each| each["problem"] }.uniq).to eq(["no_review_pane"])
      expect(tally.call(run: run_hash, step: step, round: round.except("revision"))[:reviews].map { |each| each["problem"] }.uniq).to eq(["no_revision"])
    end

    it "needs every reviewer when need is not set" do
      verdict("skeptic", "approve")
      verdict("supportive", "approve")

      result = tally.call(run: run_hash, step: {"id" => "plan", "review" => {"from" => %w[skeptic supportive implementer]}}, round: round)

      expect(result).to include(outcome: :incomplete, need: 3, must: [])
    end

    describe "need and must" do
      it "is incomplete when a must reviewer is missing, though the other approvals reach need" do
        verdict("supportive", "approve")
        verdict("implementer", "approve")

        result = call

        expect(result).to include(outcome: :incomplete, approvals: 2, problem: "no counted verdict from skeptic (missing)")
      end

      it "rejects at once when need is more than the reviewers in from" do
        verdict("skeptic", "approve")
        verdict("supportive", "approve")
        verdict("implementer", "approve")

        expect(tally.call(run: run_hash, step: {"id" => "plan", "review" => review.merge("need" => 4)}, round: round)).to include(outcome: :rejected, approvals: 3, need: 4)
      end

      it "approves with exactly need counted approvals and the must among them" do
        verdict("skeptic", "approve")
        verdict("supportive", "reject")
        verdict("implementer", "approve")

        expect(call).to include(outcome: :approved, approvals: 2, need: 2)
      end
    end

    it "is incomplete, never approved, for a step with no review, no reviewers or need 0" do
      [{"id" => "plan"}, {"id" => "plan", "review" => {"from" => []}}, {"id" => "plan", "review" => review.merge("need" => 0, "must" => [])}].each do |each|
        result = tally.call(run: run_hash, step: each, round: round)

        expect(result).to include(outcome: :incomplete, reviews: [], approvals: 0)
        expect(result[:problem]).to match(/no reviewers/)
      end
      expect(proof.calls).to be_empty
    end

    it "reads a verdict past a leading byte order mark and without case, and nothing else leniently" do
      FileUtils.mkdir_p(round_dir)
      File.write(File.join(round_dir, "skeptic.md"), "﻿reviewer: skeptic\nverdict: Approve\nrevision: rev1\n")
      File.write(File.join(round_dir, "supportive.md"), "reviewer: Supportive\nverdict: approve\nrevision: rev1\n")
      File.write(File.join(round_dir, "implementer.md"), "reviewer: implementer\nverdict: approve\nrevision: REV1\n")

      result = call

      expect(row(result, "skeptic")).to include("verdict" => "approve", "counted" => true)
      expect(row(result, "supportive")).to include("problem" => "wrong_reviewer")
      expect(row(result, "implementer")).to include("problem" => "wrong_revision")
      expect(described_class.parse("﻿reviewer: a\nverdict: REJECT\nrevision: r\n")).to eq("reviewer" => "a", "verdict" => "REJECT", "revision" => "r")
    end

    it "does not count a file past the size cap (too_large)" do
      FileUtils.mkdir_p(round_dir)
      File.write(File.join(round_dir, "skeptic.md"), (described_class.header_lines(reviewer: "skeptic", verdict: "approve", revision: "rev1") + ["x" * described_class::MAX_BYTES]).join("\n"))

      expect(row(call, "skeptic")).to include("counted" => false, "problem" => "too_large")
    end

    it "does not count a verdict the proof refuses without saying why (unproven)" do
      verdict("skeptic", "approve")
      proof = ProofStub.new("skeptic" => {ok: false, agent_id: nil, sha256: nil, problem: nil})

      expect(row(described_class.new(proof: proof).call(run: run_hash, step: step, round: round), "skeptic")).to include("counted" => false, "problem" => "unproven")
    end

    it "counts nothing when the round's directory is missing (round_dir_missing) or can't be named (no_round_dir)" do
      expect(call[:reviews].map { |each| each["problem"] }.uniq).to eq(["round_dir_missing"])
      expect(tally.call(run: run_hash.merge("artifacts_dir" => nil), step: step, round: round)[:reviews].map { |each| each["problem"] }.uniq).to eq(["no_round_dir"])
      expect(tally.call(run: run_hash, step: step, round: round.except("round"))[:reviews].map { |each| each["path"] }.uniq).to eq([nil])
    end

    it "reads the files through the reader it was given" do
      files = instance_double(Workspace::WorkflowReviewTally::Files, directory_problem: nil)
      allow(files).to receive(:read).and_return({problem: "unreadable"})

      result = described_class.new(proof: proof, files: files).call(run: run_hash, step: step, round: round)

      expect(result[:reviews].map { |each| each["problem"] }.uniq).to eq(["unreadable"])
      expect(files).to have_received(:read).with(File.join(round_dir, "skeptic.md"))
    end
  end

  describe "#open_round" do
    it "makes the round's directory for the run's current step and last attempt" do
      expect(tally.open_round(run: run_hash, round: 1)).to be_nil
      expect(File.directory?(round_dir)).to be(true)
    end

    it "is review_tampered when anything is already at the round's path" do
      FileUtils.mkdir_p(round_dir)

      expect(tally.open_round(run: run_hash, round: 1)).to include(code: "review_tampered", problem: /was there before the round began/)
    end

    it "is review_tampered when the reviews directory is a link" do
      FileUtils.mkdir_p([artifacts, File.join(@dir, "real")])
      File.symlink(File.join(@dir, "real"), File.join(artifacts, "reviews"))

      expect(tally.open_round(run: run_hash, round: 1)).to include(code: "review_tampered", problem: /through a link/)
      expect(Dir.children(File.join(@dir, "real"))).to be_empty
    end

    it "is review_incomplete when the directory can't be made or the run has none" do
      FileUtils.mkdir_p(File.dirname(artifacts))
      File.write(artifacts, "not a directory")

      expect(tally.open_round(run: run_hash, round: 1)).to include(code: "review_incomplete", problem: /could not make/)
      expect(tally.open_round(run: run_hash.merge("artifacts_dir" => nil), round: 1)).to include(code: "review_incomplete")
    end
  end
end
