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
      attr_accessor :after_open, :after_kill

      def open_window(...) = super.tap { after_open&.call }

      def kill_window(...) = super.tap { after_kill&.call }
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

  let(:panes) { RecordingWorkflowPanes.new }
  let(:runner) do
    described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: RecordingPaneReadiness.new(tmux: tmux),
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

  describe "a window a rejected round kept" do
    let(:kept) { {"round" => 1, "window" => "@7", "pane" => "%7"} }

    before do
      step_hash.merge!("review_rounds" => 1, "review_window" => kept, "attempts" => [{"n" => 1}, {"n" => 2}])
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%7", pid: 1, store: nil}]
    end

    context "whose reviewer is between turns" do
      let(:panes) { RecordingWorkflowPanes.new(quiet: ["%7"]) }

      it "is killed and unbound, and a warm window for the next round takes its slot" do
        recorded = runner.prewarm(run, "plan", 2)

        expect(panes.calls).to eq([[:quiet?, "app", "%7"], [:unbind, "wr_1", {role: "reviewer", pane: "%7"}]])
        expect(tmux.killed_windows).to eq(["@7"])
        expect(tmux.opened_windows.map { |each| each[:option] }).to eq(["wr_1:plan:2"])
        expect(slot).to eq(recorded)
        expect(slot).to include("round" => 2, "window" => "@100", "pane" => "%100", "warm" => true)
      end

      it "records nothing, and kills the window it opened, when the slot changed during the open" do
        tmux.after_open = -> { store.runs["wr_1"]["steps"]["plan"]["review_window"] = {"round" => 1, "window" => "@9", "pane" => "%9"} }
        expect(runner.prewarm(run, "plan", 2)).to be_nil
        expect(tmux.killed_windows).to eq(%w[@7 @100])
        expect(slot["window"]).to eq("@9")
      end

      [
        ["the step moved to reviewing", ->(state) { state["state"] = "reviewing" }],
        ["its slot changed", ->(state) { state["review_window"] = {"round" => 1, "window" => "@9", "pane" => "%9"} }]
      ].each do |label, move|
        it "is left, nothing killed or unbound, when #{label} between dispatch and the follow-up" do
          as_dispatched = run
          move.call(store.runs["wr_1"]["steps"]["plan"])
          expect(runner.prewarm(as_dispatched, "plan", 2)).to be_nil
          expect(panes.calls.map(&:first)).to eq([:quiet?])
          expect(tmux.killed_windows).to be_empty
          expect(tmux.opened_windows).to be_empty
        end
      end

      it "is left when tmux refuses its kill" do
        allow(tmux).to receive(:kill_window).and_return(false)
        expect(runner.prewarm(run, "plan", 2)).to be_nil
        expect(panes.calls.map(&:first)).to eq([:quiet?])
        expect(tmux.opened_windows).to be_empty
        expect(slot).to eq(kept)
      end
    end

    # A reviewer at work or waiting, or a daemon that can't say (WorkflowPanes#quiet? answers false for each).
    it "is left for the next round's carried path when the daemon does not show its reviewer between turns" do
      expect(runner.prewarm(run, "plan", 2)).to be_nil
      expect(panes.calls).to eq([[:quiet?, "app", "%7"]])
      expect(tmux.killed_windows).to be_empty
      expect(tmux.opened_windows).to be_empty
      expect(slot).to eq(kept)
    end
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

  describe "#close_warm" do
    let(:warm_slot) { {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true} }

    before do
      store.runs["wr_1"]["current"] = "build"
      store.runs["wr_1"]["definition"]["steps"] << {"id" => "build", "produces" => []}
      store.runs["wr_1"]["steps"]["build"] = {"state" => "running", "attempts" => [{"n" => 1}]}
      step_hash["review_window"] = warm_slot
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%7", pid: 1, store: nil},
        {window: "@8", name: "review-other", review: "wr_2:plan:1", pane: "%8", pid: 1, store: nil}]
    end

    it "kills a step's warm window by its id and drops its slot once the run left the step" do
      after = runner.close_warm(run)
      expect(tmux.killed_windows).to eq(["@7"])
      expect(slot).to be_nil
      expect(after.steps["plan"].to_h).not_to have_key("review_window")
    end

    it "kills no window whose id tmux now lists under another mark, and drops the slot" do
      tmux.review_window_list = [{window: "@7", name: "review-x", review: "wr_9:x:1", pane: "%7", pid: 1, store: nil}]
      runner.close_warm(run)
      expect(tmux.killed_windows).to be_empty
      expect(slot).to be_nil
    end

    it "kills nothing and keeps the slot when tmux can't list the windows" do
      tmux.review_windows_unreadable = true
      runner.close_warm(run)
      expect(tmux.killed_windows).to be_empty
      expect(slot).to eq(warm_slot)
    end

    it "leaves the current step's warm window and a kept, not warm, window alone" do
      store.runs["wr_1"]["current"] = "plan"
      runner.close_warm(run)
      store.runs["wr_1"]["current"] = "build"
      step_hash["review_window"] = warm_slot.except("warm")
      runner.close_warm(run)
      expect(tmux.killed_windows).to be_empty
      expect(change.calls).to be_empty
    end

    it "keeps a slot the step got back, or that changed, before the drop" do
      tmux.after_kill = -> { store.runs["wr_1"]["current"] = "plan" }
      runner.close_warm(run)
      expect(tmux.killed_windows).to eq(["@7"])
      expect(slot).to eq(warm_slot)
    end

    it "answers the run as read when the change fails" do
      change = RecordingRunChange.new(store.runs, finished: %w[wr_1])
      runner = described_class.new(store: store, change: change, tmux: tmux, panes: RecordingWorkflowPanes.new, readiness: RecordingPaneReadiness.new(tmux: tmux),
        main_agent: Workspace::MainAgent.new(project_config: project_config), revision: nil, prompt: nil, round_dirs: nil, holder: -> {}, home: home)
      expect(runner.close_warm(run).id).to eq("wr_1")
      expect(slot).to eq(warm_slot)
    end
  end
end

RSpec.describe Workspace::WorkflowReviewRound, "#call into a warm window" do
  around do |example|
    Dir.mktmpdir("wf-review-warm") do |dir|
      @dir = dir
      example.run
    end
  end

  # Answers each wait in turn from +answers+ ([ready, waiting screen], or an error to raise), and calls +on_wait+ first.
  let(:readiness_class) do
    Class.new(RecordingPaneReadiness) do
      def initialize(answers:, tmux:, on_wait: nil)
        super(tmux: tmux)
        @answers = answers
        @on_wait = on_wait
      end

      def await_ready(name, pane, kind, window: nil, keep: false)
        answer = @answers.shift || [true, nil]
        @on_wait&.call
        if answer.is_a?(Exception)
          @calls << [:await_ready, name, pane, kind, keep ? {window: window, keep: true} : {window: window}]
          raise answer
        end
        @ready, @waiting = answer
        super
      end
    end
  end

  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:tmux) { FakeTmux.new(session_name: "app") }
  let(:panes) { RecordingWorkflowPanes.new }
  let(:answers) { [] }
  let(:on_wait) { nil }
  let(:readiness) { readiness_class.new(answers: answers, tmux: tmux, on_wait: on_wait) }
  let(:prompt) { RecordingWorkflowPrompt.new }
  let(:config_path) { File.join(@dir, "app.yml") }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, config_path_for: config_path, agent_pane_command: nil).tap do |config|
      allow(config).to receive(:with_configured_program) { |command, _kind, _workspace| command }
    end
  end
  let(:worktree) { File.join(@dir, "checkout") }
  let(:home) { File.join(@dir, "home") }
  let(:holder) { {"pid" => 4321, "started" => "Sat Nov 14 11:59:00 2026"} }
  let(:pending) { {"step" => "plan", "attempt" => 1, "round" => 1} }
  let(:warm) { {window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70} }

  let(:runner) do
    described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness,
      main_agent: Workspace::MainAgent.new(project_config: project_config), revision: RecordingReviewRevision.new({revision: "rev1", problem: nil}),
      prompt: prompt, round_dirs: RecordingReviewTally.new, holder: -> { holder }, shell: "/bin/zsh", which: ->(_program) { "/usr/local/bin/claude" },
      error_output: StringIO.new, clock: -> { now }, home: home)
  end

  before do
    FileUtils.mkdir_p([worktree, home])
    File.write(config_path, YAML.dump("name" => "app", "windows" => [{"main" => {"panes" => ["codex --full-auto"]}}]))
    store.runs["wr_1"] = {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => worktree,
                          "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"), "state" => "running", "current" => "plan", "pane" => "%3", "reason" => nil,
                          "definition" => {"id" => "flow", "steps" => [{"id" => "plan", "produces" => ["plan.md"], "review" => {"from" => %w[skeptic], "need" => 1}}]},
                          "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 1,
                                                 "review" => {"round" => 1, "delivery" => "delivering", "started_at" => "2026-11-14T11:59:00.000Z",
                                                              "pending" => %w[skeptic], "redeliveries" => 0, "holder" => holder},
                                                 "review_window" => {"round" => 1, "window" => "@7", "pane" => "%70", "warm" => true,
                                                                     "memory" => runner.memory_digest(worktree), "opened_at" => "2026-11-14T11:50:00.000Z"},
                                                 "attempts" => [{"n" => 1, "outcome" => "checks_passed"}]}}}
    tmux.review_window_list = [warm]
  end

  def step = store.runs["wr_1"]["steps"]["plan"]

  def round = step["review"]

  def kick = panes.calls.find { |call| call.first == :kick }&.last

  def delivered = change.events.find { |event| event[1] == "review_delivered" }&.last

  it "adopts the warm window: no new window, no /clear, no wait for the daemon's row, and review_delivered says warm" do
    runner.call("wr_1", pending)

    expect(tmux.opened_windows).to be_empty
    expect(tmux.killed_windows).to be_empty
    expect(tmux.marked_windows).to be_empty
    expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7", keep: true}]])
    expect(kick).to include(pane: "%70", fresh: false, opened: false)
    expect(round).to include("pane" => "%70", "window" => "@7", "delivery" => nil)
    expect(round).not_to have_key("clear_from")
    expect(round).not_to have_key("cleared_at")
    expect(delivered).to eq({"step" => "plan", "attempt" => 1, "round" => 1, "pane" => "%70", "window" => "@7", "reused" => false, "warm" => true})
  end

  context "while Claude Code in it is waited on" do
    let(:seen) { {} }
    let(:on_wait) { -> { seen.merge!(slot: step["review_window"], calls: panes.calls.map(&:first)) } }

    it "binds and records the pane only at delivery, after the wait" do
      runner.call("wr_1", pending)

      expect(seen[:slot]).to include("window" => "@7", "warm" => true)
      expect(seen[:calls]).not_to include(:bind)
      expect(panes.calls.map(&:first)).to eq(%i[require_daemon bind kick])
      expect(step).not_to have_key("review_window")
    end
  end

  it "tells the adopted round's prompt the slot's opened_at as the time its process started" do
    runner.call("wr_1", pending)

    expect(prompt.calls.last.last[:early_start]).to eq(Time.utc(2026, 11, 14, 11, 50, 0))
  end

  shared_examples "a new window in its place" do |killed|
    it "delivers into a new window, never the warm one" do
      runner.call("wr_1", pending)

      expect(tmux.opened_windows.size).to eq(1)
      expect(tmux.killed_windows).to eq(killed)
      expect(round).to include("window" => "@100", "pane" => "%100", "delivery" => nil)
      expect(kick).to include(pane: "%100", fresh: false, opened: true)
      expect(delivered).to include("reused" => false)
      expect(delivered).not_to have_key("warm")
      expect(prompt.calls.last.last).not_to have_key(:early_start)
    end
  end

  context "when the round now names another model" do
    before do
      store.runs["wr_1"]["definition"]["reviewers"] = {"skeptic" => {"model" => "opus"}}
      step["review_model"] = "sonnet"
    end

    include_examples "a new window in its place", ["@7"]
  end

  context "when a start-up file changed since the window opened" do
    before { File.write(File.join(worktree, "CLAUDE.md"), "edited during the author's turn") }

    include_examples "a new window in its place", ["@7"]
  end

  context "when the warm window is gone from tmux" do
    before { tmux.review_window_list = [] }

    include_examples "a new window in its place", []
  end

  # The warm case decides before the scan, which would take a window with this round's mark as `reused`.
  context "when a window has this round's mark but no slot (its slot not yet written)" do
    before { step.delete("review_window") }

    include_examples "a new window in its place", ["@7"]
  end

  context "when a window has this round's mark and a slot whose digest differs" do
    before { step["review_window"]["memory"] = "0" * 64 }

    include_examples "a new window in its place", ["@7"]
  end

  context "when Claude Code in the warm window is not ready" do
    let(:answers) { [[false, nil], [true, nil]] }

    it "closes it and delivers the round into one new window" do
      runner.call("wr_1", pending)

      expect(tmux.killed_windows).to eq(["@7"])
      expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7", keep: true}], [:await_ready, "app", "%100", "claude", {window: "@100"}]])
      expect(round).to include("window" => "@100", "delivery" => nil)
      expect(delivered).not_to have_key("warm")
      expect(prompt.calls.last.last).not_to have_key(:early_start)
    end
  end

  {"a Workspace::Error" => Workspace::Error.new("no daemon", code: "agent_not_ready"), "a Timeout::Error" => Timeout::Error.new("slow")}.each do |label, error|
    context "when the wait for the warm window raises #{label}" do
      let(:answers) { [error, [true, nil]] }

      it "takes it as not ready: closes it and delivers into one new window, the round not failed" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to eq(["@7"])
        expect(tmux.opened_windows.size).to eq(1)
        expect(round).to include("window" => "@100", "delivery" => nil)
        expect(round).not_to have_key("failure")
      end
    end
  end

  context "when another process takes the round over while the warm window is waited on" do
    let(:answers) { [[false, nil]] }
    let(:on_wait) { -> { round["holder"] = {"pid" => 999, "started" => "later"} } }

    it "leaves the window to that delivery: closes, opens and records nothing" do
      runner.call("wr_1", pending)

      expect(tmux.killed_windows).to be_empty
      expect(tmux.opened_windows).to be_empty
      expect(round).not_to have_key("failure")
      expect(panes.calls.map(&:first)).not_to include(:bind, :kick)
    end
  end

  context "when the window with the slot's id and this round's mark has another pane" do
    before { tmux.review_window_list = [warm.merge(pane: "%71")] }

    include_examples "a new window in its place", ["@7"]
  end

  context "when Claude Code in the warm window waits at an update screen" do
    let(:answers) { [[false, "update"], [true, nil]] }

    it "closes it, not keeps it, and delivers the round into one new window" do
      runner.call("wr_1", pending)

      expect(tmux.killed_windows).to eq(["@7"])
      expect(tmux.opened_windows.size).to eq(1)
      expect(round).to include("window" => "@100", "delivery" => nil)
    end
  end

  context "when neither the warm window nor the new one is ready" do
    let(:answers) { [[false, nil], [false, nil]] }

    it "fails the round as agent_not_ready, on the new window's own readiness" do
      runner.call("wr_1", pending)

      expect(tmux.opened_windows.size).to eq(1)
      expect(tmux.killed_windows).to eq(["@7", "@100"])
      expect(round).to include("delivery" => "failed", "failure" => include("code" => "agent_not_ready", "message" => /review window @100/))
    end
  end

  context "when the line is refused in the warm window" do
    let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }

    it "closes the window as a new one's would be, not keeps it as a reused one" do
      runner.call("wr_1", pending)

      expect(tmux.killed_windows).to eq(["@7"])
      expect(panes.calls).to include([:unbind, "wr_1", {role: "reviewer", pane: "%70"}])
      expect(round).to include("delivery" => "failed", "failure" => include("code" => "pane_busy"))
      expect(round).not_to have_key("window")
    end
  end

  context "in a later round whose warm window is gone" do
    let(:pending) { {"step" => "plan", "attempt" => 2, "round" => 2} }

    before do
      step.merge!("review_rounds" => 2, "attempts" => [{"n" => 1, "outcome" => "failed"}, {"n" => 2, "outcome" => "checks_passed"}])
      step["review"]["round"] = 2
      step["review_window"]["round"] = 2
      tmux.review_window_list = [{window: "@6", name: "review-plan", review: "wr_1:plan:1", pane: "%60", pid: 60}]
    end

    it "still carries the earlier round's window over and clears it" do
      runner.call("wr_1", pending)

      expect(tmux.marked_windows).to eq([["@6", "wr_1:plan:2"]])
      expect(kick).to include(pane: "%60", fresh: true, opened: false)
      expect(delivered).to include("cleared" => true, "carried" => true)
      expect(delivered).not_to have_key("warm")
    end
  end
end
