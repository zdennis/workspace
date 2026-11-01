require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"

# Tags, symrefs and packed refs behave in ways a double of Git hides, so these run on real
# repositories; only the two commands `go` calls, and the config lookup, are doubles.
RSpec.describe Workspace::Commands::Go, "against a real repository" do
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:workflow_start) { instance_double(Workspace::Commands::WorkflowStart, catalog_project: nil, call: {"outcome" => "started"}, check_agent!: nil, locate_project: {project_workspace: "app"}) }
  let(:workflow) { instance_double(Workspace::Commands::Workflow, run: {"outcome" => "started"}) }
  let(:definition) { Workspace::WorkflowDefinition.parse("inputs:\n  task:\nsteps:\n  plan:\n    prompt: Plan.\n", id: "rpiv", source: "global", path: "/defs/rpiv.yml") }
  let(:catalog) { instance_double(Workspace::WorkflowCatalog, find: definition, known_ids: %w[rpiv]) }
  let(:workflow_defaults) { instance_double(Workspace::WorkflowDefaults, lookup: nil) }
  let(:state) { instance_double(Workspace::State, load: nil, keys: []) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      @repo = File.join(@dir, "app")
      FileUtils.mkdir_p(@repo)
      example.run
    end
  end

  def sh(path, *args)
    out = IO.popen(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", path, *args], err: [:child, :out], &:read)
    raise "git #{args.join(" ")} failed: #{out}" unless $?.success?
    out
  end

  def init(branch = "main")
    sh(@repo, "init", "-q", "-b", branch)
    QuietGit.configure(@repo)
    sh(@repo, "commit", "-q", "--allow-empty", "-m", "init")
  end

  # A clone, so origin/HEAD names the default branch, left on another branch.
  def init_clone(default)
    origin = File.join(@dir, "origin")
    FileUtils.mkdir_p(origin)
    sh(origin, "init", "-q", "-b", default)
    QuietGit.configure(origin)
    sh(origin, "commit", "-q", "--allow-empty", "-m", "init")
    sh(@dir, "clone", "-q", origin, @repo)
    QuietGit.configure(@repo)
    sh(@repo, "checkout", "-q", "-b", "side")
  end

  def linked(name, branch: name)
    path = File.join(@repo, ".worktrees", name)
    sh(@repo, "worktree", "add", "-q", path, branch)
    path
  end

  def mark(path)
    File.write(File.join(path, ".workspace-project"), "app.worktree-#{File.basename(path)}\n")
    allow(project_config).to receive(:project_root_for).with("app.worktree-#{File.basename(path)}").and_return(path)
  end

  def go(from, **args)
    allow(git).to receive(:root).and_return(from)
    command = described_class.new(workflow_start: workflow_start, workflow: workflow, workflow_defaults: workflow_defaults, catalog: catalog,
      start_ref: Workspace::StartRef.new(git: git), git: git, project_detector: Workspace::ProjectDetector.new(state: state, project_config: project_config),
      project_config: project_config, output: StringIO.new, working_dir: from)
    command.call(**args)
  end

  def refusal(from, **args)
    go(from, **args)
    nil
  rescue Workspace::Error => e
    e
  end

  def expect_nothing_ran
    expect(workflow).not_to have_received(:run)
    expect(workflow_start).not_to have_received(:call)
  end

  describe "a tag named like the branch" do
    it "refuses the main checkout's branch" do
      init("release")
      sh(@repo, "branch", "main")
      sh(@repo, "tag", "release")

      error = refusal(@repo, argument: "release", workflow: "rpiv")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to eq("branch" => "release", "path" => @repo, "reason" => "main_checkout")
      expect_nothing_ran
    end

    context "in a marked linked worktree on the default branch" do
      before do
        init
        sh(@repo, "tag", "main")
        sh(@repo, "checkout", "-q", "-b", "side")
        @worktree = linked("keep", branch: "main")
        mark(@worktree)
      end

      it "refuses bare go" do
        expect(refusal(@worktree)).to be_a(Workspace::UsageError)
        expect_nothing_ran
      end

      it "takes free text to a new worktree workspace" do
        expect(go(@worktree, argument: "fix the bug")["decision"]["route"]).to eq("start")
        expect(workflow).not_to have_received(:run)
      end
    end

    it "does not misread a reused checkout that holds its own branch" do
      init
      sh(@repo, "branch", "foo")
      sh(@repo, "tag", "foo")
      linked("foo")

      expect(refusal(@repo, argument: "foo")).to be_nil
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "foo"))
    end

    it "runs in place in a marked linked worktree on another branch" do
      init
      sh(@repo, "branch", "foo")
      sh(@repo, "tag", "foo")
      worktree = linked("foo")
      mark(worktree)

      expect(go(worktree, argument: "fix the bug")["decision"]["route"]).to eq("run")
    end
  end

  describe "a branch that is a symref" do
    it "counts as the default branch, under the name given" do
      init_clone("main")
      sh(@repo, "symbolic-ref", "refs/heads/master", "refs/heads/main")

      error = refusal(@repo, argument: "master")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to include("branch" => "master", "reason" => "default_branch")
      expect_nothing_ran
    end

    it "counts as the main checkout's branch, with its path" do
      init
      sh(@repo, "checkout", "-q", "-b", "release")
      sh(@repo, "symbolic-ref", "refs/heads/rel", "refs/heads/release")

      error = refusal(@repo, argument: "rel")

      expect(error.details).to eq("branch" => "rel", "path" => @repo, "reason" => "main_checkout")
      expect_nothing_ran
    end

    it "is not in place in a marked linked worktree on it" do
      init
      sh(@repo, "symbolic-ref", "refs/heads/master", "refs/heads/main")
      sh(@repo, "checkout", "-q", "-b", "side")
      worktree = linked("master")
      mark(worktree)

      expect(refusal(worktree)).to be_a(Workspace::UsageError)
      expect(go(worktree, argument: "fix it")["decision"]["route"]).to eq("start")
      expect(workflow).not_to have_received(:run)
    end

    it "counts as this checkout when it points at this checkout's own branch" do
      init
      sh(@repo, "branch", "foo")
      sh(@repo, "symbolic-ref", "refs/heads/alias", "refs/heads/foo")
      worktree = linked("foo")
      mark(worktree)

      expect(go(worktree, argument: "alias", caller_pane: "%3")["decision"]["route"]).to eq("run")
      expect(workflow_start).to have_received(:call) do |here:, ref:, **|
        expect(ref).to eq("alias")
        expect(here.path).to eq(worktree)
      end
    end

    it "refuses free text whose slug is one" do
      init
      sh(@repo, "symbolic-ref", "refs/heads/master", "refs/heads/main")

      error = refusal(@repo, argument: "master !")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details["branch"]).to eq("master")
      expect_nothing_ran
    end
  end

  it "refuses origin/main with --workflow, naming main" do
    init_clone("main")

    error = refusal(@repo, argument: "origin/main", workflow: "rpiv")

    expect(error.code).to eq("unknown_ref")
    expect(error.details["did_you_mean"]).to eq("main")
    expect_nothing_ran
  end

  describe "free text and packed branches" do
    it "refuses a slug that is a case alias of the default branch" do
      init_clone("Develop")
      sh(@repo, "pack-refs", "--all")

      error = refusal(@repo, argument: "develop !")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to include("branch" => "develop", "reason" => "default_branch")
      expect(error.message).to include("Reword the text")
      expect_nothing_ran
    end

    it "refuses a slug that is a case alias of a plain branch, naming it" do
      init
      sh(@repo, "branch", "Feature")
      sh(@repo, "pack-refs", "--all")

      error = refusal(@repo, argument: "feature !")

      expect(error.code).to eq("branch_exists")
      expect(error.details).to eq("branch" => "Feature", "path" => File.join(@repo, ".worktrees", "Feature"), "worktree" => false)
      expect(error.message).to include("Reword the text")
      expect_nothing_ran
    end

    it "lets a slug with no such branch through" do
      init

      expect(go(@repo, argument: "fix the bug")["decision"]["route"]).to eq("start")
    end
  end
end
