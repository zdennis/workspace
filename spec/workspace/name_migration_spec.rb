require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::NameMigration do
  let(:home) { Dir.mktmpdir("ws-rename", "/tmp") }
  let(:root) { File.join(home, "src", "Notes").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:config) { Workspace::Config.new(workspace_dir: home) }
  let(:project_config) { Workspace::ProjectConfig.new(config: config, git: git, output: StringIO.new) }
  let(:git) { Workspace::Git.new(output: StringIO.new) }
  let(:tmux) { Workspace::Tmux.new(config: config) }
  let(:event_log) { Workspace::EventLog.new(config: config, error_output: StringIO.new) }
  let(:state) { Workspace::State.new(config: config, event_log: event_log) }
  let(:live_sessions) { [] }

  around do |example|
    saved = ENV.to_h.slice("HOME", "XDG_STATE_HOME")
    ENV["HOME"] = home
    ENV.delete("XDG_STATE_HOME")
    example.run
  ensure
    ENV.delete("XDG_STATE_HOME")
    saved.each { |key, value| ENV[key] = value }
  end

  before do
    allow(tmux).to receive(:session_exists?) { |name, **| live_sessions.include?(name) }
    allow(tmux).to receive(:rename_session) do |from, to, **|
      live_sessions.map! { |name| (name == from) ? to : name }
      true
    end
  end

  after { FileUtils.remove_entry(home) }

  def migration
    described_class.new(config: config, project_config: project_config, tmux: tmux, state: state, event_log: event_log,
      project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) })
  end

  def write(path, text = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def listing(dir)
    Dir.children(dir).sort
  end

  def tmuxinator_yml(name, session, dir)
    <<~YML
      # #{config.config_path_for(name)}

      name: #{session}
      root: #{dir}
      tmux_options: -CC

      on_project_start: |
        tmux resize-pane -t #{session}:0.0 -y 15%

      windows:
        - workspace-#{session}:
            panes:
              - |
                printf '\\033]2;workspace-#{session}\\a' &&
                tmux resize-pane -t #{session}:0.2 -y 35% &&
                ascii-banner "#{session}" --rainbow
    YML
  end

  def mixed_case_workspace
    write(config.config_path_for("Notes"), tmuxinator_yml("Notes", "Notes", root))
    write(config.project_config_path("Notes"), "hooks: {}\n")
    write(config.agent_log_path("Notes"), "old log\n")
    write(config.agent_lock_path("Notes"))
    write(config.agent_socket_path("Notes"))
    write(config.pipeline_state_path("Notes"), "{}")
    write(config.inbox_path("workspace", "Notes"), "[]")
    write(config.inbox_path("project", File.realpath(root), name: "Notes"), "[]")
    state.load
    state["Notes"] = {"iterm_window_id" => 7}
    state.save
  end

  it "renames every file, directory and key named for the workspace to lowercase" do
    mixed_case_workspace

    result = migration.call("Notes")

    expect(result.name).to eq("notes")
    expect(result.from).to eq("Notes")
    expect(result.warnings).to eq([])
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.notes.yml"])
    expect(listing(config.workspace_projects_dir)).to eq(["notes.yml"])
    expect(listing(config.run_dir)).to eq(%w[workspace-notes.lock workspace-notes.log workspace-notes.sock])
    expect(File.read(config.agent_log_path("notes"))).to start_with("old log\n")
    expect(listing(config.state_dir)).to include("notes")
    expect(listing(config.state_dir)).not_to include("Notes")
    expect(listing(File.join(config.inbox_dir, "workspace"))).to eq(["notes.json"])
    expect(listing(File.join(config.inbox_dir, "project"))).to eq([File.basename(config.inbox_path("project", File.realpath(root), name: "notes"))])
    expect(state.load.to_h).to eq("notes" => {"iterm_window_id" => 7})
  end

  it "rewrites the session name in the tmuxinator config, keeping its root and banner" do
    mixed_case_workspace

    migration.call("Notes")

    text = File.read(config.config_path_for("notes"))
    expect(text).to eq(tmuxinator_yml("notes", "notes", root).sub('ascii-banner "notes"', 'ascii-banner "Notes"'))
    expect(text).to include("root: #{root}")
  end

  it "renames a live tmux session" do
    mixed_case_workspace
    live_sessions << "Notes"

    result = migration.call("Notes")

    expect(live_sessions).to eq(["notes"])
    expect(result.renamed).to include({"what" => "tmux_session", "from" => "Notes", "to" => "notes"})
  end

  it "writes one workspace_renamed event-log line" do
    mixed_case_workspace

    migration.call("Notes")

    events = event_log.events.select { |event| event["type"] == "workspace_renamed" }
    expect(events.size).to eq(1)
    expect(events.first["project"]).to eq("notes")
    expect(events.first["data"]).to include("workspace" => "notes", "from" => "Notes", "failed" => [])
    expect(events.first["data"]["renamed"]).to include("tmuxinator_config", "state_dir", "inbox", "project_inbox", "state", "socket", "log", "lock")
  end

  it "does nothing the second time, or for a workspace already lowercase" do
    mixed_case_workspace
    migration.call("Notes")
    before = event_log.events.size

    again = migration.call("notes")

    expect(again.from).to be_nil
    expect(again.renamed).to eq([])
    expect(again.warnings).to eq([])
    expect(event_log.events.size).to eq(before)
  end

  it "settles any spelling of the name to the lowercase one" do
    mixed_case_workspace

    expect(migration.call("NOTES").from).to eq("Notes")
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.notes.yml"])
  end

  it "keeps going after a step fails, holds the config back so the next start retries, and reports it" do
    mixed_case_workspace
    live_sessions << "Notes"
    allow(tmux).to receive(:rename_session).and_return(false)

    result = migration.call("Notes")

    expect(result.warnings).to eq(["Notes: tmux_session not renamed (tmux rename-session failed)",
      "Notes: tmuxinator_config not renamed until the steps above succeed; the next agentd start tries again (a name already taken has to be cleared by hand)"])
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.Notes.yml"])
    expect(listing(config.run_dir)).to include("workspace-notes.sock")
    event = event_log.events.find { |e| e["type"] == "workspace_renamed" }
    expect(event["data"]["failed"]).to eq(["tmux_session"])

    allow(tmux).to receive(:rename_session) do |from, to, **|
      live_sessions.map! { |name| (name == from) ? to : name }
      true
    end
    expect(migration.call("notes").warnings).to eq([])
    expect(live_sessions).to eq(["notes"])
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.notes.yml"])
  end

  it "leaves a key alone when the lowercase name is already taken" do
    mixed_case_workspace
    state["notes"] = {"iterm_window_id" => 9}
    state.save

    result = migration.call("Notes")

    expect(result.warnings.first).to eq("Notes: state not renamed (the state file already has notes)")
    expect(state.load.to_h).to eq("Notes" => {"iterm_window_id" => 7}, "notes" => {"iterm_window_id" => 9})
  end

  it "leaves a live session alone when one with the lowercase name exists" do
    mixed_case_workspace
    live_sessions.push("Notes", "notes")

    result = migration.call("Notes")

    expect(result.warnings.first).to eq("Notes: tmux_session not renamed (a tmux session named notes already exists)")
    expect(live_sessions).to eq(%w[Notes notes])
  end

  it "appends the rename and its warnings to the daemon log under the new name" do
    mixed_case_workspace
    state["notes"] = {}
    state.save

    migration.call("Notes")

    expect(File.read(config.agent_log_path("notes"))).to eq("old log\n" \
      "workspace agent: renamed workspace 'Notes' to 'notes'\n" \
      "Warning: Notes: state not renamed (the state file already has notes)\n" \
      "Warning: Notes: tmuxinator_config not renamed until the steps above succeed; the next agentd start tries again (a name already taken has to be cleared by hand)\n")
  end

  it "keeps the root: line as written, even where it looks like a window name" do
    dir = File.join(home, "workspace-Notes").tap { |d| FileUtils.mkdir_p(d) }
    write(config.config_path_for("Notes"), tmuxinator_yml("Notes", "Notes", dir))

    migration.call("Notes")

    expect(File.read(config.config_path_for("notes"))).to include("root: #{dir}\n", "- workspace-notes:")
  end

  describe "#call_locked" do
    before { mixed_case_workspace }

    it "renames under the startup lock when no daemon answers" do
      allow(config).to receive(:agent_running?).and_return(false)

      result = migration.call_locked("Notes")

      expect(result.from).to eq("Notes")
      expect(config).to have_received(:agent_running?).with("Notes")
    end

    it "gives up at once when another process holds the lowercase name's lock" do
      File.open(config.agent_lock_path("notes"), File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)

        expect(migration.call_locked("Notes", wait: false)).to be_nil
      end
      expect(listing(config.tmuxinator_dir)).to eq(["workspace.Notes.yml"])
    end

    it "renames nothing while a daemon answers" do
      allow(config).to receive(:agent_running?).and_return(true)

      expect(migration.call_locked("Notes")).to be_nil
      expect(listing(config.tmuxinator_dir)).to eq(["workspace.Notes.yml"])
    end
  end

  it "rewrites a worktree's .workspace-project marker" do
    worktree = File.join(root, ".worktrees", "Feat").tap { |dir| FileUtils.mkdir_p(dir) }
    write(config.config_path_for("Notes.worktree-Feat"), tmuxinator_yml("Notes.worktree-Feat", "Notes-wt-Feat", worktree))
    write(File.join(worktree, ".workspace-project"), "Notes.worktree-Feat")

    migration.call("Notes.worktree-Feat")

    expect(File.read(File.join(worktree, ".workspace-project"))).to eq("notes.worktree-feat")
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.notes.worktree-feat.yml"])
    expect(File.read(config.config_path_for("notes.worktree-feat"))).to include("name: notes-wt-feat\n", "-t notes-wt-feat:0.0")
  end

  context "with worktrees" do
    let(:worktree) { File.join(root, ".worktrees", "Feat").tap { |dir| FileUtils.mkdir_p(dir) } }

    before do
      mixed_case_workspace
      write(config.config_path_for("Notes.worktree-Feat"), tmuxinator_yml("Notes.worktree-Feat", "Notes-wt-Feat", worktree))
      write(config.inbox_path("workspace", "Notes.worktree-Feat"), "[]")
      live_sessions << "Notes-wt-Feat"
    end

    it "renames a project's worktree workspaces and their tmux sessions with it" do
      result = migration.call("Notes")

      expect(result.warnings).to eq([])
      expect(listing(config.tmuxinator_dir)).to eq(%w[workspace.notes.worktree-feat.yml workspace.notes.yml])
      expect(live_sessions).to eq(["notes-wt-feat"])
      expect(listing(File.join(config.inbox_dir, "workspace"))).to eq(%w[notes.json notes.worktree-feat.json])
      expect(event_log.events.select { |e| e["type"] == "workspace_renamed" }.map { |e| e["data"]["from"] }).to eq(%w[Notes Notes.worktree-Feat])
    end

    it "leaves a worktree whose agent daemon is starting for that daemon to rename" do
      File.open(config.agent_lock_path("notes.worktree-feat"), File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        # flock is per open file, so the migration's own open can't take it.
        result = migration.call("Notes")

        expect(result.warnings).to eq(["Notes.worktree-Feat: its agent daemon is running or starting; it is renamed when that daemon next starts"])
      end

      expect(listing(config.tmuxinator_dir)).to eq(%w[workspace.Notes.worktree-Feat.yml workspace.notes.yml])
      expect(live_sessions).to eq(["Notes-wt-Feat"])
    end
  end

  it "moves a long name's hashed run files to the lowercase name's" do
    long = "Notes-#{"x" * 120}"
    write(config.config_path_for(long), tmuxinator_yml(long, long, root))
    write(config.agent_socket_path(long))
    write(config.agent_log_path(long))

    migration.call(long)

    expect(listing(config.run_dir)).to contain_exactly(File.basename(config.agent_socket_path(long.downcase)),
      File.basename(config.agent_log_path(long.downcase)))
  end
end
