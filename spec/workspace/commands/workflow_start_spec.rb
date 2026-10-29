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
      workflow: workflow, readiness: readiness, tmux: tmux, agent_commands: agent_commands, excludes: excludes, output: output)
  end

  before do
    allow(git).to receive_messages(root: root)
    allow(git).to receive(:valid_branch_name?) { |_path, name| !name.include?("..") }
    allow(git).to receive(:worktree_exists?) { |path| worktrees.include?(path) }
    allow(git).to receive(:branch_exists?) { |name| branches.include?(name) }
    allow(git).to receive(:find_worktree_by_branch).and_return(nil)
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

  it "preflights against the main checkout, with no pane" do
    command.call(id: "flow", ref: "PROJ-1", dry_run: true)

    expect(engine).to have_received(:preflight).with(hash_including(workspace: "app", worktree: root, pane: nil))
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
