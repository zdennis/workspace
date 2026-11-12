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

  it "rewrites the config in place when only the branch changes, the name staying" do
    path = config.config_path_for(old)
    write(path, "name: proj-wt-feat\nroot: #{checkout}\n  - echo 'Worktree — a/b (x)'\n")
    state.load
    state[old] = {"unique_id" => "u"}
    state.save

    outcome = described_class.new(config: config, project_config: project_config, tmux: tmux, state: state,
      project_catalog_factory: -> { Workspace::ProjectCatalog.new(project_config: project_config, git: git) },
      old: old, new: old, session: "proj-wt-feat", new_session: "proj-wt-feat", root: checkout, branch: "a/b", new_branch: "a-b").call

    expect(outcome.failed).to eq([])
    expect(File.read(path)).to include("Worktree — a-b (x)")
    expect(state.load.to_h).to have_key(old)
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

  context "after a process was killed swapping the config" do
    let(:from) { config.config_path_for(old) }
    let(:to) { config.config_path_for(new) }
    let(:held) { File.join(config.tmuxinator_dir, ".workspace.#{old}.yml.4242.old") }
    let(:staged) { File.join(config.tmuxinator_dir, ".workspace.#{new}.yml.4242.tmp") }

    it "brings the held config back and finishes" do
      File.rename(from, held)
      write(staged, "partial")

      expect(rename.call.failed).to eq([])

      expect(listing(config.tmuxinator_dir)).to eq(["workspace.proj.worktree-other.yml"])
      expect(File.read(to)).to include("name: proj-wt-other\n")
    end

    it "clears the held config when the new one was already in place" do
      File.write(to, "name: done\n")
      File.rename(from, held)

      rename.call

      expect(listing(config.tmuxinator_dir)).to eq(["workspace.proj.worktree-other.yml"])
      expect(File.read(to)).to eq("name: done\n")
    end

    it "leaves another workspace's files alone" do
      other = File.join(config.tmuxinator_dir, ".workspace.proj.worktree-feat-2.yml.4242.old")
      write(other, "theirs")

      rename.call

      expect(File.read(other)).to eq("theirs")
    end
  end

  it "stages the new config under the name it reports" do
    expect(described_class.staged_name("workspace.a.yml", 12)).to eq(".workspace.a.yml.12.tmp")
    expect(described_class.staged_name("workspace.a.yml").bytesize).to eq(".workspace.a.yml..tmp".bytesize + described_class::PID_DIGITS)
  end

  describe "a config generated from the real templates" do
    let(:templates) { File.join(PROJECT_ROOT, "lib", "templates") }
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

    describe "the render record" do
      let(:carry_failures) { [] }
      let(:writer_class) do
        failures = carry_failures
        Class.new(Workspace::TmuxinatorConfigWriter) do
          define_method(:carry_record) do |*args, **options, &block|
            error = failures.shift
            raise error if error
            super(*args, **options, &block)
          end
        end
      end
      let(:writer) { writer_class.new(config: config) }
      let(:renamed) { "proj.worktree-other" }

      def store_worktree
        store(old: old, new: renamed, session: "proj-wt-feat", new_session: "proj-wt-other", root: new_root,
          branch: "feat-branch", new_branch: "other-branch", display: "proj feat", new_display: "proj other", writer: writer)
      end

      def render_files
        Dir.children(config.render_state_dir).sort
      end

      before { project_config.create_worktree("proj", "feat", checkout, "feat-branch", quiet: true) }

      it "moves under the new name, says the new names and matches the rewritten config" do
        outcome = store_worktree.call

        expect(outcome.failed).to eq([])
        expect(render_files).to eq(["#{renamed}.json"])
        expect(writer.record(renamed).inputs).to include(workspace_name: renamed, tmux_session_name: "proj-wt-other",
          worktree_path: new_root, worktree_branch: "other-branch", display_name: "proj other",
          config_path: config.config_path_for(renamed), project_name: "proj", agent_kind: "claude")
        expect(writer.current?(renamed)).to be(true)
        expect(writer.record(old)).to be_nil
      end

      it "keeps a config edited by hand reading as edited" do
        File.write(config.config_path_for(old), "#{File.read(config.config_path_for(old))}# mine\n")

        store_worktree.call

        expect(writer.record(renamed)).not_to be_nil
        expect(writer.current?(renamed)).to be(false)
      end

      it "finishes on retry a record moved but not rewritten, the config still under the old name" do
        carry_failures << Errno::ENOSPC

        outcome = store_worktree.call

        expect(outcome.failed).to eq(["tmuxinator_config"])
        expect(described_class.listed?(config.config_path_for(old))).to be(true)
        expect(render_files).to eq(["#{renamed}.json"])
        expect(writer.record(renamed)).to be_nil
        expect(writer.record(old)).to be_nil

        expect(store_worktree.call.failed).to eq([])
        expect(writer.record(renamed).inputs).to include(workspace_name: renamed, worktree_path: new_root)
        expect(writer.current?(renamed)).to be(true)
      end

      it "finishes on retry a record rewritten when the config swap then failed" do
        staged = File.join(config.tmuxinator_dir, described_class.staged_name(File.basename(config.config_path_for(renamed)), Process.pid))
        allow(File).to receive(:rename).and_call_original
        failed = false
        allow(File).to receive(:rename).with(staged, config.config_path_for(renamed)).and_wrap_original do |original, *args|
          next original.call(*args) if failed
          failed = true
          raise Errno::EIO
        end

        expect(store_worktree.call.failed).to eq(["tmuxinator_config"])
        expect(described_class.listed?(config.config_path_for(old))).to be(true)
        expect(render_files).to eq(["#{renamed}.json"])

        expect(store_worktree.call.failed).to eq([])
        expect(writer.record(renamed).inputs).to include(workspace_name: renamed, tmux_session_name: "proj-wt-other")
        expect(writer.current?(renamed)).to be(true)
      end

      it "replaces a record left under the new name by a workspace that no longer has a config" do
        write(writer.record_path(renamed), "{}")

        store_worktree.call

        expect(render_files).to eq(["#{renamed}.json"])
        expect(writer.current?(renamed)).to be(true)
      end

      it "moves the record of a rename that changes only case" do
        FileUtils.rm_f(config.config_path_for(old))
        FileUtils.rm_rf(config.render_state_dir)
        writer.write("Proj", "name: Proj\n", kind: :project, template: "default", template_sha: "abc",
          inputs: {project_name: "Proj", workspace_name: "Proj", project_root: checkout})

        allow(File).to receive(:delete).and_call_original
        outcome = store(old: "Proj", new: "proj", session: "Proj", new_session: "proj", writer: writer).call

        expect(File).not_to have_received(:delete).with(writer.record_path("proj"))
        expect(outcome.failed).to eq([])
        expect(render_files).to eq(["proj.json"])
        expect(writer.record("proj").inputs).to include(workspace_name: "proj", project_name: "proj", project_root: checkout)
        expect(writer.current?("proj")).to be(true)
      end
    end
  end
end
