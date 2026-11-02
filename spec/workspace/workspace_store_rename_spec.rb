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

  it "says nothing about a foreign marker when no new root is given, as the lowercase migration runs" do
    write(File.join(checkout, ".workspace-project"), "elsewhere")

    expect(rename.call.warnings).to eq([])
  end

  it "says nothing about a marker that already names the new name" do
    write(File.join(checkout, ".workspace-project"), new)

    expect(rename.call.warnings).to eq([])
  end

  it "words the held-back warning with a given retry hint, and keeps the default text" do
    write(config.agent_log_path(new), "taken\n")
    expect(rename.call.warnings.last).to end_with("until the steps above succeed; the next agentd start tries again (a name already taken has to be cleared by hand)")

    hinted = described_class.new(config: config, project_config: project_config, tmux: tmux, state: state,
      project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) },
      old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other", retry_hint: "run `workspace rename` again")
    expect(hinted.call.warnings.last).to end_with("until the steps above succeed; run `workspace rename` again")
  end

  describe "a config generated from the real templates" do
    let(:templates) { File.expand_path("../../lib/templates", __dir__) }
    let(:new_root) { File.join(home, "src", "proj", ".worktrees", "other").tap { |dir| FileUtils.mkdir_p(dir) } }

    before do
      FileUtils.mkdir_p(config.tmuxinator_dir)
      FileUtils.cp(File.join(templates, "workspace.project-template.yml"), config.project_template_path)
      FileUtils.cp(File.join(templates, "workspace.project-worktree-template.yml"), config.worktree_template_path)
      FileUtils.rm_f(config.config_path_for(old))
    end

    def store(old:, new:, session:, new_session:, **options)
      described_class.new(config: config, project_config: project_config, tmux: tmux, state: state,
        project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) },
        old: old, new: new, session: session, new_session: new_session, **options)
    end

    it "renames a worktree config everywhere, root and branch included" do
      name = project_config.create_worktree("proj", "feat", checkout, "feat-branch", quiet: true)
      expect(name).to eq(old)
      expect(File.read(config.config_path_for(old))).to include("-t '=proj-wt-feat:'")

      outcome = store(old: old, new: "proj.worktree-feat-2", session: "proj-wt-feat", new_session: "proj-wt-feat-2",
        root: new_root, branch: "feat-branch", new_branch: "feat-2-branch",
        display: "proj feat", new_display: "proj feat 2").call

      expect(outcome.failed).to eq([])
      text = File.read(config.config_path_for("proj.worktree-feat-2"))
      expect(text).to include("name: proj-wt-feat-2\n", "root: #{new_root}\n", "-t '=proj-wt-feat-2:' @workspace proj.worktree-feat-2 ",
        "workspace-proj-wt-feat-2:", "2;workspace-proj-wt-feat-2\\a", 'ascii-banner "proj feat 2"', "Worktree — feat-2-branch (proj)")
      expect(text.lines.first).to eq("# #{config.config_path_for("proj.worktree-feat-2")}\n")
      expect(text).not_to match(/proj-wt-feat(?!-2)/)
      expect(text).not_to include("proj.worktree-feat ", "#{checkout}\n", "feat-branch (")
    end

    it "renames a project config everywhere" do
      project_config.create("proj", checkout)
      expect(File.read(config.config_path_for("proj"))).to include("-t '=proj:'")

      outcome = store(old: "proj", new: "other", session: "proj", new_session: "other", root: new_root,
        display: "proj", new_display: "other").call

      expect(outcome.failed).to eq([])
      text = File.read(config.config_path_for("other"))
      expect(text).to include("name: other\n", "root: #{new_root}\n", "-t '=other:' @workspace other ", "workspace-other:",
        "2;workspace-other\\a", "-t other:0.0", 'ascii-banner "other"', "Ready to work on other'")
      expect(text.sub("root: #{new_root}", "")).not_to match(/\bproj\b/)
    end

    it "keeps root and the banner when none are given" do
      project_config.create_worktree("proj", "feat", checkout, "feat-branch", quiet: true)

      store(old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other").call

      text = File.read(config.config_path_for(new))
      expect(text).to include("root: #{checkout}\n", 'ascii-banner "proj feat"', "Worktree — feat-branch (proj)")
      expect(text).not_to include("proj-wt-feat")
    end

    it "leaves the overlapping feat-2 alone when renaming feat" do
      project_config.create_worktree("proj", "feat", checkout, "feat", quiet: true)
      text = File.read(config.config_path_for(old))
      File.write(config.config_path_for(old), text + "  - tmux send-keys -t '=proj-wt-feat-2:' x\n  - echo proj-wt-feat-2 workspace-proj-wt-feat-2 @workspace proj.worktree-feat-2\n")

      store(old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other", root: new_root, branch: "feat", new_branch: "other", display: "proj feat", new_display: "proj other").call

      result = File.read(config.config_path_for(new))
      expect(result).to include("-t '=proj-wt-feat-2:' x", "echo proj-wt-feat-2 workspace-proj-wt-feat-2 @workspace proj.worktree-feat-2")
      expect(result.gsub("feat-2", "")).not_to include("feat")
    end

    it "does not match a new session that holds the workspace- prefix a second time" do
      project_config.create_worktree("proj", "feat", checkout, "feat", quiet: true)

      store(old: old, new: new, session: "proj-wt-feat", new_session: "workspace-proj-wt-feat").call

      text = File.read(config.config_path_for(new))
      expect(text).to include("-t '=workspace-proj-wt-feat:'")
      expect(text).not_to include("workspace-workspace-proj-wt-feat:'")
    end

    it "finds the marker in the new root of a checkout that moved" do
      project_config.create_worktree("proj", "feat", checkout, "feat", quiet: true)
      write(File.join(new_root, ".workspace-project"), old)

      store(old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other", root: new_root).call

      expect(File.read(File.join(new_root, ".workspace-project")).strip).to eq(new)
    end

    it "warns about a marker naming neither name when a new root is given" do
      project_config.create_worktree("proj", "feat", checkout, "feat", quiet: true)
      write(File.join(new_root, ".workspace-project"), "elsewhere")

      outcome = store(old: old, new: new, session: "proj-wt-feat", new_session: "proj-wt-other", root: new_root).call

      expect(outcome.warnings.size).to eq(1)
      expect(outcome.warnings.first).to include("marker", '"elsewhere"', "neither #{old} nor #{new}")
    end
  end
end
