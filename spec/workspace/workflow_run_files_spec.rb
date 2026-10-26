require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowRunFiles do
  subject(:files) { described_class.new }

  around do |example|
    Dir.mktmpdir("wf-run-files") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:artifacts) { File.join(@dir, "app", ".workflow", "wr_1") }

  def write(relative, text)
    path = File.join(artifacts, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def run_for(attempts: [], produces: [], **extra)
    {"id" => "wr_1", "worktree" => File.join(@dir, "app"), "artifacts_dir" => artifacts,
     "definition" => {"steps" => [{"id" => "research", "produces" => produces}]},
     "steps" => {"research" => {"attempts" => attempts}}}.merge(extra)
  end

  it "lists an attempt's prompt and check log, and each produces entry with no attempt" do
    prompt = write("steps/research.1.prompt.md", "prompt text\n")
    log = write("steps/research.1.check.log", "ok\n")
    write("research.md", "# Research\n")

    rows = files.list(run_for(attempts: [{"n" => 1, "prompt_file" => prompt, "check" => {"log" => log}}], produces: ["research.md", "plan.md"]))

    expect(rows).to eq([
      {"path" => prompt, "kind" => "prompt", "step" => "research", "attempt" => 1, "exists" => true, "bytes" => 12},
      {"path" => log, "kind" => "check_log", "step" => "research", "attempt" => 1, "exists" => true, "bytes" => 3},
      {"path" => File.join(artifacts, "research.md"), "kind" => "produces", "step" => "research", "attempt" => nil, "exists" => true, "bytes" => 11},
      {"path" => File.join(artifacts, "plan.md"), "kind" => "produces", "step" => "research", "attempt" => nil, "exists" => false, "bytes" => nil}
    ])
  end

  it "leaves out the rows of a prompt or check that was not recorded" do
    rows = files.list(run_for(attempts: [{"n" => 1}]))

    expect(rows).to eq([])
  end

  it "reports a missing recorded file as not existing" do
    rows = files.list(run_for(attempts: [{"n" => 2, "prompt_file" => File.join(artifacts, "steps", "research.2.prompt.md")}]))

    expect(rows).to eq([{"path" => File.join(artifacts, "steps", "research.2.prompt.md"), "kind" => "prompt", "step" => "research", "attempt" => 2, "exists" => false, "bytes" => nil}])
  end

  it "reports a symlink as a link without its target's size, and does not follow it" do
    target = File.join(@dir, "big.bin")
    File.write(target, "x" * 5000)
    FileUtils.mkdir_p(artifacts)
    File.symlink(target, File.join(artifacts, "out.md"))
    File.symlink(File.join(@dir, "nowhere"), File.join(artifacts, "dangling.md"))
    expect(File).not_to receive(:stat)
    expect(File).not_to receive(:size)

    rows = files.list(run_for(produces: ["out.md", "dangling.md"]))

    expect(rows.map { |row| row.slice("exists", "bytes", "link") }).to eq([{"exists" => true, "bytes" => nil, "link" => true}] * 2)
    expect(rows.to_s).not_to include("5000")
  end

  it "skips a path outside the artifacts directory, on a directory boundary" do
    write("ok.md", "a")
    FileUtils.mkdir_p("#{artifacts}-evil")
    File.write("#{artifacts}-evil/x.md", "b")
    outside = File.join(@dir, "secret.txt")
    File.write(outside, "s")
    run = run_for(produces: ["ok.md", "../../../secret.txt", "../wr_1-evil/x.md"],
      attempts: [{"n" => 1, "prompt_file" => "#{artifacts}-evil/x.md", "check" => {"log" => outside}}])

    rows = files.list(run)

    expect(rows.map { |row| row["path"] }).to eq([File.join(artifacts, "ok.md")])
  end

  it "skips a path that goes out through a linked directory" do
    FileUtils.mkdir_p(artifacts)
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    File.write(File.join(@dir, "elsewhere", "a.md"), "elsewhere")
    File.symlink(File.join(@dir, "elsewhere"), File.join(artifacts, "dir"))

    expect(files.list(run_for(produces: ["dir/a.md"]))).to eq([])
  end

  it "falls back to <worktree>/.workflow/<id> when the run has no artifacts_dir" do
    write("research.md", "# Research\n")
    run = run_for(produces: ["research.md"])
    run.delete("artifacts_dir")

    expect(files.artifacts_dir(run)).to eq(artifacts)
    expect(files.list(run).map { |row| [row["path"], row["exists"]] }).to eq([[File.join(artifacts, "research.md"), true]])
  end

  it "answers no directory and no files for a run with neither artifacts_dir nor worktree" do
    run = run_for(produces: ["research.md"])
    run.delete("artifacts_dir")
    run.delete("worktree")

    expect(files.artifacts_dir(run)).to be_nil
    expect(files.list(run)).to eq([])
  end

  it "lists a file as missing when its parent directory is missing" do
    rows = files.list(run_for(produces: ["no/such/dir/a.md"]))

    expect(rows).to eq([{"path" => File.join(artifacts, "no/such/dir/a.md"), "kind" => "produces", "step" => "research", "attempt" => nil, "exists" => false, "bytes" => nil}])
  end
end
