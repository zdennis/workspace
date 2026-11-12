require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Names do
  # Lists the workspaces with a config and their roots; a name matches only as spelled.
  let(:config_class) do
    Class.new do
      def initialize(roots)
        @roots = roots
      end

      def available_projects = @roots.keys

      def existing_name(name) = @roots.key?(name) ? name : nil

      def project_root_for(name) = @roots[name]
    end
  end

  # Finds the workspace of one directory.
  let(:detector_class) do
    Class.new do
      def initialize(found = {})
        @found = found
      end

      def detect(dir) = @found[dir]
    end
  end

  let(:err) { StringIO.new }
  let(:project_config) { config_class.new("app" => "/src/app", "app.worktree-fix" => "/src/app/.worktrees/fix", "web.worktree-fix" => "/src/web/.worktrees/fix", "api.worktree-docs" => "/src/api/.worktrees/docs") }
  let(:detector) { detector_class.new }
  let(:lineage) { CLITestHelpers::FakeLineage.new }

  def invocation(help_asked: false, quiet: false)
    Workspace::CLI::Invocation.new(output: StringIO.new, error_output: err, exit_handler: FakeExitHandler, help_asked: help_asked, quiet: quiet, env: {})
  end

  def names(workspace_name: Workspace::WorkspaceName.new(project_config: project_config), working_dir: "/src/elsewhere")
    described_class.new(project_config: project_config, project_detector: detector, lineage: lineage, working_dir: working_dir, workspace_name: workspace_name)
  end

  describe "#given_name" do
    it "settles a worktree suffix to its workspace and says so on the invocation's error output" do
      expect(names.given_name(invocation, "docs")).to eq("api.worktree-docs")
      expect(err.string).to eq("Workspace 'docs' is api.worktree-docs.\n")
    end

    it "prints nothing under --json" do
      expect(names.given_name(invocation(quiet: true), "docs")).to eq("api.worktree-docs")
      expect(err.string).to eq("")
    end

    it "matches only the exact name while help is asked for, so an ambiguous suffix does not fail" do
      expect(names.given_name(invocation(help_asked: true), "fix")).to be_nil
      expect { names.given_name(invocation, "fix") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ambiguous_workspace") }
    end

    it "asks the project config when built with no WorkspaceName" do
      expect(names(workspace_name: nil).given_name(invocation, "docs")).to be_nil
      expect(names(workspace_name: nil).given_name(invocation, "app")).to eq("app")
    end
  end

  describe "#settle_name and #take_known_workspace!" do
    it "settles a known name, keeps an unknown one as given, and takes a known first positional only" do
      expect(names.settle_name(invocation, "docs")).to eq("api.worktree-docs")
      expect(names.settle_name(invocation, "new-one")).to eq("new-one")
      expect(names(workspace_name: nil).settle_name(invocation, "docs")).to eq("docs")

      args = ["app", "KEY"]
      expect(names.take_known_workspace!(invocation, args)).to eq("app")
      expect(args).to eq(["KEY"])
      expect(names.take_known_workspace!(invocation, args)).to be_nil
      expect(args).to eq(["KEY"])
    end
  end

  describe "#pick_workspace_name and #single_workspace_arg" do
    it "takes --name or the positional, and refuses both when they differ" do
      expect(names.pick_workspace_name(invocation, nil, "docs")).to eq("api.worktree-docs")
      expect(names.pick_workspace_name(invocation, "app", "app")).to eq("app")
      expect { names.pick_workspace_name(invocation, "app", "docs") }
        .to raise_error(Workspace::UsageError, "Give the workspace once: 'api.worktree-docs' and --name app differ.")
    end

    it "refuses more than one positional" do
      expect { names.single_workspace_arg(invocation, ["a", "b"], nil, "kill") }
        .to raise_error(Workspace::UsageError, "workspace kill takes one workspace; got: a b. Run 'workspace kill --help'.")
      expect(names.single_workspace_arg(invocation, [], "app", "kill")).to eq("app")
    end
  end

  describe "#require_known_workspace!" do
    it "refuses a name with no config as unknown_workspace" do
      expect { names.require_known_workspace!("app") }.not_to raise_error
      expect { names.require_known_workspace!("gone") }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["unknown_workspace", {"name" => "gone"}]) }
    end
  end

  describe "#working_dir_for and #dev_working_dir" do
    it "answers the named workspace's root, else the working directory" do
      expect(names.working_dir_for("app")).to eq("/src/app")
      expect(names.working_dir_for(nil)).to eq("/src/elsewhere")
      expect { names.working_dir_for("gone") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    end

    it "refuses dev outside any workspace as not_in_workspace, and answers the directory inside one" do
      expect { names.dev_working_dir(nil) }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["not_in_workspace", {"path" => "/src/elsewhere"}]) }
      expect(names.dev_working_dir("app")).to eq("/src/app")

      inside = detector_class.new("/src/app" => "app")
      named = described_class.new(project_config: project_config, project_detector: inside, lineage: lineage, working_dir: "/src/app")
      expect(named.dev_working_dir(nil)).to eq("/src/app")
    end
  end

  describe "#workspace_here and #current_workspace!" do
    it "answers the detector's workspace, else a configured main checkout of the same name" do
      detected = described_class.new(project_config: project_config, project_detector: detector_class.new("/x" => "app"), lineage: lineage, working_dir: "/x")
      expect(detected.workspace_here).to eq("app")

      checkout = described_class.new(project_config: project_config, project_detector: detector, lineage: CLITestHelpers::FakeLineage.new("app"), working_dir: "/src/app")
      expect(checkout.workspace_here).to eq("app")

      worktree = described_class.new(project_config: project_config, project_detector: detector, lineage: CLITestHelpers::FakeLineage.new("app", is_worktree: true), working_dir: "/src/app")
      expect(worktree.workspace_here).to be_nil
    end

    it "answers the name given, else the workspace here, else refuses as not_in_workspace" do
      expect(names.current_workspace!("app")).to eq("app")
      expect { names.current_workspace!(nil) }.to raise_error(Workspace::Error, /No workspace found for \/src\/elsewhere/) { |e| expect(e.code).to eq("not_in_workspace") }
    end
  end
end
