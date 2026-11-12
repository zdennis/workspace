require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

# The plan and spine family through CLI#run: its rescue funnel (the `--json` error envelopes and
# exit codes), its help, and a real StatusScope, over doubles of the plan, spine and goal commands.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::PlanSpineFamilyCli

  describe "#run with plan" do
    let(:plan_command) { instance_double(Workspace::Commands::Plan, status: [], path: nil, show: nil, init: {"path" => "/n/IMPLEMENTATION_PLAN.md", "message" => nil}) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(plan_command: plan_command, plan_dispatch_command: instance_double(Workspace::Commands::PlanDispatch), plan_task_command: instance_double(Workspace::Commands::PlanTask), project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "reads the plan of the workspace detected from the working directory" do
      cli.run(["plan", "status"])

      expect(detector).to have_received(:detect).with("/some/dir")
      expect(plan_command).to have_received(:status).with(names: ["detected-ws"], json: false)
    end

    it "passes --name and --json to status, in any order" do
      cli.run(["plan", "--json", "status", "--name", "api.worktree-x"])

      expect(plan_command).to have_received(:status).with(names: ["api.worktree-x"], json: true)
    end

    it "passes --all and --file to status without looking for a workspace" do
      cli.run(["plan", "status", "--all", "--json"])
      cli.run(["plan", "status", "--file", "/x/plan.md"])

      expect(plan_command).to have_received(:status).with(all: true, json: true)
      expect(plan_command).to have_received(:status).with(file: "/x/plan.md", json: false)
      expect(detector).not_to have_received(:detect)
    end

    describe "status --project" do
      let(:project) { Struct.new(:name, :members).new("my-app", [Struct.new(:workspace).new("detected-ws")]) }
      let(:catalog) { instance_double(Workspace::ProjectCatalog, all: [project], find: project, member_at: nil) }
      let(:built) do
        build_test_cli(plan_command: plan_command, plan_dispatch_command: instance_double(Workspace::Commands::PlanDispatch), plan_task_command: instance_double(Workspace::Commands::PlanTask),
          project_detector: detector, working_dir: "/some/dir", project_catalog: catalog)
      end

      it "reads the project of the current workspace when bare, or the named project, in text and JSON" do
        cli.run(["plan", "status", "--project"])
        cli.run(["plan", "status", "--project", "my-app", "--json"])

        expect(plan_command).to have_received(:status).with(project: project, json: false)
        expect(plan_command).to have_received(:status).with(project: project, json: true)
      end

      it "reads --project followed by another flag as a bare project" do
        cli.run(["plan", "status", "--project", "--json"])

        expect(catalog).not_to have_received(:find)
        expect(plan_command).to have_received(:status).with(project: project, json: true)
      end

      it "refuses it beside each other scope with the fuller message, before looking anything up" do
        [%w[--name a], %w[--all], %w[--file x], %w[--group g]].each do |flags|
          expect { cli.run(["plan", "status", "--project", *flags, "--json"]) }.to raise_error(FakeSystemExit), flags.inspect
          expect(JSON.parse(output.string.lines.last)).to include("code" => "usage", "error" => "Give only one of --name, --project, --all, --file and --group."), flags.inspect
        end
        expect(plan_command).not_to have_received(:status)
      end

      it "is refused by the other plan verbs" do
        expect { cli.run(["plan", "show", "--project"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--project does not apply to 'plan show'")
      end

      it "answers not_in_workspace outside a workspace, naming the flags that fix it" do
        allow(detector).to receive(:detect).and_return(nil)

        expect { cli.run(["plan", "status", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(output.string)).to include("code" => "not_in_workspace")
        expect(JSON.parse(output.string)["error"]).to include("--project NAME")
      end
    end

    it "passes path and show on with the workspace" do
      cli.run(["plan", "path", "--json"])
      cli.run(["plan", "show", "--name", "api"])

      expect(plan_command).to have_received(:path).with(name: "detected-ws", json: true)
      expect(plan_command).to have_received(:show).with(name: "api")
    end

    it "initialises a plan and prints the action document under --json" do
      cli.run(["plan", "init", "--title", "Auth", "--from", "/old.md", "--force", "--json", "--name", "api"])

      expect(plan_command).to have_received(:init).with(name: "api", title: "Auth", from: "/old.md", force: true)
      expect(JSON.parse(output.string)).to include("ok" => true, "action" => "plan init", "status" => "ok",
        "results" => [{"workspace" => "api", "outcome" => "created", "reason" => nil, "message" => nil, "path" => "/n/IMPLEMENTATION_PLAN.md"}])
    end

    it "carries the import note into the action row" do
      allow(plan_command).to receive(:init).and_return("path" => "/n/p.md", "message" => "no tasks")

      cli.run(["plan", "init", "--name", "api", "--json"])

      expect(JSON.parse(output.string)["results"].first).to include("message" => "no tasks")
    end

    it "initialises a plan without a document in text mode" do
      cli.run(["plan", "init"])

      expect(plan_command).to have_received(:init).with(name: "detected-ws", title: nil, from: nil, force: false)
      expect(output.string).to eq("")
    end

    it "fails with not_in_workspace outside a workspace, as an envelope under --json" do
      allow(detector).to receive(:detect).and_return(nil)

      expect { cli.run(["plan", "path", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
    end

    it "prints a command's failure as the envelope under --json and on stderr without it" do
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("There is already a plan", code: "plan_exists", details: {"path" => "/p"}))

      expect { cli.run(["plan", "init", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "plan_exists", "details" => {"path" => "/p"})

      expect { cli.run(["plan", "init"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Error: There is already a plan")
    end

    it "shows help" do
      cli.run(["plan", "--help"])

      expect(output.string).to include("workspace plan status").and include("--from FILE")
      expect(plan_command).not_to have_received(:status)
    end

    it "rejects a missing subcommand, an unknown one, and extra arguments as usage errors" do
      [["plan"], ["plan", "bogus"], ["plan", "status", "extra"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
    end

    it "rejects a flag that does not belong to the subcommand" do
      expect { cli.run(["plan", "path", "--all", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("code" => "usage", "error" => a_string_including("--all does not apply to 'plan path'"))
      expect { cli.run(["plan", "show", "--json"]) }.to raise_error(FakeSystemExit)
    end

    it "passes --group to status_group, also in the --group=value form, without looking for a workspace" do
      allow(plan_command).to receive(:status_group)

      cli.run(["plan", "status", "--group", "billing", "--json"])
      cli.run(["plan", "status", "--group=ops"])

      expect(plan_command).to have_received(:status_group).with(group: "billing", json: true)
      expect(plan_command).to have_received(:status_group).with(group: "ops", json: false)
      expect(detector).not_to have_received(:detect)
    end

    it "rejects --group on a subcommand other than status" do
      expect { cli.run(["plan", "path", "--group", "billing"]) }.to raise_error(FakeSystemExit)
    end

    it "rejects more than one of --name, --project, --all, --file and --group" do
      [%w[--name a --all], %w[--project --all], %w[--project --name a], %w[--all --file x], %w[--name a --file x], %w[--group g --all], %w[--group g --name a], %w[--group g --file x]].each do |flags|
        expect { cli.run(["plan", "status", *flags, "--json"]) }.to raise_error(FakeSystemExit), flags.inspect
        expect(JSON.parse(output.string.lines.last)).to include("code" => "usage"), flags.inspect
      end
    end

    it "fails when no plan command was wired" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["plan", "status", "--name", "a"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("plan is not available")
    end
  end

  describe "#run with goal" do
    let(:goal_command) { instance_double(Workspace::Commands::Goal, show: nil, list: nil) }
    let(:detector) { Struct.new(:found) { def detect(_dir) = found }.new(nil) }
    let(:built) { build_test_cli(goal_command: goal_command, project_detector: detector, project_config: CLITestHelpers::FakeProjectConfig.new) }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "shows a ref" do
      cli.run(["goal", "show", "LAB-1", "--json"])

      expect(goal_command).to have_received(:show).with("LAB-1", json: true)
    end

    it "shows the workspace of the working directory when no ref is given" do
      detector.found = "lab-wc-lab-1"

      cli.run(["goal", "show"])

      expect(goal_command).to have_received(:show).with("lab-wc-lab-1", json: false)
    end

    it "fails with not_in_workspace outside a workspace" do
      expect { cli.run(["goal", "show", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
    end

    it "lists, with --all and --json" do
      cli.run(["goal", "list", "--all", "--json"])

      expect(goal_command).to have_received(:list).with(all: true, json: true)
    end

    it "refuses --all on show and an unknown subcommand" do
      expect { cli.run(["goal", "show", "x", "--all"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["goal", "nope"]) }.to raise_error(FakeSystemExit)
    end
  end

  describe "#run with spine" do
    let(:spine_command) { instance_double(Workspace::Commands::Spine, show: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_command: spine_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "answers to journey, another name for spine" do
      cli.run(["journey", "show"])

      expect(spine_command).to have_received(:show).with(name: "detected-ws", json: false, stage: nil, body: false, evaluate: false)
    end

    it "shows the spine of the workspace detected from the working directory" do
      cli.run(["spine", "show"])

      expect(detector).to have_received(:detect).with("/some/dir")
      expect(spine_command).to have_received(:show).with(name: "detected-ws", json: false, stage: nil, body: false, evaluate: false)
    end

    it "takes the workspace as an argument, as --name, or as --name=" do
      cli.run(["spine", "show", "api", "--json"])
      cli.run(["spine", "show", "--json", "--name=api"])
      cli.run(["spine", "show", "--name", "api", "api"])

      expect(spine_command).to have_received(:show).with(name: "api", json: true, stage: nil, body: false, evaluate: false).twice
      expect(spine_command).to have_received(:show).with(name: "api", json: false, stage: nil, body: false, evaluate: false)
    end

    it "passes --evaluate to show, and refuses it with set" do
      cli.run(["spine", "show", "api", "--evaluate", "--json"])

      expect(spine_command).to have_received(:show).with(name: "api", json: true, stage: nil, body: false, evaluate: true)
      expect { cli.run(["spine", "set", "verify", "--status", "completed", "--evaluate"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--evaluate are for")
    end

    it "passes --stage and --body to show, and a lone positional stays the workspace" do
      cli.run(["spine", "show", "api", "--stage", "implement/api", "--body", "--json"])
      cli.run(["spine", "show", "--stage=verify"])

      expect(spine_command).to have_received(:show).with(name: "api", json: true, stage: "implement/api", body: true, evaluate: false)
      expect(spine_command).to have_received(:show).with(name: "detected-ws", json: false, stage: "verify", body: false, evaluate: false)
    end

    it "refuses --stage, --body and --evaluate on spine set" do
      expect { cli.run(["spine", "set", "verify", "--status", "done", "--stage", "x"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("--stage, --body and --evaluate are for 'spine show'")
    end

    it "fails with not_in_workspace outside a workspace" do
      allow(detector).to receive(:detect).and_return(nil)

      expect { cli.run(["spine", "show", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
    end

    it "refuses two different workspaces as a usage error" do
      expect { cli.run(["spine", "show", "api", "--name", "web", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(spine_command).not_to have_received(:show)
    end

    it "prints a command's failure as the envelope under --json" do
      allow(spine_command).to receive(:show).and_raise(Workspace::Error.new("Unknown workspace 'x'.", code: "unknown_workspace", details: {"name" => "x"}))

      expect { cli.run(["spine", "show", "x", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "shows help" do
      cli.run(["spine", "--help"])

      expect(output.string).to include("workspace spine show").and include("--name").and include("--json")
      expect(spine_command).not_to have_received(:show)
    end

    it "rejects a missing subcommand, an unknown one and extra arguments as usage errors" do
      [["spine"], ["spine", "bogus"], ["spine", "show", "a", "b"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
      expect(spine_command).not_to have_received(:show)
    end

    it "says so when no spine command was wired" do
      cli, _, error_output, = build_test_cli

      expect { cli.run(["spine", "show", "api"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("spine is not available")
    end

    describe "set" do
      before { allow(spine_command).to receive(:set) }

      def expect_set(**expected)
        defaults = {note: nil, owner: nil, if_revision: nil, recursive: false, by: nil, json: false}
        expect(spine_command).to have_received(:set).with(**defaults.merge(expected))
      end

      it "takes the workspace and the stage path, with every flag in either form" do
        cli.run(["spine", "set", "api", "implement/api", "--status", "done", "--note", "all green", "--if-revision=9f8e7d6c", "--recursive", "--by=alice", "--json"])

        expect_set(name: "api", path: "implement/api", status: "done", note: "all green", if_revision: "9f8e7d6c", recursive: true, by: "alice", json: true)
      end

      it "takes --flag=value for --status and --note, and flags before the arguments" do
        cli.run(["spine", "set", "--status=blocked", "--note=waiting: on CI", "api", "verify"])

        expect_set(name: "api", path: "verify", status: "blocked", note: "waiting: on CI")
      end

      it "reads one argument as the path of the workspace detected from the working directory" do
        cli.run(["spine", "set", "verify", "--status", "in_progress"])

        expect(detector).to have_received(:detect).with("/some/dir")
        expect_set(name: "detected-ws", path: "verify", status: "in_progress")
      end

      it "reads the one argument as the path when --name is given" do
        cli.run(["spine", "set", "--name=api", "verify", "--status", "done"])

        expect_set(name: "api", path: "verify", status: "done")
      end

      it "passes --owner and a note alone, with no status" do
        cli.run(["spine", "set", "api", "verify", "--owner", "%6"])
        expect_set(name: "api", path: "verify", status: nil, owner: "%6")

        cli.run(["spine", "set", "api", "verify", "--note", "why", "--owner="])
        expect(spine_command).to have_received(:set).with(hash_including(status: nil, note: "why", owner: ""))
      end

      it "needs at least one of --status, --note and --owner, and a path" do
        [["spine", "set", "api", "verify", "--json"], ["spine", "set", "--status", "done", "--json"], ["spine", "set", "--owner", "you", "--json"]].each do |argv|
          expect { cli.run(argv) }.to raise_error(FakeSystemExit), argv.inspect
          expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
        end
        expect(spine_command).not_to have_received(:set)
      end

      it "refuses a third argument" do
        expect { cli.run(["spine", "set", "api", "verify", "extra", "--status", "done", "--json"]) }.to raise_error(FakeSystemExit)

        expect(JSON.parse(output.string)).to include("code" => "usage")
      end

      it "fails with not_in_workspace outside a workspace" do
        allow(detector).to receive(:detect).and_return(nil)

        expect { cli.run(["spine", "set", "verify", "--status", "done", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
      end

      it "prints a refusal as the envelope with its details" do
        allow(spine_command).to receive(:set).and_raise(Workspace::Error.new("changed", code: "stale_revision", details: {"revision" => "abc", "status" => "blocked"}))

        expect { cli.run(["spine", "set", "api", "verify", "--status", "done", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "stale_revision", "details" => {"revision" => "abc", "status" => "blocked"})
      end

      it "lists set in the help" do
        cli.run(["spine", "--help"])

        expect(output.string).to include("workspace spine set").and include("--status").and include("--if-revision").and include("--recursive").and include("--by")
      end
    end
  end

  describe "#run with spine check" do
    let(:spine_command) { instance_double(Workspace::Commands::Spine, check: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_command: spine_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:error_output) { built[2] }

    it "passes the repeated items, the direction and the options to the command" do
      cli.run(["spine", "check", "verify", "--item", "1", "--item=3", "--done"])
      cli.run(["spine", "check", "api", "implement/api", "--item", "2", "--undone", "--if-revision", "abc12345", "--by", "me", "--json"])

      expect(spine_command).to have_received(:check).with(name: "detected-ws", path: "verify", items: [1, 3], done: true, if_revision: nil, by: nil, json: false)
      expect(spine_command).to have_received(:check).with(name: "api", path: "implement/api", items: [2], done: false, if_revision: "abc12345", by: "me", json: true)
    end

    it "refuses a missing item, a missing or doubled direction, a bad number, other verbs' options and a missing path" do
      [%w[check verify --done], %w[check verify --item 1], %w[check verify --item 1 --done --undone], %w[check verify --item 0 --done],
        %w[check verify --item x --done], %w[check verify --item 1 --done --status done], %w[check --item 1 --done],
        %w[set verify --status done --item 1], %w[show --done]].each do |args|
        expect { cli.run(["spine", *args]) }.to raise_error(FakeSystemExit)
      end

      expect(spine_command).not_to have_received(:check)
    end
  end

  describe "#run with spine verify" do
    let(:spine_command) { instance_double(Workspace::Commands::Spine, verify: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_command: spine_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }

    it "passes the verdict, note, label and revision to the workspace detected, named first or named with --name" do
      cli.run(["spine", "verify", "relationships", "--pass", "--note", "all fine"])
      cli.run(["spine", "verify", "api", "verify", "--fail", "--note=item 2 missing", "--by=claude %27", "--if-revision=abc12345", "--json"])
      cli.run(["spine", "--name", "api", "verify", "verify", "--pass", "--note", "ok"])

      expect(spine_command).to have_received(:verify).with(name: "detected-ws", path: "relationships", verdict: "passed", note: "all fine", by: nil, if_revision: nil, json: false)
      expect(spine_command).to have_received(:verify).with(name: "api", path: "verify", verdict: "failed", note: "item 2 missing", by: "claude %27", if_revision: "abc12345", json: true)
      expect(spine_command).to have_received(:verify).with(hash_including(name: "api", path: "verify", verdict: "passed"))
    end

    it "refuses a missing or doubled verdict, a missing note or path, and options of other verbs" do
      [%w[verify verify --note x], %w[verify verify --pass --fail --note x], %w[verify verify --pass], ["verify", "verify", "--pass", "--note", " "],
        %w[verify --pass --note x], %w[verify verify --pass --note x --status done], %w[verify verify --pass --note x --item 1],
        %w[set verify --status done --pass], %w[show --fail], %w[check verify --item 1 --done --pass]].each do |args|
        expect { cli.run(["spine", *args]) }.to raise_error(FakeSystemExit)
      end

      expect(spine_command).not_to have_received(:verify)
    end
  end

  describe "#run with spine goal set" do
    let(:spine_command) { instance_double(Workspace::Commands::Spine, goal_set: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_command: spine_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }

    it "passes the text, the revision and the label to the workspace detected, named first or named with --name" do
      cli.run(["spine", "goal", "set", "Ship it"])
      cli.run(["spine", "goal", "set", "api", "Other goal", "--if-revision", "ab12cd34", "--by", "me", "--json"])
      cli.run(["spine", "--name", "api", "goal", "set", "Third"])

      expect(spine_command).to have_received(:goal_set).with(hash_including(name: "detected-ws", text: "Ship it", if_revision: nil, by: nil))
      expect(spine_command).to have_received(:goal_set).with(name: "api", text: "Other goal", if_revision: "ab12cd34", by: "me", json: true)
      expect(spine_command).to have_received(:goal_set).with(hash_including(name: "api", text: "Third"))
    end

    it "refuses a missing verb, missing text, extra arguments and options of other verbs" do
      [%w[goal], %w[goal get x], %w[goal set], %w[goal set a b c], %w[goal set x --status done], %w[goal set x --item 1]].each do |args|
        expect { cli.run(["spine", *args]) }.to raise_error(FakeSystemExit)
      end
      expect(spine_command).not_to have_received(:goal_set)
    end
  end

  describe "#run with spine start" do
    let(:doc) do
      {"schema_version" => 1, "ok" => true, "workspace" => "api", "path" => "verify", "file" => "40-verify.md", "outcome" => "sent", "reason" => nil,
       "pane" => "%21", "owner" => "%21", "status" => "in_progress", "previous" => "not_started", "revision" => "3e1f0a9b", "play" => nil, "message" => nil}
    end
    let(:spine_start_command) { instance_double(Workspace::Commands::SpineStart, start: doc) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_start_command: spine_start_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "starts the stage of the detected workspace, or of the one named first or with --name" do
      cli.run(["spine", "start", "verify"])
      cli.run(["spine", "start", "api", "verify", "--pane", "%21", "--if-revision", "3e1f0a9b"])
      cli.run(["spine", "--name", "api", "start", "verify", "--spawn", "codex", "--play", "research"])

      expect(spine_start_command).to have_received(:start).with(hash_including(name: "detected-ws", path: "verify", pane: nil, spawn: nil, play: nil, if_revision: nil))
      expect(spine_start_command).to have_received(:start).with(hash_including(name: "api", path: "verify", pane: "%21", if_revision: "3e1f0a9b"))
      expect(spine_start_command).to have_received(:start).with(hash_including(name: "api", path: "verify", spawn: "codex", play: "research"))
    end

    it "prints the command's document with --json" do
      cli.run(["spine", "start", "verify", "--json"])

      expect(JSON.parse(output.string)).to eq(doc)
    end

    it "exits 1 on a failed outcome, with the document under --json and the message on stderr without it" do
      allow(spine_start_command).to receive(:start).and_return(doc.merge("ok" => false, "outcome" => "failed", "message" => "not submitted"))

      expect { cli.run(["spine", "start", "verify", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("outcome" => "failed")
      expect { cli.run(["spine", "start", "verify"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("could not start stage verify of detected-ws: not submitted")
    end

    it "refuses options of show and set, both --pane and --spawn, an unknown agent kind, and a missing path" do
      [%w[start verify --status done], %w[start verify --stage x], %w[start verify --pane %1 --spawn claude],
        %w[start verify --spawn vim], %w[start], %w[set verify --status done --pane %1], %w[show --play research]].each do |args|
        expect { cli.run(["spine", *args, "--json"]) }.to raise_error(FakeSystemExit)
      end
      expect(output.string.lines.map { |line| JSON.parse(line)["code"] }.uniq).to eq(["usage"])
      expect(spine_start_command).not_to have_received(:start)
    end

    it "prints a refusal as the error envelope" do
      allow(spine_start_command).to receive(:start).and_raise(Workspace::Error.new("waits", code: "stage_waiting", details: {"waits_on" => ["research"]}))

      expect { cli.run(["spine", "start", "verify", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "stage_waiting", "details" => {"waits_on" => ["research"]})
    end

    it "lists start in the help" do
      cli.run(["spine", "--help"])

      expect(output.string).to include("workspace spine start").and include("--spawn").and include("--play").and include("--fan-out").and include("--max")
    end

    describe "--fan-out" do
      let(:fan_doc) do
        {"schema_version" => 1, "ok" => true, "workspace" => "api", "path" => "implement", "agent" => "claude", "max" => 3,
         "results" => [{"path" => "implement/a", "result" => "spawned", "pane" => "%31", "code" => nil, "message" => nil}],
         "spawned" => 1, "refused" => 0, "skipped" => 0}
      end

      before { allow(spine_start_command).to receive(:fan_out).and_return(fan_doc) }

      it "fans out with the default cap and the kind left to the command" do
        cli.run(["spine", "start", "implement", "--fan-out", "--json"])

        expect(spine_start_command).to have_received(:fan_out).with(name: "detected-ws", path: "implement", spawn: nil, max: 3)
        expect(JSON.parse(output.string)).to eq(fan_doc)
        expect(spine_start_command).not_to have_received(:start)
      end

      it "takes --max N, --max=N and --spawn" do
        cli.run(["spine", "start", "api", "implement", "--fan-out", "--max", "2", "--spawn", "codex"])
        cli.run(["spine", "start", "api", "implement", "--fan-out", "--max=5"])

        expect(spine_start_command).to have_received(:fan_out).with(name: "api", path: "implement", spawn: "codex", max: 2)
        expect(spine_start_command).to have_received(:fan_out).with(name: "api", path: "implement", spawn: nil, max: 5)
      end

      it "exits 1 when nothing was spawned and something was refused, keeping the document" do
        allow(spine_start_command).to receive(:fan_out).and_return(fan_doc.merge("ok" => false, "spawned" => 0, "refused" => 1))

        expect { cli.run(["spine", "start", "implement", "--fan-out", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "refused" => 1)
      end

      it "names the refusal codes on stderr without --json" do
        refused = fan_doc.merge("ok" => false, "spawned" => 0, "refused" => 1,
          "results" => [{"path" => "implement/a", "result" => "refused", "pane" => nil, "code" => "stage_waiting", "message" => "x"}])
        allow(spine_start_command).to receive(:fan_out).and_return(refused)

        expect { cli.run(["spine", "start", "implement", "--fan-out"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("nothing was spawned", "stage_waiting")
      end

      it "prints a whole refusal as the error envelope" do
        allow(spine_start_command).to receive(:fan_out).and_raise(Workspace::Error.new("none", code: "no_substages", details: {"path" => "implement"}))

        expect { cli.run(["spine", "start", "implement", "--fan-out", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "no_substages")
      end

      it "refuses --pane, --if-revision, --play, a --max below 1, and --max without --fan-out" do
        [%w[--fan-out --pane %1], %w[--fan-out --if-revision abc], %w[--fan-out --play research], %w[--fan-out --max 0], %w[--max 2]].each do |extra|
          expect { cli.run(["spine", "start", "implement", *extra, "--json"]) }.to raise_error(FakeSystemExit)
        end
        expect(output.string.lines.map { |line| JSON.parse(line)["code"] }.uniq).to eq(["usage"])
        expect(spine_start_command).not_to have_received(:fan_out)
      end
    end
  end

  describe "#run with spine init" do
    let(:spine_init_command) { instance_double(Workspace::Commands::SpineInit, call: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(spine_init_command: spine_init_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "inits the workspace detected from the working directory with the defaults" do
      cli.run(["spine", "init"])

      expect(spine_init_command).to have_received(:call).with(name: "detected-ws", template: nil, dry_run: false, json: false)
    end

    it "takes the workspace, --template and --dry-run in either form" do
      cli.run(["spine", "init", "api", "--template", "team", "--dry-run", "--json"])
      cli.run(["spine", "init", "--name=web", "--template=docs", "--json"])

      expect(spine_init_command).to have_received(:call).with(name: "api", template: "team", dry_run: true, json: true)
      expect(spine_init_command).to have_received(:call).with(name: "web", template: "docs", dry_run: false, json: true)
    end

    it "accepts options before the verb" do
      cli.run(["spine", "--name", "api", "init", "--dry-run"])
      cli.run(["spine", "--json", "init", "--template=team"])
      cli.run(["spine", "--name=web", "--json", "init"])
      cli.run(["spine", "--template", "docs", "init", "api"])
      expect(spine_init_command).to have_received(:call).with(name: "api", template: "docs", dry_run: false, json: false)

      expect(spine_init_command).to have_received(:call).with(name: "api", template: nil, dry_run: true, json: false)
      expect(spine_init_command).to have_received(:call).with(name: "detected-ws", template: "team", dry_run: false, json: true)
      expect(spine_init_command).to have_received(:call).with(name: "web", template: nil, dry_run: false, json: true)
    end

    it "fails with not_in_workspace outside a workspace, and refuses two different names" do
      allow(detector).to receive(:detect).and_return(nil)
      expect { cli.run(["spine", "init", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")

      output.truncate(0)
      output.rewind
      expect { cli.run(["spine", "init", "a", "--name", "b", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(spine_init_command).not_to have_received(:call)
    end

    it "prints a refusal from the command as the envelope" do
      allow(spine_init_command).to receive(:call).and_raise(Workspace::Error.new("No template.", code: "unknown_template", details: {"template" => "x"}))

      expect { cli.run(["spine", "init", "api", "--template", "x", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_template", "details" => {"template" => "x"})
    end

    it "shows its own help and rejects extra arguments" do
      cli.run(["spine", "init", "--help"])
      expect(output.string).to include("workspace spine init").and include("--template").and include("--dry-run")

      expect { cli.run(["spine", "init", "a", "b", "--json"]) }.to raise_error(FakeSystemExit)
      expect(spine_init_command).not_to have_received(:call)
    end
  end
end
