require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"

# Adversarial coverage for the `finish` / `kill` / `prune` unsaved-work work
# (commits b5d213d, f730b3e, 264e9d0). Each `it` pins one confirmed defect,
# tagged with an ID (FU1, FU2, ...).
RSpec.describe "T4 finish/kill/prune adversarial findings" do
  def git(*args, chdir:)
    stdout, stderr, status = Open3.capture3("git", "-C", chdir, *args)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?
    stdout
  end

  def build_remote_and_clone(root)
    root = File.realpath(root)
    remote = File.join(root, "remote.git")
    work = File.join(root, "work")
    Open3.capture3("git", "init", "--bare", "-q", remote)
    Open3.capture3("git", "clone", "-q", remote, work)
    git("config", "user.email", "a@a.com", chdir: work)
    git("config", "user.name", "a", chdir: work)
    File.write(File.join(work, "f"), "hi")
    git("add", "f", chdir: work)
    git("commit", "-q", "-m", "init", chdir: work)
    git("push", "-q", "origin", "HEAD:main", chdir: work)
    [remote, work]
  end

  # Real `finish`/`kill` targets are linked worktrees (created via
  # `git worktree add`), not the primary checkout — mirror that here.
  def add_linked_worktree(work, branch)
    wt_path = File.join(File.dirname(work), "wt-#{branch.tr("/", "-")}")
    git("worktree", "add", "-q", "-b", branch, wt_path, chdir: work)
    git("push", "-q", "-u", "origin", branch, chdir: wt_path)
    wt_path
  end

  # --- FU1: detached-HEAD "no upstream" message suggests a broken fix -----
  describe "Commands::Finish on a detached-HEAD worktree (FU1)" do
    it "does not tell the user to run 'push -u origin HEAD'" do
      Dir.mktmpdir("ws-fu1") do |root|
        _remote, work = build_remote_and_clone(root)
        wt_path = add_linked_worktree(work, "feature/detached")
        git("checkout", "-q", "--detach", chdir: wt_path)

        real_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new)
        project_config = double("project_config")
        kill_command = double("kill_command")
        config_path = File.join(root, "workspace.myproject.yml")
        File.write(config_path, YAML.dump("root" => wt_path))
        allow(project_config).to receive(:config_path_for).with("myproject").and_return(config_path)

        finish = Workspace::Commands::Finish.new(
          git: real_git,
          project_config: project_config,
          kill_command: kill_command,
          project_detector: Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config),
          output: StringIO.new,
          error_output: StringIO.new,
          input: StringIO.new
        )

        expect(real_git.worktree_exists?(wt_path)).to eq(true)

        message = begin
          finish.call("myproject")
          nil
        rescue Workspace::Error => e
          e.message
        end

        expect(message).not_to be_nil
        # FU1: `git push -u origin HEAD` does not, and cannot, fix a detached
        # HEAD's missing upstream — HEAD is not a branch name. The message
        # should tell the user to check out a branch first, not hand them a
        # command that will push to a remote branch literally called "HEAD".
        expect(message).not_to include("push -u origin HEAD"),
          "expected a message that doesn't suggest the nonsensical " \
          "'git push -u origin HEAD' for a detached HEAD, got: #{message.inspect}"
      end
    end
  end

  # --- FU2: `finish --json` lets Kill's plain-text output leak onto stdout -
  describe "Commands::Finish#call with json: true, success path (FU2)" do
    it "writes only the single JSON line to stdout" do
      Dir.mktmpdir("ws-fu2") do |root|
        _remote, work = build_remote_and_clone(root)
        wt_path = add_linked_worktree(work, "feature/fu2")

        shared_output = StringIO.new
        real_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new)

        config_path = File.join(root, "workspace.myproject.yml")
        File.write(config_path, YAML.dump("root" => wt_path))
        project_config = double("project_config")
        allow(project_config).to receive(:config_path_for).with("myproject").and_return(config_path)
        allow(project_config).to receive(:remove).with("myproject")

        project_settings = double("project_settings")
        allow(project_settings).to receive(:remove).with("myproject")

        stop_command = double("stop_command")
        allow(stop_command).to receive(:call).with(["myproject"], quiet: true)

        state = CLITestHelpers::FakeState.new
        project_detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)

        kill_command = Workspace::Commands::Kill.new(
          git: real_git,
          project_config: project_config,
          project_settings: project_settings,
          stop_command: stop_command,
          project_detector: project_detector,
          output: shared_output,
          input: StringIO.new
        )

        finish = Workspace::Commands::Finish.new(
          git: real_git,
          project_config: project_config,
          kill_command: kill_command,
          project_detector: project_detector,
          output: shared_output,
          error_output: StringIO.new,
          input: StringIO.new
        )

        finish.call("myproject", json: true)

        lines = shared_output.string.lines
        # FU2: Finish shares its `output:` stream with the injected Kill
        # command (see Workspace.build_cli), and Kill unconditionally prints
        # "Stopping...", "Removing worktree...", "Stopped..." regardless of
        # force. In --json mode that plain text lands on the same stdout as
        # the documented JSON line, corrupting it for any machine reader.
        expect(lines.size).to eq(1),
          "expected exactly one JSON line on stdout for --json, got #{lines.size}: #{shared_output.string.inspect}"
        expect { JSON.parse(lines.first) }.not_to raise_error
      end
    end
  end

  # --- FU3: a worktree-removal failure aborts the rest of `prune` ---------
  describe "Commands::Prune#call when one candidate's worktree removal fails (FU3)" do
    it "still processes and reports the remaining candidates before raising" do
      git_double = double("git")
      allow(git_double).to receive(:worktree_exists?).with("/path/a").and_return(true)
      allow(git_double).to receive(:worktree_exists?).with("/path/b").and_return(true)
      # force: true skips the unsaved-work check, straight to removal.
      allow(git_double).to receive(:remove_worktree).with("/path/a", force: true)
        .and_raise(Workspace::Error, "Error removing worktree: cannot remove a locked working tree")
      allow(git_double).to receive(:remove_worktree).with("/path/b", force: true)

      project_config = double("project_config")
      allow(project_config).to receive(:available_projects).and_return(["proj-a", "proj-b"])
      allow(project_config).to receive(:project_root_for).with("proj-a").and_return("/path/a")
      allow(project_config).to receive(:project_root_for).with("proj-b").and_return("/path/b")
      allow(project_config).to receive(:remove)

      project_settings = double("project_settings")
      allow(project_settings).to receive(:remove)

      state = CLITestHelpers::FakeState.new
      output = StringIO.new

      prune = Workspace::Commands::Prune.new(
        state: state,
        project_config: project_config,
        project_settings: project_settings,
        git: git_double,
        stop_command: double("stop_command"),
        output: output,
        input: StringIO.new
      )

      candidates = [
        {project: "proj-a", worktree_path: "/path/a", branch: "a", pr_number: 1, pr_url: "u", pr_state: "MERGED"},
        {project: "proj-b", worktree_path: "/path/b", branch: "b", pr_number: 2, pr_url: "u", pr_state: "MERGED"}
      ]
      allow(prune).to receive(:detect_candidates).and_return(candidates)

      # FU3: Prune#remove_candidate rescues Workspace::Error from
      # Git#remove_worktree, so a single stuck/locked worktree doesn't abort
      # the whole `prune` run — proj-b still gets processed and @state.save
      # still runs. Since something was skipped, `call` raises afterwards
      # so the CLI exits nonzero.
      expect { prune.call(force: true) }.to raise_error(Workspace::Error, /proj-a/)
      expect(output.string).to include("Skipped proj-a")
    end
  end
end
