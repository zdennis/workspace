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
  subject(:record) { described_class.new(guard: guard) }
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

    it "leaves out a definition hash a run was stored without" do
      attempt = {"n" => 1}
      record.start(run: run.except("definition_sha256"), attempt: attempt, composed: {"text" => "", "packs" => []})

      expect(attempt).not_to have_key("definition_sha256")
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

    it "does not read a file past the cap, and says so" do
      stub_const("#{described_class}::MAX_HASH_BYTES", 4)
      put("plan.md", "12345")
      attempt = {}
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => 5, "too_large" => true}])
    end

    it "hashes a file exactly at the cap" do
      stub_const("#{described_class}::MAX_HASH_BYTES", 5)
      put("plan.md", "12345")
      attempt = {}
      record.finish(run: run, step: step, attempt: attempt)

      expect(attempt["outputs"].first).to include("sha256" => Digest::SHA256.hexdigest("12345"), "bytes" => 5)
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
end
