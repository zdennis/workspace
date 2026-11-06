require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowAttemptRecord do
  around do |example|
    Dir.mktmpdir("wf-record") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:guard) { instance_double(Workspace::WorkflowGuard, head: "a" * 40) }
  let(:max_hash_bytes) { described_class::MAX_HASH_BYTES }
  let(:max_transcript_bytes) { described_class::MAX_TRANSCRIPT_BYTES }
  subject(:record) { described_class.new(guard: guard, max_hash_bytes: max_hash_bytes) }
  let(:run) do
    {"worktree" => @dir, "artifacts_dir" => File.join(@dir, "art"), "definition_sha256" => "d" * 64, "current" => "plan",
     "definition" => {"steps" => [{"id" => "plan", "produces" => ["plan.md"]}]}, "steps" => {"plan" => {"attempts" => [{"n" => 1}]}}}
  end
  let(:step) { {"id" => "plan", "produces" => ["plan.md"]} }

  before { FileUtils.mkdir_p(run["artifacts_dir"]) }

  def put(name, text)
    File.write(File.join(run["artifacts_dir"], name), text)
  end

  describe "#start" do
    it "records HEAD, the definition, the prompt hash and each pack" do
      attempt = {"n" => 1}
      record.start(run: run, attempt: attempt, composed: {"text" => "hi\n", "packs" => [{"ref" => "play/x", "sha256" => "f" * 64, "extra" => 1}]})

      expect(attempt).to eq("n" => 1, "head" => {"before" => "a" * 40, "after" => nil}, "definition_sha256" => "d" * 64,
        "prompt_sha256" => Digest::SHA256.hexdigest("hi\n"), "packs" => [{"ref" => "play/x", "sha256" => "f" * 64}])
    end

    it "never reads the remote: it runs under the run's lock" do
      allow(guard).to receive(:remote_head)
      run["definition"]["steps"][0]["require"] = [{"remote_unchanged" => true}]
      record.start(run: run, attempt: {"n" => 1}, composed: {"text" => "", "packs" => []})
      expect(guard).not_to have_received(:remote_head)
    end
    it "leaves out a definition hash a run was stored without" do
      attempt = {"n" => 1}
      record.start(run: run.except("definition_sha256"), attempt: attempt, composed: {"text" => "", "packs" => []})

      expect(attempt).not_to have_key("definition_sha256")
    end
  end

  describe "evidence" do
    let(:evidence_budget) { Workspace::WorkflowEvidence::BUDGET }
    let(:evidence) { Workspace::WorkflowEvidence.new(dir: File.join(@dir, "ev"), budget: evidence_budget) }
    subject(:record) { described_class.new(guard: guard, evidence: evidence) }
    let(:run) { super().merge("id" => "wr_1") }
    let(:prompt) { File.join(run["artifacts_dir"], "steps", "plan.1.prompt.md") }

    before do
      FileUtils.mkdir_p(File.dirname(prompt))
      File.write(prompt, "p")
    end

    it "copies the prompt on #start, before anything can change it" do
      attempt = {"n" => 1, "prompt_file" => prompt}
      record.start(run: run, attempt: attempt, composed: {"text" => "p", "packs" => []})
      File.write(prompt, "rewritten")

      expect(attempt["evidence"].map { |e| [e["name"], e["sha256"]] }).to eq([["plan.1.prompt.md", Digest::SHA256.hexdigest("p")]])
    end

    it "keeps the prompt entry and adds the outputs on #finish" do
      put("plan.md", "o")
      attempt = {"n" => 1, "prompt_file" => prompt}
      record.start(run: run, attempt: attempt, composed: {"text" => "p", "packs" => []})
      record.finish(run: run, step: step, attempt: attempt)
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["evidence"].map { |e| e["name"] }).to eq(%w[plan.1.prompt.md plan.1.out.0.plan.md])
    end

    it "takes each output's hash from the one copy" do
      put("plan.md", "o")
      attempt = {"n" => 1}
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => attempt["evidence"].last["sha256"], "bytes" => 1}])
    end

    context "with no copy budget" do
      let(:evidence_budget) { 0 }

      it "still hashes an output that the budget kept from the copy" do
        put("plan.md", "o")
        attempt = {"n" => 1}
        record.finish(run: run, step: step, attempt: attempt)

        expect(attempt["evidence"].last).to include("sha256" => nil, "budget" => true)
        expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => Digest::SHA256.hexdigest("o"), "bytes" => 1}])
      end
    end

    it "records a nil hash for an output evidence refused as outside the artifacts directory" do
      FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
      File.write(File.join(@dir, "elsewhere", "plan.md"), "key")
      File.symlink(File.join(@dir, "elsewhere"), File.join(run["artifacts_dir"], "sub"))
      attempt = {"n" => 1}
      record.finish(run: run, step: {"id" => "plan", "produces" => ["sub/plan.md"]}, attempt: attempt)

      expect(attempt["evidence"].last["problem"]).to eq("outside_artifacts")
      expect(attempt["outputs"]).to eq([{"file" => "sub/plan.md", "sha256" => nil, "bytes" => nil}])
    end

    it "still hashes an output whose copy failed" do
      put("plan.md", "o")
      full_disk = ->(path, flags, mode, &block) { File.open(path, flags, mode) { |io| block.call(Struct.new(:io) { def write(*) = raise(Errno::ENOSPC) }.new(io)) } }
      failing = Workspace::WorkflowEvidence.new(dir: File.join(@dir, "ev"), opener: full_disk)
      attempt = {"n" => 1}
      described_class.new(guard: guard, evidence: failing).finish(run: run, step: step, attempt: attempt)

      expect(attempt["evidence"].last["problem"]).to eq("copy_failed")
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => Digest::SHA256.hexdigest("o"), "bytes" => 1}])
    end

    it "reads each output once" do
      put("plan.md", "o")
      allow(Workspace::WorkflowProduced).to receive(:digest).and_call_original
      record.finish(run: run, step: step, attempt: {"n" => 1})
      expect(Workspace::WorkflowProduced).to have_received(:digest).once
    end

    it "hashes the outputs itself when it has no evidence collaborator" do
      put("plan.md", "o")
      attempt = {"n" => 1}
      described_class.new(guard: guard).finish(run: run, step: step, attempt: attempt)
      expect(attempt["outputs"].first["sha256"]).to eq(Digest::SHA256.hexdigest("o"))
      expect(attempt).not_to have_key("evidence")
    end

    it "is recorded on #abandon for an open attempt" do
      put("plan.md", "o")
      run["steps"]["plan"]["attempts"] = [{"n" => 1, "started_at" => "2026-11-01T09:00:00Z"}]
      record.abandon(run)
      expect(run["steps"]["plan"]["attempts"].last["evidence"].map { |e| e["kind"] }).to eq(%w[output])
    end

    it "reads missing for every entry when the artifacts directory is gone" do
      FileUtils.rm_rf(run["artifacts_dir"])
      run["steps"]["plan"]["attempts"] = [{"n" => 1, "started_at" => "2026-11-01T09:00:00Z"}]
      expect { record.abandon(run) }.not_to raise_error
      expect(run["steps"]["plan"]["attempts"].last["evidence"].map { |e| e["problem"] }).to eq(%w[missing])
      expect(run["steps"]["plan"]["attempts"].last["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => nil}])
    end
  end

  describe "#finish" do
    it "records HEAD now and the hash and size of each output" do
      put("plan.md", "done\n")
      attempt = {"head" => {"before" => "b" * 40, "after" => nil}}
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["head"]).to eq("before" => "b" * 40, "after" => "a" * 40)
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => Digest::SHA256.hexdigest("done\n"), "bytes" => 5}])
    end

    it "gives an empty list for a step with no produces" do
      attempt = {}
      record.finish(run: run, step: {"id" => "plan"}, attempt: attempt)

      expect(attempt["outputs"]).to eq([])
      expect(attempt["head"]).to eq("before" => nil, "after" => "a" * 40)
    end

    it "gives nil for a missing file, a link and a directory" do
      File.symlink("/etc/hosts", File.join(run["artifacts_dir"], "link.md"))
      FileUtils.mkdir(File.join(run["artifacts_dir"], "dir.md"))
      attempt = {}
      record.finish(run: run, step: {"produces" => ["gone.md", "link.md", "dir.md"]}, attempt: attempt)

      expect(attempt["outputs"]).to all(include("sha256" => nil, "bytes" => nil))
      expect(attempt["outputs"].map { |each| each["file"] }).to eq(%w[gone.md link.md dir.md])
    end

    context "with a cap of 4 bytes" do
      let(:max_hash_bytes) { 4 }

      it "does not read a file past the cap, and says so" do
        put("plan.md", "12345")
        attempt = {}
        record.finish(run: run, step: step, attempt: attempt)

        expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => 5, "too_large" => true}])
      end
    end

    context "with a cap of 5 bytes" do
      let(:max_hash_bytes) { 5 }

      it "hashes a file exactly at the cap" do
        put("plan.md", "12345")
        attempt = {}
        record.finish(run: run, step: step, attempt: attempt)

        expect(attempt["outputs"].first).to include("sha256" => Digest::SHA256.hexdigest("12345"), "bytes" => 5)
      end
    end

    it "names the cap as 16 MiB" do
      expect(described_class::MAX_HASH_BYTES).to eq(16 * 1024 * 1024)
    end
  end

  describe "#abandon" do
    it "closes the open attempt with the end fields and adds no outcome" do
      put("plan.md", "x")
      closed = record.abandon(run)

      expect(closed).to include("outputs" => [include("bytes" => 1)], "head" => {"before" => nil, "after" => "a" * 40})
      expect(closed).not_to include("outcome", "ended_at")
    end

    it "leaves an attempt that has ended" do
      run["steps"]["plan"]["attempts"].last["ended_at"] = "2026-10-04T12:00:00Z"

      expect(record.abandon(run)).to be_nil
      expect(run["steps"]["plan"]["attempts"].last).not_to include("outputs")
    end

    it "does nothing for a step with no attempt" do
      run["steps"]["plan"]["attempts"].clear

      expect(record.abandon(run)).to be_nil
    end

    it "never raises" do
      allow(guard).to receive(:head).and_raise("boom")

      expect(record.abandon(run)).to be_nil
      expect(record.abandon({})).to be_nil
    end
  end

  describe "#reasons" do
    let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
    subject(:record) { described_class.new(guard: guard, clock: -> { now.first }) }
    let(:attempt) { run["steps"]["plan"]["attempts"].last }

    def reason(code, since) = {"code" => code, "since" => since, "details" => {}}

    it "opens an entry on the open attempt, then closes it when the reason changes or clears" do
      run["reason"] = reason("turn_ended_incomplete", "2026-10-04T12:00:00Z")
      record.reasons(run: run)
      now[0] += 30
      run["reason"] = reason("failed_check", "2026-10-04T12:00:30Z")
      record.reasons(run: run)
      now[0] += 30
      run["reason"] = nil
      record.reasons(run: run)

      expect(attempt["reasons"]).to eq([
        {"code" => "turn_ended_incomplete", "since" => "2026-10-04T12:00:00Z", "until" => "2026-10-04T12:00:30Z"},
        {"code" => "failed_check", "since" => "2026-10-04T12:00:30Z", "until" => "2026-10-04T12:01:00Z"}
      ])
    end

    it "does not repeat an entry whose code and since stand" do
      run["reason"] = reason("waiting_you", "2026-10-04T12:00:00Z")
      2.times { record.reasons(run: run) }
      run["reason"]["details"] = {"changed" => true}
      record.reasons(run: run)

      expect(attempt["reasons"].size).to eq(1)
    end

    it "records a parked resume as the reason `parked` and ends it when the park goes" do
      run["parked"] = {"requested_at" => "2026-10-04T12:00:00Z"}
      record.reasons(run: run)
      now[0] += 10
      run.delete("parked")
      record.reasons(run: run)

      expect(attempt["reasons"]).to eq([{"code" => "parked", "since" => "2026-10-04T12:00:00Z", "until" => "2026-10-04T12:00:10Z"}])
    end

    it "gives a failed check or a gate wait set as the attempt ends to that attempt" do
      attempt["ended_at"] = "2026-10-04T12:00:00Z"
      run["reason"] = {"code" => "failed_check", "since" => "2026-10-04T12:00:00Z", "details" => {"attempt" => attempt["n"]}}
      record.reasons(run: run, was_open: ["plan", attempt["n"]])
      run["reason"] = {"code" => "waiting_you", "since" => "2026-10-04T12:00:01Z", "details" => {"kind" => "gate"}}
      record.reasons(run: run, was_open: ["plan", attempt["n"]])

      expect(attempt["reasons"].map { |each| each["code"] }).to eq(%w[failed_check waiting_you])
    end

    it "puts any other reason set in the change that ended an attempt (a lock wait on a retry) on the run" do
      attempt["ended_at"] = "2026-10-04T12:00:00Z"
      run["reason"] = reason("waiting_lock", "2026-10-04T12:00:00Z")
      record.reasons(run: run, was_open: ["plan", attempt["n"]])

      expect(attempt).not_to have_key("reasons")
      expect(run["reasons"].map { |each| each["code"] }).to eq(["waiting_lock"])
    end

    it "keeps the wait under a park when a park replaces a park (round 3, 2)" do
      run["reason"] = {"code" => "failed_check", "since" => "2026-10-04T12:00:00Z", "details" => {}}
      record.reasons(run: run)
      run["parked"] = {"requested_at" => "2026-10-04T12:00:05Z"}
      record.reasons(run: run)
      run["parked"] = {"requested_at" => "2026-10-04T12:00:09Z"}
      record.reasons(run: run)
      run.delete("parked")
      record.reasons(run: run)

      expect(attempt["reasons"].map { |e| [e["code"], e["until"]] }).to eq([["failed_check", nil], ["parked", "2026-10-04T12:00:00Z"], ["parked", "2026-10-04T12:00:00Z"]])
    end

    it "leaves an open entry alone in a later change, wherever it sits, even once its attempt has ended" do
      attempt["ended_at"] = "2026-10-04T12:00:00Z"
      run["reason"] = {"code" => "waiting_you", "since" => "2026-10-04T12:00:00Z", "details" => {"kind" => "gate"}}
      record.reasons(run: run, was_open: ["plan", attempt["n"]])
      now[0] += 5
      record.reasons(run: run)
      record.reasons(run: run, was_open: nil)

      expect(attempt["reasons"]).to eq([{"code" => "waiting_you", "since" => "2026-10-04T12:00:00Z", "until" => nil}])
      expect(run).not_to have_key("reasons")
    end

    it "keeps a reason with no attempt to own it on the run, with the step" do
      attempt["ended_at"] = "2026-10-04T11:00:00Z"
      run["reason"] = reason("waiting_lock", "2026-10-04T12:00:00Z")
      record.reasons(run: run)

      expect(attempt).not_to have_key("reasons")
      expect(run["reasons"]).to eq([{"code" => "waiting_lock", "since" => "2026-10-04T12:00:00Z", "until" => nil, "step" => "plan"}])
    end

    it "reads a run stored without any history, and never raises" do
      run["reason"] = reason("waiting_you", "2026-10-04T12:00:00Z")
      expect { record.reasons(run: run) }.not_to raise_error
      expect(record.reasons(run: {})).to be_nil
    end
  end

  describe "session, agent and usage at the end of an attempt" do
    let(:ledger_path) { File.join(@dir, "ledger.jsonl") }
    let(:ledger) { Workspace::SessionLedger.new(path: ledger_path) }
    let(:transcript) { File.join(@dir, "s1.jsonl") }
    let(:server) { [nil] }
    subject(:record) do
      described_class.new(guard: guard, ledger: ledger, clock: -> { Time.utc(2026, 10, 4, 12, 10, 0) },
        session_names: ->(workspace) { [workspace, "tmux-#{workspace}"] }, server_for: ->(_pane) { server.first },
        max_transcript_bytes: max_transcript_bytes)
    end
    let(:attempt) { {"n" => 2, "started_at" => "2026-10-04T12:00:00.000Z", "ended_at" => "2026-10-04T12:05:00Z"} }

    def ledger_line(entry) = File.open(ledger_path, "a") { |f| f.puts(JSON.generate({"workspace" => "tmux-w", "tmux_server" => "99"}.merge(entry))) }

    def start_line(id, at, **more) = ledger_line({"at" => at, "event" => "session_start", "pane_id" => "%5", "session_id" => id, "transcript_path" => transcript}.merge(more))

    def assistant(at, id, input, output, model: "claude-opus-5-5", **extra)
      JSON.generate({"type" => "assistant", "timestamp" => at, "version" => "2.4.1",
                     "message" => {"id" => id, "model" => model, "usage" => {"input_tokens" => input, "output_tokens" => output, "cache_read_input_tokens" => 0}}}.merge(extra))
    end

    def write_transcript(*lines) = File.write(transcript, lines.join("\n") + "\n")

    before do
      run["pane"] = "%5"
      run["workspace"] = "w"
      start_line("old", "2026-10-04T11:00:00Z")
      start_line("s1", "2026-10-04T12:00:01Z")
      write_transcript(
        assistant("2026-10-04T11:30:00Z", "m0", 1000, 100),
        assistant("2026-10-04T12:01:00Z", "m1", 10, 1),
        assistant("2026-10-04T12:01:01Z", "m1", 10, 5),
        assistant("2026-10-04T12:02:00Z", "m2", 20, 7),
        assistant("2026-10-04T12:09:00Z", "m3", 5000, 500)
      )
    end

    it "uses the last session started in the pane by the attempt's end, and sums only the attempt's own window" do
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["session"]).to eq("id" => "s1", "transcript" => transcript)
      expect(attempt["agent"]).to eq("kind" => "claude", "version" => "2.4.1", "model" => "claude-opus-5-5")
      expect(attempt["usage"]).to eq("input_tokens" => 30, "output_tokens" => 12)
    end

    it "counts a message by its last line, even one just past the window (U3)" do
      write_transcript(assistant("2026-10-04T12:04:59Z", "m1", 10, 1), assistant("2026-10-04T12:05:03Z", "m1", 10, 90))
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["usage"]).to eq("input_tokens" => 10, "output_tokens" => 90)
    end

    it "counts two consecutive attempts in one session separately (T3)" do
      first = {"n" => 1, "started_at" => "2026-10-04T12:00:00.000Z", "ended_at" => "2026-10-04T12:01:30Z"}
      second = {"n" => 2, "started_at" => "2026-10-04T12:01:40.000Z", "ended_at" => "2026-10-04T12:05:00Z"}
      record.finish(run: run, step: step, attempt: first)
      record.finish(run: run, step: step, attempt: second)

      expect(first["usage"]).to eq("input_tokens" => 10, "output_tokens" => 5)
      expect(second["usage"]).to eq("input_tokens" => 20, "output_tokens" => 7)
    end

    it "leaves out sub-agent lines (U5)" do
      write_transcript(assistant("2026-10-04T12:01:00Z", "m1", 10, 1), assistant("2026-10-04T12:02:00Z", "side", 9000, 900, "isSidechain" => true))
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["usage"]).to eq("input_tokens" => 10, "output_tokens" => 1)
    end

    it "is nil, not smaller, when a usage line has no readable time (U1)" do
      write_transcript(assistant("2026-10-04T12:01:00Z", "m1", 10, 1), assistant("garbled", "m2", 20, 7))
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["usage"]).to be_nil
      expect(attempt["session"]).to include("id" => "s1")
    end

    it "is nil when a count is present and not a whole number from 0 up, and 0 when a key is absent (U2)" do
      bad = JSON.generate("type" => "assistant", "timestamp" => "2026-10-04T12:01:00Z", "message" => {"id" => "b", "usage" => {"input_tokens" => "7", "output_tokens" => 1}})
      write_transcript(bad)
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["usage"]).to be_nil

      negative = JSON.generate("type" => "assistant", "timestamp" => "2026-10-04T12:01:00Z", "message" => {"id" => "n", "usage" => {"input_tokens" => -1, "output_tokens" => 1}})
      write_transcript(negative)
      again = attempt.except("usage")
      record.finish(run: run, step: step, attempt: again)
      expect(again["usage"]).to be_nil

      sparse = JSON.generate("type" => "assistant", "timestamp" => "2026-10-04T12:01:00Z", "message" => {"id" => "p", "usage" => {"output_tokens" => 4}})
      write_transcript(sparse)
      third = attempt.except("usage")
      record.finish(run: run, step: step, attempt: third)
      expect(third["usage"]).to eq("input_tokens" => 0, "output_tokens" => 4)
    end

    context "with a short transcript read" do
      let(:max_transcript_bytes) { 400 }

      it "reaches only back to the first line of a session that began inside the attempt (U4)" do
        File.write(ledger_path, "")
        start_line("s1", "2026-10-04T12:01:00Z", "source" => "startup")
        filler = Array.new(6) { |n| assistant("2026-10-04T11:0#{n}:00Z", "old#{n}", 1, 1) }
        write_transcript(*filler, assistant("2026-10-04T12:01:00Z", "m1", 10, 1), assistant("2026-10-04T12:02:00Z", "m2", 20, 7))
        record.finish(run: run, step: step, attempt: attempt)
        expect(attempt["usage"]).to eq("input_tokens" => 30, "output_tokens" => 8)

        File.write(ledger_path, "")
        start_line("s1", "2026-10-04T10:00:00Z", "source" => "startup")
        second = attempt.except("usage")
        record.finish(run: run, step: step, attempt: second)
        expect(second["usage"]).to be_nil
      end

      it "reaches back to the attempt's start, not the session's, for a resume or compact, which keep the old file (round 2, 3)" do
        File.write(ledger_path, "")
        start_line("s1", "2026-10-04T12:01:00Z", "source" => "resume")
        filler = Array.new(6) { |n| assistant("2026-10-04T11:0#{n}:00Z", "old#{n}", 1, 1) }
        write_transcript(*filler, assistant("2026-10-04T12:00:30Z", "m0", 5, 5), assistant("2026-10-04T12:02:00Z", "m2", 20, 7))
        record.finish(run: run, step: step, attempt: attempt)

        expect(attempt["usage"]).to be_nil
      end

      it "reads a startup session that began a few seconds before the attempt from a long file, counting nothing before the attempt (round 3, 3)" do
        filler = Array.new(6) { |n| assistant("2026-10-04T11:0#{n}:00Z", "old#{n}", 1, 1) }
        write_transcript(*filler, assistant("2026-10-03T11:59:57Z", "pre", 900, 90), assistant("2026-10-04T11:59:57Z", "pre2", 900, 90), assistant("2026-10-04T12:02:00Z", "m2", 20, 7))
        File.write(ledger_path, "")
        start_line("s1", "2026-10-04T11:59:57Z", "source" => "startup")
        record.finish(run: run, step: step, attempt: attempt)
        expect(attempt["usage"]).to eq("input_tokens" => 20, "output_tokens" => 7)
      end
    end

    it "is nil when the last line of a message has a usage that is not a hash (round 2, 1)" do
      [nil, "x"].each do |bad|
        last = JSON.generate("type" => "assistant", "timestamp" => "2026-10-04T12:01:30Z", "message" => {"id" => "m1", "usage" => bad})
        write_transcript(assistant("2026-10-04T12:01:00Z", "m1", 10, 1), last)
        one = attempt.except("usage")
        record.finish(run: run, step: step, attempt: one)
        expect(one["usage"]).to be_nil
      end
    end

    it "keeps a session live that was resumed under the same id after an earlier end (round 2, 2)" do
      File.write(ledger_path, "")
      start_line("s1", "2026-10-04T11:00:00Z")
      ledger_line("at" => "2026-10-04T11:30:00Z", "event" => "session_end", "pane_id" => "%5", "session_id" => "s1")
      start_line("s1", "2026-10-04T11:59:00Z", "source" => "resume")
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["session"]).to include("id" => "s1")
      expect(attempt["usage"]).to eq("input_tokens" => 30, "output_tokens" => 12)
    end

    it "accepts a session carried into the attempt for another agent when the pane's server is the one it started under (round 2, 4)" do
      File.write(ledger_path, "")
      start_line("c1", "2026-10-04T09:00:00Z", "kind" => "codex")
      server[0] = "123"
      refused = attempt.except("usage")
      record.finish(run: run, step: step, attempt: refused)
      expect(refused["session"]).to be_nil

      server[0] = "99"
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to include("id" => "c1")
      expect(attempt["agent"]).to eq("kind" => "codex", "version" => nil, "model" => nil)
    end

    it "wants proof for a carried session when the server is unknown, but not for one that began a moment before the attempt (round 2, 5)" do
      File.write(ledger_path, "")
      start_line("c1", "2026-10-04T11:59:58Z", "kind" => "codex")
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to include("id" => "c1")

      File.write(ledger_path, "")
      start_line("c1", "2026-10-04T09:00:00Z", "kind" => "codex")
      older = attempt.except("session", "agent", "usage")
      record.finish(run: run, step: step, attempt: older)
      expect(older["session"]).to be_nil
    end

    it "matches no entry when the run has no workspace name (round 2, 6)" do
      File.write(ledger_path, "")
      File.open(ledger_path, "a") { |f| f.puts(JSON.generate("at" => "2026-10-04T12:00:01Z", "event" => "session_start", "pane_id" => "%5", "session_id" => "s1", "transcript_path" => transcript)) }
      run["workspace"] = nil
      plain = described_class.new(guard: guard, ledger: ledger, clock: -> { Time.utc(2026, 10, 4, 12, 10, 0) })
      plain.finish(run: run, step: step, attempt: attempt)

      expect(attempt["session"]).to be_nil
    end

    it "ignores a session that ended before the attempt began" do
      File.write(ledger_path, "")
      start_line("s1", "2026-10-04T10:00:00Z")
      ledger_line("at" => "2026-10-04T11:59:00Z", "event" => "session_end", "pane_id" => "%5", "session_id" => "s1")
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["session"]).to be_nil
      expect(attempt["usage"]).to be_nil
    end

    it "ignores another workspace's entry for the same pane id, and accepts the tmux session's name (S1)" do
      File.write(ledger_path, "")
      start_line("other", "2026-10-04T12:00:02Z", "workspace" => "someone-else")
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to be_nil

      File.write(ledger_path, "")
      start_line("s1", "2026-10-04T12:00:02Z", "workspace" => "w")
      other = attempt.except("session", "agent", "usage")
      record.finish(run: run, step: step, attempt: other)
      expect(other["session"]).to include("id" => "s1")
    end

    it "ignores an entry from another tmux server when this one is known (S1)" do
      server[0] = "123"
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to be_nil

      server[0] = "99"
      again = attempt.except("session", "agent", "usage")
      record.finish(run: run, step: step, attempt: again)
      expect(again["session"]).to include("id" => "s1")
    end

    it "does not choose a start older than the attempt, never ended, whose transcript has nothing in the window (S1)" do
      File.write(ledger_path, "")
      start_line("s1", "2026-10-04T09:00:00Z")
      write_transcript(assistant("2026-10-04T09:30:00Z", "m0", 1, 1))
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to be_nil
      expect(attempt["agent"]).to be_nil

      write_transcript(assistant("2026-10-04T09:30:00Z", "m0", 1, 1), assistant("2026-10-04T12:02:00Z", "m2", 20, 7))
      proven = attempt.except("session", "agent", "usage")
      record.finish(run: run, step: step, attempt: proven)
      expect(proven["session"]).to include("id" => "s1")
      expect(proven["usage"]).to eq("input_tokens" => 20, "output_tokens" => 7)
    end

    it "records no usage for another agent" do
      start_line("c1", "2026-10-04T12:00:02Z", "kind" => "codex")
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["usage"]).to be_nil
      expect(attempt["agent"]).to eq("kind" => "codex", "version" => nil, "model" => nil)
    end

    it "does not trust a ledger path or id that is not the expected shape" do
      File.write(ledger_path, "")
      start_line("s1", "2026-10-04T12:00:01Z", "transcript_path" => "relative/$(x).jsonl")
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to eq("id" => "s1", "transcript" => nil)
      expect(attempt["usage"]).to be_nil

      File.write(ledger_path, "")
      start_line("a b;rm", "2026-10-04T12:00:01Z")
      later = attempt.except("session", "usage", "agent")
      record.finish(run: run, step: step, attempt: later)
      expect(later["session"]).to be_nil
    end

    it "never follows a transcript that is a link, nor blocks on a ledger that is a pipe (S3)" do
      real = File.join(@dir, "real.jsonl")
      FileUtils.mv(transcript, real)
      File.symlink(real, transcript)
      record.finish(run: run, step: step, attempt: attempt)
      expect(attempt["session"]).to include("id" => "s1")
      expect(attempt["usage"]).to be_nil

      FileUtils.rm_f(ledger_path)
      File.mkfifo(ledger_path)
      expect(ledger.recent_entries(max_bytes: 100)).to eq([])
    end

    it "records nothing without a ledger or a transcript, and never raises" do
      bare = described_class.new(guard: guard)
      one = attempt.dup
      bare.finish(run: run, step: step, attempt: one)
      expect(one).to include("session" => nil, "usage" => nil, "agent" => nil)

      FileUtils.rm_f(transcript)
      two = attempt.dup
      record.finish(run: run, step: step, attempt: two)
      expect(two["session"]).to include("id" => "s1")
      expect(two["usage"]).to be_nil
    end

    describe "#abandon" do
      it "sets session, agent and usage and still adds no ended_at, counting to now" do
        open = {"n" => 2, "started_at" => "2026-10-04T12:00:00.000Z"}
        run["steps"]["plan"]["attempts"] = [open]
        closed = record.abandon(run)

        expect(closed).not_to include("ended_at", "outcome")
        expect(closed["session"]).to include("id" => "s1")
        expect(closed["agent"]).to include("kind" => "claude")
        expect(closed["usage"]).to eq("input_tokens" => 5030, "output_tokens" => 512)
      end
    end
  end
end
