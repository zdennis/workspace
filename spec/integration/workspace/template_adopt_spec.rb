require "spec_helper"
require "tmpdir"
require "digest"

# TemplateAdopt over a real ProjectConfig (which renders the shipped templates), TmuxinatorConfigWriter,
# TemplateStatus, TemplateApply and NameMigration lock, all in a temporary directory.
RSpec.describe Workspace::TemplateAdopt do
  around do |example|
    Dir.mktmpdir("template-adopt") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) do
    instance_double(Workspace::Config, render_state_dir: File.join(@dir, "state", ".render"), tmuxinator_backups_dir: File.join(@dir, "state", "backups", "tmuxinator")).tap do |c|
      allow(c).to receive(:config_path_for) { |name| File.join(@dir, "tmuxinator", "workspace.#{name}.yml") }
      allow(c).to receive(:agent_lock_path) { |name| File.join(@dir, "locks", "#{name}.lock") }
      allow(c).to receive(:tmuxinator_dir).and_return(File.join(@dir, "tmuxinator"))
    end
  end
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:templates) { File.join(PROJECT_ROOT, "lib", "library", "template", "default") }
  let(:library) do
    instance_double(Workspace::Library).tap do |l|
      allow(l).to receive(:tmuxinator_template) { |kind, **| {"name" => "default", "path" => File.join(templates, "#{kind}.yml")} }
    end
  end
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: {}, load: {}) }
  let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
  let(:project_config) do
    Workspace::ProjectConfig.new(config: config, git: Workspace::Git.new, output: StringIO.new, agent_commands: agent_commands, writer: writer, library: -> { library })
  end
  let(:main_agent) { Workspace::MainAgent.new(project_config: project_config, agent_commands: agent_commands) }
  let(:locks) { Workspace::NameMigration.new(config: config, project_config: nil, tmux: nil, state: nil, event_log: nil, project_catalog_factory: nil, writer: writer) }
  let(:status) { Workspace::TemplateStatus.new(library: library, project_config: project_config, writer: writer) }
  subject(:adopt) { described_class.new(library: library, project_config: project_config, writer: writer, main_agent: main_agent, locks: locks) }

  before { FileUtils.mkdir_p([File.join(@dir, "locks"), File.join(@dir, "tmuxinator")]) }

  def path(name) = config.config_path_for(name)

  # A config as `start` writes it, then its record deleted, as a config written before records existed.
  def legacy_project(name = "myapp", root: "/src/my app")
    project_config.create(name, root)
    writer.remove_record(name)
  end

  def legacy_worktree(task_id: nil, agent_kind: nil)
    name = project_config.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", quiet: true, task_id: task_id, agent_kind: agent_kind)
    writer.remove_record(name)
    name
  end

  it "adopts a project config exact: the record's sha is the file's, and status reads current" do
    legacy_project
    before = File.binread(path("myapp"))

    rows = adopt.call(["myapp"])

    expect(rows.first).to include("outcome" => "adopted", "match" => "exact", "kind" => "project", "template" => "default", "code" => nil)
    expect(File.binread(path("myapp"))).to eq(before)
    expect(writer.record("myapp")).to have_attributes(approx: false, rendered_sha: Digest::SHA256.hexdigest(before), inputs: hash_including(project_root: "/src/my app", workspace_name: "myapp"))
    expect(status.row("myapp").state).to eq("current")
  end

  it "adopts a worktree config exact, recovering the branch, project and a task id" do
    name = legacy_worktree(task_id: "t_abc123")

    rows = adopt.call([name])

    expect(rows.first).to include("outcome" => "adopted", "match" => "exact", "kind" => "worktree")
    expect(writer.record(name).inputs).to include(worktree_branch: "PROJ-123", project_name: "myapp", task_id: "t_abc123", worktree_path: "/src/myapp/.worktrees/PROJ-123", agent_kind: "claude")
    expect(status.row(name).state).to eq("current")
  end

  it "adopts a codex worktree exact" do
    name = legacy_worktree(agent_kind: "codex")

    expect(adopt.call([name]).first).to include("match" => "exact")
    expect(writer.record(name).inputs).to include(agent_kind: "codex")
  end

  it "adopts a hand-edited config approx: the file is left alone, status reads modified and apply skips it until --force" do
    legacy_project
    File.write(path("myapp"), File.read(path("myapp")).sub("startup_pane: 2", "startup_pane: 1"))
    edited = File.binread(path("myapp"))

    rows = adopt.call(["myapp"])

    expect(rows.first).to include("outcome" => "adopted", "match" => "approx")
    expect(File.binread(path("myapp"))).to eq(edited)
    expect(writer.record("myapp").approx).to be(true)
    expect(status.row("myapp").state).to eq("modified")

    apply = Workspace::TemplateApply.new(status: status, writer: writer, backups: Workspace::TmuxinatorBackupStore.new(config: config, writer: writer), locks: locks,
      project_config: project_config, tmux: instance_double(Workspace::Tmux, session_exists?: false, session_name_for: "myapp"),
      differ: ->(*) { "" }, retention: instance_double(Workspace::TmuxinatorBackupConfig, keep: 20, max_age: nil))
    expect(apply.call(["myapp"]).rows.first).to include("outcome" => "skipped", "reason" => "approx", "code" => "template_approx")
    expect(File.binread(path("myapp"))).to eq(edited)

    forced = apply.call(["myapp"], force: true)
    expect(forced.rows.first).to include("outcome" => "applied")
    expect(writer.record("myapp").approx).to be(false)
    expect(status.row("myapp").state).to eq("current")
  end

  it "writes nothing and takes no lock under a dry run" do
    legacy_project

    expect(adopt.call(["myapp"], dry_run: true).first).to include("outcome" => "would_adopt", "match" => "exact")
    expect(writer.record("myapp")).to be_nil
    expect(Dir.children(File.join(@dir, "locks"))).to be_empty
  end

  it "skips a config that already has a record, leaving the record alone" do
    project_config.create("myapp", "/src/myapp")
    record = File.binread(writer.record_path("myapp"))

    expect(adopt.call(["myapp"]).first).to include("outcome" => "skipped", "reason" => "tracked")
    expect(File.binread(writer.record_path("myapp"))).to eq(record)
  end

  it "skips a workspace whose config is gone" do
    expect(adopt.call(["ghost"]).first).to include("outcome" => "skipped", "reason" => "gone")
    expect(writer.record("ghost")).to be_nil
  end

  it "fails a config it cannot read the inputs out of, and goes on" do
    File.write(path("broken"), "windows: [\n")
    File.write(path("noroot"), "name: noroot\n")
    legacy_project

    rows = adopt.call(%w[broken noroot myapp])

    expect(rows.map { |row| [row["workspace"], row["outcome"], row["code"]] }).to eq([["broken", "failed", "adopt_unrecoverable"], ["noroot", "failed", "adopt_unrecoverable"], ["myapp", "adopted", nil]])
    expect(writer.record("broken")).to be_nil
  end

  it "adopts a worktree config with no Worktree echo line approx, the branch from the checkout's HEAD" do
    name = legacy_worktree
    checkout = File.join(@dir, "checkout")
    FileUtils.mkdir_p(File.join(@dir, "gitdir"))
    FileUtils.mkdir_p(checkout)
    File.write(File.join(@dir, "gitdir", "HEAD"), "ref: refs/heads/feat/x\n")
    File.write(File.join(checkout, ".git"), "gitdir: #{File.join(@dir, "gitdir")}\n")
    File.write(path(name), File.read(path(name)).sub(/^.*Worktree — .*\n/, "").sub(%r{^root: .*$}, "root: #{checkout}"))

    expect(adopt.call([name]).first).to include("outcome" => "adopted", "match" => "approx")
    expect(writer.record(name).inputs).to include(project_name: "myapp", worktree_branch: "feat/x")
    expect(status.row(name)).to have_attributes(state: "modified", approx: true)
    expect(status.row(name).to_h).to include("approx" => true)
  end

  it "falls back to the directory name for the branch when the checkout is not readable" do
    name = legacy_worktree
    File.write(path(name), File.read(path(name)).sub(/^.*Worktree — .*\n/, ""))

    adopt.call([name])

    expect(writer.record(name).inputs).to include(worktree_branch: "PROJ-123", project_name: "myapp")
  end

  it "takes only an absolute path in the header as the config path" do
    legacy_project
    File.write(path("myapp"), File.read(path("myapp")).sub(/\A# .*$/, "# not a path, just a comment"))

    adopt.call(["myapp"])

    expect(writer.record("myapp").inputs).to include(config_path: path("myapp"))
  end

  it "reads an agent the config does not run as claude" do
    legacy_project
    allow(main_agent).to receive(:kind).and_return("none")

    adopt.call(["myapp"])

    expect(writer.record("myapp").inputs).to include(agent_kind: "claude")
  end

  it "#recover answers the inputs without writing" do
    legacy_project

    expect(adopt.recover("myapp")).to have_attributes(kind: :project, inputs: hash_including(project_name: "myapp", project_root: "/src/my app"))
    expect(adopt.recover("ghost")).to be_nil
    expect(writer.record("myapp")).to be_nil
  end
end
