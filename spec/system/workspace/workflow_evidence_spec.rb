require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowEvidence do
  around do |example|
    Dir.mktmpdir("wf-evidence") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:evidence_dir) { File.join(@dir, "evidence") }
  let(:art) { File.join(@dir, "art") }
  let(:now) { [Time.now] }
  let(:max_bytes) { described_class::MAX_BYTES }
  let(:budget) { described_class::BUDGET }
  subject(:evidence) { described_class.new(dir: evidence_dir, clock: -> { now.first }, max_bytes: max_bytes, budget: budget) }
  let(:run) { {"id" => "wr_1", "artifacts_dir" => art} }
  let(:step) { {"id" => "report", "produces" => ["report.md"]} }
  let(:attempt) { {"n" => 1, "check" => {"log" => "x"}} }
  let(:copies) { File.join(evidence_dir, "wr_1") }

  before { FileUtils.mkdir_p(File.join(art, "steps")) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def put(name, text)
    path = File.join(art, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  it "copies the check log and each output with the hash of the bytes copied and where it came from" do
    put("steps/report.1.check.log", "log")
    put("report.md", "out")

    entries = evidence.copy(run: run, step: step, attempt: attempt)

    expect(entries).to eq([
      {"name" => "report.1.check.log", "kind" => "check_log", "source" => File.join(art, "steps", "report.1.check.log"), "sha256" => sha("log"), "bytes" => 3},
      {"name" => "report.1.out.0.report.md", "kind" => "output", "source" => File.join(art, "report.md"), "sha256" => sha("out"), "bytes" => 3}
    ])
    expect(File.read(File.join(copies, "report.1.out.0.report.md"))).to eq("out")
    expect(File.stat(copies).mode & 0o777).to eq(0o700)
  end

  describe "#prompt" do
    it "copies the prompt file as written and names it for the step and attempt" do
      path = put("steps/report.1.prompt.md", "prompt")
      entries = evidence.prompt(run: run, step_id: "report", attempt: {"n" => 1, "prompt_file" => path})

      expect(entries).to eq([{"name" => "report.1.prompt.md", "kind" => "prompt", "source" => path, "sha256" => sha("prompt"), "bytes" => 6}])
      expect(File.read(File.join(copies, "report.1.prompt.md"))).to eq("prompt")
    end

    it "keeps the first copy when the agent rewrites the prompt later" do
      path = put("steps/report.1.prompt.md", "prompt")
      attempt = {"n" => 1, "prompt_file" => path}
      first = evidence.prompt(run: run, step_id: "report", attempt: attempt)
      File.write(path, "rewritten")

      expect(first.first["sha256"]).to eq(sha("prompt"))
      expect(File.read(File.join(copies, "report.1.prompt.md"))).to eq("prompt")
    end
  end

  it "takes no check log from an attempt that had no check" do
    expect(evidence.copy(run: run, step: {"id" => "report"}, attempt: {"n" => 2}).map { |e| e["kind"] }).to eq([])
  end

  it "notes a missing file and copies nothing for it" do
    entries = evidence.copy(run: run, step: step, attempt: {"n" => 1})
    expect(entries).to include(a_hash_including("kind" => "output", "sha256" => nil, "bytes" => nil, "problem" => "missing"))
    expect(Dir.children(copies)).to eq([])
  end

  it "reads every entry as missing when the artifacts directory is gone, and raises nothing" do
    FileUtils.rm_rf(art)
    entries = evidence.copy(run: run, step: step, attempt: attempt)
    expect(entries.map { |e| e["problem"] }).to eq(%w[missing missing])
  end

  it "never follows a link as the file" do
    File.write(File.join(@dir, "secret"), "s")
    File.symlink(File.join(@dir, "secret"), File.join(art, "report.md"))
    entry = evidence.copy(run: run, step: step, attempt: {"n" => 1}).last
    expect(entry).to include("problem" => "missing", "sha256" => nil)
    expect(Dir.children(copies)).to eq([])
  end

  it "refuses a file reached through a linked parent directory that leaves the artifacts directory" do
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    File.write(File.join(@dir, "elsewhere", "a.md"), "key")
    File.symlink(File.join(@dir, "elsewhere"), File.join(art, "sub"))
    entry = evidence.copy(run: run, step: {"id" => "s", "produces" => ["sub/a.md"]}, attempt: {"n" => 1}).last
    expect(entry).to include("problem" => "outside_artifacts", "sha256" => nil)
    expect(Dir.glob(File.join(copies, "*"))).to eq([])
  end

  it "refuses a prompt whose steps directory was swapped for a link" do
    FileUtils.rm_rf(File.join(art, "steps"))
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    File.write(File.join(@dir, "elsewhere", "report.1.prompt.md"), "x")
    File.symlink(File.join(@dir, "elsewhere"), File.join(art, "steps"))
    entries = evidence.prompt(run: run, step_id: "report", attempt: {"n" => 1, "prompt_file" => File.join(art, "steps", "report.1.prompt.md")})
    expect(entries.first["problem"]).to eq("outside_artifacts")
  end

  it "copies a file in a real subdirectory of the artifacts directory" do
    put("sub/a.md", "y")
    entry = evidence.copy(run: run, step: {"id" => "s", "produces" => ["sub/a.md"]}, attempt: {"n" => 1}).last
    expect(entry).to include("name" => "s.1.out.0.sub_a.md", "sha256" => sha("y"))
  end

  it "gives names that differ for files that sanitise alike" do
    put("sub/a.md", "one")
    put("sub_a.md", "two")
    entries = evidence.copy(run: run, step: {"id" => "s", "produces" => ["sub/a.md", "sub_a.md"]}, attempt: {"n" => 1})

    expect(entries.map { |e| e["name"] }.uniq.size).to eq(2)
    expect(entries.map { |e| File.read(File.join(copies, e["name"])) }).to eq(%w[one two])
  end

  it "keeps attempt 1's copy when attempt 2 copies a changed output" do
    put("report.md", "first")
    one = evidence.copy(run: run, step: {"id" => "report", "produces" => ["report.md"]}, attempt: {"n" => 1})
    put("report.md", "second")
    two = evidence.copy(run: run, step: {"id" => "report", "produces" => ["report.md"]}, attempt: {"n" => 2})

    expect([one.first["sha256"], two.first["sha256"]]).to eq([sha("first"), sha("second")])
    expect(File.read(File.join(copies, one.first["name"]))).to eq("first")
    expect(File.read(File.join(copies, two.first["name"]))).to eq("second")
  end

  context "with a 2 byte limit" do
    let(:max_bytes) { 2 }

    it "records a file over the limit with its size and no copy" do
      put("report.md", "abcd")
      entry = evidence.copy(run: run, step: step, attempt: {"n" => 1}).last
      expect(entry).to include("sha256" => nil, "bytes" => 4, "too_large" => true)
      expect(entry).not_to have_key("budget")
      expect(Dir.children(copies)).to eq([])
    end
  end

  context "with a 15 byte budget" do
    let(:budget) { 15 }

    it "stops copying past the budget for one attempt, the prompt counted" do
      path = put("steps/s.1.prompt.md", "12345")
      prompt = evidence.prompt(run: run, step_id: "s", attempt: {"n" => 1, "prompt_file" => path})
      put("a.md", "12345678")
      put("b.md", "12345678")
      entries = evidence.copy(run: run, step: {"id" => "s", "produces" => ["a.md", "b.md"]}, attempt: {"n" => 1, "evidence" => prompt})

      expect(entries[0]).to include("sha256" => sha("12345678"))
      expect(entries[1]).to include("sha256" => nil, "bytes" => 8, "too_large" => true, "budget" => true)
      expect(Dir.children(copies)).not_to include(entries[1]["name"])
    end
  end

  it "copies nothing for a run id that is not a plain id" do
    expect(evidence.copy(run: run.merge("id" => "../../x"), step: step, attempt: attempt)).to eq([])
    expect(File.exist?(evidence_dir)).to be(false)
  end

  it "notes copy_failed on every entry when the directory can't be made" do
    File.write(evidence_dir, "a file")
    put("report.md", "x")
    entries = evidence.copy(run: run, step: step, attempt: attempt)
    expect(entries.map { |e| e["problem"] }.uniq).to eq(["copy_failed"])
  end

  it "lets one entry fail without losing the others" do
    put("a.md", "a")
    put("b.md", "b")
    calls = 0
    flaky = described_class.new(dir: evidence_dir, opener: lambda { |path, flags, mode, &block|
      raise ArgumentError, "boom" if (calls += 1) == 1
      File.open(path, flags, mode, &block)
    })
    entries = flaky.copy(run: run, step: {"id" => "s", "produces" => ["a.md", "b.md"]}, attempt: {"n" => 1})

    expect(entries.map { |e| e["problem"] }).to eq(["copy_failed", nil])
    expect(entries.last["sha256"]).to eq(sha("b"))
  end

  # An opener whose file takes no bytes: the disk is full.
  def full_disk_opener
    ->(path, flags, mode, &block) { File.open(path, flags, mode) { |io| block.call(Struct.new(:io) { def write(*) = raise(Errno::ENOSPC) }.new(io)) } }
  end

  it "reports a failed write as copy_failed, not missing" do
    put("report.md", "x")
    full = described_class.new(dir: evidence_dir, opener: full_disk_opener)
    entry = full.copy(run: run, step: step, attempt: {"n" => 1}).last
    expect(entry).to include("problem" => "copy_failed", "sha256" => nil)
    expect(Dir.children(copies)).to eq([])
  end

  it "has a 64 MiB budget for one attempt" do
    expect(described_class::BUDGET).to eq(64 * 1024 * 1024)
  end

  it "refuses a file when its directory is swapped for a link between the check and the open" do
    put("sub/a.md", "mine")
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    File.write(File.join(@dir, "elsewhere", "a.md"), "key")
    swapping = described_class.new(dir: evidence_dir, opener: lambda { |path, flags, mode, &block|
      File.rename(File.join(art, "sub"), File.join(art, "sub.old"))
      File.symlink(File.join(@dir, "elsewhere"), File.join(art, "sub"))
      File.open(path, flags, mode, &block)
    })
    entry = swapping.copy(run: run, step: {"id" => "s", "produces" => ["sub/a.md"]}, attempt: {"n" => 1}).last

    expect(entry).to include("problem" => "outside_artifacts", "sha256" => nil)
    expect(Dir.glob(File.join(copies, "*"), File::FNM_DOTMATCH).map { |p| File.basename(p) } - %w[. ..]).to eq([])
  end

  it "keeps a finished copy whose name ends in .tmp when the next copy sweeps" do
    put("x.7.tmp", "data")
    step = {"id" => "s", "produces" => ["x.7.tmp"]}
    first = evidence.copy(run: run, step: step, attempt: {"n" => 1}).last
    evidence.copy(run: run, step: step, attempt: {"n" => 2})

    expect(File.read(File.join(copies, first["name"]))).to eq("data")
  end

  describe "stray temp files" do
    before { FileUtils.mkdir_p(copies) }

    def dead_pid
      pid = Process.spawn("true")
      Process.wait(pid)
      pid
    end

    it "removes the temp of a process that is gone" do
      stray = File.join(copies, ".tmp.#{dead_pid}.x")
      File.write(stray, "half")
      evidence.copy(run: run, step: {"id" => "s"}, attempt: {"n" => 1})
      expect(File.exist?(stray)).to be(false)
    end

    it "removes a temp older than an hour even when its process lives" do
      stray = File.join(copies, ".tmp.#{Process.pid}.x")
      File.write(stray, "half")
      File.utime(Time.now - 7200, Time.now - 7200, stray)
      evidence.copy(run: run, step: {"id" => "s"}, attempt: {"n" => 1})
      expect(File.exist?(stray)).to be(false)
    end

    it "leaves a recent temp of a live process, which may be a copy in progress" do
      stray = File.join(copies, ".tmp.#{Process.pid}.x")
      File.write(stray, "half")
      evidence.copy(run: run, step: {"id" => "s"}, attempt: {"n" => 1})
      expect(File.exist?(stray)).to be(true)
    end
  end

  describe "#remove" do
    it "removes one run's directory only for a plain id" do
      FileUtils.mkdir_p([File.join(evidence_dir, "wr_1"), File.join(evidence_dir, "wr_2")])
      evidence.remove("wr_1")
      evidence.remove("../evidence")
      expect(Dir.children(evidence_dir)).to eq(["wr_2"])
    end
  end
end
