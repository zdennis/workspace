require "spec_helper"
require "tmpdir"
require "yaml"

# The warm review window over a whole engine: a real run store in a temporary directory, the real WorkflowReviewRound
# built through `review_runner:` with `prewarm: true` (as `build_cli` builds it), over FakeTmux, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine, "warm review window" do
  around do |example|
    Dir.mktmpdir("wf-engine-prewarm") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after { EventKeysCheck.verify!(runs_dir, archive_dir) }

  let(:worktree) { File.join(@dir, "app") }
  let(:home) { File.join(@dir, "home") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 11, 14, 12, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { InterruptibleWorkflowPanes.new }
  # Closes by the mark as WorkflowPanes#close_review does, so a close the engine registers kills the window over FakeTmux.
  let(:closing_panes) do
    Class.new(RecordingWorkflowPanes) do
      attr_accessor :fake_tmux

      def close_review(workspace, run_id, step: nil, round: nil)
        super
        fake_tmux.review_windows("app").filter_map do |window|
          run, marked_step, marked_round = Workspace::WorkflowPanes.parse_review_mark(window[:review])
          next if run != run_id || (step && marked_step != step) || (round.is_a?(Integer) && marked_round > round)
          window[:window] if fake_tmux.kill_window(window[:window])
        end
      end
    end
  end
  let(:review_panes) { closing_panes.new.tap { |panes| panes.fake_tmux = tmux } }
  # Runs +before_open+ once, just before the next window opens, and +after_open+ once, just after, so a spec can put
  # the run where a race leaves it.
  let(:racing_tmux) do
    Class.new(FakeTmux) do
      attr_accessor :before_open, :after_open

      def open_window(...)
        hook = before_open
        self.before_open = nil
        hook&.call
        opened = super
        hook = after_open
        self.after_open = nil
        hook&.call
        opened
      end
    end
  end
  let(:tmux) { racing_tmux.new(session_name: "app") }
  let(:tally) { RecordingReviewTally.new }
  let(:holder) { {"pid" => 4321, "started" => "Sat Nov 14 11:59:00 2026"} }
  let(:config_path) { File.join(@dir, "app.yml") }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, config_path_for: config_path, agent_pane_command: nil).tap do |config|
      allow(config).to receive(:with_configured_program) { |command, _kind, _workspace| command }
    end
  end
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, round_snapshot: {"head" => "1" * 40, "tree_sha256" => "t" * 64}, round_check: nil) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }

  # One revision for the round (at delivery) and the engine (at the round's end), moved by the spec; each ask is recorded.
  let(:revision_now) { ["revA"] }
  let(:revision_calls) { [] }
  let(:revision_source) do
    lambda do |run:, step:, stop_when: nil|
      revision_calls << [Workspace::WorkflowRun.from_h(run).id, step["id"], revision_now.first]
      {revision: revision_now.first, problem: nil}
    end
  end

  def build_engine(prewarm: true, review_runner: true, review_revision: nil)
    Workspace.build_workflow_engine(review_revision: review_revision, store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {}, workspace_known: ->(_) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), review_tally: tally, round_holder: -> { holder }, prewarm: prewarm,
      review_runner: review_runner && ->(change:, store:, prompt:) do
        Workspace::WorkflowReviewRound.new(store: store, change: change, tmux: tmux, panes: review_panes, readiness: RecordingPaneReadiness.new(tmux: tmux),
          main_agent: Workspace::MainAgent.new(project_config: project_config), revision: review_revision || RecordingReviewRevision.new({revision: "rev1", problem: nil}),
          prompt: prompt, round_dirs: tally, holder: -> { holder }, shell: "/bin/zsh", which: ->(_) { "/usr/local/bin/claude" },
          error_output: StringIO.new, clock: -> { now.first }, home: home)
      end,
      clock: -> { now.first })
  end

  subject(:engine) { build_engine }

  before do
    FileUtils.mkdir_p([worktree, home])
    File.write(config_path, YAML.dump("name" => "app", "windows" => [{"main" => {"panes" => ["claude"]}}]))
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  let(:flow) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      max_attempts: 5
      reviewers:
        skeptic: {prompt: Find what is wrong.}
      steps:
        plan:
          prompt: Write {{artifacts}}/plan.md.
          produces: [plan.md]
          review: [skeptic]
        build:
          prompt: Build it.
    YAML
  end

  def start = engine.start(actor: "person", definition: flow, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")

  def run = stored_run(store, "wr_1")

  def slot = run["steps"]["plan"]["review_window"]

  def lines(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  def author_done
    path = File.join(worktree, ".workflow", "wr_1", "plan.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
  end

  it "opens the window of the plan step's first round once the author's line is typed, and the round adopts it" do
    start

    expect(panes.kicks.size).to eq(1)
    expect(tmux.opened_windows.map { |each| each.slice(:name, :option) }).to eq([{name: "review-plan", option: "wr_1:plan:1"}])
    expect(slot).to include("round" => 1, "window" => "@100", "pane" => "%100", "warm" => true)
    expect(review_panes.calls).to be_empty

    author_done

    expect(tmux.opened_windows.size).to eq(1)
    expect(tmux.killed_windows).to be_empty
    expect(run["steps"]["plan"]["review"]).to include("window" => "@100", "pane" => "%100", "delivery" => nil)
    expect(slot).to be_nil
    expect(lines("review_delivered").last).to include("window" => "@100", "warm" => true, "reused" => false)
    expect(lines("review_delivered").last).not_to have_key("cleared")
  end

  describe "a round that rejects" do
    let(:tally) { RecordingReviewTally.new(outcome: :rejected, reviews: [{"reviewer" => "skeptic", "verdict" => "rejected"}]) }

    def reject_round_1
      start
      author_done
      now[0] += 60
      engine.turn_ended("wr_1", actor: "agent", pane: "%100")
      expect(run["steps"]["plan"]["attempts"].last).to include("n" => 2, "retry_of" => 1)
    end

    def author_done_again
      now[0] += 60
      author_done
    end

    context "with its reviewer between turns" do
      let(:review_panes) { closing_panes.new(quiet: ["%100"]).tap { |panes| panes.fake_tmux = tmux } }

      it "has the kept window replaced by a warm one at the retry's dispatch, and round 2 delivered warm with no /clear" do
        reject_round_1

        expect(tmux.killed_windows).to eq(["@100"])
        expect(review_panes.calls).to include([:unbind, "wr_1", {role: "reviewer", pane: "%100"}])
        expect(slot).to include("round" => 2, "window" => "@101", "pane" => "%101", "warm" => true)

        author_done_again

        expect(tmux.opened_windows.map { |each| each[:option] }).to eq(%w[wr_1:plan:1 wr_1:plan:2])
        expect(run["steps"]["plan"]["review"]).to include("round" => 2, "window" => "@101", "delivery" => nil)
        expect(lines("review_delivered").last).to include("round" => 2, "window" => "@101", "warm" => true, "reused" => false)
        expect(lines("review_delivered").last).not_to have_key("cleared")
        expect(review_panes.calls.select { |call| call.first == :kick }.map { |call| call.last.slice(:pane, :fresh) }).to eq([{pane: "%100", fresh: false}, {pane: "%101", fresh: false}])
      end
    end

    it "keeps the window for round 2's carried path, with a /clear, when its reviewer is not between turns" do
      reject_round_1

      expect(tmux.killed_windows).to be_empty
      expect(slot).to include("round" => 1, "window" => "@100")
      expect(slot).not_to have_key("warm")

      author_done_again

      expect(tmux.opened_windows.size).to eq(1)
      expect(lines("review_delivered").last).to include("round" => 2, "window" => "@100", "carried" => true, "cleared" => true)
      expect(lines("review_delivered").last).not_to have_key("warm")
    end
  end

  describe "with the round's revision recomputed when it ends" do
    let(:engine) { build_engine(review_revision: revision_source) }

    it "refuses a round delivered into the warm window as stale when the checkout moves before its turn ends, and took its revision at delivery" do
      start
      # The warm window is open; nothing has been judged yet, so no revision has been computed at prewarm time.
      expect(slot).to include("warm" => true)
      expect(revision_calls).to be_empty

      # The author's work changes after the window opened and before the line is delivered.
      revision_now[0] = "revB"
      author_done
      expect(lines("review_delivered").last).to include("window" => "@100", "warm" => true)
      expect(run["steps"]["plan"]["review"]).to include("revision" => "revB", "window" => "@100")
      expect(revision_calls).to eq([["wr_1", "plan", "revB"]])

      # The checkout moves while the reviewer works; the round's end recomputes a different revision.
      revision_now[0] = "revC"
      now[0] += 60
      engine.turn_ended("wr_1", actor: "agent", pane: "%100")

      expect(revision_calls.last).to eq(["wr_1", "plan", "revC"])
      expect(lines("review_ended").map { |each| each["outcome"] }).to eq(["stale"])
      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "review_stale")
      expect(run["reason"]["details"]).to include("revision" => "revB", "revision_now" => "revC")
      expect(lines("review_retry")).to be_empty
      expect(tally.calls.map(&:first)).not_to include(:call)
    end

    it "judges the round as for a cold one when the revision is unchanged at its end" do
      start
      author_done
      now[0] += 60
      engine.turn_ended("wr_1", actor: "agent", pane: "%100")

      expect(lines("review_ended").map { |each| each["outcome"] }).to eq(["approved"])
      expect(tally.calls.map(&:first)).to include(:call)
    end

    describe "a rejected round whose retry changed nothing" do
      let(:tally) { RecordingReviewTally.new(outcome: :rejected, reviews: [{"reviewer" => "skeptic", "verdict" => "rejected"}]) }
      let(:review_panes) { closing_panes.new(quiet: ["%100"]).tap { |panes| panes.fake_tmux = tmux } }

      def marked = tmux.review_windows("app").map { |each| each[:window] }

      it "stops review_no_change as for a cold window, with no round spent, and leaves no warm window once the run is cancelled" do
        start
        author_done
        now[0] += 60
        engine.turn_ended("wr_1", actor: "agent", pane: "%100")
        expect(run["steps"]["plan"]["attempts"].last).to include("n" => 2, "retry_of" => 1)
        # Round 2's warm window replaced the kept one at the retry's dispatch.
        expect(slot).to include("round" => 2, "window" => "@101", "warm" => true)

        # The retry rewrites its file but the revision it judges is the one the rejection judged.
        now[0] += 60
        author_done

        expect(run["state"]).to eq("waiting")
        expect(run["reason"]).to include("code" => "review_no_change")
        expect(lines("review_no_change").last).to include("round" => 2, "rejected_round" => 1, "rejected_attempt" => 1)
        expect(lines("review_delivered").map { |each| each["round"] }).to eq([1])

        engine.cancel("wr_1", actor: "person")

        expect(run["state"]).to eq("cancelled")
        expect(marked).to be_empty
        expect(slot).to be_nil
      end
    end
  end

  it "opens none when the author's line was not typed" do
    panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
    start
    expect(tmux.opened_windows).to be_empty
    expect(slot).to be_nil
  end

  it "opens none with prewarm: false, and the round opens its window at delivery" do
    engine = build_engine(prewarm: false)
    engine.start(actor: "person", definition: flow, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    expect(tmux.opened_windows).to be_empty
    path = File.join(worktree, ".workflow", "wr_1", "plan.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
    expect(tmux.opened_windows.size).to eq(1)
    expect(lines("review_delivered").last).not_to have_key("warm")
  end

  it "refuses prewarm: true with no review_runner:" do
    expect { build_engine(review_runner: false) }.to raise_error(ArgumentError, /review_runner/)
  end

  describe "a restart of the step (infra retry, `workflow recover`)" do
    def restart = engine.resume("wr_1", actor: "person", restart_step: true, bound: "idle")

    it "keeps an open warm window" do
      start
      restart
      expect(run["steps"]["plan"]["attempts"].size).to eq(2)
      expect(tmux.opened_windows.size).to eq(1)
      expect(tmux.killed_windows).to be_empty
      expect(slot).to include("window" => "@100", "warm" => true)
    end

    it "opens a new one when the slot's window is gone" do
      start
      tmux.kill_window("@100")
      restart
      expect(tmux.opened_windows.map { |each| each[:option] }).to eq(%w[wr_1:plan:1 wr_1:plan:1])
      expect(slot).to include("window" => "@101", "warm" => true)
    end
  end

  it "has the round open cold when it is delivered before the slot is written, and the late slot write records nothing and kills only its own window" do
    other = {window: "@5", name: "review-other", review: "wr_9:plan:1", pane: "%5", pid: 1, store: nil}
    tmux.review_window_list << other
    # The author's turn ends, and the round is delivered, while the warm window is opening.
    tmux.before_open = -> { author_done }
    start

    # The round's own delivery opened its window first (@100); the warm open that was under way came after it (@101).
    expect(run["steps"]["plan"]["review"]).to include("window" => "@100", "delivery" => nil)
    expect(lines("review_delivered").last).not_to have_key("warm")
    expect(tmux.killed_windows).to eq(["@101"])
    expect(slot).to be_nil
    expect(tmux.review_windows("app").map { |each| each[:window] }).to contain_exactly("@5", "@100")
  end

  it "has the round kill the unslotted window and open cold when the author's turn ends after the open and before the slot write" do
    other = {window: "@5", name: "review-other", review: "wr_9:plan:1", pane: "%5", pid: 1, store: nil}
    tmux.review_window_list << other
    tmux.after_open = -> { author_done }
    start

    # The warm open made @100; the round found it marked with no slot, killed it and delivered into a new @101.
    expect(tmux.opened_windows.map { |each| each[:window] }).to eq(%w[@100 @101])
    expect(run["steps"]["plan"]["review"]).to include("window" => "@101", "delivery" => nil)
    expect(lines("review_delivered").last).not_to have_key("warm")
    # The late slot write records nothing; its kill of @100 is the only other kill, of its own window.
    expect(slot).to be_nil
    expect(tmux.killed_windows.uniq).to eq(["@100"])
    expect(tmux.review_windows("app").map { |each| each[:window] }).to contain_exactly("@5", "@101")
  end

  it "closes a warm window of a step the run has left, at the next dispatch" do
    start
    # The plan step failed and the run went on to build, whose line could not be typed: a resume dispatches it again.
    edit_run(store, "wr_1") do |stored|
      stored["steps"]["plan"]["state"] = "failed"
      stored.merge!("current" => "build", "state" => "waiting",
        "reason" => {"code" => "waiting_you", "since" => "2026-11-14T12:00:00Z", "details" => {"kind" => "dispatch", "step" => "build"}})
    end
    engine.resume("wr_1", actor: "person")

    expect(run["current"]).to eq("build")
    expect(tmux.killed_windows).to eq(["@100"])
    expect(slot).to be_nil
  end
  describe "a run that ends or leaves the step without its round" do
    def marked = tmux.review_windows("app").map { |each| each[:window] }

    it "closes the warm window when the run is cancelled while the plan step runs" do
      start
      expect(marked).to eq(["@100"])

      engine.cancel("wr_1", actor: "person")

      expect(run["state"]).to eq("cancelled")
      expect(tmux.killed_windows).to eq(["@100"])
      expect(marked).to be_empty
    end

    it "closes the warm window of a step the plan failed out of when the run then completes" do
      start
      expect(marked).to eq(["@100"])
      # The plan step failed and the run is on build, whose attempt runs; the warm window of plan is still marked.
      edit_run(store, "wr_1") do |stored|
        stored["steps"]["plan"]["state"] = "failed"
        stored["steps"]["build"].merge!("state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-11-14T12:00:00Z"}])
        stored["current"] = "build"
      end

      engine.turn_ended("wr_1", actor: "agent", pane: "%5")

      expect(run["state"]).to eq("completed")
      expect(marked).to be_empty
      expect(tmux.killed_windows).to eq(["@100"])
    end

    it "closes the warm window when `resume --from` goes to another step" do
      start
      edit_run(store, "wr_1") { |stored| stored["current"] = "build" }

      engine.resume("wr_1", actor: "person", from: "build")

      expect(run["current"]).to eq("build")
      expect(marked).to be_empty
      expect(slot).to be_nil
    end

    it "keeps the warm window when the step fails and loops to itself" do
      start
      edit_run(store, "wr_1") do |stored|
        stored["steps"]["plan"]["state"] = "failed"
        stored["state"] = "waiting"
        stored["reason"] = {"code" => "waiting_you", "since" => "2026-11-14T12:00:00Z", "details" => {"kind" => "dispatch", "step" => "plan"}}
      end
      engine.resume("wr_1", actor: "person")

      expect(run["steps"]["plan"]["attempts"].size).to eq(2)
      expect(marked).to eq(["@100"])
      expect(tmux.killed_windows).to be_empty
      expect(slot).to include("window" => "@100", "warm" => true)
    end

    describe "`reject --to` an earlier step" do
      let(:gated) do
        Workspace::WorkflowDefinition.parse(<<~YAML, id: "gated", source: "global", path: "/defs/gated.yml")
          max_attempts: 5
          reviewers:
            skeptic: {prompt: Find what is wrong.}
          steps:
            plan:
              prompt: Plan it.
            build:
              prompt: Build it.
              review: [skeptic]
              gate: approve
        YAML
      end

      # The run sits at build's gate, build holding a window in its `review_window` slot.
      def at_gate(warm:)
        engine.start(actor: "person", definition: gated, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
        engine.turn_ended("wr_1", actor: "agent", pane: "%5")
        edit_run(store, "wr_1") do |stored|
          expect(stored["current"]).to eq("build")
          stored["steps"]["build"]["state"] = "passed"
          stored["steps"]["build"]["gate"] = {"state" => "waiting", "since" => "2026-11-14T12:00:00Z"}
          stored["steps"]["build"]["review_window"].delete("warm") unless warm
        end
      end

      [true, false].each do |warm|
        it "closes the #{warm ? "warm" : "kept"} window of the gated step it leaves" do
          at_gate(warm: warm)
          expect(marked).to eq(["@100"])

          engine.reject("wr_1", actor: "person", note: "again", to: "plan")

          expect(run["current"]).to eq("plan")
          expect(marked).to be_empty
          expect(run["steps"]["build"]["review_window"]).to be_nil
        end
      end
    end
  end
end
