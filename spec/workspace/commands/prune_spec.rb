require "tmpdir"

RSpec.describe Workspace::Commands::Prune do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:event_log_file) { File.join(tmpdir, "events.jsonl") }
  let(:state) do
    allow(config).to receive(:state_file).and_return(state_file)
    allow(config).to receive(:event_log_file).and_return(event_log_file)
    event_log = Workspace::EventLog.new(config: config)
    Workspace::State.new(config: config, event_log: event_log)
  end
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { instance_double(Workspace::Git) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  let(:kill_command) { instance_double(Workspace::Commands::Kill) }

  subject(:command) do
    described_class.new(
      state: state,
      project_config: project_config,
      project_settings: project_settings,
      git: git,
      kill_command: kill_command,
      output: output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  # Helpers to create a fake worktree directory
  def make_worktree_dir(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, ".git"), "gitdir: /some/repo/.git/worktrees/#{File.basename(path)}\n")
  end

  describe "#call" do
    context "when there are no available projects and state is empty" do
      before do
        allow(project_config).to receive(:available_projects).and_return([])
      end

      it "prints no candidates message and returns empty array" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "when project root is nil (no config root)" do
      before do
        allow(project_config).to receive(:available_projects).and_return(["myproject"])
        allow(project_config).to receive(:project_root_for).with("myproject").and_return(nil)
      end

      it "skips the project and returns empty array" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "when project root is configured but the directory no longer exists" do
      let(:project_root) { File.join(tmpdir, "gone-dir") }

      before do
        allow(project_config).to receive(:available_projects).and_return(["gone-dir"])
        allow(project_config).to receive(:project_root_for).with("gone-dir").and_return(project_root)
        # directory is NOT created — it's gone

        input.string = "y\n"
        input.rewind
      end

      it "marks the project eligible and includes it in the candidates" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("gone-dir")
        allow(project_settings).to receive(:remove).with("gone-dir")

        result = command.call
        expect(result).to include("gone-dir")
        expect(output.string).to include("eligible (directory gone)")
        expect(output.string).to include("(directory gone)")
        expect(output.string).to include("Pruned 1 project(s).")
      end

      it "does not call remove_worktree since the directory is already gone" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("gone-dir")
        allow(project_settings).to receive(:remove).with("gone-dir")
        expect(git).not_to receive(:remove_worktree)

        command.call
      end
    end

    context "when project root exists but is not a linked worktree" do
      let(:project_root) { File.join(tmpdir, "mainrepo") }

      before do
        FileUtils.mkdir_p(project_root)
        # .git is a directory (main worktree), not a file
        FileUtils.mkdir_p(File.join(project_root, ".git"))

        allow(project_config).to receive(:available_projects).and_return(["mainrepo"])
        allow(project_config).to receive(:project_root_for).with("mainrepo").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(false)
      end

      it "skips the project and returns empty array" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "when project is a linked worktree with no associated PR" do
      let(:project_root) { File.join(tmpdir, "wt-no-pr") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-no-pr"])
        allow(project_config).to receive(:project_root_for).with("wt-no-pr").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/no-pr")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/no-pr", project_root).and_return(nil)
      end

      it "skips the project" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "when project is a linked worktree with an OPEN PR" do
      let(:project_root) { File.join(tmpdir, "wt-open") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-open"])
        allow(project_config).to receive(:project_root_for).with("wt-open").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/open")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/open", project_root).and_return({number: 42, url: "https://github.com/org/repo/pull/42", state: "OPEN"})
      end

      it "skips the project" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "when project is a linked worktree with a CLOSED PR" do
      let(:project_root) { File.join(tmpdir, "wt-closed") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-closed"])
        allow(project_config).to receive(:project_root_for).with("wt-closed").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/closed")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/closed", project_root).and_return({number: 10, url: "https://github.com/org/repo/pull/10", state: "CLOSED"})
      end

      it "includes the project as a candidate" do
        input.string = "y\n"
        input.rewind
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-closed")
        allow(project_settings).to receive(:remove).with("wt-closed")

        result = command.call
        expect(result).to include("wt-closed")
        expect(output.string).to include("wt-closed")
        expect(output.string).to include("CLOSED")
      end
    end

    context "when project is a linked worktree with a MERGED PR" do
      let(:project_root) { File.join(tmpdir, "wt-merged") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-merged"])
        allow(project_config).to receive(:project_root_for).with("wt-merged").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/merged")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/merged", project_root).and_return({number: 20, url: "https://github.com/org/repo/pull/20", state: "MERGED"})
      end

      it "includes the project as a candidate" do
        input.string = "y\n"
        input.rewind
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-merged")
        allow(project_settings).to receive(:remove).with("wt-merged")

        result = command.call
        expect(result).to include("wt-merged")
        expect(output.string).to include("wt-merged")
        expect(output.string).to include("MERGED")
      end
    end

    context "with --dry-run" do
      let(:project_root) { File.join(tmpdir, "wt-dry") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-dry"])
        allow(project_config).to receive(:project_root_for).with("wt-dry").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/dry")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/dry", project_root).and_return({number: 5, url: "https://github.com/org/repo/pull/5", state: "MERGED"})
      end

      it "prints the table and dry-run notice without removing anything" do
        result = command.call(dry_run: true)

        expect(result).to eq(["wt-dry"])
        expect(output.string).to include("wt-dry")
        expect(output.string).to include("(dry run — no changes made)")
        expect(output.string).not_to include("Pruned")
      end

      it "does not call remove methods" do
        expect(git).not_to receive(:remove_worktree)
        expect(project_config).not_to receive(:remove)
        expect(project_settings).not_to receive(:remove)

        command.call(dry_run: true)
      end
    end

    context "without flags, when user confirms with 'y'" do
      let(:project_root) { File.join(tmpdir, "wt-confirm") }

      before do
        state["wt-confirm"] = {"iterm_window_id" => 1}
        state.save

        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-confirm"])
        allow(project_config).to receive(:project_root_for).with("wt-confirm").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/confirm")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/confirm", project_root).and_return({number: 7, url: "https://github.com/org/repo/pull/7", state: "CLOSED"})

        input.string = "y\n"
        input.rewind
      end

      it "kills the live session, removes worktree, config, settings, and state entry" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(true)
        expect(kill_command).to receive(:call).with(["wt-confirm"])
        expect(git).to receive(:remove_worktree).with(project_root, force: true)
        expect(project_config).to receive(:remove).with("wt-confirm")
        expect(project_settings).to receive(:remove).with("wt-confirm")

        result = command.call
        expect(result).to eq(["wt-confirm"])
        expect(output.string).to include("Pruned 1 project(s).")

        state.load
        expect(state["wt-confirm"]).to be_nil
      end
    end

    context "when project has a closed PR but no active session in state" do
      let(:project_root) { File.join(tmpdir, "wt-nosession") }

      before do
        # project is in available_projects but NOT in state (never launched)
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-nosession"])
        allow(project_config).to receive(:project_root_for).with("wt-nosession").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/nosession")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/nosession", project_root).and_return({number: 99, url: "https://github.com/org/repo/pull/99", state: "MERGED"})

        input.string = "y\n"
        input.rewind
      end

      it "does not call kill_command when project has no active session" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-nosession")
        allow(project_settings).to receive(:remove).with("wt-nosession")
        expect(kill_command).not_to receive(:call)

        result = command.call
        expect(result).to eq(["wt-nosession"])
      end
    end

    context "without flags, when user enters 'n'" do
      let(:project_root) { File.join(tmpdir, "wt-cancel") }

      before do
        state["wt-cancel"] = {"iterm_window_id" => 2}
        state.save

        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-cancel"])
        allow(project_config).to receive(:project_root_for).with("wt-cancel").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/cancel")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/cancel", project_root).and_return({number: 8, url: "https://github.com/org/repo/pull/8", state: "CLOSED"})

        input.string = "n\n"
        input.rewind
      end

      it "prints Cancelled and leaves state unchanged" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("Cancelled.")

        state.load
        expect(state["wt-cancel"]).not_to be_nil
      end
    end

    context "with --force" do
      let(:project_root) { File.join(tmpdir, "wt-force") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-force"])
        allow(project_config).to receive(:project_root_for).with("wt-force").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/force")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/force", project_root).and_return({number: 9, url: "https://github.com/org/repo/pull/9", state: "MERGED"})
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-force")
        allow(project_settings).to receive(:remove).with("wt-force")
      end

      it "removes without prompting" do
        result = command.call(force: true)

        expect(result).to eq(["wt-force"])
        expect(output.string).to include("Pruned 1 project(s).")
        expect(output.string).not_to include("[y/N]")
      end
    end

    context "when gh is unavailable" do
      let(:project_root) { File.join(tmpdir, "wt-nogh") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-nogh"])
        allow(project_config).to receive(:project_root_for).with("wt-nogh").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/nogh")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(false)
      end

      it "emits a warning and skips all projects" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("Warning:")
        expect(output.string).to include("`gh` is not authenticated")
        expect(output.string).to include("No projects eligible for pruning found.")
      end
    end

    context "with a state-only entry (no tmuxinator config) that has a closed PR" do
      let(:project_root) { File.join(tmpdir, "wt-state-only") }

      before do
        state["wt-state-only"] = {"iterm_window_id" => 3}
        state.save

        make_worktree_dir(project_root)
        # available_projects returns nothing — project only in state
        allow(project_config).to receive(:available_projects).and_return([])
        allow(project_config).to receive(:project_root_for).with("wt-state-only").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/state-only")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/state-only", project_root).and_return({number: 11, url: "https://github.com/org/repo/pull/11", state: "CLOSED"})

        input.string = "y\n"
        input.rewind
      end

      it "includes the project as a candidate, kills the session, and removes it" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-state-only")
        allow(project_settings).to receive(:remove).with("wt-state-only")
        expect(kill_command).to receive(:call).with(["wt-state-only"])

        result = command.call
        expect(result).to include("wt-state-only")
        expect(output.string).to include("Pruned 1 project(s).")
      end
    end

    context "with a config-only project (not in state) that has a closed PR" do
      let(:project_root) { File.join(tmpdir, "wt-config-only") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-config-only"])
        allow(project_config).to receive(:project_root_for).with("wt-config-only").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/config-only")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/config-only", project_root).and_return({number: 12, url: "https://github.com/org/repo/pull/12", state: "CLOSED"})

        input.string = "y\n"
        input.rewind
      end

      it "includes the project and removes it" do
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-config-only")
        allow(project_settings).to receive(:remove).with("wt-config-only")

        result = command.call
        expect(result).to include("wt-config-only")
      end
    end

    context "when the worktree path is already gone during remove_candidate" do
      let(:project_root) { File.join(tmpdir, "wt-gone") }

      before do
        make_worktree_dir(project_root)
        allow(project_config).to receive(:available_projects).and_return(["wt-gone"])
        allow(project_config).to receive(:project_root_for).with("wt-gone").and_return(project_root)
        allow(git).to receive(:linked_worktree?).with(project_root).and_return(true)
        allow(git).to receive(:worktree_branch).with(project_root).and_return("feature/gone")
        allow_any_instance_of(described_class).to receive(:gh_usable?).and_return(true)
        allow_any_instance_of(described_class).to receive(:pr_status).with("feature/gone", project_root).and_return({number: 13, url: "https://github.com/org/repo/pull/13", state: "MERGED"})
        allow(git).to receive(:worktree_exists?).with(project_root).and_return(false)
        allow(project_config).to receive(:remove).with("wt-gone")
        allow(project_settings).to receive(:remove).with("wt-gone")

        input.string = "y\n"
        input.rewind
      end

      it "does not call remove_worktree when worktree path is already gone" do
        expect(git).not_to receive(:remove_worktree)

        result = command.call
        expect(result).to eq(["wt-gone"])
      end
    end
  end
end
