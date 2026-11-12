require "spec_helper"
require "stringio"
require "tmpdir"
require "json"
require "digest"
require "fileutils"

# The workflow family through CLI#run: its rescue funnel, the help pages and the scope rules a
# real StatusScope applies, and real Commands::Workflow objects over temporary directories.
RSpec.describe Workspace::CLI do
  # Sets the named keys on the real ENV (nil deletes) until the example ends; nothing else is touched.
  def stub_env(vars)
    @saved_env ||= {}
    vars.each do |key, value|
      @saved_env[key] = ENV[key] unless @saved_env.key?(key)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  after do
    (@saved_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # A CLI with only the workflow family's collaborators: the commands no workflow verb reaches are nil.
  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    state = CLITestHelpers::FakeState.new
    project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
    project_detector = overrides[:project_detector] || Workspace::ProjectDetector.new(state: state, project_config: project_config)
    status_scope = Workspace::StatusScope.new(project_detector: project_detector, catalog: overrides[:project_catalog] || CLITestHelpers::FakeStatusCatalog.new)
    unused = %i[launch_command kill_command finish_command start_command stop_command focus_command tile_command layout_command resize_command
      init_command repair_command cleanup_command prune_command claude_command lookup_command update_pane_command run_command run_result_store
      run_and_report_command capture_command wait_until_content_command lock_command dev_command parent_command agent_command sessions_command
      session_event_command config_command statusline_command ask_command].to_h { |key| [key, nil] }

    cli = CLITestHelpers.build_cli(
      config: Workspace::Config.new,
      state: state,
      project_config: project_config,
      git: Workspace::Git.new(output: output, input: input),
      window_manager: CLITestHelpers::FakeWindowManager.new,
      doctor: CLITestHelpers::FakeDoctor.new,
      project_settings: CLITestHelpers::FakeProjectSettings.new,
      hook_runner: CLITestHelpers::FakeHookRunner.new,
      project_detector: project_detector,
      status_scope: status_scope,
      lineage: CLITestHelpers::FakeLineage.new,
      workflow_command: overrides[:workflow_command],
      workflow_start_command: overrides[:workflow_start_command],
      logger: Workspace::Logger.new(output: error_output),
      output: output,
      error_output: error_output,
      exit_handler: FakeExitHandler,
      input: input,
      working_dir: overrides[:working_dir] || Dir.tmpdir,
      sleeper: ->(_) {},
      launch_mode: CLITestHelpers.launch_mode(headless: false),
      env: {},
      **unused
    )
    [cli, output, error_output]
  end

  describe "#run with workflow" do
    let(:workflow_command) { CLITestHelpers::FakeWorkflowCommand.new }
    let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/work/api") }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(workflow_command: workflow_command, project_config: project_config, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    before { stub_env("TMUX_PANE" => nil) }

    it "answers an invalid global file with --source --json and exit 0, end to end" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "global"))
        bad = "title: Flow\nbogus: 1\nsteps:\n  plan:\n    nope: 1\n"
        File.write(File.join(dir, "global", "bad.yml"), bad)
        catalog = Workspace::WorkflowCatalog.new(config: instance_double(Workspace::Config, workflows_dir: File.join(dir, "global"), builtin_workflows_dir: File.join(dir, "none")))
        out = StringIO.new
        real_cli = build_test_cli(workflow_command: Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil, tmux: nil, process_tree: nil, lock_holder: nil, output: out))[0]

        real_cli.run(["workflow", "show", "bad", "--source", "--json"])
        doc = JSON.parse(out.string)
        expect(doc["workflow"]).to include("text" => bad, "sha256" => Digest::SHA256.hexdigest(bad))
        expect(doc["workflow"]["problems"]).not_to be_empty

        expect { real_cli.run(["workflow", "show", "bad"]) }.to raise_error(FakeSystemExit)
      end
    end

    context "start" do
      let(:start_command) { CLITestHelpers::FakeWorkflowStartCommand.new }
      let(:built) { build_test_cli(workflow_command: workflow_command, workflow_start_command: start_command, project_config: project_config, project_detector: detector, working_dir: "/some/dir") }

      it "routes --ref with no ID, and refuses it beside an ID, a REF or --prompt" do
        cli.run(["workflow", "start", "--ref", "#123", "--dry-run", "--force"])
        expect(start_command.calls.last).to include(id: nil, ref: "#123", route: true, dry_run: true, force: true)

        [["rpiv", "--ref", "PROJ-1"], ["--ref", "PROJ-1", "rpiv"], ["--ref", "PROJ-1", "--prompt", "x"], ["--ref", " "]].each do |args|
          expect { cli.run(["workflow", "start", *args]) }.to raise_error(FakeSystemExit)
        end
        expect(start_command.calls.size).to eq(1)
        expect(error_output.string).to include("--ref takes the place of", "--prompt has no kind", "--ref needs a REF")
      end

      it "keeps the routing line off stdout under --ref --json: one document" do
        raw = StringIO.new
        gate = Workspace::OutputGate.new(raw)
        err = StringIO.new
        routing = AnnouncingWorkflowStartCommand.new(gate, "Routing PROJ-1 (jira) to rpiv, this project's default for jira.")
        routing.row = {"workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => "Would.", "routed" => {"ref" => "PROJ-1", "kind" => "jira", "workflow" => "rpiv", "source" => "default", "scope" => "project", "key" => "workflows.by_ref.jira"}}
        json_cli, = build_test_cli(workflow_command: workflow_command, workflow_start_command: routing, project_config: project_config, project_detector: detector, working_dir: "/some/dir", output: gate, error_output: err)

        json_cli.run(["workflow", "start", "--ref", "PROJ-1", "--dry-run", "--json"])

        doc = JSON.parse(raw.string)
        expect(doc["results"].first["routed"]).to include("workflow" => "rpiv", "scope" => "project")
        expect(err.string).to include("Routing PROJ-1")
      end

      it "refuses --ref with another subcommand" do
        expect { cli.run(["workflow", "run", "rpiv", "--ref", "PROJ-1"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--ref is for `workflow start")
      end

      it "refuses --project after --prompt TEXT as a flag of another subcommand" do
        expect { cli.run(["workflow", "start", "rpiv", "--prompt", "add a script", "--project"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("--project is for `workflow status`, `workflow stats` and `workflow compare`.")
        expect(start_command.calls).to be_empty
      end

      it "needs a REF or --prompt" do
        expect { cli.run(["workflow", "start"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to match(/needs a REF.*--prompt/)
        expect(start_command.calls).to be_empty
      end

      it "refuses --name and --pane" do
        expect { cli.run(["workflow", "start", "rpiv", "PROJ-1", "--name", "ws"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--name is for `workflow run`")
        expect { cli.run(["workflow", "start", "rpiv", "PROJ-1", "--pane", "%1"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--pane is for `workflow run`")
        expect(start_command.calls).to be_empty
      end

      it "refuses a start-only flag with workflow run" do
        expect { cli.run(["workflow", "run", "rpiv", "--prompt", "x"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--prompt is for `workflow start")
        expect { cli.run(["workflow", "run", "rpiv", "--slug"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--slug is for `workflow start")
        expect(workflow_command.calls).to be_empty
      end

      it "refuses --force with workflow run and remove" do
        expect { cli.run(["workflow", "run", "rpiv", "--force"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--force is for `workflow start")
        expect { cli.run(["workflow", "remove", "rpiv", "--force"]) }.to raise_error(FakeSystemExit)
        expect(workflow_command.calls).to be_empty
      end

      it "prints a refusal's warnings once on stderr in text mode, and leaves them to the document under --json" do
        start_command.error = Workspace::Error.new("Needs task.", code: "input_required", details: {"warnings" => ["\"rpvi\" is not a known workflow"]})

        expect { cli.run(["workflow", "start", "rpvi", "--dry-run"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string.scan("Warning: \"rpvi\" is not a known workflow").size).to eq(1)

        error_output.truncate(0)
        expect { cli.run(["workflow", "start", "rpvi", "--dry-run", "--json"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).not_to include("Warning:")
      end
    end

    it "adds a definition from stdin end to end, then refuses a second add with workflow_exists" do
      Dir.mktmpdir do |dir|
        config = instance_double(Workspace::Config, workflows_dir: File.join(dir, "home", "workflows"), builtin_workflows_dir: File.join(dir, "builtin"), workspace_projects_dir: File.join(dir, "no-projects"))
        catalog = Workspace::WorkflowCatalog.new(config: config)
        text = "title: Ship\nsteps:\n  plan:\n    prompt: Plan.\n"
        command = Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, files: Workspace::WorkflowFiles.new(config: config, catalog: catalog),
          engine: nil, status: nil, store: nil, panes: nil, run_files: nil, tmux: nil, process_tree: nil, lock_holder: nil, output: StringIO.new, input: StringIO.new(text))
        real_cli, out = build_test_cli(workflow_command: command)

        real_cli.run(["workflow", "add", "ship", "-", "--json"])
        row = JSON.parse(out.string)["results"].first
        expect(row).to include("outcome" => "added", "workflow" => "ship", "path" => File.join(dir, "home", "workflows", "ship.yml"),
          "sha256" => Digest::SHA256.hexdigest(text))
        expect(File.read(row["path"])).to eq(text)

        out.truncate(0)
        out.rewind
        File.write(File.join(dir, "again.yml"), text)
        expect { real_cli.run(["workflow", "add", "ship", File.join(dir, "again.yml"), "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(out.string.lines.last)).to include("ok" => false, "code" => "workflow_exists")
      end
    end

    it "updates a definition end to end, then answers stale_workflow with the current sha256 for a second update from the old one" do
      Dir.mktmpdir do |dir|
        home = File.join(dir, "home", "workflows")
        FileUtils.mkdir_p(home)
        old_text = "title: Old\nsteps:\n  plan:\n    prompt: Old.\n"
        text = "title: Ship\nsteps:\n  plan:\n    prompt: Plan.\n"
        File.write(File.join(home, "ship.yml"), old_text)
        config = instance_double(Workspace::Config, workflows_dir: home, builtin_workflows_dir: File.join(dir, "builtin"), workspace_projects_dir: File.join(dir, "no-projects"))
        catalog = Workspace::WorkflowCatalog.new(config: config)
        command = Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, files: Workspace::WorkflowFiles.new(config: config, catalog: catalog),
          engine: nil, status: nil, store: nil, panes: nil, run_files: nil, tmux: nil, process_tree: nil, lock_holder: nil, output: StringIO.new, input: StringIO.new(text))
        real_cli, out = build_test_cli(workflow_command: command)
        old_sha = Digest::SHA256.hexdigest(old_text)

        real_cli.run(["workflow", "update", "ship", "-", "--if-sha256", old_sha, "--json"])
        row = JSON.parse(out.string)["results"].first
        expect(row).to include("outcome" => "updated", "workflow" => "ship", "sha256" => Digest::SHA256.hexdigest(text))
        expect(File.read(File.join(home, "ship.yml"))).to eq(text)

        out.truncate(0)
        out.rewind
        File.write(File.join(dir, "again.yml"), text)
        expect { real_cli.run(["workflow", "update", "ship", File.join(dir, "again.yml"), "--if-sha256", old_sha, "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(out.string.lines.last)).to include("ok" => false, "code" => "stale_workflow", "details" => include("sha256" => Digest::SHA256.hexdigest(text)))
        expect(File.read(File.join(home, "ship.yml"))).to eq(text)
      end
    end

    it "removes a definition end to end, refuses with confirmation_required under --no-input, and answers cancelled on a declined prompt" do
      Dir.mktmpdir do |dir|
        home = File.join(dir, "home", "workflows")
        FileUtils.mkdir_p(home)
        File.write(File.join(home, "ship.yml"), "title: Ship\nsteps:\n  plan:\n    prompt: Plan.\n")
        config = instance_double(Workspace::Config, workflows_dir: home, builtin_workflows_dir: File.join(dir, "builtin"), workspace_projects_dir: File.join(dir, "no-projects"))
        catalog = Workspace::WorkflowCatalog.new(config: config)
        command = Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, files: Workspace::WorkflowFiles.new(config: config, catalog: catalog),
          engine: nil, status: nil, store: nil, panes: nil, run_files: nil, tmux: nil, process_tree: nil, lock_holder: nil, output: StringIO.new, input: StringIO.new("n\n"))
        real_cli, out = build_test_cli(workflow_command: command)

        expect { real_cli.run(["workflow", "remove", "ship"]) }.not_to raise_error
        expect(File.exist?(File.join(home, "ship.yml"))).to be(true)

        guarded = Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true)
        unknown_cli, unknown_out = build_test_cli(workflow_command: command, input: guarded)
        expect { unknown_cli.run(["workflow", "remove", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(unknown_out.string.lines.last)).to include("ok" => false, "code" => "unknown_workflow")

        no_input_cli, no_input_out = build_test_cli(workflow_command: command, input: Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true))
        expect { no_input_cli.run(["workflow", "remove", "ship", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(no_input_out.string.lines.last)).to include("ok" => false, "code" => "confirmation_required")
        expect(File.exist?(File.join(home, "ship.yml"))).to be(true)

        real_cli.run(["workflow", "remove", "ship", "--dry-run", "--json"])
        expect(JSON.parse(out.string.lines.last)["results"].first).to include("outcome" => "dry_run", "workflow" => "ship")
        expect(File.exist?(File.join(home, "ship.yml"))).to be(true)

        real_cli.run(["workflow", "remove", "ship", "--yes", "--json"])
        expect(JSON.parse(out.string.lines.last)["results"].first).to include("outcome" => "removed", "workflow" => "ship", "path" => File.join(home, "ship.yml"))
        expect(File.exist?(File.join(home, "ship.yml"))).to be(false)
      end
    end

    it "refuses a negative or non-integer --since as a usage error, as an envelope under --json" do
      ["-1", "x", "1.5", ""].each do |value|
        expect { cli.run(["workflow", "events", "wr_1", "--since", value, "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage")
        expect(JSON.parse(output.string.lines.last)["error"]).to match(/--since needs a whole number/)
      end
      expect { cli.run(["workflow", "status", "--since", "1"]) }.to raise_error(FakeSystemExit)
      expect(workflow_command.calls.map(&:first)).not_to include(:events)
    end

    it "refuses --id outside validate" do
      expect { cli.run(["workflow", "add", "ship", "x.yml", "--id", "other"]) }.to raise_error(FakeSystemExit)
      expect(workflow_command.calls).to eq([])
    end

    it "reports what a dirty checkout refused a dry run with, in the error document" do
      workflow_command.error = Workspace::Error.new("not clean", code: "dirty_worktree",
        details: {"path" => "/work/api", "guard" => "tracked_changed", "files" => ["a.rb"]})

      expect { cli.run(["workflow", "run", "investigate", "--name", "api", "--dry-run", "--json"]) }.to raise_error(FakeSystemExit)

      document = JSON.parse(output.string.lines.last)
      expect(document).to include("ok" => false, "code" => "dirty_worktree")
      expect(document["details"]).to eq("path" => "/work/api", "guard" => "tracked_changed", "files" => ["a.rb"])
    end

    it "fails an unknown --name with unknown_workspace, starting nothing" do
      expect { cli.run(["workflow", "run", "rpiv", "--name", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
      expect(workflow_command.calls).to be_empty
    end

    it "refuses an --input that is not KEY=VALUE, and a run with no workspace" do
      expect { cli.run(["workflow", "run", "rpiv", "--input", "task"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include('--input takes KEY=VALUE, got "task".')

      allow(detector).to receive(:detect).and_return(nil)
      expect { cli.run(["workflow", "run", "rpiv"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("workflow run needs a workspace: pass --name, or run from inside a project.")
      expect(workflow_command.calls).to be_empty
    end

    it "shows where runs stand: this workspace's going runs, a named workspace's, every run, or one run" do
      cli.run(["workflow", "status"])
      cli.run(["workflow", "status", "--name", "api", "--json"])
      cli.run(["workflow", "status", "--all", "--json"])
      cli.run(["workflow", "status", "wr_1"])

      expect(workflow_command.calls.map(&:last).map { |kw| kw.merge(scope: kw[:scope]&.to_h) }).to eq([
        {run: nil, scope: {kind: :workspace, workspace: "detected-ws", project: nil}, json: false, hint: true, table: false},
        {run: nil, scope: {kind: :workspace, workspace: "api", project: nil}, json: true, hint: false, table: false},
        {run: nil, scope: {kind: :all, workspace: nil, project: nil}, json: true, hint: true, table: false},
        {run: "wr_1", scope: nil, json: false, hint: true, table: false}
      ])
    end

    it "shows a project's runs for --project, bare or by name" do
      project = Struct.new(:name, :members).new("my-app", [Struct.new(:workspace).new("detected-ws")])
      catalog = instance_double(Workspace::ProjectCatalog, all: [project], find: project)
      cli, = build_test_cli(workflow_command: workflow_command, project_config: project_config, project_detector: detector, working_dir: "/some/dir", project_catalog: catalog)

      cli.run(["workflow", "status", "--project", "--json"])
      cli.run(["workflow", "status", "--project", "my-app", "--json"])

      expect(workflow_command.calls.map { |_, kw| kw[:scope].project }).to eq([project, project])
      expect(workflow_command.calls.map { |_, kw| kw[:scope].kind }).to eq([:project, :project])
    end

    it "refuses two scopes, and a RUN with any scope" do
      [%w[--name api --all], %w[--name api --project], %w[--project --all]].each do |flags|
        expect { cli.run(["workflow", "status", *flags]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Give only one of --name, --project and --all.")
      end
      %w[--name=api --project --all].each do |flag|
        expect { cli.run(["workflow", "status", "wr_1", flag]) }.to raise_error(FakeSystemExit)
      end
      expect(error_output.string).to include("workflow status RUN takes no --name, --project or --all")
      expect(workflow_command.calls).to be_empty
    end

    it "refuses --project on the other subcommands, and lists it in the help beside --prompt" do
      expect { cli.run(["workflow", "show", "rpiv", "--project"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--project is for `workflow status`, `workflow stats` and `workflow compare`.")

      cli.run(["workflow", "--help"])
      expect(output.string).to include("--project [NAME]").and include("--prompt TEXT")
    end

    it "passes --table through, at every scope and for a RUN, and lists it in the help after the scope group" do
      cli.run(["workflow", "status", "--table"])
      cli.run(["workflow", "status", "--all", "--table", "--json"])
      cli.run(["workflow", "status", "wr_1", "--table"])

      expect(workflow_command.calls.map(&:last).map { |kw| kw.values_at(:table, :json) }).to eq([[true, false], [true, true], [true, false]])

      cli.run(["workflow", "status", "--help"])
      expect(output.string).to include("--project [NAME] | --all] [--table] [--json]").and include("--table")
    end

    it "passes --needs-me through as the needs_me scope, narrowed by --name, and refuses what it can't combine with" do
      cli.run(["workflow", "status", "--needs-me", "--json"])
      cli.run(["workflow", "status", "--needs-me", "--name", "api"])

      expect(workflow_command.calls.map { |_, kw| [kw[:scope].kind, kw[:scope].workspace, kw[:json]] }).to eq([[:needs_me, nil, true], [:needs_me, "api", false]])

      [%w[--needs-me --all], %w[--needs-me --table], %w[--needs-me wr_1], %w[--needs-me --name api --project]].each do |flags|
        expect { cli.run(["workflow", "status", *flags]) }.to raise_error(FakeSystemExit)
      end
      expect { cli.run(["workflow", "show", "rpiv", "--needs-me"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--needs-me is for `workflow status`.")
      expect(workflow_command.calls.size).to eq(2)
    end

    it "exits with the code the status command returns, and with none for no code, 0 or a non-hash" do
      workflow_command.status_result = {exit_code: 3}
      expect { cli.run(["workflow", "status", "--needs-me"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

      [nil, {exit_code: 0}, "text", 3, {}].each do |result|
        workflow_command.status_result = result
        expect { cli.run(["workflow", "status", "--needs-me"]) }.not_to raise_error
      end
    end

    it "exits 3 for a list with an unreadable run file, through the real status and command" do
      Dir.mktmpdir("cli-needs-me") do |dir|
        store = Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive"))
        FileUtils.mkdir_p(File.join(dir, "runs"))
        File.write(File.join(dir, "runs", "wr_bad.json"), "{not json")
        real_status = Workspace::WorkflowStatus.new(store: store, panes: instance_double(Workspace::WorkflowPanes), snapshot_client: instance_double(Workspace::AgentSnapshotClient),
          ask_store_for: ->(_) {}, gate_note: instance_double(Workspace::WorkflowGateNote))
        real = Workspace::Commands::Workflow.new(lint: nil, catalog: nil, engine: nil, status: real_status, store: store, panes: nil, files: nil, run_files: nil, needs_me: Workspace::WorkflowNeedsMe.new,
          tmux: nil, process_tree: nil, lock_holder: nil, output: output)
        real_cli, = build_test_cli(workflow_command: real)

        expect { real_cli.run(["workflow", "status", "--needs-me", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
        expect(JSON.parse(output.string)).to include("status" => "partial", "unreadable" => 1)
      end
    end

    it "refuses --table on the other subcommands, and with a RUN and a scope flag" do
      expect { cli.run(["workflow", "show", "rpiv", "--table"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--table is for `workflow status`.")

      expect { cli.run(["workflow", "status", "wr_1", "--table", "--name", "X"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("workflow status RUN takes no --name, --project or --all")
      expect(workflow_command.calls).to be_empty
    end

    it "reads --project followed by another flag as a bare project, not as its NAME" do
      project = Struct.new(:name, :members).new("my-app", [Struct.new(:workspace).new("detected-ws")])
      catalog = instance_double(Workspace::ProjectCatalog, all: [project], find: project)
      cli, = build_test_cli(workflow_command: workflow_command, project_config: project_config, project_detector: detector, working_dir: "/some/dir", project_catalog: catalog)

      cli.run(["workflow", "status", "--project", "--json"])

      expect(catalog).not_to have_received(:find).with("--json")
      expect(workflow_command.calls.map(&:last)).to contain_exactly(a_hash_including(json: true, scope: have_attributes(kind: :project, project: project)))
    end

    it "answers not_in_workspace outside a workspace, in JSON too, and exits 1" do
      allow(detector).to receive(:detect).and_return(nil)

      expect { cli.run(["workflow", "status", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
      expect(workflow_command.calls).to be_empty
    end

    it "passes --extra-tokens to resume and reject, and refuses a bad one or another verb" do
      cli.run(["workflow", "resume", "wr_1", "--extra-tokens", "250000"])
      cli.run(["workflow", "reject", "wr_1", "--note", "No.", "--extra-tokens=3"])

      expect(workflow_command.calls.map { |call| [call.first, call.last[:extra_tokens]] }).to eq([[:resume, 250_000], [:reject, 3]])
      {["workflow", "resume", "wr_1", "--extra-tokens", "0"] => /--extra-tokens must be a whole number from 1 up, got "0"/,
       ["workflow", "resume", "wr_1", "--extra-tokens", "1e6"] => /--extra-tokens must be a whole number/,
       ["workflow", "approve", "wr_1", "--extra-tokens", "1"] => /--extra-tokens is for `workflow resume` and `workflow reject`/}.each do |argv, message|
        cli, _, error_output = build_test_cli(workflow_command: workflow_command)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)
      end
    end

    it "passes --extra-attempts to resume and reject, and refuses a bad one or another verb" do
      cli.run(["workflow", "resume", "wr_1", "--extra-attempts", "2"])
      cli.run(["workflow", "reject", "wr_1", "--note", "No.", "--extra-attempts=3"])

      expect(workflow_command.calls.map { |call| [call.first, call.last[:extra_attempts]] }).to eq([[:resume, 2], [:reject, 3]])
      {["workflow", "resume", "wr_1", "--extra-attempts", "0"] => /--extra-attempts must be a whole number from 1 up, got "0"/,
       ["workflow", "resume", "wr_1", "--extra-attempts", "x"] => /--extra-attempts must be a whole number/,
       ["workflow", "approve", "wr_1", "--extra-attempts", "1"] => /--extra-attempts is for `workflow resume` and `workflow reject`/}.each do |argv, message|
        cli, _, error_output = build_test_cli(workflow_command: workflow_command)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)
      end
    end

    it "refuses a bad --step, --attempt or --note-sha256 as a usage error, and moves nothing" do
      {["workflow", "approve", "wr_1", "--attempt", "2"] => /--attempt needs --step/,
       ["workflow", "approve", "wr_1", "--step", "plan", "--attempt", "0"] => /--attempt must be a whole number from 1 up, got "0"/,
       ["workflow", "approve", "wr_1", "--step", "plan", "--attempt", "two"] => /--attempt must be a whole number/,
       ["workflow", "approve", "wr_1", "--note-sha256", "ABC"] => /--note-sha256 must be 64 lowercase hex digits/,
       ["workflow", "approve", "wr_1", "--note-sha256", "A" * 64] => /--note-sha256 must be 64 lowercase hex digits/,
       ["workflow", "reject", "wr_1", "--note", "No.", "--note-sha256", "a" * 64] => /--note-sha256 is for `workflow approve`/,
       ["workflow", "resume", "wr_1", "--step", "plan"] => /--step and --attempt are for `workflow approve` and `workflow reject`/,
       ["workflow", "cancel", "wr_1", "--attempt", "1"] => /--step and --attempt are for/}.each do |argv, message|
        cli, _, error_output = build_test_cli(workflow_command: workflow_command)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)

        cli, output = build_test_cli(workflow_command: workflow_command)
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage")
      end
      expect(workflow_command.calls).to be_empty
    end

    it "refuses a --background-task without a colon, an empty id or a type off the list" do
      ["shell", "shell:", "dream:abc", "shell:a b", ":abc"].each do |value|
        expect { cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--background-task", value]) }.to raise_error(FakeSystemExit)
      end

      expect(error_output.string).to include("--background-task takes TYPE:ID")
      expect(workflow_command.calls).to be_empty
    end

    it "refuses a --turn-started that is not a time" do
      expect { cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--turn-started", "soon"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include('--turn-started takes an ISO 8601 time, got "soon".')
      expect(workflow_command.calls).to be_empty
    end

    it "refuses a --stopped-at that is not a time" do
      expect { cli.run(["workflow", "advance", "wr_1", "--turn-ended", "--stopped-at", "soon"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include('--stopped-at takes an ISO 8601 time, got "soon".')
      expect(workflow_command.calls).to be_empty
    end

    it "emits the command's error envelope under --json, and its message without" do
      workflow_command.error = Workspace::Error.new("Run wr_1 is not waiting at a gate (step plan is running).", code: "gate_not_waiting",
        details: {"run" => "wr_1", "step" => "plan", "state" => "running"})

      expect { cli.run(["workflow", "approve", "wr_1", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "gate_not_waiting",
        "details" => {"run" => "wr_1", "step" => "plan", "state" => "running"})

      expect { cli.run(["workflow", "approve", "wr_1"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Run wr_1 is not waiting at a gate")
    end

    it "rejects bad usage, as an envelope under --json" do
      {
        ["workflow"] => /Missing subcommand: list, show, validate, add, update, remove, install, uninstall, run, start, render, check, simulate, status, events, files, attempts, audit, stats, compare, sweep, resume, cancel, approve or reject/,
        ["workflow", "validate"] => /workflow validate needs a PATH, or - for stdin/,
        ["workflow", "events"] => /workflow events needs a RUN id/,
        ["workflow", "files"] => /workflow files needs a RUN id/,
        ["workflow", "attempts"] => /workflow attempts needs a RUN id/,
        ["workflow", "files", "wr_1", "--attempt-of", "plan"] => /--attempt-of is for `workflow attempts RUN`/,
        ["workflow", "show", "--source"] => /workflow show --source needs an ID/,
        ["workflow", "status", "--source"] => /--source is for `workflow show ID`/,
        ["workflow", "run"] => /workflow run needs an ID/,
        ["workflow", "cancel"] => /workflow cancel needs a RUN id/,
        ["workflow", "approve"] => /workflow approve needs a RUN id/,
        ["workflow", "resume"] => /workflow resume needs a RUN id/,
        ["workflow", "reject", "wr_1"] => /workflow reject needs --note TEXT/,
        ["workflow", "reject", "wr_1", "--note", " "] => /workflow reject needs --note TEXT/,
        ["workflow", "status", "wr_1", "extra"] => /Unexpected argument: extra/,
        ["workflow", "add"] => /workflow add needs an ID and a PATH \(or - for stdin\)/,
        ["workflow", "add", "ship"] => /workflow add needs an ID and a PATH/,
        ["workflow", "add", "ship", "a.yml", "extra"] => /Unexpected argument: extra/,
        ["workflow", "update"] => /workflow update needs an ID and a PATH \(or - for stdin\)/,
        ["workflow", "update", "ship"] => /workflow update needs an ID and a PATH/,
        ["workflow", "update", "ship", "a.yml"] => /workflow update needs --if-sha256 SHA/,
        ["workflow", "update", "ship", "a.yml", "--if-sha256", ""] => /workflow update needs --if-sha256 SHA/,
        ["workflow", "update", "ship", "a.yml", "--if-sha256", "abc", "extra"] => /Unexpected argument: extra/,
        ["workflow", "remove"] => /workflow remove needs an ID/,
        ["workflow", "remove", "ship", "extra"] => /Unexpected argument: extra/,
        ["workflow", "show", "rpiv", "extra"] => /Unexpected argument: extra/,
        ["workflow", "validate", "a.yml", "b.yml"] => /Unexpected argument: b\.yml/,
        ["workflow", "cancel", "wr_1", "wr_2"] => /Unexpected argument: wr_2/,
        ["workflow", "run", "rpiv", "--nope"] => /invalid option/
      }.each do |argv, message|
        cli, _, error_output = build_test_cli(workflow_command: workflow_command, project_detector: detector)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)

        cli, output = build_test_cli(workflow_command: workflow_command, project_detector: detector)
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage")
      end
      expect(workflow_command.calls).to be_empty
    end

    it "prints help, also from the main help" do
      cli.run(["workflow", "--help"])
      expect(output.string).to include("Usage: workspace workflow list [--json]").and include("workflow validate PATH|- [--id ID]").and include("workflow add ID PATH|- [--dry-run] [--json]").and include("add, update: check and write no definition").and include("workflow update ID PATH|- --if-sha256 SHA [--dry-run] [--json]").and include("--if-sha256 SHA").and include("workflow events RUN [--since N] [--json]").and include("--since N").and include("workflow files RUN [--json]").and include("--id ID").and include("--input KEY=VALUE")
      output.truncate(0)
      output.rewind
      cli.run(["workflow", "status", "--help"])
      expect(output.string).to include("Usage: workspace workflow status [RUN | --name WORKSPACE | --project [NAME] | --all]", "waiting_lock, waiting_you, turn_ended_incomplete")

      cli.run(["help"])
      expect(output.string).to match(/^\s+workflow\s+Run a workflow \(ordered steps, e\.g\. rpiv\)/)
        .and match(/^\s+step\s+For the agent on a workflow step/)
        .and match(/^\s+pipeline\s+Deprecated \(use workflow\)/)
    end
  end
end
