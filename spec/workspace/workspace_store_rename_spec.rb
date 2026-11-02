require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkspaceStoreRename do
  let(:home) { Dir.mktmpdir("ws-store-rename", "/tmp") }
  let(:checkout) { File.join(home, "src", "proj", ".worktrees", "feat").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:config) { Workspace::Config.new(workspace_dir: home) }
  let(:git) { Workspace::Git.new(output: StringIO.new) }
  let(:project_config) { Workspace::ProjectConfig.new(config: config, git: git, output: StringIO.new) }
  let(:tmux) { Workspace::Tmux.new(config: config) }
  let(:event_log) { Workspace::EventLog.new(config: config, error_output: StringIO.new) }
  let(:state) { Workspace::State.new(config: config, event_log: event_log) }
  let(:live_sessions) { ["proj-wt-feat"] }
  let(:old) { "proj.worktree-feat" }
  let(:new) { "proj.worktree-other" }

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

  def rename
    described_class.new(config: config, project_config: project_config, tmux: tmux, state: state,
      project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) },
      old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other")
  end

  def write(path, text = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def listing(dir)
    Dir.children(dir).sort
  end

  def yml
    <<~YML
      # #{config.config_path_for(old)}

      name: proj-wt-feat
      root: #{checkout}

      on_project_start: |
        tmux resize-pane -t proj-wt-feat:0.0 -y 15%

      windows:
        - workspace-proj-wt-feat:
            panes:
              - ascii-banner "proj-wt-feat"
    YML
  end

  before do
    write(config.config_path_for(old), yml)
    write(config.project_config_path(old), "hooks: {}\n")
    write(config.agent_log_path(old), "old log\n")
    write(File.join(checkout, ".workspace-project"), old)
    state.load
    state[old] = {"iterm_window_id" => 7}
    state.save
  end

  it "renames every store to an unrelated name" do
    outcome = rename.call

    expect(outcome.failed).to eq([])
    expect(outcome.warnings).to eq([])
    expect(outcome.renamed.map { |entry| entry["what"] }).to eq(%w[tmux_session project_settings log state marker tmuxinator_config])
    expect(live_sessions).to eq(["proj-wt-other"])
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.proj.worktree-other.yml"])
    expect(listing(config.workspace_projects_dir)).to eq(["proj.worktree-other.yml"])
    expect(File.read(config.agent_log_path(new))).to start_with("old log\n")
    expect(state.load.to_h).to eq(new => {"iterm_window_id" => 7})
    expect(File.read(File.join(checkout, ".workspace-project"))).to eq(new)
    text = File.read(config.config_path_for(new))
    expect(text).to include("name: proj-wt-other\n", "-t proj-wt-other:0.0", "workspace-proj-wt-other:", "root: #{checkout}")
    expect(text.lines.first).to eq("# #{config.config_path_for(new)}\n")
    expect(text).to include('ascii-banner "proj-wt-feat"')
  end

  it "leaves a marker that names another workspace alone" do
    write(File.join(checkout, ".workspace-project"), "elsewhere")

    rename.call

    expect(File.read(File.join(checkout, ".workspace-project"))).to eq("elsewhere")
  end

  it "holds the config back while a step failed, and a retry finishes" do
    write(config.agent_log_path(new), "taken\n")

    first = rename.call

    expect(first.failed).to eq(["log"])
    expect(first.warnings.first).to start_with("#{old}: log not renamed (")
    expect(first.warnings.last).to include("tmuxinator_config not renamed until the steps above succeed")
    expect(first.renamed.map { |entry| entry["what"] }).to include("tmux_session", "project_settings", "state", "marker")
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.proj.worktree-feat.yml"])

    File.delete(config.agent_log_path(new))
    second = rename.call

    expect(second.failed).to eq([])
    expect(second.warnings).to eq([])
    expect(second.renamed.map { |entry| entry["what"] }).to eq(%w[log tmuxinator_config])
    expect(listing(config.tmuxinator_dir)).to eq(["workspace.proj.worktree-other.yml"])
    expect(File.read(config.agent_log_path(new))).to eq("old log\n")
  end
end
