require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::WorkflowStart do
  let(:root) { "/src/app" }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:start_ref) { Workspace::StartRef.new(git: git, lineage: lineage) }
  let(:catalog) { instance_double(Workspace::WorkflowCatalog) }
  let(:ticket_source) { instance_double(Workspace::TicketSource) }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:output) { StringIO.new }
  let(:worktrees) { [] }
  let(:branches) { [] }
  let(:local_branches) { [] }
  let(:remotes) { {"origin" => "git@github.com:o/r.git"} }
  let(:expanded) { {} }
  let(:ssh_runs) { [] }
  let(:ssh_answer) { [] }
  let(:ssh_hosts) do
    Workspace::SshHostResolver.new(runner: ->(argv, **) {
      ssh_runs << argv
      ssh_answer.empty? ? ["hostname #{argv.last}\n", "", true] : ssh_answer
    })
  end
  let(:ticket) { {"title" => "Fix login", "body" => "Details.", "url" => "https://acme.atlassian.net/browse/PROJ-1"} }
  let(:yaml) do
    <<~YAML
      inputs:
        task: {required: true}
        spec:
      steps:
        plan:
          prompt: Plan {{inputs.task}}.
    YAML
  end
  let(:definition) { Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml") }
  let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil, worktree_config_name: "app.worktree-x") }
  let(:start) { instance_double(Workspace::Commands::Start) }
  let(:workflow) { instance_double(Workspace::Commands::Workflow) }
  let(:readiness) { instance_double(Workspace::AgentReadiness, deadline_in: 99.0) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:agent_commands) { instance_double(Workspace::AgentCommands, detector: :detector, kind: "claude") }
  let(:excludes) { instance_double(Workspace::GitExclude, add: true) }
  let(:ready) { Workspace::AgentReadiness::Result.new(ready: true, pane: "0.0", pane_id: "%7", label: "Claude Code") }
  subject(:command) { build_command(engine) }

  def build_command(engine)
    described_class.new(catalog: catalog, engine: engine, start_ref: start_ref, ticket_source: ticket_source, git: git, project_config: project_config, start: start,
      workflow: workflow, readiness: readiness, tmux: tmux, agent_commands: agent_commands, excludes: excludes, ssh_hosts: ssh_hosts, output: output)
  end

  before do
    allow(git).to receive_messages(root: root)
    allow(git).to receive(:valid_branch_name?) { |_path, name| !name.include?("..") }
    allow(git).to receive(:worktree_exists?) { |path| worktrees.include?(path) }
    allow(git).to receive(:branch_exists?) { |name| branches.include?(name) }
    allow(git).to receive(:find_worktree_by_branch).and_return(nil)
    allow(git).to receive(:branch_tracking).and_return({"remote" => nil, "merge" => nil})
    allow(git).to receive(:remote_config_url) { |_path, remote| remotes[remote] }
    allow(git).to receive(:remote_effective_url) { |path, remote| expanded.fetch(remote) { git.remote_config_url(path, remote) } }
    allow(git).to receive(:local_branch_exists?) { |name| local_branches.include?(name) }
    allow(catalog).to receive(:find).with("flow").and_return(definition)
    allow(ticket_source).to receive(:fetch).and_return(ticket)
    allow(engine).to receive(:preflight) do |definition:, inputs:, **|
      {"workflow" => "flow", "workspace" => "app", "project" => "app", "step" => "plan", "pane" => nil, "inputs" => inputs, "packs" => ["play/binding"]}
    end
  end

  it "refuses an unknown workflow before anything else" do
    allow(catalog).to receive(:find).with("nope").and_raise(Workspace::Error.new("No workflow nope.", code: "unknown_workflow"))
    expect(git).not_to receive(:root)

    expect { command.call(id: "nope", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workflow") }
  end

  it "seeds task from a JIRA ticket's key, title and url" do
    row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect(row["inputs"]["task"]).to eq("PROJ-1: Fix login (https://acme.atlassian.net/browse/PROJ-1)")
    expect(row["branch"]).to eq("PROJ-1")
    expect(ticket_source).to have_received(:fetch).with(having_attributes(kind: "jira"), chdir: root)
  end

  it "puts the ticket line before the prompt when both are given" do
    row = command.call(id: "flow", ref: "PROJ-1", prompt: "Keep it small.", dry_run: true)

    expect(row["inputs"]["task"]).to eq("PROJ-1: Fix login (https://acme.atlassian.net/browse/PROJ-1)\n\nKeep it small.")
  end

  it "lets --input task= win over the ticket" do
    row = command.call(id: "flow", ref: "PROJ-1", inputs: {"task" => "mine"}, dry_run: true)

    expect(row["inputs"]["task"]).to eq("mine")
  end

  it "seeds only inputs the definition declares" do
    definition = Workspace::WorkflowDefinition.parse("steps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    allow(catalog).to receive(:find).with("flow").and_return(definition)

    row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect(row["inputs"]).to eq({})
  end

  it "seeds a declared pr input from a pull request ref's number, never over --input, and not for a branch" do
    definition = Workspace::WorkflowDefinition.parse("inputs:\n  task:\n  pr:\nsteps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    allow(catalog).to receive(:find).with("flow").and_return(definition)
    pr_ticket = ticket.merge("url" => "https://github.com/o/r/pull/12", "key" => "o/r#12", "cross_repository" => false)

    allow(ticket_source).to receive(:fetch).and_return(pr_ticket)
    expect(command.call(id: "flow", ref: "https://github.com/o/r/pull/12", dry_run: true)["inputs"]).to include("pr" => "12")
    expect(command.call(id: "flow", ref: "https://github.com/o/r/pull/12", inputs: {"pr" => "99"}, dry_run: true)["inputs"]).to include("pr" => "99")
    expect(command.call(id: "flow", ref: "my-branch", dry_run: true)["inputs"]).not_to have_key("pr")
  end

  it "leaves pr empty for an issue or JIRA ref, and for a workflow that does not declare it" do
    with_pr = Workspace::WorkflowDefinition.parse("inputs:\n  pr:\nsteps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    allow(catalog).to receive(:find).with("flow").and_return(with_pr)
    expect(command.call(id: "flow", ref: "PROJ-1", dry_run: true)["inputs"]).not_to have_key("pr")
    expect(command.call(id: "flow", ref: "https://github.com/o/r/issues/5", dry_run: true)["inputs"]).not_to have_key("pr")

    without = Workspace::WorkflowDefinition.parse("inputs:\n  task:\nsteps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    allow(catalog).to receive(:find).with("flow").and_return(without)
    allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/12", "cross_repository" => false))
    expect(command.call(id: "flow", ref: "https://github.com/o/r/pull/12", dry_run: true)["inputs"]).not_to have_key("pr")
  end

  it "reports the file the ticket body would go to as spec, only when spec is declared and not given" do
    row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)
    expect(row["inputs"]["spec"]).to eq("/src/app/.worktrees/PROJ-1/.workflow/tickets/PROJ-1.md")

    given = command.call(id: "flow", ref: "PROJ-1", inputs: {"spec" => "x.md"}, dry_run: true)
    expect(given["inputs"]["spec"]).to eq("x.md")

    allow(ticket_source).to receive(:fetch).and_return(ticket.merge("body" => ""))
    expect(command.call(id: "flow", ref: "PROJ-1", dry_run: true)["inputs"]).not_to have_key("spec")
  end

  it "derives the branch from a prompt alone" do
    row = command.call(id: "flow", prompt: "Fix the login bug!", dry_run: true)

    expect(row).to include("branch" => "fix-the-login-bug", "path" => "/src/app/.worktrees/fix-the-login-bug", "would_create" => true)
    expect(row["inputs"]["task"]).to eq("Fix the login bug!")
    expect(ticket_source).not_to have_received(:fetch)
  end

  it "asks for --branch when the prompt has no letters or digits" do
    expect { command.call(id: "flow", prompt: "!!!") }.to raise_error(Workspace::UsageError, /--branch/)
  end

  it "needs a ref or a prompt, and not a ref with --branch" do
    expect { command.call(id: "flow") }.to raise_error(Workspace::UsageError, /REF or --prompt/)
    expect { command.call(id: "flow", ref: "PROJ-1", branch: "x") }.to raise_error(Workspace::UsageError, /--branch/)
  end

  it "refuses an invalid --branch" do
    expect { command.call(id: "flow", prompt: "x", branch: "bad..name") }.to raise_error(Workspace::UsageError, /not a valid branch name/)
  end

  it "refuses a derived branch that exists, or whose worktree does, with branch_exists" do
    branches << "fix-login"
    expect { command.call(id: "flow", prompt: "Fix login") }.to raise_error(Workspace::Error) do |e|
      expect(e.code).to eq("branch_exists")
      expect(e.details).to include("branch" => "fix-login", "worktree" => false)
    end

    branches.clear
    worktrees << "/src/app/.worktrees/fix-login"
    expect { command.call(id: "flow", prompt: "Fix login", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("branch_exists") }
  end

  it "reuses an existing workspace for a named --branch or a ticket ref" do
    branches << "mine"
    worktrees << "/src/app/.worktrees/mine" << "/src/app/.worktrees/PROJ-1"

    named = command.call(id: "flow", prompt: "x", branch: "mine", dry_run: true)
    ticketed = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect([named["would_create"], ticketed["would_create"]]).to eq([false, false])
  end

  it "refuses a derived branch that exists only on the remote or as a plain directory" do
    branches << "fix-login"
    expect { command.call(id: "flow", prompt: "Fix login") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("branch_exists") }

    branches.clear
    Dir.mktmpdir do |dir|
      allow(git).to receive(:root).and_return(dir)
      FileUtils.mkdir_p(File.join(dir, ".worktrees", "fix-login"))
      expect { command.call(id: "flow", prompt: "Fix login") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("branch_exists") }
    end
  end

  it "reports the worktree where start would adopt a branch checked out elsewhere" do
    allow(git).to receive(:find_worktree_by_branch).with("PROJ-1", repo: root).and_return("/elsewhere/proj-1")

    row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect(row).to include("path" => "/elsewhere/proj-1", "would_create" => false)
  end

  it "checks the agent kind of a reused worktree's own workspace, and the project's under its normalized name" do
    worktrees << "/src/app/.worktrees/PROJ-1"
    allow(project_config).to receive(:existing_name).with("app").and_return("App")
    allow(agent_commands).to receive(:kind).with("App").and_return("claude")
    allow(agent_commands).to receive(:kind).with("app.worktree-x").and_return("codex")

    expect { command.call(id: "flow", ref: "PROJ-1", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_needs_claude") }
    expect(project_config).to have_received(:worktree_config_name).with("App", "PROJ-1")
  end

  it "refuses before anything is made when the agent kind is not claude" do
    allow(agent_commands).to receive(:kind).with("app").and_return("codex")
    expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["workflow_needs_claude", {"agent_kind" => "codex"}]) }
    expect { command.call(id: "flow", ref: "PROJ-1", agent_kind: "codex") }.to raise_error(Workspace::Error)
    expect(ticket_source).not_to have_received(:fetch)
    expect { command.call(id: "flow", ref: "PROJ-1", agent_kind: "claude", dry_run: true) }.not_to raise_error
  end

  it "adds the ticket title's words to the branch with slug" do
    expect(command.call(id: "flow", ref: "PROJ-1", slug: true, dry_run: true)["branch"]).to eq("PROJ-1-fix-login")
  end

  describe "a ticket that can't be read" do
    before { allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("no jira", code: "ticket_source_unavailable")) }

    it "is refused when it was the only source of task" do
      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ticket_source_unavailable") }
    end

    it "is a warning when --prompt gives the task" do
      row = command.call(id: "flow", ref: "PROJ-1", prompt: "Fix login", dry_run: true)

      expect(row["inputs"]["task"]).to eq("Fix login")
      expect(row["warnings"]).to contain_exactly(/PROJ-1.*no jira/)
      expect(row["ticket"]).to be_nil
    end

    it "is a warning when --input task= gives the task" do
      row = command.call(id: "flow", ref: "PROJ-1", inputs: {"task" => "x"}, dry_run: true)

      expect(row["warnings"].size).to eq(1)
    end

    it "warns that --slug was ignored" do
      row = command.call(id: "flow", ref: "PROJ-1", prompt: "Fix login", slug: true, dry_run: true)

      expect(row["branch"]).to eq("PROJ-1")
      expect(row["warnings"]).to include("--slug ignored: ticket unreadable")
    end

    it "is a warning, not a refusal, when the definition has no task input" do
      bare = Workspace::WorkflowDefinition.parse("steps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
      allow(catalog).to receive(:find).with("flow").and_return(bare)

      row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

      expect(row["warnings"].size).to eq(1)
    end

    it "does not hide a ticket_not_found as a warning when it was the only source" do
      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("none", code: "ticket_not_found"))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ticket_not_found") }
    end
  end

  it "refuses a missing required input as preflight does" do
    allow(engine).to receive(:preflight).and_raise(Workspace::Error.new("needs task", code: "input_required"))

    expect { command.call(id: "flow", ref: "feature/x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("input_required") }
  end

  it "hands preflight the seeded pr, so its pattern check sees it" do
    definition = Workspace::WorkflowDefinition.parse("inputs:\n  pr: {pattern: '[0-9]+'}\nsteps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    allow(catalog).to receive(:find).with("flow").and_return(definition)
    allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/12", "key" => "o/r#12", "cross_repository" => false))
    allow(engine).to receive(:preflight).and_raise(Workspace::Error.new("bad", code: "invalid_input"))

    expect { command.call(id: "flow", ref: "https://github.com/o/r/pull/12") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_input") }
    expect(engine).to have_received(:preflight).with(hash_including(inputs: hash_including("pr" => "12")))
  end

  it "preflights against the main checkout, with no pane, and checks no tree for a checkout it will make" do
    command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect(engine).to have_received(:preflight).with(hash_including(workspace: "app", worktree: root, pane: nil, tree: nil))
  end

  it "checks the tree of a reused or adopted checkout" do
    worktrees << "/src/app/.worktrees/PROJ-1"
    command.call(id: "flow", ref: "PROJ-1", dry_run: true)
    expect(engine).to have_received(:preflight).with(hash_including(tree: "/src/app/.worktrees/PROJ-1"))

    allow(git).to receive(:find_worktree_by_branch).with("mine", repo: root).and_return("/elsewhere/mine")
    command.call(id: "flow", prompt: "x", branch: "mine", dry_run: true)
    expect(engine).to have_received(:preflight).with(hash_including(tree: "/elsewhere/mine"))
  end

  describe "a dirty reused checkout" do
    let(:repo) { Dir.mktmpdir("wfs-dirty") }
    let(:guarded) do
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
        inputs:
          task:
        steps:
          look:
            prompt: Look.
            guard: unchanged
      YAML
    end

    before do
      git_env = {"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"}
      system(git_env, "git", "-C", repo, "init", "-q", "-b", "main", exception: true)
      File.write(File.join(repo, "a.txt"), "one\n")
      system(git_env, "git", "-C", repo, "add", "a.txt", exception: true)
      system(git_env, "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init", exception: true)
      File.write(File.join(repo, "a.txt"), "two\n")
      allow(git).to receive(:find_worktree_by_branch).with("mine", repo: root).and_return(repo)
    end

    after { FileUtils.remove_entry(repo) }

    def real_engine
      Workspace::WorkflowEngine.allocate.tap do |real|
        real.instance_variable_set(:@guard, Workspace::WorkflowGuard.new)
        real.instance_variable_set(:@lineage, lineage)
        real.instance_variable_set(:@panes, nil)
        real.instance_variable_set(:@commands_config, instance_double(Workspace::CommandsConfig, for_project: {test: "rspec", lint: "standardrb"}))
        allow(real).to receive(:compose).and_return({"packs" => []})
      end
    end

    it "is refused with dirty_worktree, also in a dry run, for a guarded workflow" do
      allow(catalog).to receive(:find).with("flow").and_return(guarded)
      expect(start).not_to receive(:payload)

      [true, false].each do |dry_run|
        expect { build_command(real_engine).call(id: "flow", prompt: "x", branch: "mine", dry_run: dry_run) }.to raise_error(Workspace::Error) do |e|
          expect(e.code).to eq("dirty_worktree")
          expect(e.details).to include("path" => repo, "guard" => "tracked_changed", "files" => ["a.txt"])
        end
      end
    end

    it "is not refused for rpiv, which has no guarded step" do
      rpiv = Workspace::WorkflowDefinition.parse(File.read(File.expand_path("../../../lib/workflows/rpiv.yml", __dir__)), id: "rpiv", source: "preset", path: "rpiv.yml")
      allow(catalog).to receive(:find).with("rpiv").and_return(rpiv)

      row = build_command(real_engine).call(id: "rpiv", prompt: "x", branch: "mine", dry_run: true)

      expect(row).to include("outcome" => "dry_run", "path" => repo, "would_create" => false)
    end
  end

  describe "a pull request from a fork" do
    let(:pr_ticket) { ticket.merge("url" => "https://github.com/o/r/pull/12", "cross_repository" => true) }

    before { allow(ticket_source).to receive(:fetch).and_return(pr_ticket) }

    it "is refused before any worktree, check or agent, also in a dry run" do
      expect(start).not_to receive(:payload)
      expect(git).not_to receive(:find_worktree_by_branch)
      expect(git).not_to receive(:worktree_exists?)

      [true, false].each do |dry_run|
        expect { command.call(id: "flow", ref: "#12", prompt: "x", dry_run: dry_run) }.to raise_error(Workspace::Error) do |e|
          expect(e.code).to eq("fork_pull_request")
          expect(e.details).to eq("pr" => 12, "url" => "https://github.com/o/r/pull/12", "cross_repository" => true, "reason" => "cross_repository", "next" => ["workspace start '#12'"])
          expect(e.message).to include("comes from a fork", "workspace start '#12'", "workspace workflow run flow")
        end
      end
      expect(engine).not_to have_received(:preflight)
    end

    it "is refused when gh can't say whether it is from a fork" do
      pr_ticket["cross_repository"] = nil

      expect { command.call(id: "flow", ref: "o/r#12", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("fork_pull_request")
        expect(e.details["cross_repository"]).to be_nil
        expect(e.message).to include("Could not tell whether the pull request o/r#12 comes from a fork")
      end
    end

    it "is refused for every workflow, rpiv too" do
      allow(catalog).to receive(:find).with("rpiv").and_return(Workspace::WorkflowDefinition.parse("steps:\n  plan:\n    prompt: Go.\n", id: "rpiv", source: "preset", path: "rpiv.yml"))

      expect { command.call(id: "rpiv", ref: "#12", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("fork_pull_request") }
    end

    %w[ticket_not_found ticket_source_unavailable].each do |code|
      it "is refused with #{code} when it can't be read, even with --prompt" do
        allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("no", code: code))

        expect { command.call(id: "flow", ref: "#12", prompt: "x", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq(code) }
        expect { command.call(id: "flow", ref: "#12", inputs: {"task" => "x"}, dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq(code) }
      end
    end

    it "leaves an unreadable issue a warning with --prompt" do
      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("no", code: "ticket_not_found"))

      row = command.call(id: "flow", ref: "https://github.com/o/r/issues/5", prompt: "x", dry_run: true)

      expect(row["warnings"].size).to eq(1)
    end
  end

  describe "the repository a pull request is read from and checked out from" do
    let(:dir) { Dir.mktmpdir("wfs-pr") }
    let(:gh_calls) { [] }
    let(:real_source) do
      runner = lambda do |argv, chdir:, timeout:|
        gh_calls << argv
        [JSON.generate("title" => "T", "body" => "", "url" => "https://github.com/o/r/pull/12", "isCrossRepository" => false), "", true]
      end
      Workspace::TicketSource.new(runner: runner, which: ->(_) { true })
    end

    before do
      allow(git).to receive(:root).and_return(dir)
      allow(start).to receive(:payload) do |input, **|
        checkouts << input
        {exit_code: 1, json: {"ok" => false, "error" => "stop here", "code" => "usage"}}
      end
    end

    let(:checkouts) { [] }

    after { FileUtils.remove_entry(dir) }

    {"#12" => nil, "o/r#12" => "o/r", "https://github.com/o/r/pull/12" => "o/r"}.each do |ref, viewed_with|
      it "is the same for #{ref}" do
        command = described_class.new(catalog: catalog, engine: engine, start_ref: start_ref, ticket_source: real_source, git: git, project_config: project_config,
          start: start, workflow: workflow, readiness: readiness, tmux: tmux, agent_commands: agent_commands, excludes: excludes, ssh_hosts: ssh_hosts, output: output)

        expect { command.call(id: "flow", ref: ref) }.to raise_error(Workspace::Error, /stop here/)

        view = gh_calls.first
        expect(view.include?("--repo") ? view[view.index("--repo") + 1] : nil).to eq(viewed_with)
        # A bare #12 is viewed in the checkout's repository, which answered o/r; the checkout names it.
        expect(checkouts.map { |input| start_ref.call(input).pr[:repo] }).to eq(["o/r"])
      end
    end
  end

  describe "a reused or adopted branch that tracks another repository" do
    before { allow(git).to receive(:find_worktree_by_branch).with("feature", repo: root).and_return("/elsewhere/feature") }

    def refusal
      command.call(id: "flow", prompt: "x", branch: "feature", dry_run: true)
      nil
    rescue Workspace::Error => e
      e
    end

    it "is refused when it merges a pull request ref, with nothing made" do
      allow(git).to receive(:branch_tracking).with("/elsewhere/feature", "feature").and_return({"remote" => "origin", "merge" => "refs/pull/7/head"})
      expect(start).not_to receive(:payload)

      e = refusal
      expect(e.code).to eq("fork_pull_request")
      expect(e.details).to eq("branch" => "feature", "path" => "/elsewhere/feature", "reason" => "pull_ref", "next" => ["workspace start feature"])
      expect(e.message).to include("workspace start feature")
      expect(engine).not_to have_received(:preflight)
    end

    it "is refused when its remote is a URL, or a remote with no URL" do
      allow(git).to receive(:branch_tracking).and_return({"remote" => "https://github.com/fork/r.git", "merge" => "refs/heads/feature"})
      expect(refusal.details["reason"]).to eq("url_remote")

      allow(git).to receive(:branch_tracking).and_return({"remote" => "git@github.com:fork/r.git", "merge" => "refs/heads/feature"})
      expect(refusal.details["reason"]).to eq("url_remote")

      allow(git).to receive(:branch_tracking).and_return({"remote" => "gone", "merge" => "refs/heads/feature"})
      expect(refusal.details["reason"]).to eq("unknown_remote")
    end

    it "is refused when its remote is another repository than origin's, and passes for the same one" do
      allow(git).to receive(:branch_tracking).and_return({"remote" => "upstream", "merge" => "refs/heads/feature"})
      allow(git).to receive(:remote_config_url).with("/elsewhere/feature", "origin").and_return("git@github.com:O/R.git")
      allow(git).to receive(:remote_config_url).with("/elsewhere/feature", "upstream").and_return("https://github.com/fork/r")
      expect(refusal.details["reason"]).to eq("other_repository")

      allow(git).to receive(:remote_config_url).with("/elsewhere/feature", "upstream").and_return("https://github.com/o/r.git/")
      expect(refusal).to be_nil
    end

    it "passes for origin, a local upstream or none" do
      [{"remote" => "origin", "merge" => "refs/heads/feature"}, {"remote" => ".", "merge" => "refs/heads/main"}, {"remote" => nil, "merge" => nil}].each do |tracking|
        allow(git).to receive(:branch_tracking).and_return(tracking)
        expect(refusal).to be_nil
      end
    end
  end

  describe "a pull request's base repository" do
    def pr(url, cross: false) = ticket.merge("url" => url, "cross_repository" => cross)

    def refusal(ref)
      command.call(id: "flow", ref: ref, dry_run: true)
      nil
    rescue Workspace::Error => e
      e
    end

    it "is refused when it is not origin's or upstream's, whatever the ref names" do
      allow(ticket_source).to receive(:fetch).and_return(pr("https://github.com/attacker/evil/pull/1"))
      expect(start).not_to receive(:payload)

      ["attacker/evil#1", "https://github.com/attacker/evil/pull/1", "#1"].each do |ref|
        e = refusal(ref)
        expect(e.code).to eq("fork_pull_request")
        expect(e.details).to include("reason" => "other_base_repository", "pr" => 1, "cross_repository" => false)
        expect(e.message).to include("github.com/attacker/evil", "CLAUDE.md")
      end
    end

    it "is refused on another host with the same owner/repo, and when the URL is not that pull request's" do
      allow(ticket_source).to receive(:fetch).and_return(pr("https://ghe.example.com/o/r/pull/12"))
      expect(refusal("#12").details["reason"]).to eq("other_base_repository")

      allow(ticket_source).to receive(:fetch).and_return(pr("https://github.com/o/r/pull/13"))
      expect(refusal("#12").details["reason"]).to eq("other_base_repository")

      allow(ticket_source).to receive(:fetch).and_return(pr(nil))
      expect(refusal("#12").details["reason"]).to eq("other_base_repository")
    end

    context "when origin is written as a short form or a host alias" do
      before { allow(ticket_source).to receive(:fetch).and_return(pr("https://github.com/o/r/pull/12")) }

      it "passes when git's insteadOf expands the short form to the same repository" do
        remotes["origin"] = "gh:o/r"
        expanded["origin"] = "https://github.com/o/r"

        expect(refusal("#12")).to be_nil
        expect(ssh_runs).to be_empty
      end

      it "is refused when the short form is not expanded" do
        remotes["origin"] = "gh:o/r"
        ssh_answer.replace(["", "", false])

        expect(refusal("#12").details["reason"]).to eq("other_base_repository")
      end

      it "passes when an ssh alias resolves to the real host" do
        remotes["origin"] = "git@github-work:o/r.git"
        ssh_answer.replace(["hostname github.com\n", "", true])

        expect(refusal("#12")).to be_nil
        expect(ssh_runs).to eq([["ssh", "-G", "--", "github-work"]])
      end

      it "is refused when the alias resolves to another host" do
        remotes["origin"] = "git@github-work:o/r.git"
        ssh_answer.replace(["hostname ghe.example.com\n", "", true])

        expect(refusal("#12").details["reason"]).to eq("other_base_repository")
      end

      it "is refused without running ssh when the alias starts with a dash or is not a plain name" do
        ["ssh://-oProxyCommand=x/o/r.git", "ssh://a b/o/r.git", "ssh://a;b/o/r.git"].each do |url|
          remotes["origin"] = url
          expect(refusal("#12").details["reason"]).to eq("other_base_repository")
        end
        expect(ssh_runs).to be_empty
      end

      it "is refused when ssh -G fails or times out" do
        remotes["origin"] = "git@github-work:o/r.git"
        ssh_answer.replace(["", "boom", false])
        expect(refusal("#12").details["reason"]).to eq("other_base_repository")

        hosts = Workspace::SshHostResolver.new(runner: ->(*, **) { raise Timeout::Error })
        expect(hosts.hostname("github-work")).to be_nil
      end
    end

    it "passes for upstream's repository" do
      remotes.merge!("origin" => "https://github.com/me/r.git", "upstream" => "ssh://git@github.com:22/O/R.git")
      allow(ticket_source).to receive(:fetch).and_return(pr("https://github.com/o/r/pull/12"))

      expect(refusal("#12")).to be_nil
    end

    it "names the reason for a fork and for an unknown answer" do
      allow(ticket_source).to receive(:fetch).and_return(pr("https://github.com/o/r/pull/12", cross: nil))
      expect(refusal("#12").details["reason"]).to eq("unknown_cross_repository")
    end
  end

  describe "a pull request on another host than github.com" do
    let(:dir) { Dir.mktmpdir("wfs-ghe") }

    before do
      remotes["origin"] = "git@ghe.example.com:o/r.git"
      allow(git).to receive(:root).and_return(dir)
      allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://ghe.example.com/o/r/pull/12", "cross_repository" => false))
      allow(start).to receive(:payload).and_return({exit_code: 1, json: {"ok" => false, "error" => "stop here", "code" => "usage"}})
    end

    after { FileUtils.remove_entry(dir) }

    it "keeps a bare #N for start, which gh resolves from the same repository config as the read" do
      expect { command.call(id: "flow", ref: "#12") }.to raise_error(Workspace::Error, /stop here/)

      expect(start).to have_received(:payload).with("#12", anything)
    end
  end

  describe "a reused pr-N worktree for a pull request ref" do
    let(:same) { ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => false) }
    let(:fork) { ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => true) }

    before do
      worktrees << "/src/app/.worktrees/pr-7"
      allow(ticket_source).to receive(:fetch).and_return(same)
    end

    it "passes when start recorded that pull request, without another read" do
      allow(git).to receive(:branch_tracking).and_return({"remote" => nil, "merge" => nil, "pr" => "O/R#7"})

      expect(command.call(id: "flow", ref: "https://github.com/o/r/pull/7", dry_run: true)).to include("would_create" => false)
      expect(ticket_source).to have_received(:fetch).once
    end

    it "is refused when start recorded another pull request" do
      remotes["upstream"] = "https://github.com/up/r.git"
      allow(git).to receive(:branch_tracking).and_return({"remote" => nil, "merge" => nil, "pr" => "up/r#7"})

      expect { command.call(id: "flow", ref: "o/r#7", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("fork_pull_request")
        expect(e.details).to include("reason" => "other_pull_request", "branch" => "pr-7", "path" => "/src/app/.worktrees/pr-7")
      end
    end

    it "with no record, looks #N up and refuses a fork's checkout left by an earlier start '#7'" do
      allow(ticket_source).to receive(:fetch) { |ref, **| (ref.key == "#7") ? fork : same }

      expect { command.call(id: "flow", ref: "https://github.com/o/r/pull/7", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.details).to include("reason" => "cross_repository", "branch" => "pr-7")
      end
    end

    it "with no record, refuses when #N is another repository's pull request" do
      remotes["upstream"] = "https://github.com/up/r.git"
      allow(ticket_source).to receive(:fetch) { |ref, **| (ref.key == "#7") ? same.merge("url" => "https://github.com/up/r/pull/7") : same }

      expect { command.call(id: "flow", ref: "o/r#7", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.details).to include("reason" => "other_pull_request")
      end
    end

    it "with no record, passes when #N is the same pull request" do
      expect(command.call(id: "flow", ref: "#7", dry_run: true)).to include("would_create" => false)
      expect(ticket_source).to have_received(:fetch).twice
    end
  end

  describe "a local branch with no worktree" do
    before { allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => true)) }

    it "is checked, from the project's config, when it is a fork's pr-N left behind" do
      local_branches << "pr-7"
      expect(start).not_to receive(:payload)

      expect { command.call(id: "flow", ref: "pr-7", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("reason" => "cross_repository", "path" => root) }
      expect { command.call(id: "flow", prompt: "x", branch: "pr-7") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("fork_pull_request") }
      expect(git).to have_received(:branch_tracking).with(root, "pr-7").at_least(:once)
    end

    it "is refused when it tracks another repository" do
      local_branches << "feature"
      allow(git).to receive(:branch_tracking).with(root, "feature").and_return({"remote" => "alice", "merge" => "refs/heads/feature"})
      remotes["alice"] = "https://github.com/alice/r.git"

      expect { command.call(id: "flow", ref: "feature", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("reason" => "other_repository") }
    end

    it "is not checked when there is none" do
      expect(command.call(id: "flow", ref: "pr-7", dry_run: true)).to include("would_create" => true)
      expect(git).not_to have_received(:branch_tracking)
    end
  end

  describe "remotes the tracking check reads" do
    before { allow(git).to receive(:find_worktree_by_branch).with("feature", repo: root).and_return("/elsewhere/feature") }

    def reason_for(tracking)
      allow(git).to receive(:branch_tracking).and_return(tracking)
      command.call(id: "flow", prompt: "x", branch: "feature", dry_run: true)
      nil
    rescue Workspace::Error => e
      e.details["reason"]
    end

    it "passes upstream when origin is your fork and upstream the project" do
      remotes.merge!("origin" => "git@github.com:me/r.git", "upstream" => "git@github.com:o/r.git")

      expect(reason_for({"remote" => "upstream", "merge" => "refs/heads/feature"})).to be_nil
    end

    it "compares the host, and refuses a relative or local path remote" do
      remotes["other"] = "git@gitlab.com:o/r.git"
      expect(reason_for({"remote" => "other", "merge" => "refs/heads/feature"})).to eq("other_repository")

      remotes["other"] = "../r"
      expect(reason_for({"remote" => "other", "merge" => "refs/heads/feature"})).to eq("other_repository")

      remotes["other"] = "file:///src/r.git"
      expect(reason_for({"remote" => "other", "merge" => "refs/heads/feature"})).to eq("other_repository")

      remotes["other"] = "https://github.com/o/r"
      expect(reason_for({"remote" => "other", "merge" => "refs/heads/feature"})).to be_nil
    end

    it "reads a local pr-N it tracks as that pull request, and refuses a pull ref under the local remote" do
      allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => true))

      expect(reason_for({"remote" => ".", "merge" => "refs/heads/pr-7"})).to eq("cross_repository")
      expect(ticket_source).to have_received(:fetch).with(having_attributes(key: "#7"), chdir: root)
      expect(reason_for({"remote" => ".", "merge" => "refs/pull/7/head"})).to eq("pull_ref")
      expect(reason_for({"remote" => ".", "merge" => "refs/heads/main"})).to be_nil
    end
  end

  describe "a reused pr-N branch" do
    before do
      allow(git).to receive(:find_worktree_by_branch).with("pr-7", repo: root).and_return("/elsewhere/pr-7")
      allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => true))
    end

    it "is read as pull request #N, whose upstream start dropped, and refused when it is from a fork" do
      expect { command.call(id: "flow", ref: "pr-7", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("fork_pull_request")
        expect(e.details).to include("pr" => 7, "branch" => "pr-7", "path" => "/elsewhere/pr-7", "cross_repository" => true)
      end
      expect(ticket_source).to have_received(:fetch).with(having_attributes(kind: "github_pr", key: "#7"), chdir: root)
      expect { command.call(id: "flow", prompt: "x", branch: "pr-7", dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("fork_pull_request") }
    end

    it "passes for a pull request from the same repository" do
      allow(ticket_source).to receive(:fetch).and_return(ticket.merge("url" => "https://github.com/o/r/pull/7", "cross_repository" => false))

      expect(command.call(id: "flow", ref: "pr-7", dry_run: true)).to include("would_create" => false)
    end

    it "is refused with the read's code when the pull request can't be read" do
      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("gh failed", code: "ticket_source_unavailable", details: {"source" => "gh"}))

      expect { command.call(id: "flow", prompt: "x", branch: "pr-7", dry_run: true) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("ticket_source_unavailable")
        expect(e.details).to include("source" => "gh", "branch" => "pr-7")
      end
    end

    it "is not read when nothing is reused" do
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)

      command.call(id: "flow", ref: "pr-7", dry_run: true)

      expect(ticket_source).not_to have_received(:fetch)
    end
  end

  it "lets a command set at the project layer pass the check the new worktree would make" do
    config = instance_double(Workspace::ConfigResolver)
    view = ->(workspace) { double(raw: ->(_) {}).tap { |v| allow(v).to receive(:raw) { |key| (workspace == "app" && key == "commands.test") ? "bundle exec rspec" : nil } } }
    allow(config).to receive(:view) { |workspace:| view.call(workspace) }
    real = Workspace::WorkflowEngine.allocate
    real.instance_variable_set(:@commands_config, Workspace::CommandsConfig.new(config_resolver: config))
    real.instance_variable_set(:@lineage, lineage)
    real.instance_variable_set(:@panes, nil)
    allow(real).to receive(:compose).and_return({"packs" => []})
    checking = Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      inputs:
        task: {required: true}
      steps:
        verify:
          prompt: Verify.
          status: {command: test}
    YAML
    allow(catalog).to receive(:find).with("flow").and_return(checking)
    command = build_command(real)

    row = command.call(id: "flow", prompt: "Fix it", dry_run: true)

    expect(row).to include("outcome" => "dry_run", "step" => "verify")
  end

  describe "the dry run" do
    it "returns the row and creates nothing" do
      expect(command).not_to receive(:start_workspace)
      expect(git).not_to receive(:add_worktree)

      row = command.call(id: "flow", ref: "PROJ-1", dry_run: true)

      expect(row).to eq(
        "workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => "Would create the workspace for PROJ-1 in app and start flow at step plan.", "workflow" => "flow", "step" => "plan",
        "project" => "app", "branch" => "PROJ-1", "path" => "/src/app/.worktrees/PROJ-1", "would_create" => true,
        "inputs" => {"task" => "PROJ-1: Fix login (https://acme.atlassian.net/browse/PROJ-1)",
                     "spec" => "/src/app/.worktrees/PROJ-1/.workflow/tickets/PROJ-1.md"},
        "packs" => ["play/binding"], "warnings" => [],
        "ticket" => {"key" => "PROJ-1", "title" => "Fix login", "url" => "https://acme.atlassian.net/browse/PROJ-1"}
      )
      expect(output.string).to match(/Would create the workspace for PROJ-1 in app and start flow at step plan/)
    end
  end

  describe "creating the workspace" do
    let(:dir) { Dir.mktmpdir("wfs") }
    let(:path) { File.join(dir, ".worktrees", "PROJ-1") }
    let(:started) { {"workspace" => "app.worktree-PROJ-1", "path" => path, "branch" => "PROJ-1", "created" => true, "task" => {"id" => "t1", "title" => "Fix login"}} }

    before do
      allow(git).to receive(:root).and_return(dir)
      allow(start).to receive(:payload).and_return({exit_code: 0, json: started})
      allow(tmux).to receive(:session_name_for).with("app.worktree-PROJ-1").and_return("app-wt")
      allow(readiness).to receive(:wait).and_return(ready)
      allow(workflow).to receive(:run).and_return({"workspace" => "app.worktree-PROJ-1", "outcome" => "started", "run_id" => "wr_1"})
    end

    after { FileUtils.remove_entry(dir) }

    it "starts the workspace with no prompt, waits on its session, and runs in the ready pane" do
      row = command.call(id: "flow", ref: "PROJ-1", base: "main", headless: true, prompt_timeout: 30)

      expect(start).to have_received(:payload).with("PROJ-1", yes: true, base: "main", headless: true, spine: false, no_packs: true, title: "Fix login")
      expect(readiness).to have_received(:deadline_in).with(30)
      expect(readiness).to have_received(:wait).with("app-wt", deadline: 99.0, detector: :detector)
      expect(workflow).to have_received(:run).with(hash_including(id: "flow", workspace: "app.worktree-PROJ-1", worktree: path, pane: "%7", note: nil))
      expect(row).to include("outcome" => "started", "run_id" => "wr_1", "branch" => "PROJ-1", "path" => path, "created" => true,
        "task" => {"id" => "t1", "title" => "Fix login"}, "warnings" => [])
      expect(row["ticket"]).to include("key" => "PROJ-1")
    end

    it "titles the task with the prompt when there is no ticket" do
      command.call(id: "flow", prompt: "Fix the login bug")

      expect(start).to have_received(:payload).with("fix-the-login-bug", hash_including(title: "Fix the login bug"))
    end

    it "titles the task with only the prompt's first line" do
      command.call(id: "flow", prompt: "Fix the login bug\n\nIt fails on Safari.", branch: "fix-login")

      expect(start).to have_received(:payload).with("fix-login", hash_including(title: "Fix the login bug"))
    end

    it "writes the ticket body to the spec file and excludes .workflow/, only when spec is declared" do
      command.call(id: "flow", ref: "PROJ-1")

      expect(File.read(File.join(path, ".workflow/tickets/PROJ-1.md"))).to eq("Details.")
      expect(excludes).to have_received(:add).with(path, "/.workflow/")
      expect(workflow).to have_received(:run).with(hash_including(inputs: hash_including("spec" => File.join(path, ".workflow/tickets/PROJ-1.md"))))
    end

    it "writes the ticket file under the path start returned and points spec at it" do
      other = File.join(dir, "elsewhere")
      allow(start).to receive(:payload).and_return({exit_code: 0, json: started.merge("path" => other)})
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "slow"))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.details["next"].first).to include(File.join(other, ".workflow/tickets/PROJ-1.md")) }
      expect(File.read(File.join(other, ".workflow/tickets/PROJ-1.md"))).to eq("Details.")
      expect(excludes).to have_received(:add).with(other, "/.workflow/")

      allow(readiness).to receive(:wait).and_return(ready)
      command.call(id: "flow", ref: "PROJ-1")
      expect(workflow).to have_received(:run).with(hash_including(worktree: other, inputs: hash_including("spec" => File.join(other, ".workflow/tickets/PROJ-1.md"))))
    end

    it "leaves a spec given with --input alone, with a ticket or a prompt" do
      mine = File.join(dir, "mine.md")
      File.write(mine, "mine")

      command.call(id: "flow", ref: "PROJ-1", inputs: {"spec" => mine})
      expect { command.call(id: "flow", prompt: "Fix it", inputs: {"spec" => mine}) }.not_to raise_error

      expect(File.read(mine)).to eq("mine")
      expect(File.exist?(File.join(path, ".workflow"))).to be false
      expect(workflow).to have_received(:run).with(hash_including(inputs: hash_including("spec" => mine))).twice
    end

    it "keeps the workspace and names the command when writing the ticket fails" do
      allow(File).to receive(:write).and_raise(Errno::EACCES)

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("error")
        expect(e.details).to include("workspace" => "app.worktree-PROJ-1", "path" => path)
        expect(e.details["next"].first).to start_with("workspace workflow run flow --name app.worktree-PROJ-1")
      end
    end

    it "keeps a UsageError a UsageError and carries start's warnings" do
      allow(start).to receive(:payload).and_return({exit_code: 0, json: started.merge("warnings" => ["careful"])})
      allow(workflow).to receive(:run).and_raise(Workspace::UsageError, "bad")

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::UsageError) { |e| expect(e.details["warnings"]).to eq(["careful"]) }
    end

    it "raises start_failed when its session did not start" do
      allow(start).to receive(:payload).and_return({exit_code: 1, json: started.merge("launched" => false, "error" => "Could not start the workspace session: x")})

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("start_failed")
        expect(e.message).to include("Could not start the workspace session")
        expect(e.details["next"].first).to start_with("workspace workflow run flow --name app.worktree-PROJ-1")
      end
      expect(readiness).not_to have_received(:wait)
    end

    it "passes agent_kind and slug to start, and waits the default time without a prompt_timeout" do
      command.call(id: "flow", ref: "PROJ-1", agent_kind: "claude", slug: true)

      expect(start).to have_received(:payload).with("PROJ-1", hash_including(agent_kind: "claude", slug: true))
      expect(readiness).to have_received(:deadline_in).with(Workspace::AgentReadiness::DEFAULT_TIMEOUT)
    end

    it "writes no file when the definition declares no spec" do
      bare = Workspace::WorkflowDefinition.parse("inputs:\n  task: {required: true}\nsteps:\n  plan:\n    prompt: Go.\n", id: "flow", source: "global", path: "/d.yml")
      allow(catalog).to receive(:find).with("flow").and_return(bare)

      command.call(id: "flow", ref: "PROJ-1")

      expect(File.exist?(File.join(path, ".workflow"))).to be false
      expect(excludes).not_to have_received(:add)
    end

    it "keeps the workspace and names the command when the agent is not ready" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up"))

      expect { command.call(id: "flow", ref: "PROJ-1", inputs: {"task" => "do it"}) }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("agent_not_ready")
        expect(e.message).to include("(waited up to 60s)")
        expect(e.details).to include("workspace" => "app.worktree-PROJ-1", "path" => path)
        expect(e.details["next"].first).to start_with("workspace workflow run flow --name app.worktree-PROJ-1 --input task=do\\ it")
      end
      expect(workflow).not_to have_received(:run)
    end

    it "carries the note into the command it names" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up"))

      expect { command.call(id: "flow", ref: "PROJ-1", inputs: {"task" => "do it"}, note: "first try") }.to raise_error(Workspace::Error) do |e|
        expect(e.details["next"].first).to end_with(" --note first\\ try")
      end
    end

    it "leaves an input that was never set out of the command it names" do
      allow(engine).to receive(:preflight) { |inputs:, **| {"step" => "plan", "inputs" => inputs.merge("spec" => ""), "packs" => []} }
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up"))

      expect { command.call(id: "flow", ref: "PROJ-1", inputs: {"task" => "do it", "spec" => "s.md"}) }.to raise_error(Workspace::Error) do |e|
        expect(e.details["next"].first).not_to include("--input spec=")
      end
    end

    it "says the workspace is there, not that it was made, when it was reused" do
      worktrees << path
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up"))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) do |e|
        expect(e.message).to include("The workspace app.worktree-PROJ-1 is at #{path}")
      end
    end

    it "keeps the code of a failed run and adds where the workspace is" do
      allow(workflow).to receive(:run).and_raise(Workspace::Error.new("busy", code: "pane_has_run", details: {"pane" => "%7"}))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("pane_has_run")
        expect(e.details).to include("pane" => "%7", "workspace" => "app.worktree-PROJ-1", "path" => path)
        expect(e.details["next"].first).to match(/\Aworkspace workflow run flow --name app\.worktree-PROJ-1 /)
      end
    end

    it "sends no packs, and passes slug only when the ticket was read" do
      command.call(id: "flow", ref: "PROJ-1", slug: true)
      expect(start).to have_received(:payload).with("PROJ-1", hash_including(no_packs: true, slug: true))

      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("no", code: "ticket_source_unavailable"))
      command.call(id: "flow", ref: "PROJ-1", prompt: "x", slug: true)
      expect(start).to have_received(:payload).with("PROJ-1", hash_excluding(:slug)).once
    end

    it "treats a nonzero exit code as a failed session start even when launched is true" do
      allow(start).to receive(:payload).and_return({exit_code: 1, json: started.merge("launched" => true, "error" => "Prompt was not sent")})

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("start_failed") }
    end

    it "does not let a document without a workspace escape as a KeyError" do
      allow(start).to receive(:payload).and_return({exit_code: 1, json: {"ok" => false, "error" => "no base", "code" => "usage"}})

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("usage") }
    end

    it "keeps a person's own --input spec in the command when start fails after making the checkout" do
      allow(start).to receive(:payload) { worktrees << path && raise(Workspace::Error.new("x", code: "hook_error")) }

      expect { command.call(id: "flow", ref: "PROJ-1", inputs: {"spec" => "mine.md"}) }.to raise_error(Workspace::Error) { |e| expect(e.details["next"].first).to include("--input spec=mine.md") }
    end

    it "adds no next when the worktree was already there" do
      worktrees << path
      allow(start).to receive(:payload).and_raise(Workspace::Error.new("x", code: "hook_error"))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect(e.details).not_to have_key("next") }
    end

    it "points at the checkout when start fails after making it" do
      allow(start).to receive(:payload) { worktrees << path && raise(Workspace::Error.new("hooks failed", code: "hook_error")) }

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) do |e|
        expect(e.code).to eq("hook_error")
        expect(e.details).to include("path" => path)
        expect(e.details["next"].first).to start_with("cd #{path} && workspace workflow run flow")
      end
    end

    it "gives start's own failure unchanged, as nothing was made" do
      allow(start).to receive(:payload).and_raise(Workspace::Error.new("no base", code: "usage"))

      expect { command.call(id: "flow", ref: "PROJ-1") }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["usage", {}]) }
    end
  end
end
