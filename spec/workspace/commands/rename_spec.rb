require "spec_helper"
require "tmpdir"
require "open3"
require "fileutils"
require "json"

RSpec.describe Workspace::Commands::Rename do
  let(:home) { File.realpath(Dir.mktmpdir("ws-rename", "/tmp")) }
  let(:repo) { File.join(home, "src", "api") }
  let(:linked) { File.join(repo, ".worktrees", "feat-a") }
  let(:moved) { File.join(repo, ".worktrees", "feat-b") }
  let(:main_notes) { File.join(repo, "tmp", "workspace-notes") }
  let(:notes_a) { File.join(main_notes, "feat-a") }
  let(:notes_b) { File.join(main_notes, "feat-b") }
  let(:old) { "api.worktree-feat-a" }
  let(:new) { "api.worktree-feat-b" }
  let(:config) { Workspace::Config.new(workspace_dir: home) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:project_settings) { Workspace::ProjectSettings.new(config: config) }
  let(:event_log) { Workspace::EventLog.new(config: config, error_output: StringIO.new) }
  let(:state) { Workspace::State.new(config: config, event_log: event_log) }
  let(:tmux) { Workspace::Tmux.new(config: config) }
  let(:task_store) { Workspace::TaskStore.new(dir: config.task_dir, error_output: StringIO.new) }
  let(:session_ledger) { Workspace::SessionLedger.new(path: File.join(config.state_dir, "ledger.jsonl")) }
  let(:pane_bindings) { Workspace::PaneBindings.new(path: config.pane_bindings_path, error_output: StringIO.new) }
  let(:git_exclude) { Workspace::GitExclude.new(git: git) }
  let(:journal) { Workspace::RenameJournal.new(config: config) }
  let(:engine) { instance_double(Workspace::WorkflowEngine, run_on_checkout: nil) }
  let(:inbox_store_factory) { ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, error_output: error_output) } }

  around do |example|
    saved = ENV.to_h.slice("HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME")
    ENV["HOME"] = home
    ENV.delete("XDG_STATE_HOME")
    ENV.delete("XDG_CONFIG_HOME")
    example.run
  ensure
    %w[HOME XDG_STATE_HOME XDG_CONFIG_HOME].each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
    FileUtils.remove_entry(home)
  end

  def sh(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless status.success?
    out
  end

  def write_config(name, root, session, display, branch: nil)
    path = config.config_path_for(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~YAML)
      # #{path}
      name: #{session}
      root: #{root}
      windows:
        - workspace-#{session}:
            panes:
              - ascii-banner "#{display}" --rainbow
              - echo 'Worktree — #{branch} (#{old})'
              - echo 'Ready to work on #{name}'
    YAML
  end

  # A fresh set of the objects a process reads through, as a re-run gets (ProjectConfig caches roots).
  def command
    project_config = Workspace::ProjectConfig.new(config: config, git: git, output: StringIO.new)
    resolver = Workspace::ConfigResolver.new(project_settings: Workspace::ProjectSettings.new(config: config))
    notes = Workspace::Commands::Notes.new(notes_dir: Workspace::NotesDir.new(git: git), project_config: project_config, config_resolver: resolver,
      git_exclude: git_exclude, output: StringIO.new)
    plan = Workspace::RenamePlan.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
      notes_dir: Workspace::NotesDir.new(git: git, home: home), workflow_engine: engine, journal: journal.method(:read), transcripts: ->(_path) { false })
    name_migration = Workspace::NameMigration.new(config: config, project_config: project_config, tmux: tmux, state: state, event_log: event_log,
      project_catalog_factory: -> { [] })
    described_class.new(plan: plan, journal: journal, git: git, config: config, project_config: project_config, project_settings: project_settings,
      tmux: tmux, state: state, notes: notes, name_migration: name_migration, task_store: task_store, inbox_store_factory: inbox_store_factory,
      session_ledger: session_ledger, pane_bindings: pane_bindings, event_log: event_log,
      project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) }, error_output: StringIO.new)
  end

  def rename(workspace: old, branch: "feat/b", **options)
    command.call(workspace: workspace, new: branch, **options)
  end

  def refused(code, **options)
    rename(**options)
    raise "no error"
  rescue Workspace::Error => e
    expect(e.code).to eq(code)
    e
  end

  def journal_path = config.rename_journal_path(old)

  def branch_of(path) = sh("rev-parse", "--abbrev-ref", "HEAD", dir: path).strip

  def stored_notes(name) = project_settings.load(name).dig("notes", "dir")

  def events = event_log.events.select { |event| event["type"] == "workspace_renamed" }

  # Makes the next call of +method+ raise; later calls go through.
  def fail_once(object, method, error = Errno::EACCES.new("no"))
    calls = 0
    allow(object).to receive(method).and_wrap_original do |original, *args, **options, &block|
      calls += 1
      raise error if calls == 1
      original.call(*args, **options, &block)
    end
  end

  # Makes the next File.rename to a path matching +pattern+ raise.
  def fail_rename_once(pattern)
    calls = 0
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      if to.to_s.match?(pattern) && (calls += 1) == 1
        raise Errno::EACCES, to
      end
      original.call(from, to)
    end
  end

  def catching(*signals)
    caught = []
    previous = signals.to_h { |name| [name, Signal.trap(name) { caught << name }] }
    yield caught
  ensure
    previous.each { |name, handler| Signal.trap(name, handler) }
  end

  def expect_finished
    expect(Dir.exist?(linked)).to be(false)
    expect(branch_of(moved)).to eq("feat/b")
    expect(sh("worktree", "list")).to include(moved)
    expect(File.exist?(journal_path)).to be(false)
    expect(File.exist?(config.config_path_for(old))).to be(false)
    text = File.read(config.config_path_for(new))
    expect(text).to include("root: #{moved}", "name: api-wt-feat-b", 'ascii-banner "api feat b"', "Worktree — feat/b (", "Ready to work on #{new}")
    expect(File.read(File.join(moved, ".workspace-project")).strip).to eq(new)
    expect(File.exist?(config.project_config_path(old))).to be(false)
    expect(stored_notes(new)).to eq(notes_b)
    expect(File.read(File.join(notes_b, "note.md"))).to eq("mine")
    expect(Dir.exist?(notes_a)).to be(false)
    expect(File.read(File.join(repo, ".git", "info", "exclude"))).to include("/tmp/workspace-notes/feat-b/")
    expect(Dir.exist?(config.pipeline_state_dir(old))).to be(false)
    expect(File.read(config.ask_state_path(new))).to eq("[]")
    expect(state.load.to_h.keys).to include(new)
    expect(state.load.to_h.keys).not_to include(old)
    expect(task_store.active_for(new)).to include("branch" => "feat/b", "path" => moved)
    expect(task_store.active_for(old)).to be_nil
    expect(Workspace::InboxStore.new(path: config.inbox_path("workspace", new), error_output: StringIO.new).list.first["scope"]).to include("key" => new, "name" => new)
    expect(File.exist?(config.inbox_path("workspace", old))).to be(false)
    expect(File.read(Workspace::HookEventLog.path_for(config.hook_events_dir, new))).to eq("{}\n")
    expect(File.exist?(Workspace::HookEventLog.path_for(config.hook_events_dir, old))).to be(false)
    expect(session_ledger.slots_for(new, "api-wt-feat-b").map { |slot| [slot["pane_slot"], slot["session_id"], slot["cwd"]] }).to eq([["api-wt-feat-b:0.0", "s1", moved]])
    expect(pane_bindings.binding_for("%7")).to include("workspace" => new, "session" => "api-wt-feat-b")
    expect(events.size).to eq(1)
  end

  before do
    FileUtils.mkdir_p(repo)
    FileUtils.mkdir_p(config.run_dir)
    sh("init", "-q", "-b", "main")
    sh("commit", "-q", "--allow-empty", "-m", "start")
    sh("worktree", "add", "-q", "-b", "feat/a", linked)
    write_config("api", repo, "api", "api")
    write_config(old, linked, "api-wt-feat-a", "api feat a", branch: "feat/a")
    File.write(File.join(linked, ".workspace-project"), old)
    FileUtils.mkdir_p(notes_a)
    File.write(File.join(notes_a, "note.md"), "mine")
    git_exclude.add(repo, "/tmp/workspace-notes/feat-a/")
    project_settings.save(old, {"notes" => {"dir" => notes_a}})
    FileUtils.mkdir_p(config.pipeline_state_dir(old))
    File.write(config.ask_state_path(old), "[]")
    state.load
    state[old] = {"unique_id" => "u"}
    state.save
    task_store.start(workspace: old, branch: "feat/a", path: linked)
    Workspace::InboxStore.new(path: config.inbox_path("workspace", old), error_output: StringIO.new)
      .add({"kind" => "note", "title" => "t", "scope" => {"kind" => "workspace", "key" => old, "name" => old}})
    FileUtils.mkdir_p(config.hook_events_dir)
    File.write(Workspace::HookEventLog.path_for(config.hook_events_dir, old), "{}\n")
    session_ledger.record({"event" => "session_start", "workspace" => old, "pane_slot" => "api-wt-feat-a:0.0", "pane_id" => "%7", "tmux_server" => "1",
                           "session_id" => "s1", "cwd" => linked})
    pane_bindings.bind("%7", {"kind" => "play", "id" => "p", "workspace" => old, "session" => "api-wt-feat-a", "pane_slot" => "api-wt-feat-a:0.0"})
    allow(tmux).to receive(:session_exists?).and_return(false)
  end

  describe "a rename that goes through" do
    it "moves everything keyed on the names and drops the journal" do
      result = rename

      expect_finished
      expect(result).to include("project" => "api", "dry_run" => false, "resume" => false, "warnings" => [])
      expect(result["workspace"]).to eq("from" => old, "to" => new)
      expect(result["notes"]).to include("action" => "move", "from" => notes_a, "to" => notes_b)
      expect(result["next"]).to eq("Run `workspace restore #{new}` to resume the conversation; a plain `workspace launch #{new}` starts a new one.")
    end

    it "writes workspace_renamed with names only" do
      rename

      event = events.first
      expect(event["project"]).to eq(new)
      expect(event["data"]).to eq("workspace" => new, "from" => old, "branch" => "feat/b", "from_branch" => "feat/a",
        "session" => "api-wt-feat-b", "from_session" => "api-wt-feat-a",
        "renamed" => %w[project_settings state_dir inbox state marker tmuxinator_config], "failed" => [])
    end

    it "holds both startup locks while it works" do
      held = nil
      allow(task_store).to receive(:active_for).and_wrap_original do |original, *args|
        held = [old, new].map do |name|
          File.open(config.agent_lock_path(name), File::RDWR | File::CREAT) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
        end
        original.call(*args)
      end

      rename

      expect(held).to eq([false, false])
    end

    it "changes only the branch when the directory and names stay the same" do
      result = rename(branch: "feat-a")

      expect(result["path"]).to eq("from" => linked, "to" => linked)
      expect(branch_of(linked)).to eq("feat-a")
      expect(File.read(config.config_path_for(old))).to include("Worktree — feat-a (")
      expect(task_store.active_for(old)).to include("branch" => "feat-a")
      slot = session_ledger.slots_for(old, "api-wt-feat-a").first
      expect(slot["session_id"]).to eq("s1")
      expect(slot["ended_at"]).to be_nil
      expect(File.exist?(journal_path)).to be(false)
    end

    it "refuses when a daemon starts before the locks are held, with nothing changed" do
      reads = 0
      allow(config).to receive(:agent_running?).and_wrap_original do |_original, name|
        (reads += 1) > 1 && name == old
      end

      refused("workspace_running")

      expect(branch_of(linked)).to eq("feat/a")
      expect(File.exist?(journal_path)).to be(false)
    end
  end

  describe "--dry-run" do
    def snapshot
      Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.") }.sort.to_h do |path|
        [path, [File.mtime(path), File.file?(path) ? File.binread(path) : nil]]
      end
    end

    it "writes nothing and answers the plan" do
      before = snapshot

      result = rename(dry_run: true)

      expect(snapshot).to eq(before)
      expect(result).to include("dry_run" => true, "next" => nil)
      expect(result["branch"]).to eq("from" => "feat/a", "to" => "feat/b")
      expect(result["notes"]["action"]).to eq("move")
    end
  end

  describe "--dry-run with a journal present" do
    before do
      fail_once(task_store, :update)
      refused("rename_incomplete")
    end

    it "answers the plan for the same name as a resume, and leaves the journal and the work alone" do
      text = File.read(journal_path)

      result = rename(dry_run: true)

      expect(result).to include("dry_run" => true, "resume" => true, "next" => nil)
      expect(File.read(journal_path)).to eq(text)
      expect(task_store.active_for(old)).not_to be_nil
    end

    it "refuses another name, printing the command that finishes the first" do
      error = refused("rename_in_progress", branch: "feat/c", dry_run: true)

      expect(error.details).to include("fix" => "workspace rename #{old} feat/b", "rerun" => true)
      expect(error.message).to include("Run `workspace rename #{old} feat/b` to finish it.")
    end
  end

  describe "a failed git step" do
    it "undoes the move after a failed branch step, ending with rename_failed and no journal" do
      allow(git).to receive(:rename_branch).and_return([false, "fatal: no\nmore"])

      error = refused("rename_failed")

      expect(error.details).to include("step" => "branch_rename", "rolled_back" => true, "workspace" => old, "new_branch" => "feat/b")
      expect(error.message).to include("git branch -m failed: fatal: no", "Nothing changed")
      expect(Dir.exist?(linked)).to be(true)
      expect(Dir.exist?(moved)).to be(false)
      expect(branch_of(linked)).to eq("feat/a")
      expect(sh("worktree", "list")).to include(linked)
      expect(File.exist?(journal_path)).to be(false)
      expect(File.read(File.join(notes_a, "note.md"))).to eq("mine")
      expect(File.exist?(config.config_path_for(old))).to be(true)
    end

    it "is rename_failed when the move itself fails" do
      allow(git).to receive(:move_worktree).and_return([false, "fatal: locked"])

      expect(refused("rename_failed").details).to include("step" => "worktree_move")
      expect(File.exist?(journal_path)).to be(false)
    end

    it "is rename_incomplete, keeping the journal, when the undo fails; the re-run finishes" do
      allow(git).to receive(:rename_branch).and_return([false, "no"])
      calls = 0
      allow(git).to receive(:move_worktree).and_wrap_original do |original, *args|
        ((calls += 1) == 2) ? [false, "busy"] : original.call(*args)
      end

      error = refused("rename_incomplete")

      expect(error.details).to include("failed" => ["undo"], "fix" => "workspace rename #{old} feat/b", "rerun" => true)
      expect(File.exist?(journal_path)).to be(true)
      allow(git).to receive(:rename_branch).and_call_original

      expect(rename["resume"]).to be(true)
      expect_finished
    end

    it "moves nothing for a signal that comes before the first git step" do
      catching("TERM") do |caught|
        allow(journal).to receive(:write).and_wrap_original do |original, *args|
          Process.kill("TERM", Process.pid)
          original.call(*args)
        end
        allow(git).to receive(:move_worktree).and_call_original

        error = refused("rename_failed")

        expect(error.details).to include("signal" => "SIGTERM", "step" => "worktree_move", "rolled_back" => true)
        expect(git).not_to have_received(:move_worktree)
        expect(caught).to eq([])
      end
      expect(branch_of(linked)).to eq("feat/a")
      expect(File.exist?(journal_path)).to be(false)
    end

    it "undoes both git steps for a signal that comes after the branch step" do
      catching("TERM") do |caught|
        allow(git).to receive(:rename_branch).and_wrap_original do |original, *args|
          Process.kill("TERM", Process.pid)
          original.call(*args)
        end

        error = refused("rename_failed")

        expect(error.details).to include("signal" => "SIGTERM", "step" => "branch_rename")
        expect(caught).to eq([])
      end
      expect(branch_of(linked)).to eq("feat/a")
      expect(Dir.exist?(moved)).to be(false)
      expect(File.exist?(journal_path)).to be(false)
    end
  end

  describe "a failure after the git steps" do
    {
      "notes_dir" => ["notes_dir", ->(spec) { spec.fail_once(spec.project_settings, :save) }],
      "state" => ["state", ->(spec) { spec.fail_once(spec.state, :save) }],
      "tmuxinator_config" => ["tmuxinator_config", ->(spec) { spec.fail_rename_once(/workspace\.api\.worktree-feat-b\.yml\z/) }],
      "notes_exclude" => ["notes_exclude", ->(spec) { spec.fail_once(spec.git_exclude, :add) }],
      "task" => ["task", ->(spec) { spec.fail_once(spec.task_store, :update) }],
      "inbox" => ["inbox", ->(spec) { spec.fail_once(spec.inbox_store_factory, :call) }],
      "hook_events" => ["hook_events", ->(spec) { spec.fail_rename_once(/\.events\/.*feat-b\.jsonl\z/) }],
      "ledger" => ["ledger", ->(spec) { spec.fail_once(spec.session_ledger, :carry) }],
      "bindings" => ["bindings", ->(spec) { spec.fail_once(spec.pane_bindings, :rename_workspace) }]
    }.each do |label, (step, arrange)|
      it "keeps the journal at #{label}, and the same command finishes" do
        arrange.call(self)

        error = refused("rename_incomplete")

        expect(error.details["failed"]).to eq([step])
        expect(error.details).to include("workspace" => old, "new_workspace" => new, "new_branch" => "feat/b", "rerun" => true)
        expect(error.message).to include("workspace rename #{old} feat/b")
        expect(File.exist?(journal_path)).to be(true)
        expect(branch_of(moved)).to eq("feat/b")
        expect(events).to eq([])

        expect(rename["resume"]).to be(true)
        expect_finished
      end
    end

    it "finishes a process killed between the two renames of the config" do
      fail_once(project_settings, :save)
      refused("rename_incomplete")
      dir = config.tmuxinator_dir
      File.rename(config.config_path_for(old), File.join(dir, ".workspace.#{old}.yml.4242.old"))
      File.write(File.join(dir, ".workspace.#{new}.yml.4242.tmp"), "partial")

      rename

      expect_finished
      expect(Dir.children(dir).grep(/4242/)).to eq([])
    end

    it "keeps the journal and writes no event when no config is under the new name" do
      fail_once(project_settings, :save)
      refused("rename_incomplete")
      File.delete(config.config_path_for(old))

      error = refused("rename_incomplete")

      expect(error.details).to include("failed" => ["tmuxinator_config"], "rerun" => false, "fix" => "rm #{Shellwords.escape(journal_path)}")
      expect(error.details["problems"].first).to include(config.config_path_for(new))
      expect(File.exist?(journal_path)).to be(true)
      expect(events).to eq([])
    end

    it "takes a failed startup lock on a re-run as unfinished, keeping the journal" do
      fail_once(task_store, :update)
      refused("rename_incomplete")
      lock = config.agent_lock_path(old)
      allow(File).to receive(:open).and_wrap_original do |original, *args, **options, &block|
        raise Errno::EACCES, lock if args.first == lock
        original.call(*args, **options, &block)
      end

      error = refused("rename_incomplete")

      expect(error.details).to include("failed" => ["startup_lock"], "rerun" => true)
      expect(error.message).not_to include("Nothing changed")
      expect(File.exist?(journal_path)).to be(true)
    end

    it "is rename_failed when the startup lock fails on a first run" do
      lock = config.agent_lock_path(old)
      allow(File).to receive(:open).and_wrap_original do |original, *args, **options, &block|
        raise Errno::EACCES, lock if args.first == lock
        original.call(*args, **options, &block)
      end

      expect(refused("rename_failed").details).to include("step" => "startup_lock")
      expect(branch_of(linked)).to eq("feat/a")
    end

    it "names a signal that came during the step that failed" do
      catching("TERM") do |caught|
        allow(task_store).to receive(:update) do
          Process.kill("TERM", Process.pid)
          sleep 0.05
          raise Errno::EACCES, "no"
        end

        error = refused("rename_incomplete")

        expect(error.details).to include("signal" => "SIGTERM", "failed" => ["task"])
        expect(caught).to eq([])
      end
    end

    context "with a launch under the new name during the rename" do
      let(:old_events) { Workspace::HookEventLog.path_for(config.hook_events_dir, old) }
      let(:new_events) { Workspace::HookEventLog.path_for(config.hook_events_dir, new) }

      before do
        fail_once(task_store, :update)
        refused("rename_incomplete")
        File.write(new_events, "{\"launch\":1}\n")
      end

      it "appends the old event log to the new one" do
        rename

        expect(File.read(new_events)).to eq("{\"launch\":1}\n{}\n")
        expect(File.exist?(old_events)).to be(false)
        expect(File.exist?(journal_path)).to be(false)
      end

      it "joins only once when a killed run left both files" do
        File.write(new_events, "{\"launch\":1}\n{}\n")

        rename

        expect(File.read(new_events)).to eq("{\"launch\":1}\n{}\n")
        expect(File.exist?(old_events)).to be(false)
      end

      it "leaves both files whole when the join fails, and the re-run finishes it" do
        fail_rename_once(/feat-b\.jsonl\z/)

        expect(refused("rename_incomplete").details["failed"]).to eq(["hook_events"])
        expect(File.read(new_events)).to eq("{\"launch\":1}\n")
        expect(Dir.children(config.hook_events_dir)).to contain_exactly(File.basename(old_events), File.basename(new_events))

        rename

        expect(File.read(new_events)).to eq("{\"launch\":1}\n{}\n")
      end
    end

    it "says how to clear a journal whose checkouts are both gone" do
      fail_once(task_store, :update)
      refused("rename_incomplete")
      sh("worktree", "remove", "--force", moved)

      [{}, {branch: "feat/c"}].each do |options|
        error = refused("rename_in_progress", **options)

        expect(error.details).to include("path" => journal_path, "rerun" => false, "fix" => "rm #{journal_path}")
        expect(error.message).to include("Delete #{journal_path}")
      end
      File.delete(journal_path)
      expect(journal.read(old)).to be_nil
    end

    it "finishes from the new name once the config has moved" do
      fail_once(task_store, :update)
      refused("rename_incomplete")

      rename(workspace: new)

      expect_finished
    end

    it "gives the held-back config warning the re-run command" do
      fail_once(state, :save)

      error = refused("rename_incomplete")

      expect(error.details["problems"].join).to include("run `workspace rename #{old} feat/b` again")
    end

    it "refuses a re-run with another name" do
      fail_once(task_store, :update)
      refused("rename_incomplete")

      expect(refused("rename_in_progress", branch: "feat/c").details).to include("new_branch" => "feat/b", "rerun" => true)
    end

    it "refuses a re-run when another workspace's store is also there" do
      fail_once(project_settings, :save)
      refused("rename_incomplete")
      FileUtils.mkdir_p(config.pipeline_state_dir(new))

      expect(refused("rename_target_taken").details["taken"]).to eq(["state_dir"])
    end

    it "finishes from the journal when the process died after the journal was written" do
      plan = command.instance_variable_get(:@plan).call(workspace: old, new: "feat/b")
      journal.write(plan)

      expect(rename["resume"]).to be(true)
      expect_finished
    end
  end

  describe "a signal during a later step" do
    it "waits for the step, stops before the next, and keeps the journal" do
      ran = []
      catching("TERM") do |caught|
        allow(task_store).to receive(:active_for).and_wrap_original do |original, *args|
          Process.kill("TERM", Process.pid) if ran.empty?
          ran << :task
          original.call(*args)
        end

        error = refused("rename_incomplete")

        expect(error.details).to include("signal" => "SIGTERM", "failed" => ["inbox"])
        expect(error.message).to include("stopped by SIGTERM before inbox")
        expect(caught).to eq([])
      end
      expect(ran).to eq([:task])
      expect(File.exist?(journal_path)).to be(true)
      expect(task_store.active_for(new)).not_to be_nil
      expect(session_ledger.slots_for(new, "api-wt-feat-b")).to eq([])
    end

    it "sends on a signal that came during the last step, after the handlers are back" do
      catching("TERM") do |caught|
        allow(pane_bindings).to receive(:rename_workspace).and_wrap_original do |original, **options|
          Process.kill("TERM", Process.pid)
          original.call(**options)
        end

        rename

        expect(caught).to eq(["TERM"])
      end
      expect_finished
    end
  end

  describe "what `kill` left under the new name" do
    it "refuses before git moves anything" do
      write = lambda do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "left")
      end
      log = config.agent_log_path(new)
      inbox = config.inbox_path("workspace", new)
      events = Workspace::HookEventLog.path_for(config.hook_events_dir, new)
      [log, inbox, events].each(&write)

      error = refused("rename_target_taken")

      expect(error.details["taken"]).to eq(%w[agent_log inbox hook_events])
      expect(error.details["paths"]).to eq("agent_log" => log, "inbox" => inbox, "hook_events" => events)
      expect(error.details).not_to have_key("fix")
      expect(branch_of(linked)).to eq("feat/a")
      expect(File.exist?(journal_path)).to be(false)
    end

    it "gives the delete when only logs are in the way, and that clears it" do
      log = config.agent_log_path(new)
      File.write(log, "left")

      expect(refused("rename_target_taken").details["fix"]).to eq("rm #{log}")

      File.delete(log)
      rename

      expect_finished
    end
  end

  describe "notes on a re-run" do
    it "uses the first run's decision for a notes.dir inside the old checkout, and rewrites it" do
      inside = File.join(linked, "my-notes")
      FileUtils.mkdir_p(inside)
      File.write(File.join(inside, "note.md"), "mine")
      project_settings.save(old, {"notes" => {"dir" => inside}})
      fail_once(state, :save)
      refused("rename_incomplete")

      expect(JSON.parse(File.read(journal_path))["notes"]).to include("action" => "with_checkout", "from" => inside, "to" => File.join(moved, "my-notes"))
      expect(rename["notes"]["action"]).to eq("with_checkout")

      expect(stored_notes(new)).to eq(File.join(moved, "my-notes"))
      expect(File.read(File.join(moved, "my-notes", "note.md"))).to eq("mine")
    end

    it "rewrites a notes.dir that goes with the checkout on the first run too" do
      inside = File.join(linked, "my-notes")
      FileUtils.mkdir_p(inside)
      project_settings.save(old, {"notes" => {"dir" => inside}})

      rename

      expect(stored_notes(new)).to eq(File.join(moved, "my-notes"))
    end

    it "keeps custom notes out of the rename, on the re-run too" do
      custom = File.join(home, "elsewhere")
      FileUtils.mkdir_p(custom)
      project_settings.save(old, {"notes" => {"dir" => custom}})
      fail_once(task_store, :update)
      refused("rename_incomplete")

      expect(rename["notes"]).to include("action" => "stays", "reason" => "custom")
      expect(stored_notes(new)).to eq(custom)
    end

    it "takes a gone source with the target there as done" do
      fail_once(project_settings, :save)
      refused("rename_incomplete")
      expect(Dir.exist?(notes_a)).to be(false)

      rename

      expect_finished
    end

    it "moves over an empty target" do
      fail_rename_once(/workspace-notes\/feat-b\z/)
      refused("rename_incomplete")
      FileUtils.mkdir_p(notes_b)

      rename

      expect_finished
    end

    it "stops as a failed step when both are there and the target holds files, and never merges" do
      fail_rename_once(/workspace-notes\/feat-b\z/)
      refused("rename_incomplete")
      FileUtils.mkdir_p(notes_b)
      File.write(File.join(notes_b, "other.md"), "theirs")

      error = refused("rename_incomplete")

      expect(error.details["failed"]).to eq(["notes"])
      expect(error.details["problems"].first).to include(notes_a, notes_b)
      expect(File.read(File.join(notes_a, "note.md"))).to eq("mine")
      expect(Dir.children(notes_b)).to eq(["other.md"])
      expect(stored_notes(old)).to eq(notes_a)
      expect(File.exist?(journal_path)).to be(true)

      FileUtils.rm_rf(notes_b)
      rename
      expect_finished
    end
  end

  describe Workspace::RenameJournal do
    it "reads a journal by the new name, and leaves out one it can't read" do
      FileUtils.mkdir_p(config.rename_journal_dir)
      File.write(config.rename_journal_path("other"), "{")
      File.write(journal_path, JSON.generate("workspace" => old, "new_workspace" => new))

      expect(journal.read(new)).to include("workspace" => old)
      expect(journal.read("nobody")).to be_nil
      expect(journal.read("../x")).to be_nil
    end

    it "says a workspace's own unreadable journal is a rename in progress" do
      FileUtils.mkdir_p(config.rename_journal_dir)
      File.write(journal_path, "{")

      expect { journal.read(old) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("rename_in_progress")
        expect(e.details).to include("path" => journal_path, "rerun" => false, "fix" => "rm #{journal_path}")
      }
    end
  end
end
