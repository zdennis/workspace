require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Go do
  let(:project_root) { "/src/app" }
  let(:checkout) { "/src/app/.worktrees/feature" }
  let(:root) { checkout }
  let(:from_worktree) { true }
  let(:detected) { "app.worktree-feature" }
  let(:configured_root) { checkout }
  let(:current_branch) { "feature" }
  let(:main_branch) { "main" }
  let(:default_branch) { "main" }
  let(:names) { %w[feature main other pr-12] }
  let(:local_names) { names }
  let(:held) { {} }
  let(:stored_default) { nil }
  let(:tied) { "app" }
  let(:yaml) { "inputs:\n  task: {required: true}\nsteps:\n  plan:\n    prompt: Plan.\n" }
  let(:definition) { Workspace::WorkflowDefinition.parse(yaml, id: "rpiv", source: "global", path: "/defs/rpiv.yml") }
  let(:project) { Workspace::StartRef::Project.new(root: project_root, name: "app", from_worktree: from_worktree) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:start_ref) { Workspace::StartRef.new(git: git) }
  let(:workflow_start) { instance_double(Workspace::Commands::WorkflowStart, catalog_project: tied, check_agent!: nil, locate_project: {root: root, project: project, project_workspace: "app"}) }
  let(:workflow) { instance_double(Workspace::Commands::Workflow) }
  let(:workflow_defaults) { instance_double(Workspace::WorkflowDefaults) }
  let(:catalog) { instance_double(Workspace::WorkflowCatalog, known_ids: %w[pr-feedback rpiv], find: definition) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: detected) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: configured_root) }
  let(:output) { StringIO.new }
  let(:ticket_source) { instance_double(Workspace::TicketSource, fetch: {"title" => "T"}) }
  let(:running) { nil }
  let(:go_task) { instance_double(Workspace::Commands::GoTask, run_for: running) }
  let(:start_row) { {"workspace" => "app.worktree-x", "outcome" => "started", "warnings" => ["from start"]} }
  let(:run_row) { {"workspace" => detected, "outcome" => "started"} }

  subject(:command) do
    described_class.new(workflow_start: workflow_start, workflow: workflow, workflow_defaults: workflow_defaults, catalog: catalog, start_ref: start_ref,
      git: git, project_detector: project_detector, project_config: project_config, go_task: go_task, ticket_source: ticket_source, output: output, working_dir: root || "/nowhere")
  end

  before do
    allow(git).to receive(:root) { root }
    allow(start_ref).to receive(:project).and_return(project)
    allow(git).to receive(:default_branch_name).and_return(default_branch)
    allow(git).to receive(:branch_names) { names }
    allow(git).to receive(:local_branch_names) { local_names }
    allow(git).to receive(:branch_target) { |_path, name| name }
    allow(git).to receive(:find_worktree_by_branch) { |branch, **| held[branch] }
    allow(git).to receive(:worktree_exists?) { |path| held.value?(path) }
    allow(git).to receive(:worktree_branch) do |path|
      next main_branch if path == project_root
      next current_branch if path == root

      held.key(path)
    end
    allow(workflow_defaults).to receive(:lookup).and_return(stored_default)
    allow(File).to receive(:realpath).and_call_original
    allow(File).to receive(:realpath).with(%r{\A/(src|home)}) { |path| path }
    allow(workflow_start).to receive(:tracks_repository?) { |_root, repo| repo == "o/r" }
    allow(workflow_start).to receive(:call).and_return(start_row)
    allow(workflow).to receive(:run).and_return(run_row)
  end

  def refusal(**args)
    command.call(**args)
    nil
  rescue Workspace::Error => e
    e
  end

  def expect_nothing_ran
    expect(workflow).not_to have_received(:run)
    expect(workflow_start).not_to have_received(:call)
  end

  shared_context "main checkout" do
    let(:root) { project_root }
    let(:from_worktree) { false }
    let(:detected) { "app" }
    let(:configured_root) { project_root }
    let(:current_branch) { "main" }
  end

  shared_examples "not in place" do
    [false, true].each do |dry_run|
      it "starts a new worktree workspace for free text#{" (dry run)" if dry_run}" do
        row = command.call(argument: "fix the bug", dry_run: dry_run)

        expect(workflow_start).to have_received(:call).with(id: "rpiv", prompt: "fix the bug", headless: false, inputs: {}, dry_run: dry_run)
        expect(workflow).not_to have_received(:run)
        expect(row["decision"]["route"]).to eq("start")
        expect(output.string).to include("makes a new worktree workspace")
      end

      it "refuses bare go#{" (dry run)" if dry_run}" do
        error = refusal(dry_run: dry_run)

        expect(error).to be_a(Workspace::UsageError)
        expect(error.message).to include("linked worktree workspace off the default branch")
        expect_nothing_ran
      end
    end
  end

  shared_examples "refuses the default branch" do
    [false, true].each do |dry_run|
      it "refuses go main#{" (dry run)" if dry_run}" do
        error = refusal(argument: "main", dry_run: dry_run)

        expect(error.code).to eq("branch_not_allowed")
        expect(error.details).to include("branch" => "main", "reason" => "default_branch")
        expect_nothing_ran
      end
    end
  end

  describe "routes in place" do
    it "runs a bare go here with kind prompt" do
      row = command.call(caller_pane: "%3")

      expect(workflow).to have_received(:run).with(id: "rpiv", workspace: detected, worktree: root, inputs: {}, dry_run: false, caller_pane: "%3", project: "app")
      expect(workflow_start).not_to have_received(:call)
      expect(row["decision"]).to include("kind" => "prompt", "route" => "run")
    end

    it "runs free text here as the task" do
      command.call(argument: "fix the bug", inputs: {"a" => "b"}, here: true)

      expect(workflow).to have_received(:run).with(hash_including(inputs: {"a" => "b", "task" => "fix the bug"}))
      expect(output.string).to include("runs in this worktree")
    end

    it "passes a ref to this checkout's branch to WorkflowStart with here" do
      row = command.call(argument: "feature", caller_pane: "%3", dry_run: true, headless: true)

      expect(workflow_start).to have_received(:call) do |id:, ref:, here:, headless:, inputs:, dry_run:|
        expect([id, ref, headless, inputs, dry_run]).to eq(["rpiv", "feature", true, {}, true])
        expect(here.to_h).to eq(workspace: detected, path: root, caller_pane: "%3")
      end
      expect(workflow).not_to have_received(:run)
      expect(row["decision"]).to include("kind" => "branch", "route" => "run")
    end

    it "matches a pull request ref on its branch" do
      allow(git).to receive(:worktree_branch).with(root).and_return("pr-12")

      command.call(argument: "#12")

      expect(workflow_start).to have_received(:call).with(hash_including(ref: "#12", here: instance_of(Workspace::Commands::WorkflowStart::Here)))
    end

    it "leaves here out for any other ref" do
      row = command.call(argument: "other")

      expect(workflow_start).to have_received(:call).with(id: "rpiv", ref: "other", headless: false, here: nil, inputs: {}, dry_run: false)
      expect(row["decision"]["route"]).to eq("start")
      expect(output.string).to include("makes or reuses the worktree workspace for other")
    end
  end

  describe "free text from a linked worktree workspace" do
    it "starts a new workspace and touches nothing in the current one" do
      row = command.call(argument: "fix the bug", caller_pane: "%3")

      expect(workflow_start).to have_received(:call).with(id: "rpiv", prompt: "fix the bug", headless: false, inputs: {}, dry_run: false)
      expect(workflow).not_to have_received(:run)
      expect(row["decision"]).to include("kind" => "prompt", "route" => "start")
      expect(output.string).to include("makes a new worktree workspace")
    end

    context "with a branch that differs from the text's slug only in case" do
      let(:names) { %w[Feature-X main] }

      it "refuses the slug" do
        error = refusal(argument: "feature x")

        expect(error.code).to eq("branch_exists")
        expect_nothing_ran
      end
    end

    it "passes an existing branch name on to WorkflowStart's own check" do
      allow(workflow_start).to receive(:call).and_raise(Workspace::Error.new("Pass --branch.", code: "branch_exists", details: {"branch" => "other", "path" => "/src/app/.worktrees/other", "worktree" => false}))

      expect(refusal(argument: "other !").code).to eq("branch_exists")
    end

    it "refuses a slug that is the default branch" do
      expect(refusal(argument: "main !").code).to eq("branch_not_allowed")
      expect_nothing_ran
    end
  end

  describe "--here with a run going" do
    let(:running) { {"id" => "wr_1", "workflow" => "rpiv", "current" => "plan"} }
    let(:task_row) { {"outcome" => "added", "decision" => {"route" => "task"}} }

    before { allow(go_task).to receive(:add).and_return(task_row) }

    it "hands the text and the flags to the task path before choosing a workflow" do
      row = command.call(argument: "also this", here: true, workflow: "investigate", inputs: {"a" => "b"}, dry_run: true)

      expect(row).to eq(task_row)
      expect(go_task).to have_received(:add).with(running, "also this", an_object_having_attributes(workspace: detected), flags: {workflow: "investigate", inputs: {"a" => "b"}, base: nil}, dry_run: true)
      expect(workflow_defaults).not_to have_received(:lookup)
      expect_nothing_ran
    end

    it "leaves bare go --here to the run check" do
      command.call(here: true)

      expect(go_task).not_to have_received(:add)
      expect(workflow).to have_received(:run)
    end

    it "does not stop free text without --here from starting a workspace" do
      row = command.call(argument: "fix the bug")

      expect(go_task).not_to have_received(:run_for)
      expect(workflow_start).to have_received(:call)
      expect(row["decision"]["route"]).to eq("start")
    end
  end

  describe "--here" do
    it "runs free text here" do
      row = command.call(argument: "fix the bug", here: true, caller_pane: "%3")

      expect(workflow).to have_received(:run).with(hash_including(caller_pane: "%3", inputs: {"task" => "fix the bug"}))
      expect(workflow_start).not_to have_received(:call)
      expect(row["decision"]["route"]).to eq("run")
    end

    it "runs with a ref for the current branch" do
      expect(command.call(argument: "feature", here: true)["decision"]["route"]).to eq("run")
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "feature", here: instance_of(Workspace::Commands::WorkflowStart::Here)))
    end

    it "refuses a ref for another branch, as a usage error" do
      error = refusal(argument: "other", here: true)

      expect(error).to be_a(Workspace::UsageError)
      expect(error.message).to include("another branch")
      expect_nothing_ran
    end

    shared_examples "go_here_unavailable" do
      it "refuses with text and with no argument" do
        [{argument: "fix the bug"}, {}].each do |args|
          error = refusal(here: true, **args)

          expect(error.code).to eq("go_here_unavailable")
          expect(error.details).to eq("path" => root)
        end
        expect_nothing_ran
      end
    end

    context "in a main checkout" do
      include_context "main checkout"
      it_behaves_like "go_here_unavailable"
    end

    context "in a worktree with no marker of its own" do
      let(:configured_root) { nil }
      it_behaves_like "go_here_unavailable"
    end

    context "on a detached HEAD" do
      let(:current_branch) { nil }
      it_behaves_like "go_here_unavailable"
    end

    context "on the default branch" do
      let(:current_branch) { "main" }
      let(:main_branch) { "develop" }
      let(:held) { {"main" => root} }
      it_behaves_like "go_here_unavailable"
    end
  end

  describe "--base" do
    before { allow(git).to receive(:commit_exists?) { |_path, ref| %w[origin/main abc123].include?(ref) } }

    it "goes to WorkflowStart for free text" do
      command.call(argument: "try the thing", base: "origin/main")

      expect(workflow_start).to have_received(:call).with(hash_including(prompt: "try the thing", base: "origin/main"))
    end

    it "goes to WorkflowStart for a ref" do
      command.call(argument: "PROJ-1", base: "abc123")

      expect(workflow_start).to have_received(:call).with(hash_including(ref: "PROJ-1", base: "abc123"))
    end

    it "leaves base out of the call when not given" do
      command.call(argument: "try the thing")

      expect(workflow_start).to have_received(:call).with(hash_excluding(:base))
    end

    it "is refused in place" do
      expect { command.call(argument: "feature", base: "origin/main") }.to raise_error(Workspace::UsageError, /--base would be ignored/)
      expect { command.call(base: "origin/main") }.to raise_error(Workspace::UsageError, /--base would be ignored/)
      expect_nothing_ran
    end

    it "is refused under --here" do
      expect { command.call(argument: "try the thing", here: true, base: "origin/main") }.to raise_error(Workspace::UsageError, /--base would be ignored/)
      expect_nothing_ran
    end

    it "is handed to the task path, which refuses it" do
      allow(go_task).to receive(:run_for).and_return({"id" => "wr_1"})
      allow(go_task).to receive(:add).and_return({})

      command.call(argument: "also this", here: true, base: "abc123")

      expect(go_task).to have_received(:add).with(anything, "also this", anything, flags: hash_including(base: "abc123"), dry_run: false)
    end

    [true, false].each do |dry_run|
      %w[nosuchref -x --upload-pack=evil].each do |bad|
        it "refuses #{bad} as unknown_base with nothing made#{" (dry run)" if dry_run}" do
          error = refusal(argument: "try the thing", base: bad, dry_run: dry_run)

          expect(error.code).to eq("unknown_base")
          expect(error.details).to eq("base" => bad)
          expect(output.string).to eq("")
          expect_nothing_ran
        end
      end
    end

    it "looks the base up in the checkout go runs in, where git worktree add runs" do
      allow(git).to receive(:commit_exists?).and_return(true)
      command.call(argument: "try the thing", base: "HEAD~1")

      expect(git).to have_received(:commit_exists?).with(root, "HEAD~1")
      expect(git).not_to have_received(:commit_exists?).with(project_root, anything)
    end

    it "never asks git about a value starting with a dash" do
      refusal(argument: "try the thing", base: "-x")

      expect(git).not_to have_received(:commit_exists?)
    end
  end

  describe "routes that start" do
    it "starts a ticket, a pull request and an issue" do
      {"PROJ-1" => "jira", "#12" => "github_pr", "https://github.com/o/r/issues/4" => "github_issue"}.each do |ref, kind|
        row = command.call(argument: ref)

        expect(workflow_start).to have_received(:call).with(hash_including(ref: ref, here: nil))
        expect(row["decision"]).to include("kind" => kind, "route" => "start")
      end
    end

    it "starts another word on a new branch with --workflow" do
      row = command.call(argument: "newbranch", workflow: "rpiv")

      expect(workflow_start).to have_received(:call).with(hash_including(id: "rpiv", ref: "newbranch", here: nil))
      expect(row["decision"]).to include("kind" => "branch", "route" => "start")
    end
  end

  describe "the empty argument" do
    ["", "   ", "\n", "  ", "　"].each do |empty|
      it "refuses #{empty.inspect}, in place or not" do
        expect(refusal(argument: empty)).to be_a(Workspace::UsageError)
        expect(git).not_to have_received(:root)
        expect_nothing_ran
      end
    end
  end

  describe "classifying" do
    it "reads a URL inside a sentence as that ref, with the sentence as the prompt" do
      row = command.call(argument: "see https://github.com/o/r/pull/1 please")

      expect(row["decision"]).to include("kind" => "github_pr", "workflow" => "pr-feedback", "extracted" => "https://github.com/o/r/pull/1")
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "https://github.com/o/r/pull/1", prompt: "see https://github.com/o/r/pull/1 please"))
      expect(output.string).to include("makes or reuses the worktree workspace for pr-1 (from https://github.com/o/r/pull/1 in the text)")
    end

    it "strips a ref before reading it" do
      row = command.call(argument: " #12 ")

      expect(row["decision"]["kind"]).to eq("github_pr")
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "#12"))
    end

    it "reads a URL after a no-break space as that ref" do
      expect(command.call(argument: "see https://github.com/o/r/pull/1")["decision"]["kind"]).to eq("github_pr")
    end

    it "reads an ideographic space as free text" do
      expect(command.call(argument: "fix　bug")["decision"]["kind"]).to eq("prompt")
    end

    it "reads a URL after an ideographic space as that ref" do
      expect(command.call(argument: "see　https://github.com/o/r/issues/4")["decision"]["kind"]).to eq("github_issue")
    end

    context "with a pull request or issue whose branch differs only in case from a real one" do
      let(:names) { %w[Issue-4 PR-9 main] }

      {"https://github.com/o/r/issues/4" => "Issue-4", "https://github.com/o/r/pull/9" => "PR-9"}.each do |word, real|
        it "refuses #{word} as unknown_ref naming #{real}" do
          error = refusal(argument: word, inputs: {"task" => "x"})

          expect(error.code).to eq("unknown_ref")
          expect(error.details).to include("ref" => word, "did_you_mean" => real)
          expect(error.message).to include("differs only in case from the branch #{real}")
          expect(error.message).not_to include("is not a branch", "git fetch", "--workflow", "space")
          expect_nothing_ran
        end
      end
    end

    context "with a ticket key that differs only in case from a branch" do
      let(:names) { %w[abc-7 feature main pr-12] }

      [nil, "rpiv"].each do |flag|
        {"PR-12" => "pr-12", "https://acme.atlassian.net/browse/PR-12" => "pr-12"}.each do |word, real|
          it "refuses #{word} as unknown_ref naming #{real}, with --workflow #{flag.inspect}" do
            error = refusal(argument: word, workflow: flag, inputs: {"task" => "x"})

            expect(error.code).to eq("unknown_ref")
            expect(error.details).to include("ref" => word, "did_you_mean" => real)
            expect_nothing_ran
          end
        end
      end
    end

    it "reuses a branch that differs from the key only in case, by its real name" do
      allow(git).to receive(:local_branch_names).and_return([])
      allow(git).to receive(:branch_names).and_return([])
      allow(git).to receive(:local_branch_names).with(root).and_return(%w[abc-7])
      allow(git).to receive(:branch_names).with(root).and_return(%w[abc-7])
      allow(start_ref).to receive(:call).and_call_original

      row = command.call(argument: "ABC-7")

      expect(row["decision"]).to include("kind" => "jira", "route" => "start")
      expect(start_ref).to have_received(:call).with("ABC-7", root: root)
    end

    it "reuses a branch that only origin has, under its real name" do
      allow(git).to receive(:local_branch_names).and_return(%w[main])
      allow(git).to receive(:branch_names).and_return(%w[Proj-1 main])
      allow(start_ref).to receive(:call).and_call_original

      expect(command.call(argument: "PROJ-1")["decision"]).to include("kind" => "jira", "route" => "start")
      expect(start_ref.call("PROJ-1", root: root).branch).to eq("Proj-1")
    end

    it "keeps a ticket with no such branch" do
      expect(command.call(argument: "PROJ-1")["decision"]).to include("kind" => "jira", "route" => "start")
    end

    context "with a branch named exactly as the ticket" do
      let(:names) { %w[PROJ-1 feature main] }

      it "keeps the ticket" do
        expect(command.call(argument: "PROJ-1")["decision"]["kind"]).to eq("jira")
      end
    end

    it "refuses a word naming a workflow, saying how to name one" do
      error = refusal(argument: "rpiv")

      expect(error.code).to eq("unknown_ref")
      expect(error.details).to eq("ref" => "rpiv", "known" => %w[pr-feedback rpiv])
      expect(error.message).to include("--workflow", "needs a space", "git fetch")
      expect_nothing_ran
    end

    [nil, "rpiv"].each do |flag|
      %w[MAIN Pr-12].zip(%w[main pr-12]).each do |word, real|
        it "refuses #{word} as unknown_ref naming #{real}, with --workflow #{flag.inspect}" do
          error = refusal(argument: word, workflow: flag)

          expect(error.code).to eq("unknown_ref")
          expect(error.details).to include("ref" => word, "did_you_mean" => real)
          expect(error.message).to include("differs only in case from the branch #{real}")
          expect(error.message).not_to include("git fetch")
          expect(error.message.include?("--workflow")).to be(flag.nil?)
          expect_nothing_ran
        end
      end
    end

    [nil, "rpiv"].each do |flag|
      it "refuses origin/main as unknown_ref naming main, with --workflow #{flag.inspect}" do
        error = refusal(argument: "origin/main", workflow: flag)

        expect(error.code).to eq("unknown_ref")
        expect(error.details).to include("ref" => "origin/main", "did_you_mean" => "main")
        expect(error.message).to include("Use main")
        expect_nothing_ran
      end
    end

    it "treats a word under origin/ with no such branch by the usual rule" do
      expect(refusal(argument: "origin/nope").details).not_to include("did_you_mean")
      expect(refusal(argument: "origin/nope", workflow: "rpiv")).to be_nil
    end

    context "with a branch really named origin/keep" do
      let(:names) { %w[keep main origin/keep] }

      it "takes the exact name" do
        expect(refusal(argument: "origin/keep")).to be_nil
      end
    end

    context "with an origin name that differs only in case from a local branch" do
      let(:names) { %w[Main feature main] }
      let(:local_names) { %w[feature main] }

      [nil, "rpiv"].each do |flag|
        it "refuses it naming the local branch, with --workflow #{flag.inspect}" do
          error = refusal(argument: "Main", workflow: flag)

          expect(error.code).to eq("unknown_ref")
          expect(error.details).to include("ref" => "Main", "did_you_mean" => "main")
          expect_nothing_ran
        end
      end

      it "settles a ticket key on the local branch instead of refusing it" do
        allow(git).to receive(:local_branch_names).and_return(%w[abc-7])
        allow(git).to receive(:branch_names).and_return(%w[ABC-7 abc-7])

        expect(command.call(argument: "ABC-7")["decision"]).to include("kind" => "jira", "route" => "start")
      end
    end

    context "with an origin-only name and no local variant" do
      let(:default_branch) { "trunk" }
      let(:main_branch) { "trunk" }
      let(:names) { %w[Main feature trunk] }
      let(:local_names) { %w[feature trunk] }

      it "passes" do
        expect(refusal(argument: "Main")).to be_nil
        expect(workflow_start).to have_received(:call).with(hash_including(ref: "Main"))
      end
    end
  end

  describe "outside a repository" do
    let(:root) { nil }

    before { allow(start_ref).to receive(:project).and_raise("project read with no root") }

    it "refuses bare go with the UsageError" do
      expect(refusal).to be_a(Workspace::UsageError)
    end

    it "says a repository is needed for a branch word or free text, before locate_project" do
      ["a-word", "free text"].each do |argument|
        error = refusal(argument: argument)

        expect(error).not_to be_a(Workspace::UsageError)
        expect(error.message).to eq("go must run inside a git repository.")
      end
      expect(workflow_start).not_to have_received(:locate_project)
    end

    it "says a repository is needed under --here, not go_here_unavailable" do
      [nil, "free text"].each do |argument|
        error = refusal(argument: argument, here: true)

        expect(error).not_to be_a(Workspace::UsageError)
        expect(error.code).not_to eq("go_here_unavailable")
        expect(error.message).to eq("go must run inside a git repository.")
      end
    end
  end

  describe "choosing the workflow" do
    it "takes --workflow first, without reading config" do
      row = command.call(argument: "free text", workflow: "flow")

      expect(workflow_defaults).not_to have_received(:lookup)
      expect(row["decision"]).to include("workflow" => "flow", "source" => "flag", "reason" => "named with --workflow")
    end

    it "reads config for the kind and the project's workspace" do
      allow(workflow_defaults).to receive(:lookup).with("branch", workspace: "app", project: "app").and_return({id: "flow", key: "workflows.by_ref.branch"})

      row = command.call(argument: "other")

      expect(row["decision"]).to include("workflow" => "flow", "source" => "workflows.by_ref.branch", "reason" => "set by workflows.by_ref.branch")
      expect(output.string).to include("flow (set by workflows.by_ref.branch)")
    end

    [false, true].each do |dry_run|
      it "refuses an in-place run in a worktree whose agent is not Claude Code (dry_run: #{dry_run})" do
        refusal = Workspace::Error.new("no", code: "workflow_needs_claude")
        allow(workflow_start).to receive(:check_agent!).with(detected, project: "app").and_raise(refusal)

        expect { command.call(argument: "free text", dry_run: dry_run, here: true) }.to raise_error(refusal)
        expect { command.call(dry_run: dry_run) }.to raise_error(refusal)
        expect(workflow).not_to have_received(:run)
      end
    end

    context "in a clone that only shares a project's name" do
      let(:tied) { nil }

      it "reads no project key, as workflow start does" do
        allow(workflow_defaults).to receive(:lookup).with("branch", workspace: nil, project: nil).and_return({id: "flow", key: "workflows.default"})

        expect(command.call(argument: "feature")["decision"]).to include("workflow" => "flow")
      end
    end

    it "reads the worktree's own layers when it runs in place, for a ref too" do
      allow(workflow_defaults).to receive(:lookup).with("branch", workspace: detected, project: "app").and_return({id: "flow", key: "workflows.default"})

      expect(command.call(argument: "feature")["decision"]).to include("workflow" => "flow", "route" => "run")
    end

    it "reads the prompt kind for no argument and free text" do
      allow(workflow_defaults).to receive(:lookup).with("prompt", workspace: detected, project: "app").and_return({id: "flow", key: "workflows.default"})

      expect(command.call["decision"]).to include("source" => "workflows.default", "kind" => "prompt")
      expect(command.call(argument: "free text", here: true)["decision"]).to include("workflow" => "flow")
    end

    it "falls back to pr-feedback for a pull request and rpiv otherwise" do
      expect(command.call(argument: "#12")["decision"]).to include("workflow" => "pr-feedback", "source" => "built_in")
      expect(command.call(argument: "PROJ-1")["decision"]).to include("workflow" => "rpiv", "source" => "built_in", "reason" => "built in for jira")
    end

    it "refuses an unknown workflow before anything prints" do
      allow(catalog).to receive(:find).with("nope", project: "app").and_raise(Workspace::Error.new("No workflow.", code: "unknown_workflow"))

      expect(refusal(argument: "free text", workflow: "nope").code).to eq("unknown_workflow")
      expect(output.string).to eq("")
    end
  end

  describe "in a main checkout, running or stopped" do
    include_context "main checkout"

    it_behaves_like "not in place"
    it_behaves_like "refuses the default branch"

    context "with no detected workspace" do
      let(:detected) { nil }

      it_behaves_like "not in place"
      it_behaves_like "refuses the default branch"
    end
  end

  describe "in a linked worktree on the default branch" do
    let(:current_branch) { "main" }
    let(:main_branch) { "develop" }
    let(:held) { {"main" => root} }

    it_behaves_like "not in place"
    it_behaves_like "refuses the default branch"

    it "names the checkout that holds it" do
      expect(refusal(argument: "main").details["path"]).to eq(root)
    end
  end

  describe "in a linked worktree on a case alias of the default branch" do
    let(:current_branch) { "MAIN" }

    it_behaves_like "not in place"
  end

  describe "in a linked worktree on a case alias of the main checkout's branch" do
    let(:current_branch) { "DEVELOP" }
    let(:main_branch) { "develop" }

    it_behaves_like "not in place"
  end

  describe "in a main checkout on a case alias of a branch" do
    include_context "main checkout"
    let(:current_branch) { "Feature" }
    let(:main_branch) { "Feature" }

    it "refuses go feature as the main checkout's branch and runs nothing" do
      error = refusal(argument: "feature")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to eq("branch" => "feature", "path" => project_root, "reason" => "main_checkout")
      expect_nothing_ran
    end
  end

  describe "with a default branch other than main" do
    let(:default_branch) { "trunk" }
    let(:main_branch) { "trunk" }
    let(:current_branch) { "trunk" }
    let(:names) { %w[main trunk] }

    it_behaves_like "not in place"

    it "refuses it, and not a branch that is only called main" do
      expect(refusal(argument: "trunk").code).to eq("branch_not_allowed")
      expect(refusal(argument: "main")).to be_nil
    end
  end

  describe "in a linked worktree whose detected workspace is another checkout" do
    let(:configured_root) { project_root }
    let(:detected) { "app" }

    it_behaves_like "not in place"
  end

  describe "#checkout_here" do
    it "answers nil for a missing root path" do
      allow(File).to receive(:realpath).with(root).and_raise(Errno::ENOENT)

      expect(refusal).to be_a(Workspace::UsageError)
    end

    it "takes free text to the start route for a missing root path" do
      allow(File).to receive(:realpath).with(root).and_raise(Errno::ENOENT)

      expect(command.call(argument: "fix the bug")["decision"]["route"]).to eq("start")
      expect(workflow).not_to have_received(:run)
    end

    it "takes a ~ root in the config" do
      allow(File).to receive(:expand_path).and_call_original
      allow(File).to receive(:expand_path).with("~/app/.worktrees/feature").and_return(root)
      allow(project_config).to receive(:project_root_for).and_return("~/app/.worktrees/feature")

      expect(command.call["decision"]["route"]).to eq("run")
    end

    context "with a marker and no config" do
      let(:configured_root) { nil }

      it_behaves_like "not in place"
    end

    context "with a detached HEAD" do
      let(:current_branch) { nil }

      it_behaves_like "not in place"
    end
  end

  describe "branch_not_allowed" do
    let(:main_branch) { "main" }

    it "has a null path when no checkout holds the default branch, and is the origin-only case" do
      allow(git).to receive(:worktree_branch).and_return(current_branch)
      allow(git).to receive(:worktree_branch).with(project_root).and_return("develop")

      error = refusal(argument: "main")

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to eq("branch" => "main", "path" => nil, "reason" => "default_branch")
      expect(error.message).to include("Name a new branch, or use free text")
    end

    it "names a linked worktree that holds the default branch" do
      allow(git).to receive(:worktree_branch).and_return(current_branch)
      allow(git).to receive(:worktree_branch).with(project_root).and_return("develop")
      allow(git).to receive(:find_worktree_by_branch).with("main", repo: project_root).and_return("/src/app/.worktrees/keep")

      expect(refusal(argument: "main").details["path"]).to eq("/src/app/.worktrees/keep")
    end

    it "refuses the main checkout's branch" do
      allow(git).to receive(:worktree_branch).with(project_root).and_return("other")
      allow(git).to receive(:find_worktree_by_branch).with("other", repo: project_root).and_return(project_root)

      error = refusal(argument: "other")

      expect(error.details).to eq("branch" => "other", "path" => project_root, "reason" => "main_checkout")
      expect_nothing_ran
    end

    it "refuses a branch whose reused checkout holds the default branch" do
      path = "/src/app/.worktrees/other"
      allow(git).to receive(:worktree_exists?).with(path).and_return(true)
      allow(git).to receive(:worktree_branch).with(path).and_return("main")

      error = refusal(argument: "other", dry_run: true)

      expect(error.code).to eq("branch_not_allowed")
      expect(error.details).to eq("branch" => "main", "path" => path, "reason" => "default_branch")
      expect_nothing_ran
    end

    it "compares nothing with an unknown default branch" do
      allow(git).to receive(:default_branch_name).and_return(nil)
      allow(git).to receive(:worktree_branch).with(project_root).and_return(nil)

      expect(refusal(argument: "other")).to be_nil
    end
  end

  describe "a reused checkout holding another branch" do
    let(:path) { "/src/app/.worktrees/foo" }
    let(:names) { %w[bar foo main] }

    before { allow(git).to receive(:worktree_exists?) { |checked| checked == path } }

    def expect_held(error, branch, held)
      expect(error.code).to eq("branch_exists")
      expect(error.details).to eq("branch" => branch, "path" => path, "worktree" => true, "held" => held)
      expect(error.message).to include("The checkout at #{path} holds #{held || "no branch"}")
      expect(output.string).to eq("")
      expect_nothing_ran
    end

    before { allow(git).to receive(:worktree_branch).with(path).and_return("bar") }

    [false, true].each do |dry_run|
      context "from outside#{" (dry run)" if dry_run}" do
        include_context "main checkout"

        it("refuses") { expect_held(refusal(argument: "foo", dry_run: dry_run), "foo", "bar") }
      end

      context "from inside that worktree#{" (dry run)" if dry_run}" do
        let(:root) { path }
        let(:configured_root) { path }
        let(:current_branch) { "bar" }
        let(:detected) { "app.worktree-foo" }

        it("refuses") { expect_held(refusal(argument: "foo", dry_run: dry_run), "foo", "bar") }
      end

      context "with two branches that sanitize alike#{" (dry run)" if dry_run}" do
        let(:path) { "/src/app/.worktrees/a-b" }
        let(:names) { %w[a-b a/b main] }

        before { allow(git).to receive(:worktree_branch).with(path).and_return("a-b") }

        it("refuses") { expect_held(refusal(argument: "a/b", dry_run: dry_run), "a/b", "a-b") }
      end

      it "refuses a detached checkout#{" (dry run)" if dry_run}" do
        allow(git).to receive(:worktree_branch).with(path).and_return(nil)

        expect_held(refusal(argument: "foo", dry_run: dry_run), "foo", nil)
      end
    end

    it "gives way to branch_not_allowed" do
      allow(git).to receive(:worktree_branch).with(path).and_return("main")

      expect(refusal(argument: "foo").code).to eq("branch_not_allowed")
    end

    it "passes when the checkout holds the ref's branch" do
      allow(git).to receive(:worktree_branch).with(path).and_return("foo")

      expect(refusal(argument: "foo")).to be_nil
    end

    it "allows a branch in a worktree outside .worktrees" do
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).with("foo", repo: project_root).and_return("/elsewhere/foo")

      expect(refusal(argument: "foo")).to be_nil
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "foo"))
    end
  end

  describe "free text with no letters or digits" do
    it "is refused on the start route, naming the way forward" do
      allow(project_config).to receive(:project_root_for).and_return(nil)

      error = refusal(argument: "! ! !")

      expect(error).to be_a(Workspace::UsageError)
      expect(error.message).to include("workflow start ID --prompt TEXT --branch NAME")
      expect_nothing_ran
    end

    it "runs in place, where no branch is named" do
      expect(command.call(argument: "! ! !", here: true)["decision"]["route"]).to eq("run")
    end
  end

  describe "a branch_exists from WorkflowStart" do
    let(:configured_root) { nil }
    let(:details) { {"branch" => slug, "path" => "/src/app/.worktrees/#{slug}", "worktree" => worktree} }
    let(:slug) { "other" }
    let(:worktree) { false }

    before { allow(workflow_start).to receive(:call).and_raise(Workspace::Error.new("Pass --branch.", code: "branch_exists", details: details)) }

    it "names go BRANCH, same code and details" do
      error = refusal(argument: "other !")

      expect(error.code).to eq("branch_exists")
      expect(error.details).to eq(details)
      expect(error.message).to include("`workspace go other --workflow rpiv --input task=TEXT`")
      expect(error.message).not_to include("--branch")
    end

    it "names the workflow it chose, so the suggestion runs the same one" do
      allow(workflow_defaults).to receive(:lookup).with("prompt", workspace: "app", project: "app").and_return({id: "flow", key: "workflows.default"})

      expect(refusal(argument: "other !").message).to include("`workspace go other --workflow flow --input task=TEXT`")
    end

    it "says only to reword when the checkout at that path holds another branch" do
      allow(git).to receive(:worktree_exists?).with(details["path"]).and_return(true)
      allow(git).to receive(:worktree_branch).with(details["path"]).and_return("elsewhere")

      error = refusal(argument: "other !")

      expect(error.message).to include("#{details["path"]} holds elsewhere", "Reword the text")
      expect(error.message).not_to include("workspace go")
    end

    it "says the same when that checkout holds no branch" do
      allow(git).to receive(:worktree_exists?).with(details["path"]).and_return(true)
      allow(git).to receive(:worktree_branch).with(details["path"]).and_return(nil)

      expect(refusal(argument: "other !").message).to include("holds no branch", "Reword the text")
    end

    it "names --workflow when it was given" do
      expect(refusal(argument: "other !", workflow: "flow").message).to include("`workspace go other --workflow flow --input task=TEXT`")
    end

    context "with a workflow that declares no task" do
      let(:yaml) { "steps:\n  plan:\n    prompt: Plan.\n" }

      it "leaves --input task out" do
        expect(refusal(argument: "other !").message).to include("`workspace go other --workflow rpiv`")
      end
    end

    context "when the branch is protected" do
      let(:slug) { "main" }

      it "is branch_not_allowed before dispatch, saying only to reword" do
        error = refusal(argument: "main !")

        expect(error.code).to eq("branch_not_allowed")
        expect(error.message).to include("Reword the text")
        expect(error.message).not_to include("workspace go", "free text")
        expect(output.string).to eq("")
        expect_nothing_ran
      end
    end

    context "when a plain path is there with no branch" do
      let(:slug) { "stray" }

      before { allow(File).to receive(:exist?).with("/src/app/.worktrees/stray").and_return(true) }

      it "says to reword and names the path" do
        error = refusal(argument: "stray !")

        expect(error.details["worktree"]).to be(false)
        expect(error.message).to include("Reword the text", "/src/app/.worktrees/stray")
        expect(error.message).not_to include("workspace go")
      end
    end

    context "when a worktree is there on another branch" do
      let(:slug) { "stray" }
      let(:worktree) { true }

      before { allow(File).to receive(:exist?).with("/src/app/.worktrees/stray").and_return(true) }

      it "says to reword, since go stray would be unknown_ref" do
        expect(refusal(argument: "stray !").message).not_to include("workspace go")
      end
    end

    context "when only a branch differing in case is there" do
      let(:names) { %w[Feature-X main] }

      it "is branch_exists before dispatch, naming the real branch" do
        error = refusal(argument: "feature x")

        expect(error.code).to eq("branch_exists")
        expect(error.details).to include("branch" => "Feature-X", "worktree" => false)
        expect(error.message).to include("differs only in case from the branch Feature-X", "Reword the text")
        expect(output.string).to eq("")
        expect_nothing_ran
      end

      it "gives way to the UsageError for text with no letters or digits" do
        expect(refusal(argument: "! !")).to be_a(Workspace::UsageError)
      end
    end

    it "is not rewritten for a ref on the start route" do
      expect(refusal(argument: "other").message).to eq("Pass --branch.")
    end
  end

  describe "a branch_exists on the here route" do
    it "keeps WorkflowStart's message" do
      allow(workflow_start).to receive(:call).and_raise(Workspace::Error.new("The checkout is elsewhere.", code: "branch_exists", details: {"branch" => "feature"}))

      expect(refusal(argument: "feature").message).to eq("The checkout is elsewhere.")
    end
  end

  describe "reading an identifier out of free text" do
    let(:pr) { "https://github.com/o/r/pull/12" }

    def prompt_row(argument, **args)
      command.call(argument: argument, **args)
    end

    it "reads a JIRA key whose ticket reads, and passes the sentence as the prompt" do
      row = prompt_row("fix PROJ-1 login")

      expect(ticket_source).to have_received(:fetch).with(having_attributes(kind: "jira", key: "PROJ-1"), chdir: root)
      expect(row["decision"]).to include("kind" => "jira", "extracted" => "PROJ-1")
      expect(workflow_start).to have_received(:call).with(hash_including(ref: "PROJ-1", prompt: "fix PROJ-1 login"))
    end

    it "reads an Atlassian link with no ticket read before WorkflowStart" do
      row = prompt_row("fix https://acme.atlassian.net/browse/proj-9 now")

      expect(ticket_source).not_to have_received(:fetch)
      expect(row["decision"]).to include("kind" => "jira", "extracted" => "PROJ-9")
    end

    [
      ["ticket_not_found", nil, "no such ticket"],
      ["ticket_source_unavailable", "missing", "jira is missing"],
      ["ticket_source_unavailable", "timeout", "jira timed out"],
      ["ticket_source_unavailable", "error", "jira failed"]
    ].each do |code, reason, message|
      it "keeps the text free on #{code} #{reason}, with the error's message in a warning" do
        allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new(message, code: code, details: {"reason" => reason}))

        row = prompt_row("fix PROJ-1 login")

        expect(row["decision"]).to include("kind" => "prompt", "extracted" => nil)
        expect(row["warnings"].join).to include(message)
        expect(output.string).to include("Warning: PROJ-1 in the text was not read as a ticket")
        expect(workflow_start).to have_received(:call).with(hash_including(prompt: "fix PROJ-1 login"))
        expect(workflow_start).not_to have_received(:call).with(hash_including(:ref))
      end
    end

    it "escapes control characters from the ticket tool's message" do
      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("bad\e[31m", code: "ticket_not_found"))

      row = prompt_row("fix PROJ-1 login")

      expect(row["warnings"].join).to include("bad\\e[31m")
      expect(output.string).not_to include("\e[31m")
    end

    it "does not catch other errors from the ticket read" do
      allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("boom", code: "other"))

      expect(refusal(argument: "fix PROJ-1 login").code).to eq("other")
    end

    it "drops a link for a repository the project does not track, with a warning" do
      row = prompt_row("see https://github.com/x/y/pull/3 here")

      expect(row["decision"]).to include("kind" => "prompt", "extracted" => nil)
      expect(row["warnings"].join).to include("https://github.com/x/y/pull/3")
    end

    it "reads the one key left after a foreign link is dropped" do
      row = prompt_row("PROJ-1 see https://github.com/x/y/pull/3")

      expect(row["decision"]).to include("kind" => "jira", "extracted" => "PROJ-1")
      expect(row["warnings"].join).to include("x/y/pull/3")
    end

    it "takes the link over a bare key without reading the ticket" do
      row = prompt_row("PROJ-1: fix #{pr}")

      expect(ticket_source).not_to have_received(:fetch)
      expect(row["decision"]).to include("kind" => "github_pr", "extracted" => pr)
    end

    it "keeps two links as free text, naming them and the way out" do
      row = prompt_row("#{pr} and https://github.com/o/r/issues/5")

      expect(row["decision"]["kind"]).to eq("prompt")
      expect(row["warnings"].join).to include(pr, "issues/5", "workspace go ID --input task=TEXT")
    end

    it "keeps two bare keys as free text" do
      row = prompt_row("PROJ-1 and PROJ-2 clash")

      expect(row["decision"]["kind"]).to eq("prompt")
      expect(row["warnings"].join).to include("PROJ-1 and PROJ-2")
      expect(ticket_source).not_to have_received(:fetch)
    end

    it "counts one identifier repeated once" do
      expect(prompt_row("#{pr} again #{pr}")["decision"]["extracted"]).to eq(pr)
    end

    it "extracts nothing with --here, and never gives the task path a ref" do
      allow(go_task).to receive(:run_for).and_return({"id" => "wr_1"})
      allow(go_task).to receive(:add).and_return({"outcome" => "added"})

      prompt_row("fix #{pr}", here: true)

      expect(go_task).to have_received(:add).with({"id" => "wr_1"}, "fix #{pr}", anything, anything)
      expect(workflow_start).not_to have_received(:call)
    end

    it "reads no ticket and starts nothing for the sentence under --here with no run going" do
      row = prompt_row("fix PROJ-1", here: true)

      expect(ticket_source).not_to have_received(:fetch)
      expect(row["decision"]).to include("kind" => "prompt", "route" => "run", "extracted" => nil)
    end

    context "when the extracted branch is this checkout's" do
      let(:current_branch) { "pr-12" }

      it "runs in place through WorkflowStart with the text" do
        row = prompt_row("fix #{pr}")

        expect(row["decision"]).to include("route" => "run", "kind" => "github_pr")
        expect(workflow_start).to have_received(:call).with(hash_including(ref: pr, prompt: "fix #{pr}", here: an_instance_of(Workspace::Commands::WorkflowStart::Here)))
        expect(output.string).to include("runs in this worktree (from #{pr} in the text)")
      end
    end

    it "gets a sentence of only punctuation and a URL past the slug check" do
      expect(prompt_row("!! #{pr} ??")["decision"]["kind"]).to eq("github_pr")
    end

    it "keeps a sentence with no identifier as before" do
      expect(prompt_row("fix the bug")["decision"]).to include("kind" => "prompt", "extracted" => nil)
    end

    it "still refuses a protected branch an identifier names" do
      allow(git).to receive(:default_branch_name).and_return("pr-12")

      expect(refusal(argument: "see #{pr}").code).to eq("branch_not_allowed")
      expect_nothing_ran
    end

    context "with a branch that differs only in case" do
      let(:names) { %w[Pr-12 feature main] }
      let(:local_names) { names }

      it "still refuses the case clash" do
        expect(refusal(argument: "see #{pr}").code).to eq("unknown_ref")
      end
    end

    it "makes the same row under --dry-run" do
      real = prompt_row("fix #{pr}")
      dry = prompt_row("fix #{pr}", dry_run: true)

      expect(dry["decision"]).to eq(real["decision"])
      expect(workflow_start).to have_received(:call).with(hash_including(dry_run: true, ref: pr))
    end

    it "leaves out the new-branch sentence when a ref supplied the branch" do
      allow(workflow).to receive(:run)
      row = prompt_row("fix #{pr}", inputs: {"task" => "mine"})

      expect(row["warnings"]).to include("The text is not the task: --input task was given.")
    end
  end

  describe "warnings" do
    let(:yaml) { "steps:\n  plan:\n    prompt: Plan.\n" }

    it "warns when the workflow declares no task, in place, and leaves task out" do
      row = command.call(argument: "fix it", here: true)

      expect(row["warnings"]).to eq(["The text is not the task: rpiv declares no task input."])
      expect(output.string).to include("Warning: The text is not the task")
      expect(workflow).to have_received(:run).with(hash_including(inputs: {}))
    end

    it "keeps the row's own warnings in place" do
      allow(workflow).to receive(:run).and_return({"outcome" => "started", "warnings" => ["from run"]})

      expect(command.call(argument: "fix it", here: true)["warnings"]).to eq(["from run", "The text is not the task: rpiv declares no task input."])
    end

    it "says on the start route that the text still names the branch, beside the row's own warnings" do
      allow(project_config).to receive(:project_root_for).and_return(nil)

      row = command.call(argument: "fix it")

      expect(row["warnings"]).to eq(["from start", "The text is not the task: rpiv declares no task input. The text still names the new branch."])
    end

    context "when the workflow declares task" do
      let(:yaml) { "inputs:\n  task:\nsteps:\n  plan:\n    prompt: Plan.\n" }

      it "warns when --input task was given, and keeps it" do
        row = command.call(argument: "fix it", inputs: {"task" => "other"}, here: true)

        expect(row["warnings"]).to eq(["The text is not the task: --input task was given."])
        expect(workflow).to have_received(:run).with(hash_including(inputs: {"task" => "other"}))
      end

      it "says nothing otherwise" do
        expect(command.call(argument: "fix it", here: true)["warnings"]).to eq([])
      end
    end
  end

  describe "the row" do
    it "has the same decision under --dry-run, and the line prints before dispatch" do
      allow(workflow_start).to receive(:call) do
        expect(output.string).to include("go: rpiv (built in for branch)")
        start_row
      end

      real = command.call(argument: "other")
      dry = command.call(argument: "other", dry_run: true)

      expect(dry["decision"]).to eq(real["decision"])
      expect(dry["decision"]).to eq("workflow" => "rpiv", "source" => "built_in", "kind" => "branch", "route" => "start", "reason" => "built in for branch", "extracted" => nil)
    end
  end
end
