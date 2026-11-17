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
      working_dir: "/src/app", launcher: double("launcher"), **overrides)
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

  describe "workflow recover" do
    let(:command) { double("workflow command") }
    let(:launcher) { double("launcher") }
    let(:result) { {exit_code: 0, results: [], status: "ok", extra: {"next_actions" => []}} }

    before { allow(command).to receive(:recover) { |**_, &launch| (@launch = launch) && result } }

    it "prints the action document with the command's extra" do
      allow(command).to receive(:recover).and_return(result.merge(extra: {"next_actions" => [{"action" => "restore"}], "unreadable_files" => []}))

      expect(run("recover", "--json", workflow_command: command, launcher: launcher)).to be_nil

      expect(JSON.parse(out.string)).to include("action" => "workflow recover", "status" => "ok", "next_actions" => [{"action" => "restore"}], "unreadable_files" => [])
    end

    it "passes dry_run, and false without the flag" do
      run("recover", "--dry-run", workflow_command: command, launcher: launcher)
      expect(command).to have_received(:recover).with(dry_run: true)

      run("recover", workflow_command: command, launcher: launcher)
      expect(command).to have_received(:recover).with(dry_run: false)
    end

    it "hands the command a launch block that launches the missing workspaces through the launcher" do
      allow(launcher).to receive(:launch_missing).and_return({"app" => "no config"})
      run("recover", workflow_command: command, launcher: launcher)

      expect(@launch.call(["app"])).to eq({"app" => "no config"})
      expect(launcher).to have_received(:launch_missing).with(instance_of(Workspace::CLI::Invocation), ["app"])
    end

    it "exits with the result's code: 3 for partial, 1 for failed" do
      {"partial" => 3, "failed" => 1}.each do |status, code|
        allow(command).to receive(:recover).and_return(result.merge(exit_code: code, status: status, results: [{"outcome" => "failed", "run_id" => "wr_1"}]))
        expect(run("recover", "--json", workflow_command: command, launcher: launcher)).to eq(code)
      end
    end

    it "refuses a RUN or --name" do
      expect { run("recover", "wr_1", workflow_command: command, launcher: launcher) }.to raise_error(Workspace::UsageError, /takes no RUN/)
      expect { run("recover", "--name", "app", workflow_command: command, launcher: launcher) }.to raise_error(Workspace::UsageError, /takes no --name/)
    end
  end

  describe "workflow sweep --json" do
    it "puts the command's extra into the action document" do
      actions = [{"action" => "workflow resume", "args" => ["wr_1"], "needs" => [], "why" => "held"}]
      command = double("workflow command")
      allow(command).to receive(:sweep).and_return(exit_code: 0, results: [], status: nil, extra: {"next_actions" => actions})

      run("sweep", "--json", workflow_command: command)

      expect(JSON.parse(out.string)).to include("action" => "workflow sweep", "next_actions" => actions)
    end
  end

  describe "workflow sweep --budget-only" do
    let(:command) { double("workflow command") }

    before { allow(command).to receive(:sweep).and_return(exit_code: 0, results: [], status: nil, extra: {}) }

    it "passes budget_only to the command, and false without the flag" do
      run("sweep", "--name", "app", "--budget-only", workflow_command: command)
      expect(command).to have_received(:sweep).with(hash_including(name: "app", budget_only: true))

      run("sweep", "--name", "app", workflow_command: command)
      expect(command).to have_received(:sweep).with(hash_including(name: "app", budget_only: false))
    end

    it "is refused for another subcommand and with the schedule flags" do
      expect { run("status", "--budget-only") }.to raise_error(Workspace::UsageError, /--budget-only is for `workflow sweep`/)
      expect { run("sweep", "--install", "--budget-only", workflow_command: command) }.to raise_error(Workspace::UsageError, /--budget-only does not go with --install/)
    end
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

      expect(workflow_command.calls).to eq([[:events, {run: "wr_1", since: 4, json: false, follow: false, types: nil, timeout: nil}], [:attempts, {run: "wr_1", step: "plan", json: false}]])
    end

    it "parses events --follow and refuses it elsewhere" do
      run("events", "wr_1", "--follow", "--json")

      expect(workflow_command.calls).to eq([[:events, {run: "wr_1", since: 0, json: true, follow: true, types: nil, timeout: nil}]])
      expect { run("status", "--follow") }.to raise_error(Workspace::UsageError, /--follow is for `workflow events RUN`/)
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

    it "parses events --types (repeatable, comma-separated) and --timeout" do
      run("events", "wr_1", "--follow", "--types", "step_done, run_finished", "--types", "gap", "--timeout", "5m")

      expect(workflow_command.calls).to eq([[:events, {run: "wr_1", since: 0, json: false, follow: true, types: %w[step_done run_finished gap], timeout: 300.0}]])
      run("events", "wr_1", "--types", "step_done")
      expect(workflow_command.calls.last[1]).to include(types: %w[step_done], timeout: nil, follow: false)
    end

    it "refuses --timeout without --follow, a bad --timeout, and --types on another subcommand" do
      expect { run("events", "wr_1", "--timeout", "5m") }.to raise_error(Workspace::UsageError, /--timeout is for `workflow events RUN --follow`/)
      expect { run("status", "--follow", "--timeout", "5m") }.to raise_error(Workspace::UsageError, /--follow is for|--timeout is for/)
      expect { run("events", "wr_1", "--follow", "--timeout", "0") }.to raise_error(Workspace::UsageError, /--timeout/)
      expect { run("status", "--types", "x") }.to raise_error(Workspace::UsageError, /--types is for `workflow events RUN`/)
    end

    it "exits 75 for the events command's timeout code" do
      workflow_command.status_result = {exit_code: 75}
      expect(run("events", "wr_1", "--follow", "--timeout", "1m")).to eq(75)
    end

    it "exits with the events command's non-zero code and not for zero" do
      workflow_command.status_result = {exit_code: 1}
      expect(run("events", "wr_1", "--follow")).to eq(1)

      workflow_command.status_result = {exit_code: 0}
      expect(run("events", "wr_1", "--follow")).to be_nil
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

    it "routes graph with its id, format and project" do
      run("graph", "rpiv", "--format", "dot", "--name", "web")

      expect(workflow_command.calls).to eq([[:graph, {id: "rpiv", format: "dot", json: false, project: "web", run: nil}]])
    end

    it "passes --json and no format when only --json is given" do
      run("graph", "rpiv", "--json")

      expect(workflow_command.calls).to eq([[:graph, {id: "rpiv", format: nil, json: true, project: "app", run: nil}]])
    end

    it "refuses graph without an id" do
      expect { run("graph") }.to raise_error(Workspace::UsageError, "workflow graph needs an ID (see `workspace workflow show`).")
    end

    it "routes graph --run with the run id" do
      run("graph", "rpiv", "--run", "wr_261117123627abcd", "--format", "mermaid")

      expect(workflow_command.calls).to eq([[:graph, {id: "rpiv", format: "mermaid", json: false, project: "app", run: "wr_261117123627abcd"}]])
    end

    it "refuses --run on another verb" do
      expect { run("show", "rpiv", "--run", "wr_261117123627abcd") }.to raise_error(Workspace::UsageError, "--run is for `workflow graph ID`.")
      expect(workflow_command.calls).to be_empty
    end

    it "refuses --format on another verb" do
      expect { run("show", "rpiv", "--format", "dot") }.to raise_error(Workspace::UsageError, "--format is for `workflow graph ID`.")
      expect(workflow_command.calls).to be_empty
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
      expect { run }.to raise_error(Workspace::UsageError, /\AMissing subcommand: list, show, graph, validate/)
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
    it "runs expect-fail in the working directory with every file after --, and no pane" do
      expect(run("expect-fail", "--match-file", "f.txt", "--timeout", "840", "--", "spec/a_spec.rb", "-odd_spec.rb", verb: "step")).to be_nil

      expect(workflow_command.calls).to eq([[:step_expect_fail, {cwd: "/src/app", files: ["spec/a_spec.rb", "-odd_spec.rb"], match_file: "f.txt", timeout: 840}]])
    end

    it "gives expect-fail the default limit and no match file when none is given" do
      run("expect-fail", "spec/a_spec.rb", verb: "step")

      expect(workflow_command.calls).to eq([[:step_expect_fail, {cwd: "/src/app", files: ["spec/a_spec.rb"], match_file: nil, timeout: 240}]])
    end

    it "exits with the code expect-fail answers" do
      command = double("workflow command", step_expect_fail: {exit_code: 1})

      expect(run("expect-fail", "spec/a_spec.rb", verb: "step", workflow_command: command)).to eq(1)
    end

    it "refuses a --timeout that is not a whole number of seconds from 1 up" do
      %w[0 -5 1.5 soon].each do |value|
        expect { run("expect-fail", "--timeout", value, "spec/a_spec.rb", verb: "step") }.to raise_error(Workspace::UsageError, /\A--timeout takes a whole number of seconds/)
      end
      expect(workflow_command.calls).to be_empty
    end

    it "refuses the flags of done on expect-fail, and the flags of expect-fail on done and status" do
      expect { run("expect-fail", "--status", "pass", "a", verb: "step") }.to raise_error(Workspace::UsageError, "--status is not for `step expect-fail`.")
      expect { run("expect-fail", "--code", "x", "a", verb: "step") }.to raise_error(Workspace::UsageError, "--code is not for `step expect-fail`.")
      expect { run("done", "--match-file", "f", verb: "step") }.to raise_error(Workspace::UsageError, "--match-file is only for `step expect-fail`.")
      expect { run("status", "--timeout", "5", verb: "step") }.to raise_error(Workspace::UsageError, "--timeout is only for `step expect-fail`.")
      expect(workflow_command.calls).to be_empty
    end

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
      expect { run(verb: "step") }.to raise_error(Workspace::UsageError, /\AMissing subcommand: done, status or expect-fail\./)
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

  # The argv CLI#run hands this family, with the first word as the verb, over the same fake
  # commands and workspace as the CLI-level examples in spec/integration/workspace/cli/workflow_spec.rb.
  describe "argv as CLI#run routes it" do
    include CLITestHelpers::EnvStub

    let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/work/api") }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:input) { StringIO.new }
    let(:output) { out }
    let(:error_output) { err }
    let(:cli) do
      names = Workspace::CLI::Names.new(project_config: project_config, project_detector: detector, lineage: CLITestHelpers::FakeLineage.new, working_dir: "/some/dir")
      parser = described_class.new(workflow_command: workflow_command, workflow_start_command: start_command, workflow_project: nil,
        status_scope: status_scope, config: config, project_config: project_config, project_detector: detector, git: git,
        launch_mode: CLITestHelpers.launch_mode(headless: false), common: Workspace::CLI::Common.new, names: names, input: input, working_dir: "/some/dir", launcher: double("launcher"))
      Struct.new(:parser, :invocation) { def run(argv) = parser.call(argv.first, argv.drop(1), invocation) }.new(parser, invocation)
    end

    before { stub_env("TMUX_PANE" => nil) }

    it "hands workflow check the --name workspace's checkout" do
      cli.run(["workflow", "check", "rpiv", "verify", "--name", "api", "--artifacts", "fixture"])

      expect(workflow_command.calls).to eq([[:check, {id: "rpiv", step: "verify", worktree: "/work/api", artifacts: "/some/dir/fixture", json: false, project: nil}]])
    end

    it "shows every definition, or one" do
      cli.run(["workflow", "show"])
      cli.run(["workflow", "show", "rpiv", "--json"])

      expect(workflow_command.calls).to eq([[:show, {id: nil, json: false, source: false, project: nil}], [:show, {id: "rpiv", json: true, source: false, project: nil}]])
    end

    it "passes --source to show" do
      cli.run(["workflow", "show", "rpiv", "--source", "--json"])
      expect(workflow_command.calls).to eq([[:show, {id: "rpiv", json: true, source: true, project: nil}]])
    end

    context "start" do
      it "passes the ID, REF and flags to workflow start" do
        cli.run(["workflow", "start", "rpiv", "PROJ-1", "--branch", "b", "--slug", "--base", "main", "--input", "task=x", "--note", "n", "--agent-kind", "codex", "--prompt-timeout", "2m", "--no-headless", "--dry-run"])

        expect(start_command.calls).to eq([{id: "rpiv", ref: "PROJ-1", positional: nil, prompt: nil, branch: "b", slug: true, inputs: {"task" => "x"}, note: "n", base: "main",
                                            headless: false, agent_kind: "codex", prompt_timeout: 120, dry_run: true, force: false, route: false}])
      end

      it "takes --prompt with no REF, and headless from the launch mode" do
        cli.run(["workflow", "start", "rpiv", "--prompt", "add a script"])

        expect(start_command.calls.first).to include(id: nil, ref: nil, positional: "rpiv", prompt: "add a script", slug: false, headless: false, dry_run: false)
      end

      it "passes a lone argument as positional, for WorkflowStart to settle" do
        cli.run(["workflow", "start", "PROJ-1"])

        expect(start_command.calls.first).to include(id: nil, ref: nil, positional: "PROJ-1")
      end

      it "takes --prompt alone, with no id" do
        cli.run(["workflow", "start", "--prompt", "add a script"])

        expect(start_command.calls.first).to include(id: nil, ref: nil, positional: nil, prompt: "add a script")
      end

      it "gives a JSON error for a missing REF under --json" do
        expect { cli.run(["workflow", "start", "--json"]) }.to raise_error(FakeSystemExit)

        expect(JSON.parse(output.string)).to include("ok" => false)
        expect(start_command.calls).to be_empty
      end

      it "writes one document for --dry-run --json" do
        start_command.row = {"workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => "Would start.", "branch" => "add-a-script"}

        cli.run(["workflow", "start", "rpiv", "--prompt", "add a script", "--dry-run", "--json"])

        doc = JSON.parse(output.string)
        expect(doc).to include("ok" => true, "action" => "workflow start", "status" => "dry_run")
        expect(doc["results"]).to eq([start_command.row])
      end

      it "escapes control characters in a printed warning" do
        start_command.row = start_command.row.merge("warnings" => ["Could not read X: \e[31mred\e[0m\rgone"])
        cli.run(["workflow", "start", "rpiv", "x"])

        expect(error_output.string).to include('Warning: Could not read X: \e[31mred\e[0m\rgone')
        expect(error_output.string).not_to include("\e")
      end

      it "passes --force on, and prints the row's warnings on stderr in text mode only" do
        start_command.row = start_command.row.merge("warnings" => ["rpiv applies to jira, not branch. Continuing because of --force."])
        cli.run(["workflow", "start", "rpiv", "x", "--force"])
        expect(start_command.calls.last).to include(force: true)
        expect(error_output.string).to include("Warning: rpiv applies to jira, not branch. Continuing because of --force.")

        error_output.truncate(0)
        error_output.rewind
        cli.run(["workflow", "start", "rpiv", "x", "--force", "--json"])
        expect(error_output.string).not_to include("warning:")
        expect(JSON.parse(output.string.lines.last)["results"].first["warnings"]).not_to be_empty
      end
    end

    it "parses add ID PATH, with --dry-run, as an action document" do
      workflow_command.row = {"workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => "Would add workflow ship at /g/ship.yml.",
                              "workflow" => "ship", "path" => "/g/ship.yml", "sha256" => "abc"}

      expect { cli.run(["workflow", "add", "ship", "draft.yml", "--dry-run", "--json"]) }.not_to raise_error
      cli.run(["workflow", "add", "--dry-run", "ship", "-"])

      expect(workflow_command.calls).to eq([[:add, {id: "ship", path: "draft.yml", dry_run: true, project: nil}], [:add, {id: "ship", path: "-", dry_run: true, project: nil}]])
      doc = JSON.parse(output.string.lines.first)
      expect(doc).to include("ok" => true, "action" => "workflow add", "status" => "dry_run")
      expect(doc["results"]).to eq([workflow_command.row])
    end

    it "parses update ID PATH --if-sha256 SHA, with --dry-run, as an action document" do
      workflow_command.row = {"workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => "Would update workflow ship at /g/ship.yml.",
                              "workflow" => "ship", "path" => "/g/ship.yml", "sha256" => "abc"}

      cli.run(["workflow", "update", "ship", "draft.yml", "--if-sha256", "abc123", "--dry-run", "--json"])
      cli.run(["workflow", "update", "--if-sha256", "abc123", "ship", "-"])

      expect(workflow_command.calls).to eq([[:update, {id: "ship", path: "draft.yml", if_sha256: "abc123", dry_run: true, project: nil}],
        [:update, {id: "ship", path: "-", if_sha256: "abc123", dry_run: false, project: nil}]])
      doc = JSON.parse(output.string.lines.first)
      expect(doc).to include("ok" => true, "action" => "workflow update", "status" => "dry_run")
    end

    it "parses remove ID with --yes or --dry-run as an action document, and prints the help" do
      workflow_command.row = {"workspace" => nil, "outcome" => "removed", "reason" => nil, "message" => "Removed workflow ship at /g/ship.yml.", "workflow" => "ship", "path" => "/g/ship.yml"}

      cli.run(["workflow", "remove", "ship", "--yes", "--json"])
      cli.run(["workflow", "remove", "ship", "--dry-run"])

      expect(workflow_command.calls.select { |call| call.first == :remove }).to eq([[:remove, {id: "ship", yes: true, dry_run: false, project: nil}], [:remove, {id: "ship", yes: nil, dry_run: true, project: nil}]])
      expect(JSON.parse(output.string.lines.first)).to include("ok" => true, "action" => "workflow remove")
      output.truncate(0)
      cli.run(["workflow", "--help"])
      expect(output.string).to include("workspace workflow remove ID [--yes] [--dry-run] [--json]", "remove: check and delete nothing", "--yes")
    end

    it "answers a declined prompt as status cancelled and exit 0" do
      workflow_command.row = nil
      expect { cli.run(["workflow", "remove", "ship"]) }.not_to raise_error
      expect(workflow_command.calls.last).to eq([:remove, {id: "ship", yes: nil, dry_run: false, project: nil}])
    end

    it "treats --json without --yes or --dry-run as a usage error that never prompts" do
      expect { cli.run(["workflow", "remove", "ship", "--json"]) }.to raise_error(FakeSystemExit)
      expect(workflow_command.calls.map(&:first)).not_to include(:remove)
    end

    it "reads a run's events, with --since" do
      cli.run(["workflow", "events", "wr_1"])
      cli.run(["workflow", "events", "wr_1", "--since", "40", "--json"])

      expect(workflow_command.calls).to eq([[:events, {run: "wr_1", since: 0, json: false, follow: false, types: nil, timeout: nil}], [:events, {run: "wr_1", since: 40, json: true, follow: false, types: nil, timeout: nil}]])
    end

    it "lists a run's attempts, of one step" do
      cli.run(["workflow", "attempts", "wr_1", "--attempt-of", "plan", "--json"])

      expect(workflow_command.calls).to eq([[:attempts, {run: "wr_1", step: "plan", json: true}]])
    end

    it "delegates trace to the command, with --json and --table" do
      run("trace", "wr_1")
      run("trace", "wr_1", "--json")
      run("trace", "wr_1", "--table")

      expect(workflow_command.calls).to eq([
        [:trace, {run: "wr_1", json: false, table: false}],
        [:trace, {run: "wr_1", json: true, table: false}],
        [:trace, {run: "wr_1", json: false, table: true}]
      ])
    end

    it "gives the JSON document when --json and --table are both given" do
      run("trace", "wr_1", "--json", "--table")

      expect(workflow_command.calls).to eq([[:trace, {run: "wr_1", json: true, table: true}]])
    end

    it "refuses trace without a RUN and --table on other subcommands" do
      expect { run("trace") }.to raise_error(Workspace::UsageError, "workflow trace needs a RUN id (see `workspace workflow status`).")
      expect { run("attempts", "wr_1", "--table") }.to raise_error(Workspace::UsageError, "--table is for `workflow status` and `workflow trace`.")
      expect(workflow_command.calls).to be_empty
    end

    it "lists a run's files" do
      cli.run(["workflow", "files", "wr_1", "--json"])

      expect(workflow_command.calls).to eq([[:files, {run: "wr_1", json: true}]])
    end

    it "validates a PATH or stdin, with --id" do
      cli.run(["workflow", "validate", "a.yml", "--json"])
      cli.run(["workflow", "validate", "-", "--id", "ship"])

      expect(workflow_command.calls).to eq([[:validate, {path: "a.yml", id: nil, json: true, project: nil}], [:validate, {path: "-", id: "ship", json: false, project: nil}]])
    end

    it "starts a run in the detected workspace, from its working directory" do
      cli.run(["workflow", "run", "rpiv", "--input", "task=PROJ-1 export=pdf", "--input", "spec=", "--note", "Keep it small."])

      expect(workflow_command.calls).to eq([[:run, {id: "rpiv", workspace: "detected-ws", worktree: "/some/dir",
                                                    inputs: {"task" => "PROJ-1 export=pdf", "spec" => ""}, pane: nil, note: "Keep it small.", dry_run: false, caller_pane: ENV["TMUX_PANE"], project: nil, fill_from_branch: false}]])
    end

    it "fills from the branch only for a checkout it resolved: the --name target's, not the working directory" do
      cli.run(["workflow", "run", "rpiv", "--name", "api"])

      expect(workflow_command.calls.first.last).to include(worktree: "/work/api", fill_from_branch: true)
    end

    it "starts a run in a named workspace from its root, in a named pane, or only checks with --dry-run" do
      cli.run(["workflow", "run", "rpiv", "--name", "api", "--pane", "0.1", "--dry-run"])

      expect(workflow_command.calls.first.last).to include(workspace: "api", worktree: "/work/api", pane: "0.1", dry_run: true)
    end

    it "uses the detected workspace's root, not the subdirectory the command was run in" do
      allow(detector).to receive(:detect).and_return("api")

      cli.run(["workflow", "run", "rpiv"])

      expect(workflow_command.calls.first.last).to include(workspace: "api", worktree: "/work/api")
    end

    it "prints one action document under --json, with the run in its row" do
      cli.run(["workflow", "--json", "run", "rpiv"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "action" => "workflow run", "status" => "ok", "summary" => {"started" => 1})
      expect(doc["results"]).to eq([workflow_command.row])
    end

    it "reports a dry run as dry_run" do
      workflow_command.row = {"workspace" => "api", "outcome" => "dry_run", "workflow" => "rpiv", "step" => "research", "pane" => "%5"}

      cli.run(["workflow", "run", "rpiv", "--dry-run", "--json"])

      expect(JSON.parse(output.string)).to include("status" => "dry_run", "results" => [workflow_command.row])
    end

    it "exits 1 when the step could not be started, with the run still in the document" do
      workflow_command.row = workflow_command.row.merge("outcome" => "failed", "reason" => "pane_gone", "message" => "no pane %5")

      expect { cli.run(["workflow", "run", "rpiv", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => true, "status" => "failed")

      expect { cli.run(["workflow", "resume", "wr_1"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "lists --needs-me on the status help page" do
      cli.run(["workflow", "status", "--help"])
      expect(output.string).to include("workflow status --needs-me [--name WORKSPACE | --project [NAME]] [--json]")
    end

    it "resumes, cancels and rejects a run by id" do
      cli.run(["workflow", "resume", "wr_1", "--from", "implement", "--note", "Fixed the fixture.", "--pane", "%8"])
      cli.run(["workflow", "cancel", "wr_1"])
      cli.run(["workflow", "reject", "wr_1", "--note", "Too big.", "--to", "research"])

      expect(workflow_command.calls).to eq([
        [:resume, {run: "wr_1", from: "implement", note: "Fixed the fixture.", pane: "%8", extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, caller_pane: nil, accept_guard: false, guard_retry: false, restart_step: false}],
        [:cancel, {run: "wr_1"}],
        [:reject, {run: "wr_1", note: "Too big.", to: "research", step: nil, attempt: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, caller_pane: nil}]
      ])
    end

    it "tells the command which pane a resume was run from, and exits 0 for one that changed nothing" do
      stub_env("TMUX_PANE" => "%5")
      workflow_command.row = workflow_command.row.merge("outcome" => "unchanged", "message" => "Nothing was done: an agent is working on step plan.")

      cli.run(["workflow", "resume", "wr_1", "--json"])

      expect(workflow_command.calls).to eq([[:resume, {run: "wr_1", from: nil, note: nil, pane: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, caller_pane: "%5", accept_guard: false, guard_retry: false, restart_step: false}]])
      expect(JSON.parse(output.string)).to include("ok" => true, "status" => "ok", "summary" => {"unchanged" => 1})
    end

    it "hands --extra-rounds to the resume" do
      cli.run(["workflow", "resume", "wr_1", "--extra-rounds", "3"])

      expect(workflow_command.calls.last.last).to include(run: "wr_1", extra_rounds: 3)
    end

    it "passes --accept-guard and --retry with the note to the resume, leaving how they go together to the command" do
      cli.run(["workflow", "resume", "wr_1", "--accept-guard", "--note", "The rebase was mine."])
      cli.run(["workflow", "resume", "wr_1", "--accept-guard", "--retry", "--note", "Run it again.", "--extra-attempts", "1"])

      expect(workflow_command.calls).to eq([
        [:resume, {run: "wr_1", from: nil, note: "The rebase was mine.", pane: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, caller_pane: nil, accept_guard: true, guard_retry: false, restart_step: false}],
        [:resume, {run: "wr_1", from: nil, note: "Run it again.", pane: nil, extra_attempts: 1, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, caller_pane: nil, accept_guard: true, guard_retry: true, restart_step: false}]
      ])
      cli.run(%w[workflow resume wr_1 --retry --from plan])
      expect(workflow_command.calls.last).to eq([:resume, {run: "wr_1", from: "plan", note: nil, pane: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, caller_pane: nil, accept_guard: false, guard_retry: true, restart_step: false}])
    end

    {
      %w[cancel wr_1 --accept-guard --note why] => "--accept-guard is for `workflow resume`.",
      %w[approve wr_1 --retry --note why] => "--retry is for `workflow resume RUN --accept-guard --note WHY`."
    }.each do |args, message|
      it "refuses `workflow #{args.join(" ")}` before the command is called" do
        expect { cli.run(["workflow", *args]) }.to raise_error(Workspace::UsageError, Regexp.new(Regexp.escape(message)))
        expect(workflow_command.calls).to be_empty
      end
    end

    it "hands pause its --interrupt and --reason, and unpause the run, each with the caller's pane" do
      cli.run(%w[workflow pause wr_1])
      cli.run(["workflow", "pause", "wr_1", "--interrupt", "--reason", "look first"])
      cli.run(%w[workflow unpause wr_1])

      expect(workflow_command.calls).to eq([
        [:pause, {run: "wr_1", interrupt: false, reason: nil, caller_pane: ENV["TMUX_PANE"]}],
        [:pause, {run: "wr_1", interrupt: true, reason: "look first", caller_pane: ENV["TMUX_PANE"]}],
        [:unpause, {run: "wr_1", caller_pane: ENV["TMUX_PANE"]}]
      ])
    end

    it "answers pause and unpause with one action document, outcome paused and unpaused" do
      workflow_command.row = {"workspace" => "app", "outcome" => "paused", "reason" => "paused", "message" => nil, "interrupted" => true, "run" => {"id" => "wr_1"}}
      cli.run(%w[workflow pause wr_1 --json])

      expect(JSON.parse(output.string)).to include("ok" => true, "action" => "workflow pause")
    end

    {
      %w[cancel wr_1 --interrupt] => "--interrupt is for `workflow pause RUN`.",
      %w[unpause wr_1 --interrupt] => "--interrupt is for `workflow pause RUN`.",
      %w[resume wr_1 --reason why] => "--reason is for `workflow pause RUN`.",
      %w[unpause wr_1 --reason why] => "--reason is for `workflow pause RUN`.",
      ["pause", "wr_1", "--reason", "  "] => "--reason must not be empty.",
      ["pause", "wr_1", "--reason", "x" * 4001] => "--reason is at most 4000 characters, got 4001.",
      %w[pause] => "workflow pause needs a RUN id.",
      %w[unpause] => "workflow unpause needs a RUN id."
    }.each do |args, message|
      it "refuses `workflow #{args.join(" ")[0, 40]}` before the command is called" do
        expect { cli.run(["workflow", *args]) }.to raise_error(Workspace::UsageError, Regexp.new(Regexp.escape(message)))
        expect(workflow_command.calls).to be_empty
      end
    end

    it "lets a refused pause or unpause reach the CLI's error funnel, which answers the error document and exit 1" do
      workflow_command.error = Workspace::Error.new("Run wr_1 is already paused.", code: "already_paused")

      expect { cli.run(%w[workflow pause wr_1 --json]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("already_paused") }
      expect { cli.run(%w[workflow unpause wr_1]) }.to raise_error(Workspace::Error)
    end

    it "approves a gate, telling the command which pane it was run from" do
      cli.run(["workflow", "approve", "wr_1", "--note", "Go."])
      stub_env("TMUX_PANE" => "%5")
      cli.run(["workflow", "approve", "wr_1"])

      expect(workflow_command.calls.map(&:last)).to eq([{run: "wr_1", note: "Go.", step: nil, attempt: nil, note_sha256: nil, caller_pane: nil},
        {run: "wr_1", note: nil, step: nil, attempt: nil, note_sha256: nil, caller_pane: "%5"}])
    end

    it "passes the step, attempt and note hash a client saw to approve and reject, in either form and with the run after --" do
      sha = "0123456789abcdef" * 4
      stub_env("TMUX_PANE" => "%5")
      cli.run(["workflow", "approve", "--step=triage", "--attempt=2", "--note-sha256=#{sha}", "--json", "--", "wr_1"])
      cli.run(["workflow", "reject", "wr_1", "--step", "triage", "--attempt", "2", "--note", "Redo F3.", "--to", "triage"])
      cli.run(["workflow", "approve", "wr_1", "--step", "triage"])

      expect(workflow_command.calls).to eq([
        [:approve, {run: "wr_1", note: nil, step: "triage", attempt: 2, note_sha256: sha, caller_pane: "%5"}],
        [:reject, {run: "wr_1", note: "Redo F3.", to: "triage", step: "triage", attempt: 2, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, caller_pane: "%5"}],
        [:approve, {run: "wr_1", note: nil, step: "triage", attempt: nil, note_sha256: nil, caller_pane: "%5"}]
      ])
    end

    it "runs the daemon's advance: a turn that ended in a pane, or the timer's look" do
      cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5"])
      cli.run(["workflow", "advance", "wr_1"])
      cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--turn-started", "2026-10-04T12:29:58.123Z", "--stopped-at", "2026-10-04T12:30:00.500Z"])

      expect(workflow_command.calls.map(&:last)).to eq([
        {run: "wr_1", turn_ended: true, pane: "%5", turn_started: nil, stopped_at: nil, background: [], caller_pane: ENV["TMUX_PANE"]},
        {run: "wr_1", turn_ended: false, pane: nil, turn_started: nil, stopped_at: nil, background: [], caller_pane: ENV["TMUX_PANE"]},
        {run: "wr_1", turn_ended: true, pane: "%5", turn_started: Time.utc(2026, 10, 4, 12, 29, 58, 123_000),
         stopped_at: Time.utc(2026, 10, 4, 12, 30, 0, 500_000), background: [], caller_pane: ENV["TMUX_PANE"]}
      ])
      expect(output.string).to eq("")
    end

    it "parses each --background-task on its first colon" do
      cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--background-task", "MCP task:k12345678", "--background-task", "shell:b-1"])

      expect(workflow_command.calls.last.last[:background]).to eq([{"id" => "k12345678", "type" => "MCP task"}, {"id" => "b-1", "type" => "shell"}])
    end

    it "refuses a note or an input that is not valid text before the command is called, as one usage document under --json" do
      cut = (+"caf\xC3").force_encoding("UTF-8")
      [["workflow", "approve", "wr_1", "--note", cut], ["workflow", "reject", "wr_1", "--note", cut], ["workflow", "resume", "wr_1", "--note", cut],
        ["workflow", "run", "rpiv", "--note", cut], ["workflow", "run", "rpiv", "--input", "task=#{cut}"]].each do |argv|
        output.truncate(0)
        output.rewind
        output.rewind
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        flag = argv.include?("--input") ? "--input" : "--note"
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage",
          "error" => "#{flag} holds bytes that are not valid UTF-8 text (was it cut in the middle of a character?).")
      end
      expect(error_output.string).to eq("")
      expect(workflow_command.calls).to be_empty
    end

    describe "with no UTF-8 locale, where Ruby tags every argument binary" do
      it "still refuses a note cut in the middle of a character, before the command is called" do
        expect { cli.run(["workflow", "approve", "wr_1", "--note", "caf\xC3".b.freeze, "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage",
          "error" => "--note holds bytes that are not valid UTF-8 text (was it cut in the middle of a character?).")
        expect(workflow_command.calls).to be_empty
      end

      it "hands the command a valid non-ASCII input and note as UTF-8 text, which a definition's text can be joined with" do
        cli.run(["workflow", "run", "rpiv", "--input", "task=café".b.freeze, "--note", "naïve".b.freeze])

        given = workflow_command.calls.first.last
        expect(given[:inputs]).to eq("task" => "café")
        expect([given[:inputs]["task"].encoding, given[:note].encoding]).to eq([Encoding::UTF_8, Encoding::UTF_8])
        expect(Workspace::WorkflowDefinition.render("Café: {{inputs.task}}", "inputs.task" => given[:inputs]["task"])).to eq("Café: café")
      end
    end

    describe "#run with step" do
      before { stub_env("TMUX_PANE" => "%5") }

      it "records the agent's report from the pane it runs in: pass by default, or fail with a summary" do
        workflow_command.row = {"workspace" => "app", "outcome" => "recorded", "reason" => nil, "message" => nil, "run_id" => "wr_1", "step" => "plan",
                                "attempt" => 1, "reported" => {"status" => "pass", "summary" => nil}}
        cli.run(["step", "done"])
        cli.run(["step", "done", "--status", "fail", "--summary", "Two specs still fail.", "--json"])

        expect(workflow_command.calls).to eq([
          [:step_done, {pane: "%5", status: "pass", summary: nil, code: nil}],
          [:step_done, {pane: "%5", status: "fail", summary: "Two specs still fail.", code: nil}]
        ])
        expect(JSON.parse(output.string)).to include("action" => "step done", "status" => "ok", "results" => [workflow_command.row])
      end

      it "passes --code to the command" do
        cli.run(["step", "done", "--status", "fail", "--code", "not_reproduced"])

        expect(workflow_command.calls).to eq([[:step_done, {pane: "%5", status: "fail", summary: nil, code: "not_reproduced"}]])
      end

      it "refuses a summary that is not valid text, and records nothing" do
        expect { cli.run(["step", "done", "--summary", (+"caf\xC3").force_encoding("UTF-8"), "--json"]) }.to raise_error(FakeSystemExit)

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage",
          "error" => "--summary holds bytes that are not valid UTF-8 text (was it cut in the middle of a character?).")
        expect(workflow_command.calls).to be_empty
      end

      it "reads a summary as UTF-8 with no UTF-8 locale: a cut one is refused, a whole one is passed on as text" do
        expect { cli.run(["step", "done", "--summary", "caf\xC3".b.freeze, "--json"]) }.to raise_error(FakeSystemExit)
        expect(workflow_command.calls).to be_empty

        cli.run(["step", "done", "--summary", "fini à 100%".b.freeze])
        expect(workflow_command.calls.first.last[:summary]).to eq("fini à 100%")
        expect(workflow_command.calls.first.last[:summary].encoding).to eq(Encoding::UTF_8)
      end

      it "shows the step the pane is on" do
        cli.run(["step", "status", "--json"])

        expect(workflow_command.calls).to eq([[:step_status, {pane: "%5", json: true}]])
      end

      it "prints help" do
        cli.run(["step", "--help"])

        expect(output.string).to include("Usage: workspace step done [--status pass|fail] [--summary TEXT] [--code WORD] [--json]").and include("end your turn")
      end
    end
  end
end
