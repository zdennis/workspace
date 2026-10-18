require "spec_helper"
require "tmpdir"
require "open3"
require "json"

RSpec.describe Workspace::Commands::Ticket do
  around do |example|
    Dir.mktmpdir("ticket-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "api") }
  let(:output) { StringIO.new }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:fetched) { {"title" => "Fix it", "body" => "Details", "url" => "https://acme.atlassian.net/browse/PROJ-123"} }
  let(:source) { instance_double(Workspace::TicketSource, fetch: fetched) }
  let(:start_ref) { Workspace::StartRef.new(git: git, lineage: Workspace::WorkspaceLineage.new) }
  subject(:command) { described_class.new(git: git, project_config: project_config, start_ref: start_ref, source: source, output: output) }

  def sh(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless status.success?
  end

  def in_repo(&block) = Dir.chdir(repo, &block)

  def document = JSON.parse(output.string)

  before do
    FileUtils.mkdir_p(repo)
    sh("init", "-q")
    sh("commit", "-q", "--allow-empty", "-m", "init")
    allow(project_config).to receive(:worktree_config_name) { |project, dir| "#{project}.worktree-#{dir}" }
    allow(project_config).to receive(:existing_name).and_return(nil)
    allow(project_config).to receive(:project_root_for).and_return(nil)
  end

  describe "#show with --json" do
    it "prints the ticket and no workspace when none exists for it" do
      in_repo { command.show("PROJ-123", json: true) }

      expect(document).to eq(
        "schema_version" => 1, "ok" => true, "ref" => "PROJ-123", "kind" => "jira", "key" => "PROJ-123",
        "title" => "Fix it", "body" => "Details", "url" => "https://acme.atlassian.net/browse/PROJ-123",
        "branch" => "PROJ-123", "workspace" => nil
      )
      expect(source).to have_received(:fetch).with(an_object_having_attributes(kind: "jira"), chdir: repo)
    end

    it "names the workspace when start would find its worktree already there" do
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(repo, ".worktrees", "PROJ-123"))

      in_repo { command.show("PROJ-123", json: true) }

      expect(document["workspace"]).to eq("api.worktree-PROJ-123")
    end

    it "names the workspace by the spelling its config already has" do
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(repo, ".worktrees", "PROJ-123"))
      allow(project_config).to receive(:existing_name).with("api.worktree-PROJ-123").and_return("Api.worktree-PROJ-123")

      in_repo { command.show("PROJ-123", json: true) }

      expect(document["workspace"]).to eq("Api.worktree-PROJ-123")
    end

    it "names the worktree of a pull request by its pr-<n> branch" do
      sh("worktree", "add", "-q", "-b", "pr-41", File.join(repo, ".worktrees", "pr-41"))

      in_repo { command.show("https://github.com/o/r/pull/41", json: true) }

      expect(document).to include("kind" => "github_pr", "key" => "o/r#41", "branch" => "pr-41", "workspace" => "api.worktree-pr-41")
    end

    it "names a worktree that holds the branch at another path by that path's directory" do
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(@dir, "elsewhere"))

      in_repo { command.show("PROJ-123", json: true) }

      expect(document["workspace"]).to eq("api.worktree-elsewhere")
    end

    it "names no workspace when the branch is only checked out in the main checkout" do
      sh("checkout", "-q", "-b", "PROJ-123")

      in_repo { command.show("PROJ-123", json: true) }

      expect(document["workspace"]).to be_nil
    end

    it "gives a plain branch no title, body or URL and asks no tool" do
      allow(source).to receive(:fetch).and_return("title" => nil, "body" => nil, "url" => nil)

      in_repo { command.show("feature/x", json: true) }

      expect(document).to include("kind" => "branch", "key" => "feature/x", "title" => nil, "body" => nil, "url" => nil, "branch" => "feature/x")
    end

    it "looks in the parent project when run from inside a linked worktree" do
      linked = File.join(repo, ".worktrees", "x")
      sh("worktree", "add", "-q", "-b", "x", linked)
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(repo, ".worktrees", "PROJ-123"))

      Dir.chdir(linked) { command.show("PROJ-123", json: true) }

      expect(document["workspace"]).to eq("api.worktree-PROJ-123")
    end

    it "looks in the project --name names, from wherever it is run" do
      allow(project_config).to receive(:project_root_for).with("api").and_return(repo)
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(repo, ".worktrees", "PROJ-123"))

      Dir.chdir(@dir) { command.show("PROJ-123", name: "api", json: true) }

      expect(document["workspace"]).to eq("api.worktree-PROJ-123")
    end

    it "fails with unknown_workspace for a --name no workspace has" do
      expect { command.show("PROJ-123", name: "nope", json: true) }
        .to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["unknown_workspace", {"name" => "nope"}]) }
      expect(output.string).to eq("")
    end

    it "fails outside a git repository" do
      expect { Dir.chdir(@dir) { command.show("PROJ-123", json: true) } }.to raise_error(Workspace::Error, /Not inside a git repository/)
    end

    it "lets the source's failure through, and prints nothing" do
      allow(source).to receive(:fetch).and_raise(Workspace::Error.new("no", code: "ticket_not_found", details: {"source" => "jira"}))

      expect { in_repo { command.show("PROJ-123", json: true) } }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ticket_not_found") }
      expect(output.string).to eq("")
    end

    it "writes nothing to the repository" do
      before = Open3.capture2("git", "-C", repo, "status", "--porcelain", "--ignored").first

      in_repo { command.show("PROJ-123", json: true) }

      expect(Open3.capture2("git", "-C", repo, "status", "--porcelain", "--ignored").first).to eq(before)
      expect(Dir.children(repo)).to eq([".git"])
    end
  end

  describe "#show as text" do
    it "prints the key and title, the URL, a note about an existing workspace, and the body" do
      sh("worktree", "add", "-q", "-b", "PROJ-123", File.join(repo, ".worktrees", "PROJ-123"))

      in_repo { command.show("PROJ-123") }

      expect(output.string).to eq(<<~TEXT)
        PROJ-123  Fix it
        https://acme.atlassian.net/browse/PROJ-123
        Workspace: api.worktree-PROJ-123 (already exists)

        Details
      TEXT
    end

    it "prints only the key and the branch for a plain branch" do
      allow(source).to receive(:fetch).and_return("title" => nil, "body" => nil, "url" => nil)

      in_repo { command.show("feature/x") }

      expect(output.string).to eq("feature/x  (branch)\n")
    end

    it "leaves out the lines a ticket has nothing for" do
      allow(source).to receive(:fetch).and_return("title" => "Fix it", "body" => nil, "url" => nil)

      in_repo { command.show("PROJ-123") }

      expect(output.string).to eq("PROJ-123  Fix it\n")
    end
  end
end
