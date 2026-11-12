require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::Workflow do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:workflow_command) { CLITestHelpers::FakeWorkflowCommand.new }
  let(:start_command) { CLITestHelpers::FakeWorkflowStartCommand.new }
  let(:workflow_project) { RecordingWorkflowProject.new(workspace: "app", projects: {"/src/app" => "app"}) }
  let(:status_scope) { RecordingStatusScope.new }
  let(:project_config) { CLITestHelpers::FakeProjectConfig.new("app" => "/src/app", "web" => "/src/web") }
  let(:project_detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:git) { FakeGit.new(root: "/src/repo") }
  let(:input) { Workspace::PromptInput.new(StringIO.new) }
  let(:config) { Workspace::Config.new(workspace_dir: "/home/me/.config/workspace") }
  let(:headless) { false }

  def family(**overrides)
    names = Workspace::CLI::Names.new(project_config: project_config, project_detector: project_detector, lineage: LineageSupport.lineage, working_dir: "/src/app")
    described_class.new(workflow_command: workflow_command, workflow_start_command: start_command, workflow_project: workflow_project,
      status_scope: status_scope, config: config, project_config: project_config, project_detector: project_detector, git: git,
      launch_mode: CLITestHelpers.launch_mode(headless: headless), common: Workspace::CLI::Common.new, names: names, input: input,
      working_dir: "/src/app", **overrides)
  end

  def invocation
    Workspace::CLI::Invocation.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def run(*args, verb: "workflow", **overrides)
    family(**overrides).call(verb, args, invocation)
    nil
  rescue FakeSystemExit => e
    e.status
  end

  describe "workflow help" do
    it "prints the overview with the directories the definitions are read from" do
      run("--help")

      expect(out.string).to include("Usage: workspace workflow")
      expect(out.string).to include("#{config.workflows_dir}/ID.yml")
    end

    it "prints a verb's own page before it parses anything" do
      run("install", "--help", "--bogus")

      expect(out.string).to start_with(Workspace::HelpPages.render(Workspace::HelpPages::WORKFLOW.fetch("install")).first)
      expect(workflow_command.calls).to be_empty
    end
  end

  describe "the readers" do
    it "lists the workflows of the working directory's project" do
      run("list", "--json")

      expect(workflow_command.calls).to eq([[:list, {json: true, project: "app"}]])
      expect(workflow_project.calls).to eq([[:for_directory, "/src/app"]])
    end

    it "reads a --name workspace's project for show --source" do
      run("show", "rpiv", "--source", "--name", "web")

      expect(workflow_command.calls).to eq([[:show, {id: "rpiv", json: false, source: true, project: "web"}]])
    end

    it "reads no project without a workflow project resolver" do
      run("list", workflow_project: nil)

      expect(workflow_command.calls).to eq([[:list, {json: false, project: nil}]])
    end

    it "parses events --since and attempts --attempt-of" do
      run("events", "wr_1", "--since", "4")
      run("attempts", "wr_1", "--attempt-of", "plan")

      expect(workflow_command.calls).to eq([[:events, {run: "wr_1", since: 4, json: false}], [:attempts, {run: "wr_1", step: "plan", json: false}]])
    end

    it "hands stats a --project scope and the --last window in seconds" do
      run("stats", "rpiv", "--project", "app", "--last", "2d")

      expect(status_scope.calls).to eq([[:resolve, {name: nil, project: "app", all: nil, working_dir: "/src/app"}]])
      expect(workflow_command.calls.first).to eq([:stats, {workflow: "rpiv", last: 172_800, last_text: "2d", scope: {resolve: {name: nil, project: "app", all: nil, working_dir: "/src/app"}}, json: false}])
    end

    it "exits with the status command's non-zero code" do
      workflow_command.status_result = {exit_code: 3}

      expect(run("status", "--needs-me")).to eq(3)
      expect(status_scope.calls).to eq([[:resolve_needs_me, {name: nil, project: nil, all: false, working_dir: "/src/app"}]])
    end

    it "checks a step at the repository root outside a workspace" do
      run("check", "rpiv", "verify", workflow_project: RecordingWorkflowProject.new)

      expect(workflow_command.calls).to eq([[:check, {id: "rpiv", step: "verify", worktree: "/src/repo", artifacts: nil, json: false, project: nil}]])
    end

    it "finds the workspace through the project detector without a workflow project resolver" do
      run("render", "rpiv", "plan", "--input", "task=a=b", workflow_project: nil)

      expect(project_detector.calls).to eq([[:detect, "/src/app"]])
      expect(workflow_command.calls).to eq([[:render, {id: "rpiv", step: "plan", workspace: "app", worktree: "/src/app", inputs: {"task" => "a=b"}, json: false, project: nil}]])
    end
  end

  describe "list, install and uninstall" do
    it "installs only the source at --source N" do
      run("install", "--source", "2")

      expect(workflow_command.calls).to eq([[:install, {source: 2}]])
    end

    it "installs every source with no argument" do
      run("install")

      expect(workflow_command.calls).to eq([[:install, {source: nil}]])
    end

    {
      %w[install 2] => "workflow install takes no argument; --source N installs only the Nth source.",
      %w[install --source] => "workflow install --source needs N, the position in workflows.sources (1 is the first).",
      %w[install --source 0] => "--source N is not a position: use a whole number from 1.",
      %w[install --dry-run] => "--dry-run does not apply to `workflow install`.",
      %w[uninstall extra] => "workflow uninstall takes no argument.",
      %w[list --source] => "--source is for `workflow show ID` and `workflow install`."
    }.each do |args, message|
      it "refuses `workflow #{args.join(" ")}`" do
        expect { run(*args) }.to raise_error(Workspace::UsageError, message)
        expect(workflow_command.calls).to be_empty
      end
    end

    it "answers a refused install with --json as one error document and exit 1" do
      status = run("install", "--dry-run", "--json")

      expect(status).to eq(1)
      expect(JSON.parse(out.string)).to include("ok" => false, "code" => "usage", "error" => "--dry-run does not apply to `workflow install`.")
    end

    it "reports uninstall --yes as an action document" do
      run("uninstall", "--yes", "--json")

      document = JSON.parse(out.string)
      expect(document).to include("action" => "workflow uninstall", "status" => "ok")
      expect(document["results"]).to eq([workflow_command.row])
      expect(workflow_command.calls).to eq([[:uninstall, {yes: true, dry_run: false, json: true}]])
    end

    it "reports a declined uninstall as cancelled" do
      run("uninstall", "--json")

      expect(JSON.parse(out.string)).to include("status" => "cancelled", "results" => [])
    end
  end

  describe "the run verbs" do
    it "runs in the --name workspace's checkout" do
      run("run", "rpiv", "--name", "web", "--input", "task=x", "--note", "hi", "--dry-run")

      kind, keywords = workflow_command.calls.first
      expect(kind).to eq(:run)
      expect(keywords).to include(id: "rpiv", workspace: "web", worktree: "/src/web", inputs: {"task" => "x"}, note: "hi", dry_run: true, project: "web", fill_from_branch: true)
    end

    it "exits 1 when the run's row failed" do
      workflow_command.row = {"workspace" => "app", "outcome" => "failed"}

      expect(run("run", "rpiv")).to eq(1)
    end

    it "starts a workflow headless as the launch mode decides, with its warnings on stderr" do
      start_command.row = {"workspace" => "app.worktree-x", "outcome" => "started", "warnings" => ["Branch \e[31mx\e[0m"]}

      run("start", "rpiv", "PROJ-1", "--slug")

      expect(start_command.calls).to eq([{id: "rpiv", ref: "PROJ-1", positional: nil, route: false, prompt: nil, branch: nil, slug: true, inputs: {},
                                          note: nil, base: nil, headless: false, agent_kind: nil, prompt_timeout: nil, dry_run: false, force: false}])
      expect(err.string).to eq("Warning: Branch \\e[31mx\\e[0m\n")
    end

    it "refuses --name for workflow start" do
      expect { run("start", "rpiv", "--name", "app") }.to raise_error(Workspace::UsageError, "workflow start makes its own workspace: --name is for `workflow run`.")
    end

    it "refuses to remove under --no-input without --yes" do
      input.no_input!

      expect { run("remove", "mine") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
      expect(workflow_command.calls).to eq([[:check_removable, {id: "mine", project: "app"}]])
    end

    it "passes approve's --step and --attempt as the gate seen" do
      run("approve", "wr_1", "--step", "plan", "--attempt", "2")

      kind, keywords = workflow_command.calls.first
      expect(kind).to eq(:approve)
      expect(keywords).to include(run: "wr_1", step: "plan", attempt: 2, note: nil, note_sha256: nil)
    end

    it "refuses reject without --note" do
      expect { run("reject", "wr_1") }.to raise_error(Workspace::UsageError, "workflow reject needs --note TEXT: the step runs again with it.")
    end
  end

  describe "usage errors" do
    it "names the verbs when none is given" do
      expect { run }.to raise_error(Workspace::UsageError, /\AMissing subcommand: list, show, validate/)
    end

    it "refuses an unknown verb" do
      expect { run("bogus") }.to raise_error(Workspace::UsageError, "Unknown workflow subcommand: bogus. Run 'workspace workflow --help'.")
    end

    it "refuses an argument that is not valid UTF-8, naming its flag" do
      expect { run("run", "rpiv", "--note", "\xFF".b) }.to raise_error(Workspace::UsageError, /\A--note holds bytes that are not valid UTF-8/)
    end

    it "refuses an --input with no =" do
      expect { run("run", "rpiv", "--input", "task") }.to raise_error(Workspace::UsageError, "--input takes KEY=VALUE, got \"task\".")
    end

    it "says so when no workflow command was wired" do
      expect { run("list", workflow_command: nil) }.to raise_error(Workspace::Error, "workflow is not available: no workflow command was wired")
    end
  end

  describe "step" do
    it "records a step's end for the pane" do
      run("done", "--status", "fail", "--summary", "Two specs fail.", "--code", "specs_fail", verb: "step")

      kind, keywords = workflow_command.calls.first
      expect(kind).to eq(:step_done)
      expect(keywords).to include(status: "fail", summary: "Two specs fail.", code: "specs_fail")
    end

    it "prints its overview for --help" do
      run("--help", verb: "step")

      expect(out.string).to include("Usage: workspace step")
    end

    it "names its verbs when none is given" do
      expect { run(verb: "step") }.to raise_error(Workspace::UsageError, /\AMissing subcommand: done or status\./)
    end

    it "answers a usage error with --json as one error document" do
      expect(run("bogus", "--json", verb: "step")).to eq(1)
      expect(JSON.parse(out.string)).to include("error" => "Unknown step subcommand: bogus. Run 'workspace step --help'.")
    end
  end

  describe ".inputs" do
    it "splits each pair at its first =" do
      expect(described_class.inputs(["a=1", "b=x=y", "c="])).to eq("a" => "1", "b" => "x=y", "c" => "")
    end

    it "refuses an empty key" do
      expect { described_class.inputs(["=1"]) }.to raise_error(Workspace::UsageError, "--input takes KEY=VALUE, got \"=1\".")
    end
  end
end
