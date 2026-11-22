require "spec_helper"
require "digest"
require "tmpdir"
require "yaml"

# What a pre-warmed review window (opened by WorkflowReviewRound#prewarm over FakeTmux, adopted at delivery) keeps of the
# review pane's guarantees: the verdict proof, the write guard, the pane refusals and the restore skip all read the
# pane's binding, mark and environment, none of which differ from a window opened at delivery.
RSpec.describe Workspace::WorkflowReviewRound, "over a warm review window" do
  around do |example|
    Dir.mktmpdir("wf-review-prewarm") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:workspace) { "app.worktree-x" }
  let(:worktree) { File.join(@dir, "app") }
  let(:home) { File.join(@dir, "home") }
  let(:hook_dir) { File.join(@dir, "events") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 11, 14, 12, 0, 0)] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { "wr_1" }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { InterruptibleWorkflowPanes.new }
  let(:review_panes) { RecordingWorkflowPanes.new }
  let(:tmux) { FakeTmux.new(session_name: "app") }
  let(:proof) { Workspace::ReviewVerdictProof.new(hook_dir: hook_dir) }
  let(:tally) { Workspace::WorkflowReviewTally.new(proof: proof) }
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

  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {}, workspace_known: ->(_) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), review_tally: tally, round_holder: -> { holder }, prewarm: true,
      review_runner: ->(change:, store:, prompt:) do
        Workspace::WorkflowReviewRound.new(store: store, change: change, tmux: tmux, panes: review_panes, readiness: RecordingPaneReadiness.new(tmux: tmux),
          main_agent: Workspace::MainAgent.new(project_config: project_config), revision: RecordingReviewRevision.new({revision: "rev1", problem: nil}),
          prompt: prompt, round_dirs: tally, holder: -> { holder }, shell: "/bin/zsh", which: ->(_) { "/usr/local/bin/claude" },
          error_output: StringIO.new, clock: -> { now.first }, home: home)
      end,
      clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p([File.join(worktree, ".git"), home, hook_dir])
    File.write(config_path, YAML.dump("name" => "app", "windows" => [{"main" => {"panes" => ["claude"]}}]))
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def run = stored_run(store, "wr_1")

  def round = run["steps"]["plan"]["review"]

  def author_done
    path = File.join(worktree, ".workflow", "wr_1", "plan.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
  end

  # The warm window opened with the author's line, then adopted by the round when the author's turn ended.
  def adopt_warm_window
    engine.start(actor: "person", definition: flow, workspace: workspace, worktree: worktree, inputs: {}, pane: "%5")
    author_done
  end

  let(:round_dir) { File.join(run["artifacts_dir"], "reviews", "plan.1.r1") }
  let(:verdict_path) { File.join(round_dir, "skeptic.md") }
  let(:relative) { ".workflow/wr_1/reviews/plan.1.r1/skeptic.md" }
  let(:review_pane) { "%100" }
  let(:log) { Workspace::HookEventLog.path_for(hook_dir, workspace) }
  let(:seq) { [0] }

  def verdict_text(said = "approve") = (Workspace::WorkflowReviewTally.header_lines(reviewer: "skeptic", verdict: said, revision: "rev1") + ["", "Reasons."]).join("\n")

  def write_verdict(text = verdict_text)
    File.write(verdict_path, text)
    Digest::SHA256.hexdigest(text)
  end

  # One hook event log line as the daemon writes it; +seq+ goes up by one.
  def log_line(pane: review_pane, tool: "Write", agent: "agent-skeptic", path: relative, sha: nil, **rest)
    seq[0] += 1
    fields = {"type" => "tool_finished", "at" => now.first.iso8601(3), "workspace" => workspace, "pane_id" => pane, "boot_id" => "b", "seq" => seq[0],
              "tool" => tool, "tool_use_id" => "toolu_#{seq[0]}", "agent_id" => agent, "path" => path, "ok" => true}
    fields["sha256"] = sha if sha
    File.write(log, JSON.generate(fields.merge(rest).compact) + "\n", mode: "a")
  end

  def proven = proof.proven?(round_dir: round_dir, path: verdict_path, review_pane: [round["pane"]], workspace: workspace)

  describe "the adopted window" do
    it "is bound as the reviewer and recorded as the round's pane, with no pane an author search could pick" do
      adopt_warm_window

      expect(round).to include("pane" => review_pane, "window" => "@100")
      bind = review_panes.calls.find { |name, _| name == :bind }.last
      expect(bind).to include(pane: review_pane, run_id: "wr_1", step: "plan", attempt: 1, role: "reviewer", round: 1)
      expect(tmux.opened_windows.size).to eq(1)
    end

    it "has a verdict written by the warm pane's sub-agent counted, and the step passed" do
      adopt_warm_window
      log_line(sha: write_verdict)
      now[0] += 60

      expect(proven).to include(ok: true, agent_id: "agent-skeptic")
      moved = engine.turn_ended("wr_1", actor: "agent", pane: review_pane)

      expect(moved).to include("current" => "build")
      expect(moved["steps"]["plan"]["attempts"].last["reviews"].map { |row| row.values_at("reviewer", "verdict", "counted") }).to eq([["skeptic", "approve", true]])
    end

    describe "the verdict proof's refusals" do
      before { adopt_warm_window }

      it "refuses a write logged from another pane (other_pane)" do
        log_line(pane: "%9", sha: write_verdict)

        expect(proven).to include(ok: false, problem: "other_pane")
      end

      it "refuses a write logged with no hash (no_hash)" do
        write_verdict
        log_line

        expect(proven).to include(ok: false, problem: "no_hash")
      end

      it "refuses a write followed by a missing log line (log_gap)" do
        log_line(sha: write_verdict)
        seq[0] += 1
        log_line(tool: "Read", path: "plan.md")

        expect(proven).to include(ok: false, problem: "log_gap")
      end

      it "refuses a file edited after the hook hashed it (hash_mismatch)" do
        log_line(sha: write_verdict)
        write_verdict(verdict_text("reject"))

        expect(proven).to include(ok: false, problem: "hash_mismatch")
      end

      it "does not count a refused verdict" do
        log_line(pane: "%9", sha: write_verdict)
        now[0] += 60

        moved = engine.turn_ended("wr_1", actor: "agent", pane: review_pane)

        expect(moved["current"]).to eq("plan")
        expect(run["steps"]["plan"]["attempts"].last["reviews"].to_a.map { |row| row["counted"] }).not_to include(true)
      end
    end
  end

  describe "the pane's guards, read from the binding the round wrote" do
    let(:bindings) { Workspace::PaneBindings.new(path: File.join(@dir, "state", "bindings.json")) }
    let(:pane_tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_slot: "app:1.0", server_pid_for_pane: 7) }
    let(:locator) { instance_double(Workspace::PaneLocator, locate: {id: "%100", session: "app"}) }
    let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
    let(:ensurer) { ->(name:) { Workspace::Commands::EnsureAgent::Result.new(:running) } }
    let(:workflow_panes) do
      Workspace::WorkflowPanes.new(config: instance_double(Workspace::Config, agent_running?: true), bindings: bindings, tmux: pane_tmux, locator: locator,
        binder: Workspace::Commands::Binding.new(bindings: bindings, locator: locator, tmux: pane_tmux, output: StringIO.new),
        snapshot_client: snapshot_client, agent_ensurer: ensurer, clock: -> { now.first }, error_output: StringIO.new)
    end
    let(:idle_claude) { {"kind" => "claude", "state" => "idle", "window" => 1} }

    # The binding the round asked for, stored by the real binder, as the warm pane has it.
    before do
      adopt_warm_window
      fields = review_panes.calls.find { |name, _| name == :bind }.last
      workflow_panes.bind(**fields)
    end

    describe "ReviewWriteGuard" do
      let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
      let(:write_guard) { Workspace::ReviewWriteGuard.new(pane_bindings: bindings, tmux: pane_tmux, env: {"TMUX_PANE" => review_pane}, event_log: event_log) }

      def check(path, agent_id: "agent-skeptic") = write_guard.check(tool_name: "Write", tool_input: {"file_path" => path}, cwd: worktree, agent_id: agent_id)

      it "refuses a write outside the round directory and the main thread, and lets the sub-agent write its verdict" do
        expect(check(verdict_path)).to be_nil
        expect(check(File.join(worktree, "lib", "a.rb"))).to include("only its round's verdict files")
        expect(check(File.join(round_dir, "..", "plan.1.r2", "skeptic.md"))).to include("only its round's verdict files")
        expect(check(verdict_path, agent_id: nil)).to include("main thread")
        expect(event_log).to have_received(:record).with(hash_including(type: "review_write_denied", data: hash_including("run_id" => "wr_1", "reason" => "outside_round"))).twice
      end
    end

    describe "the pane searches" do
      let(:mark) { tmux.review_windows("app").first[:review] }

      it "refuses the warm pane when named for a restart, by its mark and by its binding alone" do
        marked = {"pane_id" => review_pane, "review" => mark}.merge(idle_claude)
        allow(snapshot_client).to receive(:fetch).and_return("panes" => [marked])
        error = begin
          workflow_panes.restart_target(workspace, "wr_1", bound: "%5", named: review_pane)
        rescue Workspace::Error => e
          e
        end
        expect(error).to be_a(Workspace::Error)
        expect(error).to have_attributes(code: "pane_busy", details: hash_including("reason" => "review"))

        unmarked = {"pane_id" => review_pane}.merge(idle_claude)
        allow(snapshot_client).to receive(:fetch).and_return("panes" => [unmarked])
        error = begin
          workflow_panes.restart_target(workspace, "wr_1", bound: "%5", named: review_pane)
        rescue Workspace::Error => e
          e
        end
        expect(error).to have_attributes(code: "pane_busy", details: hash_including("reason" => "review"))
      end

      it "skips the warm pane when looking for the author's pane" do
        allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => review_pane, "review" => mark}.merge(idle_claude), {"pane_id" => "%5", "window" => 0}.merge(idle_claude).merge("window" => 0)])

        expect(workflow_panes.default_pane(workspace)).to eq("%5")
      end
    end
  end

  describe "the line typed into the warm pane, over a real WorkflowPanes" do
    let(:bindings) { Workspace::PaneBindings.new(path: File.join(@dir, "state", "bindings.json")) }
    let(:pane_tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_slot: "app:1.0", server_pid_for_pane: 7, deliver: Workspace::Tmux::Delivery.new(status: :submitted, message: "ok")) }
    let(:locator) { instance_double(Workspace::PaneLocator, locate: {id: "%100", session: "app"}) }
    let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
    let(:ensurer) { ->(name:) { Workspace::Commands::EnsureAgent::Result.new(:running) } }
    let(:review_panes) do
      Workspace::WorkflowPanes.new(config: instance_double(Workspace::Config, agent_running?: true), bindings: bindings, tmux: pane_tmux, locator: locator,
        binder: Workspace::Commands::Binding.new(bindings: bindings, locator: locator, tmux: pane_tmux, output: StringIO.new),
        snapshot_client: snapshot_client, agent_ensurer: ensurer, clock: -> { now.first }, sleeper: ->(_) {}, error_output: StringIO.new)
    end

    # The row of a Claude Code pane the daemon has seen only draw its start-up: working by the screen, no prompt submitted.
    let(:startup_row) do
      {"pane_id" => review_pane, "kind" => "claude", "state" => "working", "state_changed_by" => "screen", "hook_mode" => "hooks", "user_prompt_at" => nil,
       "main_turn_over_since" => nil, "open_tools" => [], "subagents" => [], "window" => 1}
    end

    it "types the review line into a warm pane that reads working from its start-up redraw, and does not close it" do
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [startup_row])
      adopt_warm_window

      expect(pane_tmux).to have_received(:deliver).with("app", review_pane, a_string_including("plan.1.r1.review.md"))
      expect(tmux.killed_windows).to be_empty
      expect(round).to include("pane" => review_pane, "window" => "@100")
      events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }
      expect(events.select { |line| line["type"] == "review_delivered" }).to contain_exactly(include("step" => "plan", "round" => 1, "warm" => true))
      expect(events.map { |line| line["type"] }).not_to include("review_delivery_failed")
    end
  end

  describe "a SessionStart in the warm process, which has WORKSPACE_REVIEW_RUN and no binding" do
    let(:ledger) { Workspace::SessionLedger.new(path: File.join(@dir, "state", "ledger.jsonl")) }
    let(:bindings) { Workspace::PaneBindings.new(path: File.join(@dir, "state", "bindings.json")) }
    let(:hook_tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_slot: "app:1.0", pane_layout: nil, server_pid_for_pane: nil) }
    let(:config) { instance_double(Workspace::Config, agent_socket_path: "/nonexistent/agent.sock") }
    let(:output) { StringIO.new }
    let(:cwd) { File.join(@dir, "app") }
    let(:session_id) { "00000000-0000-4000-8000-000000000001" }

    # What the hook of the pane the daemon's mark names does, as `open_window` starts it with WORKSPACE_REVIEW_RUN.
    def start_session(env)
      payload = {"hook_event_name" => "SessionStart", "session_id" => session_id, "cwd" => cwd, "source" => "startup"}
      Workspace::Commands::SessionEvent.new(config: config, tmux: hook_tmux, input: StringIO.new(JSON.generate(payload)), env: env,
        output: output, session_ledger: ledger, pane_bindings: bindings).call
    end

    def restore_rows
      report = instance_double(Workspace::TmuxinatorReport)
      allow(report).to receive(:show).and_raise(Workspace::Error, "no config")
      restore_tmux = instance_double(Workspace::Tmux, sessions: ["app"], session_name_for: "app", pane_details: [])
      restore = Workspace::Commands::Restore.new(ledger: ledger, tmux: restore_tmux, pane_bindings: bindings, tmuxinator_report: report,
        process_tree: instance_double(Workspace::ProcessTree), resume_command: instance_double(Workspace::AgentResumeCommand, flags_for: nil),
        output: StringIO.new, error_output: StringIO.new)
      restore.call(["app"], dry_run: true)[:results].select { |row| row["kind"] == "pane" }
    end

    it "records the session with role reviewer, prints no context, and restore plans no resume for it" do
      adopt_warm_window
      expect(tmux.opened_windows.first[:env]).to include("WORKSPACE_REVIEW_RUN" => "wr_1")

      start_session("TMUX_PANE" => review_pane, "WORKSPACE_REVIEW_RUN" => "wr_1")

      entry = ledger.entries_for("app").last
      expect(entry).to include("event" => "session_start", "pane_id" => review_pane, "role" => "reviewer", "session_id" => session_id)
      expect(output.string).to be_empty
      expect(restore_rows).to be_empty
    end

    it "would plan a row for the same session without the reviewer role, so the skip is the role's" do
      start_session("TMUX_PANE" => "%7")

      expect(ledger.entries_for("app").last).not_to have_key("role")
      expect(restore_rows).to match([include("outcome" => "skipped").or(include("outcome" => "unmatched"))])
    end
  end
end
