require "spec_helper"
require "tmpdir"
require "open3"
require "fileutils"
require "json"

# `workspace rename` through the real build_cli, real git, the real templates and a throwaway HOME.
RSpec.describe "workspace rename, end to end" do
  let(:home) { File.realpath(Dir.mktmpdir("ws-rename-e2e", "/tmp")) }
  let(:repo) { File.join(home, "src", "api") }
  let(:linked) { File.join(repo, ".worktrees", "feat-a") }
  let(:moved) { File.join(repo, ".worktrees", "feat-b") }
  let(:old) { "api.worktree-feat-a" }
  let(:new) { "api.worktree-feat-b" }
  let(:old_session) { "api-wt-feat-a" }
  let(:config) { Workspace::Config.new }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:project_settings) { Workspace::ProjectSettings.new(config: config) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:exits) { [] }

  around do |example|
    saved = ENV.to_h
    ENV["HOME"] = home
    ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
    ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
    ENV.delete("TMUX")
    ENV.delete("TMUX_PANE")
    example.run
  ensure
    ENV.replace(saved)
    FileUtils.remove_entry(home)
  end

  def sh(*args, dir: repo)
    output, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", *args)
    raise output unless status.success?
    output
  end

  def stopped_tmux
    Class.new(Workspace::Tmux) { def session_exists?(*, **) = false }.new(config: config, logger: Workspace::Logger.new)
  end

  def cli
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    handler = Class.new { def exit(code = 0) = raise(SystemExit.new(code)) }.new
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, exit_handler: handler, tmux: stopped_tmux)
  end

  # Runs the CLI; returns the exit status (0 when it does not exit).
  def run_cli(*args)
    cli.run(args)
    0
  rescue SystemExit => e
    e.status
  end

  def inbox(name) = Workspace::InboxStore.new(path: config.inbox_path("workspace", name), error_output: StringIO.new)

  def tasks = Workspace::TaskStore.new(dir: config.task_dir, error_output: StringIO.new)

  before do
    FileUtils.mkdir_p(repo)
    FileUtils.mkdir_p(config.run_dir)
    sh("init", "-q", "-b", "main")
    sh("commit", "-q", "--allow-empty", "-m", "start")
    sh("worktree", "add", "-q", "-b", "feat/a", linked)
    FileUtils.mkdir_p(config.tmuxinator_dir)
    FileUtils.cp(Dir.glob(File.join(config.templates_dir, "*.yml")), config.tmuxinator_dir)
    project_config = Workspace::ProjectConfig.new(config: config, git: git, output: StringIO.new)
    project_config.create("api", repo)
    expect(project_config.create_worktree("api", "feat-a", linked, "feat/a", quiet: true)).to eq(old)
    File.write(File.join(linked, ".workspace-project"), old)
    notes = File.join(repo, "tmp", "workspace-notes", "feat-a")
    FileUtils.mkdir_p(notes)
    File.write(File.join(notes, "note.md"), "mine")
    project_settings.save(old, {"notes" => {"dir" => notes}})
    FileUtils.mkdir_p(config.pipeline_state_dir(old))
    File.write(config.ask_state_path(old), "[]")
    state = Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config, error_output: StringIO.new))
    state.load
    state[old] = {"unique_id" => "u"}
    state.save
    tasks.start(workspace: old, branch: "feat/a", path: linked)
    inbox(old).add({"kind" => "note", "title" => "t", "scope" => {"kind" => "workspace", "key" => old, "name" => old}})
  end

  # Files under the temp HOME that still name the old workspace, minus the logs a rename leaves as history,
  # git's own files (its worktree id stays when a worktree moves) and empty lock files, which are never removed.
  def stale_files
    history = [/\.workspace-events\.jsonl\z/, /locks\.jsonl\z/, %r{/\.workflows/(archive|evidence)/}, %r{/\.tasks/archive/}, %r{/\.workspace-runs/},
      /ledger\.jsonl\z/, /\.workspace-state\.json\.bak\z/, %r{/\.git(/|\z)}, /\.lock\z/]
    Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.reject { |path| history.any? { |re| path.match?(re) } }
      .select { |path| [old, old_session, "feat-a"].any? { |needle| path.include?(needle) || File.binread(path).include?(needle) } }
  end

  def expect_renamed
    expect(sh("worktree", "list")).to include(moved)
    expect(sh("worktree", "list")).not_to include(linked)
    expect(sh("rev-parse", "--abbrev-ref", "HEAD", dir: moved).strip).to eq("feat/b")
    expect(File.read(config.config_path_for(new))).to include("root: #{moved}")
    expect(File.exist?(config.config_path_for(old))).to be(false)
    expect(File.read(File.join(moved, ".workspace-project")).strip).to eq(new)
    expect(project_settings.load(new).dig("notes", "dir")).to eq(File.join(repo, "tmp", "workspace-notes", "feat-b"))
    expect(File.exist?(config.project_config_path(old))).to be(false)
    expect(Dir.exist?(config.pipeline_state_dir(old))).to be(false)
    expect(Dir.exist?(config.pipeline_state_dir(new))).to be(true)
    expect(inbox(new).list.first["scope"]).to include("key" => new)
    expect(File.exist?(config.inbox_path("workspace", old))).to be(false)
    expect(tasks.active_for(new)).to include("branch" => "feat/b", "path" => moved)
    expect(tasks.active_for(old)).to be_nil
    expect(stale_files).to eq([])
  end

  it "renames a stopped worktree workspace and leaves no old name behind" do
    expect(run_cli("rename", old, "feat/b")).to eq(0)

    expect_renamed
    expect(out.string).to include("#{old} -> #{new}")
  end

  it "answers one JSON document" do
    expect(run_cli("rename", old, "feat/b", "--json")).to eq(0)

    document = JSON.parse(out.string)
    expect(document["results"].first).to include("workspace" => new, "previous_workspace" => old, "outcome" => "renamed")
    expect_renamed
  end

  it "plans a dry run without changing anything" do
    expect(run_cli("rename", old, "feat/b", "--dry-run", "--json")).to eq(0)

    expect(JSON.parse(out.string)["results"].first).to include("outcome" => "dry_run")
    expect(Dir.exist?(linked)).to be(true)
    expect(File.exist?(config.config_path_for(new))).to be(false)
  end

  it "finishes a half-done rename with the old name, after the config moved" do
    skip "a root user is not stopped by file permissions" if Process.uid.zero?
    FileUtils.chmod(0o555, config.task_dir)
    begin
      expect(run_cli("rename", old, "feat/b")).not_to eq(0)
    ensure
      FileUtils.chmod(0o700, config.task_dir)
    end
    expect(File.exist?(config.config_path_for(new))).to be(true)
    expect(File.exist?(config.config_path_for(old))).to be(false)
    expect(File.exist?(config.rename_journal_path(old))).to be(true)

    expect(run_cli("rename", old, "feat/b", "--json")).to eq(0)

    document = JSON.parse(out.string)
    expect(document["results"].first).to include("workspace" => new, "resume" => true)
    expect(File.exist?(config.rename_journal_path(old))).to be(false)
    expect_renamed
  end
end
