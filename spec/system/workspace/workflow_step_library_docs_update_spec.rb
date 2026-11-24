require "spec_helper"
require "tmpdir"
require "open3"
require "shellwords"

RSpec.describe "the docs_update library step's proof" do
  let(:step) { YAML.safe_load_file(File.join(PROJECT_ROOT, "lib", "workflows", "steps", "docs_update.yml")).dig("steps", "docs_update") }
  let(:template) { step.fetch("require").first.fetch("exec") }

  around do |example|
    Dir.mktmpdir("docs-update") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "repo") }
  let(:artifacts) { File.join(@dir, "artifacts") }

  def git(*args)
    out, status = Open3.capture2e({"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"},
      "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out.strip
  end

  def commit(name)
    File.write(File.join(repo, name), "x\n")
    git("add", "-A")
    git("commit", "-q", "-m", name)
  end

  # Runs the proof as the engine does: split into an argument vector, fill the placeholders, no shell of its own.
  def proof_exit(head_before: @head_before)
    argv, problem = Workspace::WorkflowArgv.split(template)
    expect(problem).to be_nil
    expect(Workspace::WorkflowArgv.problems(argv, inputs: [])).to eq([[], []])
    filled = Workspace::WorkflowArgv.render(argv, scalars: {"attempt.head_before" => head_before, "artifacts" => artifacts}, lists: {})
    _out, status = Open3.capture2e(*filled, chdir: repo)
    status.exitstatus
  end

  def docs(text)
    File.write(File.join(artifacts, "docs.md"), text)
  end

  before do
    FileUtils.mkdir_p([repo, artifacts])
    git("init", "-q", "-b", "main")
    commit("start")
    @head_before = git("rev-parse", "HEAD")
  end

  it "passes when a commit was made since the attempt began" do
    commit("docs")
    expect(proof_exit).to eq(0)
  end

  it "passes when docs.md starts with the docs: none line and nothing was committed" do
    docs("docs: none — an internal refactor\nmore text\n")
    expect(proof_exit).to eq(0)
  end

  it "passes when the docs: none line ends with a CRLF" do
    docs("docs: none\r\nmore text\r\n")
    expect(proof_exit).to eq(0)
  end

  it "fails with no commit and no docs.md" do
    expect(proof_exit).to eq(1)
  end

  it "fails when docs.md's first line is something else" do
    docs("Notes\ndocs: none — later line\n")
    expect(proof_exit).to eq(1)
  end

  it "fails when docs.md's first line only starts like the docs: none line" do
    docs("docs: nonexistent\n")
    expect(proof_exit).to eq(1)
  end

  it "fails when an earlier attempt's commit is the only one" do
    commit("earlier")
    expect(proof_exit(head_before: git("rev-parse", "HEAD"))).to eq(1)
  end

  it "fails when the attempt has no starting commit recorded" do
    commit("docs")
    expect(proof_exit(head_before: "")).to eq(1)
  end
end
