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
  subject(:command) do
    described_class.new(catalog: catalog, engine: engine, start_ref: start_ref, ticket_source: ticket_source, git: git, output: output)
  end

  before do
    allow(git).to receive_messages(root: root)
    allow(git).to receive(:valid_branch_name?) { |_path, name| !name.include?("..") }
    allow(git).to receive(:worktree_exists?) { |path| worktrees.include?(path) }
    allow(git).to receive(:local_branch_exists?) { |name| branches.include?(name) }
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
    command = described_class.new(catalog: catalog, engine: real, start_ref: start_ref, ticket_source: ticket_source, git: git, output: output)

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

  it "leaves creating the workspace to the extension point" do
    expect { command.call(id: "flow", prompt: "Fix it") }.to raise_error(NotImplementedError)
  end
end
