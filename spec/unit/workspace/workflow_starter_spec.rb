require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowStarter do
  around do |example|
    Dir.mktmpdir("wf-starter") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { RecordingRunStore.new(on_checkout: occupied) }
  let(:occupied) { {} }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:prompt) { RecordingWorkflowPrompt.new(text: "the instructions", packs: ["play/binding", "play/commits"]) }
  let(:dispatch) { RecordingDispatch.new }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app", git_common_dir: File.join(@dir, ".git"))) }
  let(:commands) { {test: "rake test"} }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: commands, test_files: []) }
  let(:guard) { instance_double(Workspace::WorkflowGuard, head: "abc123", base: {"base_sha" => "abc123", "base_guard" => {"config_sha256" => "c"}}, check: nil) }
  let(:gate_note) { instance_double(Workspace::WorkflowGateNote, notes_dir_of: File.join(@dir, "notes")) }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: {"id" => "task_1"}) }
  let(:known) { [] }
  let(:clock) { -> { Time.utc(2026, 11, 10, 12, 0, 0) } }

  subject(:starter) do
    described_class.new(change: change, store: store, prompt: prompt, dispatch: dispatch, lineage: lineage,
      commands_config: commands_config, guard: guard, gate_note: gate_note, task_store: task_store,
      workspace_known: ->(name) { known.include?(name) }, clock: clock)
  end

  let(:yaml) { "title: Flow\ninputs:\n  task:\n    required: true\nsteps:\n  plan:\n    prompt: Plan {{inputs.task}}.\n    produces: [plan.md]\n  build:\n    prompt: Build.\n    status: {command: test}\n" }
  let(:definition) { Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml") }
  let(:worktree) { @dir }

  def refusal
    yield
    nil
  rescue Workspace::Error => e
    e
  end

  describe "#preflight" do
    it "answers the run it would start and composes the first step under the preview run, changing nothing" do
      checked = starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, pane: "%3")

      expect(checked).to eq("workflow" => "flow", "workspace" => "app", "project" => "app", "step" => "plan", "pane" => "%3",
        "inputs" => {"task" => "x"}, "packs" => ["play/binding", "play/commits"])
      composed = prompt.calls.first
      expect(composed[1].id).to eq(described_class::PREVIEW_RUN_ID)
      expect(composed[1].artifacts_dir).to eq(File.join(worktree, ".workflow", "wr_preview"))
      expect(composed[2..]).to eq(["plan", [], nil])
      expect(dispatch.calls).to eq([[:check_pane, "%3", {run_id: nil}]])
      expect(store.calls).to eq([[:on_checkout, worktree]])
      expect(store.runs).to be_empty
    end

    it "refuses a checkout another run is going on, naming the cancel command" do
      occupied[worktree] = {"id" => "wr_9", "current" => "plan", "state" => "running", "worktree" => worktree}

      error = refusal { starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}) }

      expect(error.code).to eq("checkout_has_run")
      expect(error.details).to include("worktree" => File.realpath(worktree), "run_id" => "wr_9", "step" => "plan", "state" => "running",
        "next" => ["workspace workflow cancel wr_9"])
    end

    it "lets the pane check refuse a pane another run holds" do
      starter = described_class.new(change: change, store: store, prompt: prompt, dispatch: RecordingDispatch.new(busy: ["%3"]), lineage: lineage,
        commands_config: commands_config, guard: guard, gate_note: gate_note)

      expect(refusal { starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, pane: "%3") }.code).to eq("pane_has_run")
    end

    it "refuses a missing input, an unset command, a path unsafe in shell commands and a dirty checkout for a guarded step" do
      expect(refusal { starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {}) }.code).to eq("input_required")
      expect(refusal { starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, checkout: "/src/a'b") }.code).to eq("unsafe_checkout_path")

      commands.clear
      unset = refusal { starter.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}) }
      expect(unset.code).to eq("workflow_command_unset")
      expect(unset.details).to include("project" => "app", "commands" => ["test"])

      guarded = Workspace::WorkflowDefinition.parse("steps:\n  look:\n    prompt: Look.\n    guard: unchanged\n", id: "look", source: "global", path: "/defs/look.yml")
      allow(guard).to receive(:check).and_return({"code" => "tracked_changed", "paths" => ["a.txt"]})
      dirty = refusal { starter.preflight(definition: guarded, workspace: "app", worktree: worktree, inputs: {}) }
      expect(dirty.code).to eq("dirty_worktree")
      expect(dirty.details).to eq("path" => worktree, "guard" => "tracked_changed", "files" => ["a.txt"])
    end
  end

  describe "#render" do
    it "answers the first attempt's instructions under the preview run, with the strict produces marker" do
      rendered = starter.render(definition: definition, step: "plan", workspace: "app", worktree: worktree, inputs: {"task" => "x"})

      path = File.join(worktree, ".workflow", "wr_preview", "steps", "plan.1.prompt.md")
      expect(rendered).to eq("workflow" => "flow", "step" => "plan", "workspace" => "app", "worktree" => worktree, "inputs" => {"task" => "x"},
        "gate" => nil, "text" => "the instructions", "packs" => ["play/binding", "play/commits"], "run" => "wr_preview",
        "artifacts_dir" => File.join(worktree, ".workflow", "wr_preview"), "instructions" => path, "in_checkout" => true)
      composed = prompt.calls.first
      expect(Workspace::WorkflowProduced.strict?(composed[1].definition)).to be true
      expect(composed[4]).to include("id" => "wr_preview", "step" => "plan", "attempt" => 1, "instructions" => path)
    end

    it "refuses a step the workflow lacks" do
      error = refusal { starter.render(definition: definition, step: "ship", workspace: "app", worktree: worktree, inputs: {"task" => "x"}) }

      expect(error.code).to eq("unknown_step")
      expect(error.details).to eq("workflow" => "flow", "step" => "ship", "steps" => %w[plan build])
    end
  end

  describe "#check_plan" do
    it "answers the step's command, time limit and HEAD" do
      plan = starter.check_plan(definition: definition, step: "build", worktree: worktree)

      expect(plan).to eq("workflow" => "flow", "step" => "build", "command" => "rake test",
        "timeout" => Workspace::WorkflowDefinition::DEFAULT_CHECK_TIMEOUT.to_i, "base_sha" => "abc123", "run" => "wr_preview", "in_checkout" => true)
    end

    it "refuses a step with no status: command, and an unset project command with the config hint for a known workspace" do
      expect(refusal { starter.check_plan(definition: definition, step: "plan", worktree: worktree) }.code).to eq("step_without_status")

      commands.clear
      known << "app"
      error = refusal { starter.check_plan(definition: definition, step: "build", worktree: worktree) }
      expect(error.code).to eq("workflow_command_unset")
      expect(error.message).to include("workspace config set commands.test \"<test command>\" --name app")
    end
  end

  describe "#start" do
    it "stores the run waiting, writes run_started, dispatches its first step and returns the run as a WorkflowRun" do
      run = starter.start(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, pane: "%3", note: "Be brief.")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(run.id).to eq("wr_1")
      expect(run.to_h).to include("schema_version" => 1, "workflow" => "flow", "title" => "Flow", "definition_source" => "global",
        "definition_path" => "/defs/flow.yml", "workspace" => "app", "project" => "app", "worktree" => worktree, "base_sha" => "abc123",
        "base_guard" => {"config_sha256" => "c"}, "task" => "task_1", "inputs" => {"task" => "x"}, "note" => "Be brief.", "state" => "waiting",
        "created_at" => "2026-11-10T12:00:00Z", "current" => "plan", "pane" => "%3", "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"))
      expect(run.reason).to include("code" => "waiting_you", "since" => "2026-11-10T12:00:00Z")
      expect(run.reason["details"]).to include("kind" => "dispatch", "error" => "not_started")
      expect(Workspace::WorkflowProduced.strict?(run.definition)).to be true
      expect(run.steps.transform_values(&:state)).to eq("plan" => "pending", "build" => "pending")
      expect(change.events).to eq([["wr_1", "run_started", {"workflow" => "flow", "workspace" => "app"}]])
      expect(dispatch.calls.select { |call| call.first == :dispatch }.map { |call| call[1] }).to eq(["wr_1"])
      expect(change.deliveries).to eq([{"step" => "plan"}])
      expect(dispatch.calls.select { |call| call.first == :check_pane }.map { |call| call[1] }).to eq(["%3", "%3"])
      expect(store.calls.map(&:first)).to eq(%i[on_checkout create on_checkout])
    end

    it "with dispatch: false makes one change that starts nothing" do
      run = starter.start(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, pane: "%3", dispatch: false)

      expect(run.state).to eq("waiting")
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false}]])
      expect(dispatch.calls.map(&:first)).not_to include(:dispatch)
    end

    it "keeps a run whose task store can't be read, with no task" do
      allow(task_store).to receive(:active_for).and_raise(Workspace::Error, "unreadable")

      expect(starter.start(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}, pane: "%3").task).to be_nil
    end
  end
end
