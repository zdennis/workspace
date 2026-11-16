require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe Workspace::WorkflowReviewRound do
  around do |example|
    Dir.mktmpdir("wf-review-round") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:finished) { [] }
  let(:change) { RecordingRunChange.new(store.runs, finished: finished) }
  let(:tmux) { FakeTmux.new(session_name: "app") }
  let(:panes) { RecordingWorkflowPanes.new }
  let(:readiness) { RecordingPaneReadiness.new(tmux: tmux) }
  let(:revision) { RecordingReviewRevision.new({revision: "rev1", problem: nil}) }
  let(:prompt) { RecordingWorkflowPrompt.new }
  let(:round_dirs) { RecordingReviewTally.new }
  # The project's main agent is Codex: its own tmuxinator config runs nothing else.
  let(:config_path) { File.join(@dir, "app.yml") }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, config_path_for: config_path, agent_pane_command: nil).tap do |config|
      allow(config).to receive(:with_configured_program) { |command, _kind, _workspace| command }
    end
  end
  let(:main_agent) { Workspace::MainAgent.new(project_config: project_config) }
  let(:holder) { {"pid" => 4321, "started" => "Sat Nov 14 11:59:00 2026"} }
  let(:which) { ->(program) { (program == "claude") ? "/usr/local/bin/claude" : nil } }
  let(:error_output) { StringIO.new }
  let(:pending) { {"step" => "plan", "attempt" => 1, "round" => 1} }
  let(:worktree) { File.join(@dir, "checkout") }
  let(:prompt_path) { File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.r1.review.md") }

  def build_runner(tmux: self.tmux, revision: self.revision, round_dirs: self.round_dirs, which: self.which, holder: self.holder)
    described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness, main_agent: main_agent, revision: revision,
      prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, shell: "/bin/zsh", which: which, error_output: error_output, clock: -> { now })
  end

  subject(:runner) { build_runner }

  before do
    File.write(config_path, YAML.dump("name" => "app", "windows" => [{"main" => {"panes" => ["codex --full-auto"]}}]))
    store.runs["wr_1"] = run_hash
  end

  def run_hash(review: {})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => worktree,
     "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"), "state" => "running", "current" => "plan", "pane" => "%3", "reason" => nil,
     "definition" => {"id" => "flow", "steps" => [{"id" => "plan", "produces" => ["plan.md"], "review" => {"from" => %w[skeptic], "need" => 1}}]},
     "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 1,
                            "review" => {"round" => 1, "delivery" => "delivering", "started_at" => "2026-11-14T11:59:00.000Z", "pending" => %w[skeptic],
                                         "redeliveries" => 0, "holder" => holder}.merge(review),
                            "attempts" => [{"n" => 1, "outcome" => "checks_passed"}]}}}
  end

  def round = store.runs["wr_1"]["steps"]["plan"]["review"]

  def opened = tmux.opened_windows

  describe "#call" do
    it "opens a marked window running Claude Code in the checkout, binds it as the reviewer, types the prompt's line and records the delivery" do
      run = runner.call("wr_1", pending)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(opened.size).to eq(1)
      expect(opened.first).to include(session: "app", name: "review-plan", cwd: worktree, env: {"WORKSPACE_REVIEW_RUN" => "wr_1"}, option: "wr_1:plan:1", store: "st0re")
      expect(panes.calls).to eq([
        [:require_daemon, "app"],
        [:bind, {workspace: "app", pane: "%100", run_id: "wr_1", step: "plan", attempt: 1, instructions: prompt_path,
                 artifacts: File.join(worktree, ".workflow", "wr_1"), role: "reviewer", round: 1, relative_to: worktree}],
        [:kick, {workspace: "app", pane: "%100", text: "Read #{prompt_path} and follow it.", fresh: false, run_id: "wr_1"}]
      ])
      expect(readiness.calls).to eq([[:await_ready, "app", "%100", "claude", {window: "@100"}]])
      expect(round).to include("delivery" => nil, "pane" => "%100", "window" => "@100", "revision" => "rev1", "prompt" => prompt_path, "packs" => [],
        "delivered_at" => "2026-11-14T12:00:00.000Z", "holder" => holder)
      expect(change.events).to eq([["wr_1", "review_delivered", {"step" => "plan", "attempt" => 1, "round" => 1, "pane" => "%100", "window" => "@100", "reused" => false}]])
      expect(tmux.killed_windows).to be_empty
    end

    it "starts Claude Code for the review in a project whose main agent is Codex, under a login shell" do
      runner.call("wr_1", pending)

      expect(opened.first[:command]).to eq(["/bin/zsh", "-lc", "claude"])
    end

    it "computes the revision, checks the round's directory and writes the prompt before any window opens" do
      runner.call("wr_1", pending)

      expect(revision.calls.size).to eq(1)
      expect(round_dirs.calls).to eq([[:ensure_round, "wr_1", 1]])
      expect(prompt.calls.map { |call| call.values_at(0, 2, 3, 4, 5) }).to eq([[:review_text, "plan", 1, 1, "rev1"]])
    end

    it "reuses the window already marked for the round, and closes one a round before it left" do
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70},
        {window: "@6", name: "review-plan", review: "wr_1:plan:0", pane: "%60", pid: 60},
        {window: "@5", name: "review-x", review: "wr_2:x:1", pane: "%50", pid: 50}]

      runner.call("wr_1", pending)

      expect(opened).to be_empty
      expect(tmux.killed_windows).to eq(["@6"])
      expect(panes.calls).to include([:unbind, "wr_1", {role: "reviewer", pane: "%60"}])
      expect(panes.calls).not_to include([:unbind, "wr_1", {role: "reviewer"}])
      expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7", keep: true}]])
      expect(round).to include("pane" => "%70", "window" => "@7", "delivery" => nil)
      expect(change.events.last.last).to include("reused" => true)
    end

    describe "a later round" do
      let(:pending) { {"step" => "plan", "attempt" => 2, "round" => 2} }
      let(:later_prompt) { File.join(worktree, ".workflow", "wr_1", "steps", "plan.2.r2.review.md") }

      before do
        hash = run_hash(review: {"round" => 2})
        hash["steps"]["plan"].merge!("review_rounds" => 2, "attempts" => [{"n" => 1, "outcome" => "failed"}, {"n" => 2, "outcome" => "checks_passed"}],
          "review_window" => {"round" => 1, "window" => "@7", "pane" => "%70"})
        store.runs["wr_1"] = hash
      end

      it "carries the window the round before it left over: marks it for this round, binds its reviewer to this round and clears it as the line is typed" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70},
          {window: "@8", name: "review-build", review: "wr_1:build:1", pane: "%80", pid: 80}]

        runner.call("wr_1", pending)

        expect(opened).to be_empty
        expect(tmux.marked_windows).to eq([["@7", "wr_1:plan:2"]])
        expect(tmux.killed_windows).to eq(["@8"])
        expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7"}]])
        expect(panes.calls).to include(
          [:bind, {workspace: "app", pane: "%70", run_id: "wr_1", step: "plan", attempt: 2, instructions: later_prompt,
                   artifacts: File.join(worktree, ".workflow", "wr_1"), role: "reviewer", round: 2, relative_to: worktree}],
          [:kick, {workspace: "app", pane: "%70", text: "Read #{later_prompt} and follow it.", fresh: true, run_id: "wr_1"}]
        )
        expect(round).to include("pane" => "%70", "window" => "@7", "delivery" => nil, "clear_from" => "2026-11-14T12:00:00.000Z")
        expect(store.runs["wr_1"]["steps"]["plan"]).not_to have_key("review_window")
        expect(change.events.last).to eq(["wr_1", "review_delivered", {"step" => "plan", "attempt" => 2, "round" => 2, "pane" => "%70", "window" => "@7",
                                                                       "reused" => false, "cleared" => true}])
      end

      it "records the pane and the clear's start before the line (and its /clear) is typed, so a Stop meanwhile is judged against it" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
        seen = nil
        panes = RecordingWorkflowPanes.new(on_kick: ->(**) { seen = store.runs["wr_1"]["steps"]["plan"]["review"].dup })
        runner = described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness, main_agent: main_agent, revision: revision,
          prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, shell: "/bin/zsh", which: which, error_output: error_output, clock: -> { now })

        runner.call("wr_1", pending)

        expect(seen).to include("pane" => "%70", "clear_from" => "2026-11-14T12:00:00.000Z", "delivery" => "delivering")
      end

      context "whose Claude Code is not ready" do
        let(:readiness) { RecordingPaneReadiness.new(ready: false, tmux: tmux) }

        it "closes, not keeps, a carried window (its agent exited), and says so" do
          tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

          runner.call("wr_1", pending)

          expect(tmux.killed_windows).to eq(["@7"])

          expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7"}]])
          expect(round).to include("delivery" => "failed")
          expect(round).not_to have_key("window")
          expect(round["failure"]["message"]).to include("the window an earlier round left was closed, and the round's next delivery opens a new one")
          expect(round["failure"]["message"]).not_to include("used again")
        end
      end

      it "clears a kept window an earlier delivery carried over but left at a waiting screen, when the round is delivered again in it" do
        store.runs["wr_1"]["steps"]["plan"]["review"].merge!("uncleared" => true, "window" => "@7")
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:2", pane: "%70", pid: 70}]

        runner.call("wr_1", pending)

        expect(panes.calls.last).to eq([:kick, {workspace: "app", pane: "%70", text: "Read #{later_prompt} and follow it.", fresh: true, run_id: "wr_1"}])
        expect(round).not_to have_key("uncleared")
        expect(round).to include("clear_from" => "2026-11-14T12:00:00.000Z")
      end

      context "whose Claude Code waits at a screen" do
        let(:readiness) { RecordingPaneReadiness.new(ready: false, waiting: "trust", tmux: tmux) }

        it "keeps the carried window for the person and marks the round uncleared" do
          tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

          runner.call("wr_1", pending)

          expect(tmux.killed_windows).to be_empty
          expect(round).to include("delivery" => "failed", "window" => "@7", "uncleared" => true)
        end
      end

      it "stores when the daemon confirmed the clear, from the kick's answer" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
        panes = RecordingWorkflowPanes.new(kick: {ok: true, cleared_at: "2026-11-14T12:00:03.000Z"})
        runner = described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness, main_agent: main_agent, revision: revision,
          prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, shell: "/bin/zsh", which: which, error_output: error_output, clock: -> { now })

        runner.call("wr_1", pending)

        expect(round).to include("clear_from" => "2026-11-14T12:00:00.000Z", "cleared_at" => "2026-11-14T12:00:03.000Z", "delivered_at" => "2026-11-14T12:00:00.000Z")
      end

      it "keeps a carried window whose line was refused (a person's turn running), still to be cleared, and carries it again next time" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
        refused = RecordingWorkflowPanes.new(kick: {ok: false, code: "turn_started", message: "a turn has started"})
        runner = described_class.new(store: store, change: change, tmux: tmux, panes: refused, readiness: readiness, main_agent: main_agent, revision: revision,
          prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, shell: "/bin/zsh", which: which, error_output: error_output, clock: -> { now })

        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(round).to include("delivery" => "failed", "window" => "@7", "uncleared" => true)
        expect(round).not_to have_key("pane")

        store.runs["wr_1"]["steps"]["plan"]["review"]["delivery"] = "delivering"
        build_runner.call("wr_1", pending)

        expect(readiness.calls.last).to eq([:await_ready, "app", "%70", "claude", {window: "@7"}])
        expect(panes.calls.last).to include(:kick)
        expect(panes.calls.last.last).to include(fresh: true)
      end

      it "drops the clear marks of an earlier delivery when the round's line goes into a new window" do
        store.runs["wr_1"]["steps"]["plan"]["review"].merge!("clear_from" => "2026-11-14T11:00:00.000Z", "cleared_at" => "2026-11-14T11:00:01.000Z")

        runner.call("wr_1", pending)

        expect(opened.size).to eq(1)
        expect(round).not_to include("clear_from", "cleared_at")
      end

      it "carries the newest earlier round's window and closes the older one" do
        tmux.review_window_list = [{window: "@6", name: "review-plan", review: "wr_1:plan:0", pane: "%60", pid: 60},
          {window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

        runner.call("wr_1", pending)

        expect(tmux.marked_windows).to eq([["@7", "wr_1:plan:2"]])
        expect(tmux.killed_windows).to eq(["@6"])
      end

      it "closes a window it can't mark for this round and opens a new one" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
        tmux.refuse_marks = true

        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to eq(["@7"])
        expect(opened.size).to eq(1)
        expect(panes.calls.last).to eq([:kick, {workspace: "app", pane: "%100", text: "Read #{later_prompt} and follow it.", fresh: false, run_id: "wr_1"}])
      end
    end

    it "keeps the holder a round start recorded on the delivered round" do
      runner.call("wr_1", pending)

      expect(round["holder"]).to eq(holder)
    end

    context "with no agent daemon" do
      let(:panes) { RecordingWorkflowPanes.new(no_daemon: true) }

      it "refuses the round as no_daemon before anything is opened, recording the failure" do
        runner.call("wr_1", pending)

        expect(opened).to be_empty
        expect(revision.calls).to be_empty
        expect(round).to include("delivery" => "failed", "failure" => include("code" => "no_daemon"))
        expect(change.events).to eq([["wr_1", "review_delivery_failed", {"step" => "plan", "attempt" => 1, "round" => 1, "code" => "no_daemon"}]])
      end
    end

    it "records a revision that can't be computed as a failure, opening no window" do
      runner = build_runner(revision: RecordingReviewRevision.new({revision: nil, problem: "the command failed"}))

      runner.call("wr_1", pending)

      expect(opened).to be_empty
      expect(round).to include("delivery" => "failed", "failure" => include("code" => "revision_failed", "message" => /the command failed/))
    end

    it "records a round directory that is not a plain directory as a failure, opening no window" do
      runner = build_runner(round_dirs: RecordingReviewTally.new(ensured: {code: "review_tampered", problem: "reached through a link"}))

      runner.call("wr_1", pending)

      expect(opened).to be_empty
      expect(round["failure"]).to include("code" => "review_tampered")
    end

    context "when the window's agent is never ready" do
      let(:readiness) { RecordingPaneReadiness.new(ready: false, tmux: tmux) }

      it "closes the window, binds nothing and records agent_not_ready, saying a review always runs Claude Code" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to eq(["@100"])
        expect(panes.calls.map(&:first)).not_to include(:bind, :kick)
        expect(round).to include("delivery" => "failed", "failure" => include("code" => "agent_not_ready"))
        expect(round["failure"]["message"]).to include("a review window always runs Claude Code (claude), whatever agent the main pane runs")
        expect(round["failure"]["message"]).not_to include("PATH")
      end

      it "says when Claude Code is not on PATH, as in a project whose main agent is Codex" do
        build_runner(which: ->(_program) {}).call("wr_1", pending)

        expect(round["failure"]["message"]).to include("and claude is not on this process's PATH")
      end
    end

    context "when the window's agent waits at a trust screen" do
      let(:readiness) { RecordingPaneReadiness.new(ready: false, waiting: "trust", tmux: tmux) }

      it "keeps the window for the person and records it on the failed round" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
        expect(round).to include("delivery" => "failed", "window" => "@100", "failure" => include("code" => "agent_not_ready", "message" => /trust screen/))
      end
    end

    context "when a window used again holds an agent that is not ready" do
      let(:readiness) { RecordingPaneReadiness.new(ready: false, tmux: tmux) }

      it "waits without closing it, keeps it on the failed round and leaves its binding" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

        runner.call("wr_1", pending)

        expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7", keep: true}]])
        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
        expect(round).to include("delivery" => "failed", "window" => "@7", "failure" => include("code" => "agent_not_ready", "message" => /used again, was kept/))
      end
    end

    context "when the line is refused as pane_busy with what the pane showed" do
      let(:seen) { {"state" => "working", "changed_by" => "screen"} }
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy\e[2J", reason: "working", seen: seen}) }

      it "keeps reason and seen in the failure and adds them to review_delivery_failed" do
        runner.call("wr_1", pending)

        expect(round["failure"]).to include("code" => "pane_busy", "message" => "busy\\e[2J", "reason" => "working", "seen" => seen)
        expect(change.events.last).to eq(["wr_1", "review_delivery_failed", {"step" => "plan", "attempt" => 1, "round" => 1, "code" => "pane_busy", "reason" => "working", "seen_state" => "working", "seen_changed_by" => "screen"}])
      end
    end

    context "when the line can't be typed into a window used again" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }

      it "keeps the window, its id on the failed round, and its binding" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
        expect(round).to include("delivery" => "failed", "window" => "@7", "failure" => include("code" => "pane_busy"))
        expect(round).not_to have_key("pane")
      end
    end

    it "keeps the window id a kept window left on the round when a delivery again fails before finding a window" do
      store.runs["wr_1"] = run_hash(review: {"window" => "@3"})

      build_runner(revision: RecordingReviewRevision.new({revision: nil, problem: "the command failed"})).call("wr_1", pending)

      expect(round).to include("delivery" => "failed", "window" => "@3")
    end

    it "records the tmux server the review pane is on, so the sweep can tell a restarted server" do
      tmux.server_pid = "777"

      runner.call("wr_1", pending)

      expect(round).to include("pane" => "%100", "server_pid" => "777")
    end

    it "delivers a round whose earlier delivery died between typing its line and the last change into the window it left, without closing it" do
      # A tick took the lapsed mark over: the round is delivering again under this process, with the dead delivery's pane on it.
      store.runs["wr_1"] = run_hash(review: {"pane" => "%70", "window" => "@7", "redeliveries" => 1})
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

      runner.call("wr_1", pending)

      expect(opened).to be_empty
      expect(tmux.killed_windows).to be_empty
      expect(readiness.calls).to eq([[:await_ready, "app", "%70", "claude", {window: "@7", keep: true}]])
      expect(panes.calls.map(&:first)).to eq(%i[require_daemon bind kick])
      expect(round).to include("delivery" => nil, "pane" => "%70", "window" => "@7", "redeliveries" => 1)
    end

    it "leaves a window to a round that stopped in it before its pane was recorded" do
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
      stopping = RecordingReviewTally.new(on_ensure: lambda do
        stored = store.runs["wr_1"]
        stored["state"] = "waiting"
        stored["reason"] = {"code" => "review_incomplete", "since" => "2026-11-14T12:00:00Z", "details" => {}}
        stored["steps"]["plan"]["review"]["pane"] = "%70"
      end)

      build_runner(round_dirs: stopping).call("wr_1", pending)

      expect(tmux.killed_windows).to be_empty
      expect(panes.calls.map(&:first)).not_to include(:unbind, :kick)
    end

    context "when the line can't be typed" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }

      it "unbinds the reviewer's pane, closes the window and records the failure, with no pane left on the round" do
        runner.call("wr_1", pending)

        expect(panes.calls.last).to eq([:unbind, "wr_1", {role: "reviewer", pane: "%100"}])
        expect(tmux.killed_windows).to eq(["@100"])
        expect(round).to include("delivery" => "failed", "failure" => include("code" => "pane_busy", "message" => "busy"))
        expect(round).not_to have_key("pane")
        expect(round).not_to have_key("window")
      end
    end

    context "when the run is cancelled while the round is delivered" do
      let(:finished) { ["wr_1"] }

      it "closes the window it made and unbinds its pane, as the first change finds the run ended, and types nothing" do
        runner.call("wr_1", pending)

        expect(opened.size).to eq(1)
        expect(tmux.killed_windows).to eq(["@100"])
        expect(panes.calls.last).to eq([:unbind, "wr_1", {role: "reviewer", pane: "%100"}])
        expect(panes.calls.map(&:first)).not_to include(:kick)
      end
    end

    context "when the run moves to another round while the line is typed" do
      let(:panes) { RecordingWorkflowPanes.new(on_kick: ->(**) { store.runs["wr_1"]["steps"]["plan"]["review"]["round"] = 2 }) }

      it "closes the window and records no delivery" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to eq(["@100"])
        expect(round).not_to have_key("delivered_at")
        expect(change.events).to be_empty
      end
    end

    it "records the pane on the round before the line is typed, so a review Stop that comes first finds it" do
      seen = []
      panes = RecordingWorkflowPanes.new(on_kick: ->(**) { seen << round.slice("pane", "window", "revision", "prompt", "packs", "delivery") })
      described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness, main_agent: main_agent, revision: revision,
        prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, which: which, clock: -> { now }).call("wr_1", pending)

      expect(seen).to eq([{"pane" => "%100", "window" => "@100", "revision" => "rev1", "prompt" => prompt_path, "packs" => [], "delivery" => "delivering"}])
    end

    context "when the review pane's Stop decides the round before the last change" do
      # The round's turn ended and was judged incomplete while the line was still being confirmed: the run stops for
      # a person, the round kept in its window.
      let(:panes) do
        RecordingWorkflowPanes.new(on_kick: lambda do |**|
          stored = store.runs["wr_1"]
          stored["state"] = "waiting"
          stored["reason"] = {"code" => "review_incomplete", "since" => "2026-11-14T12:00:00Z", "details" => {}}
          stored["steps"]["plan"]["review"]["ended_at"] = "2026-11-14T12:00:00Z"
        end)
      end

      it "leaves the window and the round to the stop, and ends no delivery mark" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
        expect(round).to include("pane" => "%100", "delivery" => "delivering", "ended_at" => "2026-11-14T12:00:00Z")
        expect(change.events).to be_empty
      end
    end

    context "when another live process takes the round's delivery over while the line is typed" do
      let(:panes) do
        RecordingWorkflowPanes.new(kick: {ok: false, code: "not_delivered", message: "lost"},
          on_kick: ->(**) { store.runs["wr_1"]["steps"]["plan"]["review"]["holder"] = {"pid" => 999, "started" => "later"} })
      end

      it "leaves the window it reused alone and records no failure" do
        tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]

        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(round).not_to have_key("failure")
      end
    end

    it "takes a holder with this pid but another start time for another process, and does nothing for its round" do
      store.runs["wr_1"] = run_hash(review: {"holder" => holder.merge("started" => "Fri Nov 13 09:00:00 2026")})

      runner.call("wr_1", pending)

      expect(opened).to be_empty
      expect(change.calls).to be_empty
    end

    it "closes no other round's window when another process took this round over before it looked" do
      tmux.review_window_list = [{window: "@6", name: "review-plan", review: "wr_1:plan:0", pane: "%60", pid: 60}]
      taking = RecordingReviewTally.new(on_ensure: -> { store.runs["wr_1"]["steps"]["plan"]["review"]["holder"] = {"pid" => 999, "started" => "later"} })

      build_runner(round_dirs: taking).call("wr_1", pending)

      expect(tmux.killed_windows).to be_empty
      expect(opened).to be_empty
      expect(panes.calls.map(&:first)).to eq([:require_daemon])
    end

    context "when the delivering process is interrupted" do
      let(:readiness) { RecordingPaneReadiness.new(error: Interrupt.new) }

      it "marks the round failed and closes its window, then lets the signal go on" do
        expect { runner.call("wr_1", pending) }.to raise_error(Interrupt)

        expect(round).to include("delivery" => "failed", "failure" => include("code" => "delivery_interrupted"))
        expect(tmux.killed_windows).to eq(["@100"])
      end
    end

    context "when a signal comes just after the last change commits" do
      let(:change) { RecordingRunChange.new(store.runs, raises_after: {2 => Interrupt.new}) }

      it "keeps the delivered round, its window and its reviewer binding, and lets the signal go on" do
        expect { runner.call("wr_1", pending) }.to raise_error(Interrupt)

        expect(round).to include("delivery" => nil, "pane" => "%100", "delivered_at" => "2026-11-14T12:00:00.000Z")
        expect(round).not_to have_key("failure")
        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
      end
    end

    context "when the review pane's Stop is being judged as a failure is recorded" do
      let(:panes) do
        RecordingWorkflowPanes.new(kick: {ok: false, code: "not_delivered", message: "lost"},
          on_kick: ->(**) { store.runs["wr_1"]["steps"]["plan"]["review"]["recompute"] = {"started_at" => "2026-11-14T12:00:00Z", "try" => 1} })
      end

      it "leaves the pane on the round and the window open" do
        runner.call("wr_1", pending)

        expect(round).to include("pane" => "%100", "delivery" => "delivering")
        expect(round).not_to have_key("failure")
        expect(tmux.killed_windows).to be_empty
      end
    end

    context "when a failure can't be recorded and another process took the round over" do
      let(:panes) do
        RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"},
          on_kick: ->(**) { store.runs["wr_1"]["steps"]["plan"]["review"]["holder"] = {"pid" => 999, "started" => "later"} })
      end
      let(:change) { RecordingRunChange.new(store.runs, raises: {2 => Errno::EIO.new("runs/wr_1.json")}) }

      it "leaves the window to the process that holds the round now" do
        runner.call("wr_1", pending)

        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
      end
    end

    context "when a failure can't be recorded and the round already shows this window's pane" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }
      let(:change) { RecordingRunChange.new(store.runs, raises: {2 => Errno::EIO.new("runs/wr_1.json")}) }

      it "closes the window when the pane is only this delivery's own record" do
        runner.call("wr_1", pending)

        expect(round["pane"]).to eq("%100")
        expect(tmux.killed_windows).to eq(["@100"])
        expect(panes.calls.last).to eq([:unbind, "wr_1", {role: "reviewer", pane: "%100"}])
      end

      it "leaves it when the round went on in it" do
        on_kick = lambda do |**|
          stored = store.runs["wr_1"]
          stored["state"] = "waiting"
          stored["reason"] = {"code" => "review_incomplete", "since" => "2026-11-14T12:00:00Z", "details" => {}}
        end
        panes = RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}, on_kick: on_kick)
        described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: readiness, main_agent: main_agent, revision: revision,
          prompt: prompt, round_dirs: round_dirs, holder: -> { holder }, which: which, clock: -> { now }).call("wr_1", pending)

        expect(round["pane"]).to eq("%100")
        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
      end
    end

    it "matches its own holder by pid when the round start could not read a start time" do
      store.runs["wr_1"] = run_hash(review: {"holder" => holder.merge("started" => nil)})

      runner.call("wr_1", pending)

      expect(round).to include("delivery" => nil, "pane" => "%100")
    end

    context "when the last change fails with an error other than run_not_active" do
      let(:change) { RecordingRunChange.new(store.runs, raises: {2 => Errno::EIO.new("runs/wr_1.json")}) }

      it "records the failure, marked typed, keeping the window, its reviewer and the round's pane, so the reviewers' own Stop still decides it" do
        runner.call("wr_1", pending)

        expect(round).to include("delivery" => "failed", "failure" => include("code" => "error", "message" => /runs\/wr_1.json/, "typed" => true),
          "pane" => "%100", "window" => "@100", "delivered_at" => "2026-11-14T12:00:00.000Z")
        expect(tmux.killed_windows).to be_empty
        expect(panes.calls.map(&:first)).not_to include(:unbind)
      end
    end

    context "when the agent daemon gives no answer as the line is typed (it restarted)" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "connection_failed", message: "gone"}) }

      it "records a typed failure and closes nothing, even in a window that was not cleared" do
        runner.call("wr_1", pending)

        expect(round).to include("delivery" => "failed", "pane" => "%100", "window" => "@100", "failure" => include("code" => "connection_failed", "typed" => true))
        expect(tmux.killed_windows).to be_empty
      end
    end

    context "when the line is refused before anything is typed" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }

      it "takes the round's pane off and closes a new window, as before" do
        runner.call("wr_1", pending)

        expect(round).not_to include("pane")
        expect(round["failure"]).not_to have_key("typed")
        expect(tmux.killed_windows).to eq(["@100"])
      end
    end

    it "does nothing for a round another process holds, one waiting for a lock, or one the run left" do
      store.runs["wr_1"] = run_hash(review: {"holder" => {"pid" => 999, "started" => "x"}})
      runner.call("wr_1", pending)
      store.runs["wr_1"] = run_hash(review: {"delivery" => nil, "held" => "waiting_lock"}).merge("state" => "waiting", "reason" => {"code" => "waiting_lock"})
      runner.call("wr_1", pending)
      store.runs["wr_1"] = run_hash
      runner.call("wr_1", pending.merge("round" => 2))

      expect(opened).to be_empty
      expect(panes.calls).to be_empty
      expect(change.calls).to be_empty
    end

    it "refuses a workspace on its own tmux socket as review_custom_socket, reading and closing no window on the default server" do
      tmux = FakeTmux.new(session_name: "app", sockets: {"app" => "custom"})
      tmux.review_window_list = [{window: "@6", name: "review-plan", review: "wr_1:plan:0", pane: "%60", pid: 60}]

      build_runner(tmux: tmux).call("wr_1", pending)

      expect(tmux.opened_windows).to be_empty
      expect(tmux.killed_windows).to be_empty
      expect(revision.calls).to be_empty
      expect(round["failure"]).to include("code" => "review_custom_socket", "message" => /not supported for a workspace on its own tmux socket/)
    end
  end

  describe "#call for a rerun of a round's missing reviewers" do
    let(:pending) { {"step" => "plan", "attempt" => 1, "round" => 1, "revision" => "rev0"} }

    before do
      store.runs["wr_1"] = run_hash(review: {"rerun" => %w[skeptic], "reruns" => 1, "uncleared" => true, "pane" => "%70", "window" => "@7",
                                             "panes" => %w[%70], "revision" => "rev0"})
      tmux.review_window_list = [{window: "@7", name: "review-plan", review: "wr_1:plan:1", pane: "%70", pid: 70}]
    end

    it "judges the round's own revision, writes a prompt for the rerun reviewers only, and clears the window the round ran in" do
      runner.call("wr_1", pending)

      expect(revision.calls).to be_empty
      expect(prompt.calls.map { |call| call.values_at(4, 5, 6) }).to eq([[1, "rev0", {only: %w[skeptic], rerun: 1}]])
      expect(opened).to be_empty
      expect(panes.calls.last).to include(:kick)
      expect(panes.calls.last.last).to include(fresh: true, text: "Read #{File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.r1.rerun1.review.md")} and follow it.")
      expect(round).to include("revision" => "rev0", "panes" => %w[%70], "delivery" => nil, "clear_from" => "2026-11-14T12:00:00.000Z")
      expect(round).not_to include("uncleared")
    end

    it "keeps the earliest clear of the window across deliveries of the round" do
      store.runs["wr_1"]["steps"]["plan"]["review"]["clear_from"] = "2026-11-14T11:59:30.000Z"

      runner.call("wr_1", pending)

      expect(round["clear_from"]).to eq("2026-11-14T11:59:30.000Z")
    end
  end

  describe "#call recording the pane before the line is typed" do
    it "adds the pane to the round's panes and marks when the line went out, so a verdict of an earlier delivery's pane still counts" do
      store.runs["wr_1"] = run_hash(review: {"panes" => %w[%60]})

      runner.call("wr_1", pending)

      expect(round).to include("panes" => %w[%60 %100], "kick_at" => "2026-11-14T12:00:00.000Z")
    end

    context "when a window being cleared refuses the line and the failure can't be recorded" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}) }
      let(:change) { RecordingRunChange.new(store.runs, raises: {2 => Errno::EIO.new("runs/wr_1.json")}) }

      it "leaves the round owing its clear, so the next delivery into the window clears it" do
        tmux.review_window_list = [{window: "@6", name: "review-plan", review: "wr_1:plan:0", pane: "%60", pid: 60}]

        runner.call("wr_1", pending)

        expect(panes.calls.find { |call| call.first == :kick }.last).to include(fresh: true)
        expect(round).to include("uncleared" => true, "pane" => "%60")
      end
    end
  end

  describe "#close" do
    it "closes the round's step's windows of the run up to that round, found by their mark" do
      runner.close("wr_1", {"workspace" => "app", "step" => "plan", "round" => 1, "pane" => nil})

      expect(panes.calls).to eq([[:close_review, "app", "wr_1", {step: "plan", round: 1}]])
    end

    it "closes every window of the run for a step of nil, reading the workspace from the run when none was registered" do
      runner.close("wr_1", {"step" => nil})

      expect(panes.calls).to eq([[:close_review, "app", "wr_1", {step: nil}]])
    end
  end
end
