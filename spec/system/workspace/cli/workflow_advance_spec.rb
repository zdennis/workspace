require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

# workflow advance as the agent daemon's nudger starts it, through CLI#run over a real run store,
# engine and Commands::Workflow. System tier: the engine's real WorkflowGuard runs git.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::EnvStub
  include CLITestHelpers::WorkflowFamilyCli

  describe "workflow advance, as the agent daemon starts it" do
    around do |example|
      Dir.mktmpdir("wf-advance") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    let(:runs_dir) { File.join(@dir, "runs") }
    let(:store) { PinnedFindStore.new(Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(@dir, "archive"))) }
    let(:panes) { FakeWorkflowPanes.new }
    let(:git) { instance_double(Workspace::Git, worktree_branch: "main", common_dir_from_files: nil) }
    let(:engine) do
      lock_namespace = instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: File.join(@dir, "locks")})
      Workspace.build_workflow_engine(
        store: store, panes: panes, composer: FakeStepComposer.new, git: git, guard: Workspace::WorkflowGuard.new, excludes: Workspace::GitExclude.new(git: git),
        gate_note: Workspace::WorkflowGateNote.new(notes: instance_double(Workspace::Commands::Notes)),
        resources: Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir)),
        checker: ->(**) { {exit_code: 0, timed_out: false} },
        commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}),
        lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app"))
      )
    end
    let(:command) do
      Workspace::Commands::Workflow.new(lint: nil, catalog: instance_double(Workspace::WorkflowCatalog), engine: engine,
        status: instance_double(Workspace::WorkflowStatus), store: store, panes: panes, files: nil, run_files: nil,
        tmux: instance_double(Workspace::Tmux, session_name_for: "app", pane_details: []), process_tree: nil, lock_holder: nil, output: StringIO.new)
    end
    let(:cli) { build_test_cli(workflow_command: command)[0] }
    # The daemon's nudger, with the process it would start run here instead.
    let(:nudger) do
      Workspace::WorkflowNudger.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(_) { File::NULL },
        spawner: ->(argv, _log) { cli.run(argv.drop(2)) })
    end

    describe "a parked resume made by the command" do
      let(:definition) { Workspace::WorkflowDefinition.parse("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n", id: "flow", source: "global", path: "/defs/flow.yml") }
      let(:dispatched) { store.events(run["id"])["events"].select { |entry| entry["type"] == "step_dispatched" } }
      let(:run) { engine.start(definition: definition, workspace: "app", worktree: @dir, inputs: {}, pane: "%5") }
      let(:out) { StringIO.new }
      let(:status) do
        instance_double(Workspace::WorkflowStatus).tap do |double|
          allow(double).to receive(:run) do |id|
            {"runs" => [{"id" => id, "workflow" => "flow", "workspace" => "app", "state" => "running",
                         "current" => {"step" => "a", "attempt" => 1, "state" => "running", "reason" => nil, "flags" => []}}]}
          end
        end
      end
      let(:parking) do
        Workspace::Commands::Workflow.new(lint: nil, catalog: instance_double(Workspace::WorkflowCatalog), engine: engine,
          status: status, store: store, panes: panes, files: nil, run_files: nil,
          tmux: instance_double(Workspace::Tmux, session_name_for: "app", pane_details: []), process_tree: nil, lock_holder: nil, output: out)
      end

      before do
        stub_env("TMUX_PANE" => "%5")
      end

      it "parks from the run's own pane, keeps the note off the screen, and dispatches once the turn is over" do
        run
        kicks_before = panes.kicks.size

        row = parking.resume(run: run["id"], from: "a", note: "Again.", caller_pane: "%5")

        expect(row["outcome"]).to eq("parked")
        expect(stored_run(store, run["id"])["parked"]["note"]).to eq("Again.")
        expect(row.to_s + out.string).not_to include("Again.")
        expect(panes.kicks.size).to eq(kicks_before)
        expect(store.events(run["id"])["events"].count { |entry| entry["type"] == "step_dispatched" }).to eq(1)

        stub_env("TMUX_PANE" => nil)
        panes.turn_over << "%5"
        nudger.turn_ended("app", "%5")

        expect(store.events(run["id"])["events"].count { |entry| entry["type"] == "step_dispatched" }).to eq(2)
        expect(stored_run(store, run["id"])).not_to include("parked")
      end

      it "answers --json with the parked pane and expiry, exit 0" do
        cli, output = build_test_cli(workflow_command: parking)

        cli.run(["workflow", "resume", run["id"], "--from", "a", "--note", "Again.", "--json"])

        document = JSON.parse(output.string.lines.last)
        expect(document).to include("ok" => true)
        expect(document["results"].first).to include("outcome" => "parked")
        expect(document["results"].first["parked"]).to include("pane" => "%5", "expires_at" => anything)
        expect(output.string).not_to include("Again.")
      end
    end

    describe "a run started from its own pane" do
      let(:definition) { Workspace::WorkflowDefinition.parse("steps:\n  a:\n    prompt: A\n", id: "flow", source: "global", path: "/defs/flow.yml") }
      let(:catalog) { instance_double(Workspace::WorkflowCatalog, find: definition) }
      let(:status) do
        instance_double(Workspace::WorkflowStatus).tap do |double|
          allow(double).to receive(:run) do |id|
            {"runs" => [{"id" => id, "workflow" => "flow", "workspace" => "app", "state" => "running",
                         "current" => {"step" => "a", "attempt" => 1, "state" => "running", "reason" => nil, "flags" => []}}]}
          end
        end
      end
      let(:parking) do
        Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, engine: engine,
          status: status, store: store, panes: panes, files: nil, run_files: nil,
          tmux: instance_double(Workspace::Tmux, session_name_for: "app", pane_details: []), process_tree: nil, lock_holder: nil, output: StringIO.new)
      end

      before do
        stub_env("TMUX_PANE" => nil)
      end

      it "is created and parked with nothing typed, then dispatched by ticks once the turn is over" do
        row = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5")

        id = row["run"]["id"]
        expect(row["outcome"]).to eq("parked")
        expect(panes.kicks).to be_empty
        stored = stored_run(store, id)
        expect(stored["parked"]).to include("pane" => nil)
        expect(stored["steps"]["a"]["attempts"]).to be_empty
        expect(panes.run_on("%5")).to be_nil

        3.times { nudger.tick("app") }
        expect(stored_run(store, id)["steps"]["a"]["attempts"]).to be_empty

        panes.turn_over << "%5"
        nudger.tick("app")

        expect(stored_run(store, id)).not_to include("parked")
        expect(stored_run(store, id)["steps"]["a"]["attempts"].size).to eq(1)
        expect(panes.kicks.size).to eq(1)
        expect(store.events(id)["events"].count { |entry| entry["type"] == "step_dispatched" }).to eq(1)
      end

      it "dispatches at once from another pane" do
        row = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%9")

        expect(row["outcome"]).to eq("started")
        expect(panes.kicks.size).to eq(1)
      end

      it "refuses a second run on the parked pane as pane_has_run, leaving the first parked" do
        first = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5")["run"]["id"]

        expect { parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%9") }
          .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["run_id"]]).to eq(["pane_has_run", first]) }
        expect { parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5") }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_has_run") }
        expect(stored_run(store, first)["parked"]).to include("pane" => nil)
        expect(panes.kicks).to be_empty
      end

      it "dispatches at once for --pane given from elsewhere" do
        row = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%7", caller_pane: "%5")

        expect(row["outcome"]).to eq("started")
        expect(stored_run(store, row["run"]["id"])).not_to include("parked")
        expect(panes.kicks.size).to eq(1)
      end

      it "takes today's path when the pane cannot be parked on" do
        allow(panes).to receive(:parkable?).and_return(false)

        row = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5")

        expect(row["outcome"]).to eq("started")
        expect(stored_run(store, row["run"]["id"])).not_to include("parked")
        expect(panes.kicks.size).to eq(1)
      end

      it "parks with no caller_pane when the process table puts the caller under the pane (the workflow start route)" do
        tmux = instance_double(Workspace::Tmux, session_name_for: "app", pane_details: [{id: "%5", window: 0, index: 1, pid: 200}])
        tree = instance_double(Workspace::ProcessTree)
        allow(tree).to receive(:snapshot).and_return(instance_double(Workspace::ProcessTree::Snapshot, ancestors: [{pid: 4242}, {pid: 200}]))
        under = Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, engine: engine, status: status, store: store, panes: panes,
          files: nil, run_files: nil, tmux: tmux, process_tree: tree, lock_holder: nil, pid: 4242, output: StringIO.new)

        row = under.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5")

        expect(row["outcome"]).to eq("parked")
        expect(panes.kicks).to be_empty
        expect(stored_run(store, row["run"]["id"])["parked"]).to include("pane" => nil)
      end

      it "changes nothing under --dry-run from its own pane" do
        allow(engine).to receive(:preflight).and_return("step" => "a", "inputs" => {}, "packs" => [])

        row = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5", dry_run: true)

        expect(row["outcome"]).to eq("dry_run")
        expect(going_runs(store)).to be_empty
        expect(panes.kicks).to be_empty
      end

      it "hides not_started from status while parked, and shows it once the park is gone" do
        real = Workspace::WorkflowStatus.new(store: store, panes: panes,
          snapshot_client: instance_double(Workspace::AgentSnapshotClient, fetch: {"panes" => []}),
          ask_store_for: ->(_) { instance_double(Workspace::AskStore, list: []) }, gate_note: instance_double(Workspace::WorkflowGateNote))
        id = parking.run(id: "flow", workspace: "app", worktree: @dir, pane: "%5", caller_pane: "%5")["run"]["id"]

        shown = real.run(id)["runs"].first["current"]
        expect(shown["flags"]).to include("parked")
        expect(shown.to_s).not_to include("not_started")

        edit_run(store, id) { |stored| stored.delete("parked") }
        expect(real.run(id)["runs"].first["current"].to_s).to include("not_started")
      end
    end

    describe "a parked resume" do
      let(:definition) { Workspace::WorkflowDefinition.parse("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n", id: "flow", source: "global", path: "/defs/flow.yml") }
      let(:dispatched) { store.events(run["id"])["events"].select { |entry| entry["type"] == "step_dispatched" } }
      let(:run) { engine.start(definition: definition, workspace: "app", worktree: @dir, inputs: {}, pane: "%5") }

      before do
        stub_env("TMUX_PANE" => nil)
        # The agent's own resume of its step, parked from inside the turn.
        engine.park(run["id"], from: "a", note: "Again.")
      end

      it "goes from the park through a Stop to the step's line being typed" do
        expect(nudger.turn_ended("app", "%5")).to eq(run["id"])
        expect(panes.kicks.size).to eq(1)
        expect(stored_run(store, run["id"])).to include("parked" => anything)

        panes.turn_over << "%5"
        nudger.turn_ended("app", "%5")

        stored = stored_run(store, run["id"])
        expect(stored).not_to include("parked")
        expect(stored["steps"]["a"]["attempts"].size).to eq(2)
        expect(stored["steps"]["a"]["attempts"].last["context"]).to eq(["Note from the person who resumed the run: Again."])
        expect(panes.kicks.size).to eq(2)
        expect(dispatched.size).to eq(2)
      end

      it "dispatches once when two processes both saw the proof" do
        store.pin_find(run["id"])
        panes.turn_over << "%5"

        2.times { nudger.turn_ended("app", "%5") }

        expect(panes.kicks.size).to eq(2)
        expect(dispatched.size).to eq(2)
      end

      it "goes from the park to the step's line being typed on ticks alone, for a pane that saw no Stop" do
        expect(nudger.turn_ended("app", "%9")).to be_nil
        3.times { nudger.tick("app") }
        expect(stored_run(store, run["id"])["steps"]["a"]["attempts"].size).to eq(1)

        panes.turn_over << "%5"
        expect(nudger.tick("app")).to eq([run["id"]])

        expect(stored_run(store, run["id"])).not_to include("parked")
        expect(panes.kicks.size).to eq(2)
        expect(dispatched.size).to eq(2)
        expect(nudger.tick("app")).to eq([])
      end
    end

    it "moves the run to its next step when the turn ends in its pane, and not for a turn in another pane" do
      definition = Workspace::WorkflowDefinition.parse("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n", id: "flow", source: "global", path: "/defs/flow.yml")
      run = engine.start(definition: definition, workspace: "app", worktree: @dir, inputs: {}, pane: "%5")

      expect(nudger.turn_ended("app", "%9")).to be_nil
      expect(stored_run(store, run["id"])).to include("current" => "a")

      expect(nudger.turn_ended("app", "%5")).to eq(run["id"])
      expect(stored_run(store, run["id"])).to include("current" => "b", "state" => "running")
      expect(panes.kicks.map { |kick| kick[:pane] }).to eq(%w[%5 %5])
    end
  end
end
