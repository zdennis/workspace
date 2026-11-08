require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"

# `go` sends every ref through the real WorkflowStart, so the fork pull request check and the
# in-place rules hold together. Doubles stand at the edges only: the ticket source, the workflow
# engine, `start`, `workflow run` and the agent and pane collaborators. Git and the project
# detector are real, on a temporary repository. Cases the double-light go_real_git_spec.rb
# already has (a marked linked worktree on the default branch, or on another branch; symrefs)
# are not repeated here.
RSpec.describe Workspace::Commands::Go, "with a real WorkflowStart and Git" do
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:state) { instance_double(Workspace::State, load: nil, keys: active) }
  let(:active) { [] }
  let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil) }
  let(:definition) { Workspace::WorkflowDefinition.parse("inputs:\n  task:\nsteps:\n  plan:\n    prompt: Plan.\n", id: "rpiv", source: "global", path: "/defs/rpiv.yml") }
  let(:catalog) { instance_double(Workspace::WorkflowCatalog, find: definition, known?: false, known_ids: %w[rpiv pr-feedback]) }
  let(:workflow_defaults) { instance_double(Workspace::WorkflowDefaults, lookup: nil, id_for: nil) }
  let(:ticket_source) { instance_double(Workspace::TicketSource) }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:start) { instance_double(Workspace::Commands::Start) }
  let(:workflow) { instance_double(Workspace::Commands::Workflow, run: {"outcome" => "started"}) }
  let(:ssh_hosts) { Workspace::SshHostResolver.new(runner: ->(argv, **) { ["hostname #{argv.last}\n", "", true] }) }
  let(:fork_ticket) { {"title" => "A fork", "body" => "", "url" => "https://github.com/o/r/pull/12", "cross_repository" => true} }

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

  def init
    sh(@repo, "init", "-q", "-b", "main")
    QuietGit.configure(@repo)
    sh(@repo, "commit", "-q", "--allow-empty", "-m", "init")
    sh(@repo, "remote", "add", "origin", "git@github.com:o/r.git")
  end

  def linked(name, branch: name)
    path = File.join(@repo, ".worktrees", name)
    sh(@repo, "worktree", "add", "-q", "-b", branch, path)
    path
  end

  def mark(path)
    name = "app.worktree-#{File.basename(path)}"
    File.write(File.join(path, ".workspace-project"), "#{name}\n")
    allow(project_config).to receive(:project_root_for).with(name).and_return(path)
  end

  def workflow_start
    Workspace::Commands::WorkflowStart.new(
      catalog: catalog, workflow_defaults: workflow_defaults, engine: engine, start_ref: start_ref, ticket_source: ticket_source, git: git,
      project_config: project_config, workflow_project: instance_double(Workspace::WorkflowProject, for_directory: nil), start: start, workflow: workflow, readiness: instance_double(Workspace::AgentReadiness, deadline_in: 99.0),
      tmux: instance_double(Workspace::Tmux), agent_commands: instance_double(Workspace::AgentCommands, detector: :detector, kind: "claude"),
      excludes: instance_double(Workspace::GitExclude, add: true), ssh_hosts: ssh_hosts, router: instance_double(Workspace::WorkflowRouter, unrouted: {}), output: StringIO.new
    )
  end

  def start_ref
    Workspace::StartRef.new(git: git)
  end

  def go(from, **args)
    allow(git).to receive(:root).and_return(from)
    command = described_class.new(workflow_start: workflow_start, workflow: workflow, workflow_defaults: workflow_defaults, catalog: catalog,
      start_ref: start_ref, git: git, project_detector: Workspace::ProjectDetector.new(state: state, project_config: project_config),
      project_config: project_config, go_task: instance_double(Workspace::Commands::GoTask, run_for: nil), ticket_source: instance_double(Workspace::TicketSource),
      protected_branch: Workspace::ProtectedBranch.new(git: git), branch_name_picker: instance_double(Workspace::BranchNamePicker,
        call: Workspace::BranchNamePicker::Result.new(reason: :disabled)), output: StringIO.new, working_dir: from)
    command.call(**args)
  end

  def expect_nothing_started
    expect(workflow).not_to have_received(:run)
    expect(start).not_to have_received(:payload)
  end

  before do
    allow(ticket_source).to receive(:fetch).and_return(fork_ticket)
    allow(start).to receive(:payload)
    allow(engine).to receive(:preflight) { |inputs:, **| {"inputs" => inputs} }
    init
  end

  describe "a pull request from a fork" do
    def expect_fork_refusal(from)
      [true, false].each do |dry_run|
        expect { go(from, argument: "#12", dry_run: dry_run) }.to raise_error(Workspace::Error) do |e|
          expect(e.code).to eq("fork_pull_request")
          expect(e.details).to include("pr" => 12, "reason" => "cross_repository")
        end
      end
      expect_nothing_started
      expect(engine).not_to have_received(:preflight)
    end

    it "is refused from outside a workspace, real and dry" do
      expect_fork_refusal(@repo)
    end

    it "is refused from inside another workspace, real and dry" do
      other = linked("other")
      mark(other)

      expect_fork_refusal(other)
    end

    it "is refused from that branch's own checkout, real and dry" do
      own = linked("pr-12")
      mark(own)

      expect_fork_refusal(own)
    end
  end

  describe "a marker-less linked worktree beside a main checkout that counts as active" do
    let(:active) { ["app"] }

    it "is not in place, so bare go is refused and free text starts a worktree workspace" do
      worktree = linked("side")
      allow(project_config).to receive(:project_root_for).with("app").and_return(@repo)

      expect { go(worktree) }.to raise_error(Workspace::UsageError, /runs in place only in a linked worktree/)
      expect(go(worktree, argument: "try the thing", dry_run: true)["decision"]).to include("route" => "start")
      expect(workflow).not_to have_received(:run)
    end
  end

  describe "a symref to the checkout's own branch, run from that checkout" do
    it "raises branch_exists and starts nothing" do
      own = linked("foo")
      mark(own)
      sh(@repo, "symbolic-ref", "refs/heads/alias", "refs/heads/foo")
      allow(ticket_source).to receive(:fetch).and_raise("a branch reads no ticket")

      [true, false].each do |dry_run|
        expect { go(own, argument: "alias", dry_run: dry_run) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("branch_exists") }
      end
      expect_nothing_started
    end
  end
end
