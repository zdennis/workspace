require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe Workspace::WorkflowReviewRound, "#prewarm" do
  around do |example|
    Dir.mktmpdir("wf-review-prewarm") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:moving_tmux) do
    Class.new(FakeTmux) do
      attr_accessor :after_open

      def open_window(...) = super.tap { after_open&.call }
    end
  end
  let(:tmux) { moving_tmux.new(session_name: "app") }
  let(:config_path) { File.join(@dir, "app.yml") }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, config_path_for: config_path, agent_pane_command: nil).tap do |config|
      allow(config).to receive(:with_configured_program) { |command, _kind, _workspace| command }
    end
  end
  let(:worktree) { File.join(@dir, "checkout") }
  let(:home) { File.join(@dir, "home") }
  let(:review) { {"from" => %w[skeptic], "need" => 1} }
  let(:step_hash) { {"state" => "running", "review_rounds" => 0, "attempts" => [{"n" => 1}]} }
  let(:steps) { [{"id" => "plan", "produces" => ["plan.md"], "review" => review}] }

  let(:runner) do
    described_class.new(store: store, change: change, tmux: tmux, panes: RecordingWorkflowPanes.new, readiness: RecordingPaneReadiness.new(tmux: tmux),
      main_agent: Workspace::MainAgent.new(project_config: project_config), revision: RecordingReviewRevision.new({revision: "rev1", problem: nil}),
      prompt: RecordingWorkflowPrompt.new, round_dirs: RecordingReviewTally.new, holder: -> { {"pid" => 1, "started" => nil} },
      shell: "/bin/zsh", error_output: StringIO.new, clock: -> { now }, home: home)
  end

  before do
    FileUtils.mkdir_p([worktree, home])
    File.write(config_path, YAML.dump("name" => "app", "windows" => [{"main" => {"panes" => ["codex --full-auto"]}}]))
    store.runs["wr_1"] = {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => worktree,
                          "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"), "state" => "running", "current" => "plan", "pane" => "%3", "reason" => nil,
                          "definition" => {"id" => "flow", "steps" => steps}, "steps" => {"plan" => step_hash}}
  end

  def run = store.run("wr_1")

  def slot = store.runs["wr_1"]["steps"]["plan"]["review_window"]

  it "opens one window with the round's mark and records the slot and model" do
    store.runs["wr_1"]["definition"]["reviewers"] = {"skeptic" => {"model" => "opus"}}
    recorded = runner.prewarm(run, "plan", 1)

    expect(tmux.opened_windows.size).to eq(1)
    expect(tmux.opened_windows.first).to include(session: "app", name: "review-plan", cwd: worktree, option: "wr_1:plan:1",
      env: {"WORKSPACE_REVIEW_RUN" => "wr_1"}, store: store.stamp)
    expect(tmux.opened_windows.first[:command].last).to match(/claude.*--model opus/)
    expect(slot).to eq(recorded)
    expect(slot).to include("round" => 1, "window" => "@100", "pane" => "%100", "warm" => true, "opened_at" => "2026-11-14T12:00:00.000Z")
    expect(slot["memory"]).to match(/\A\h{64}\z/)
    expect(store.runs["wr_1"]["steps"]["plan"]["review_model"]).to eq("opus")
    expect(change.events).to be_empty
  end

  it "marks the window for the round after those already started" do
    step_hash["review_rounds"] = 1
    runner.prewarm(run, "plan", 1)
    expect(tmux.opened_windows.first[:option]).to eq("wr_1:plan:2")
    expect(slot["round"]).to eq(2)
  end

  context "when it opens nothing" do
    after do
      expect(tmux.opened_windows).to be_empty
      expect(slot).to eq(step_hash["review_window"])
    end

    it "skips a step with no review:" do
      steps.first.delete("review")
      expect(runner.prewarm(run, "plan", 1)).to be_nil
    end

    it "skips a fan_out sibling" do
      steps.first["group"] = "fan"
      expect(runner.prewarm(run, "plan", 1)).to be_nil
    end

    context "with a custom tmux socket" do
      let(:tmux) { FakeTmux.new(session_name: "app", sockets: {"app" => "custom"}) }

      it "skips" do
        expect(runner.prewarm(run, "plan", 1)).to be_nil
      end
    end

    it "skips a step whose rounds are spent" do
      step_hash["review_rounds"] = Workspace::WorkflowReviewSpec::DEFAULT_MAX_ROUNDS
      expect(runner.prewarm(run, "plan", 1)).to be_nil
    end

    it "skips a step whose review_window is still open" do
      step_hash["review_window"] = {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true}
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%7", pid: 1, store: nil}]
      expect(runner.prewarm(run, "plan", 1)).to be_nil
    end
  end

  it "replaces a slot whose window is gone" do
    step_hash["review_window"] = {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true}
    runner.prewarm(run, "plan", 1)
    expect(slot["window"]).to eq("@100")
  end

  [
    ["another step is current", ->(hash) { hash["current"] = "build" }],
    ["the step is reviewing", ->(hash) { hash["steps"]["plan"]["state"] = "reviewing" }],
    ["another attempt started", ->(hash) { hash["steps"]["plan"]["attempts"] << {"n" => 2} }],
    ["a round started", ->(hash) { hash["steps"]["plan"]["review_rounds"] = 1 }],
    ["another dispatch recorded its own window", ->(hash) { hash["steps"]["plan"]["review_window"] = {"round" => 1, "window" => "@9", "pane" => "%9", "warm" => true} }]
  ].each do |label, move|
    it "records nothing and kills only the window it opened when #{label} during the open" do
      tmux.review_window_list = [{window: "@5", name: "review-other", review: "wr_1:other:1", pane: "%5", pid: 1, store: nil}]
      tmux.after_open = -> { move.call(store.runs["wr_1"]) }
      before_step = Marshal.load(Marshal.dump(store.runs["wr_1"]["steps"]["plan"]))
      expect(runner.prewarm(run, "plan", 1)).to be_nil
      expect(tmux.killed_windows).to eq(["@100"])
      expect(slot&.fetch("window")).not_to eq("@100")
      expect(store.runs["wr_1"]["steps"]["plan"].except("review_window").except("state", "attempts", "review_rounds")).to eq(before_step.except("state", "attempts", "review_rounds", "review_window"))
    end
  end

  it "leaves no slot when tmux opens no window" do
    allow(tmux).to receive(:open_window).and_return(nil)
    expect(runner.prewarm(run, "plan", 1)).to be_nil
    expect(slot).to be_nil
    expect(tmux.killed_windows).to be_empty
  end

  it "opens nothing when tmux can't be read about the recorded window" do
    step_hash["review_window"] = {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true}
    tmux.review_windows_unreadable = true
    expect(runner.prewarm(run, "plan", 1)).to be_nil
    expect(tmux.opened_windows).to be_empty
  end

  {
    "a Workspace::Error" => Workspace::Error.new("boom", code: "lock_failed"),
    "a SystemCallError" => Errno::EIO.new("disk")
  }.each do |label, error|
    it "kills the window and raises again when the change raises #{label}" do
      raising = RecordingRunChange.new(store.runs, raises: {1 => error})
      runner = described_class.new(store: store, change: raising, tmux: tmux, panes: RecordingWorkflowPanes.new, readiness: RecordingPaneReadiness.new(tmux: tmux),
        main_agent: Workspace::MainAgent.new(project_config: project_config), revision: nil, prompt: nil, round_dirs: nil, holder: -> {}, home: home)
      expect { runner.prewarm(run, "plan", 1) }.to raise_error(error.class)
      expect(tmux.killed_windows).to eq(["@100"])
      expect(slot).to be_nil
    end
  end

  it "kills the window and records nothing when the run has ended" do
    change = RecordingRunChange.new(store.runs, finished: %w[wr_1])
    runner = described_class.new(store: store, change: change, tmux: tmux, panes: RecordingWorkflowPanes.new, readiness: RecordingPaneReadiness.new(tmux: tmux),
      main_agent: Workspace::MainAgent.new(project_config: project_config), revision: nil, prompt: nil, round_dirs: nil, holder: -> {}, home: home)
    expect(runner.prewarm(run, "plan", 1)).to be_nil
    expect(tmux.killed_windows).to eq(["@100"])
  end

  describe "the memory digest" do
    def digest
      store.runs["wr_1"]["steps"]["plan"].delete("review_window")
      tmux.review_window_list = []
      runner.prewarm(run, "plan", 1)["memory"]
    end

    it "is read before the window opens" do
      original = digest
      tmux.after_open = -> { File.write(File.join(worktree, "CLAUDE.md"), "written during the open") }
      expect(digest).to eq(original)
      tmux.after_open = nil
      expect(digest).not_to eq(original)
    end

    it "is stable while no file changes" do
      expect(digest).to eq(digest)
    end

    {
      "a worktree CLAUDE.md" => ["checkout", "CLAUDE.md"],
      "a .claude/CLAUDE.md" => ["checkout", ".claude", "CLAUDE.md"],
      "a settings file" => ["checkout", ".claude", "settings.local.json"],
      "an .mcp.json" => ["checkout", ".mcp.json"],
      "a skill" => ["checkout", ".claude", "skills", "x", "SKILL.md"],
      "a command" => ["checkout", ".claude", "commands", "y.md"],
      "an agent" => ["checkout", ".claude", "agents", "z.md"],
      "the user's CLAUDE.md" => ["home", ".claude", "CLAUDE.md"],
      "the user's settings.json" => ["home", ".claude", "settings.json"]
    }.each do |label, path|
      it "changes when #{label} is created and again when it is edited" do
        original = digest
        file = File.join(@dir, *path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "one")
        created = digest
        File.write(file, "two")
        expect([original, created, digest].uniq.size).to eq(3)
      end
    end

    it "changes when a file under a symlinked skill directory is edited" do
      elsewhere = File.join(@dir, "shared-skill")
      FileUtils.mkdir_p([elsewhere, File.join(worktree, ".claude", "skills")])
      File.symlink(elsewhere, File.join(worktree, ".claude", "skills", "linked"))
      original = digest
      File.write(File.join(elsewhere, "SKILL.md"), "one")
      expect(digest).not_to eq(original)
    end

    it "changes when a symlinked file's target is created" do
      FileUtils.mkdir_p(File.join(worktree, ".claude", "agents"))
      link = File.join(worktree, ".claude", "agents", "a.md")
      File.symlink(File.join(@dir, "target.md"), link)
      dangling = digest
      File.write(File.join(@dir, "target.md"), "x")
      expect(digest).not_to eq(dangling)
    end

    it "ends on a symlink cycle" do
      FileUtils.mkdir_p(File.join(worktree, ".claude", "skills", "a"))
      File.symlink(File.join(worktree, ".claude", "skills"), File.join(worktree, ".claude", "skills", "a", "loop"))
      expect(digest).to match(/\A\h{64}\z/)
    end

    it "changes when a dotfile under a listed directory is created" do
      original = digest
      FileUtils.mkdir_p(File.join(worktree, ".claude", "rules"))
      File.write(File.join(worktree, ".claude", "rules", ".hidden.md"), "x")
      expect(digest).not_to eq(original)
    end

    it "changes when an unreadable file is created, and when it becomes readable" do
      file = File.join(worktree, "CLAUDE.md")
      original = digest
      File.write(file, "x")
      File.chmod(0o000, file)
      unreadable = digest
      File.chmod(0o644, file)
      expect([original, unreadable, digest].uniq.size).to eq(3)
    end

    it "changes when the CLAUDE.md of a directory above the checkout is edited" do
      original = digest
      File.write(File.join(@dir, "CLAUDE.md"), "one")
      created = digest
      File.write(File.join(@dir, "CLAUDE.md"), "two")
      expect([original, created, digest].uniq.size).to eq(3)
    end

    it "ignores a file outside the listed ones" do
      original = digest
      File.write(File.join(worktree, "README.md"), "x")
      expect(digest).to eq(original)
    end
  end
end
