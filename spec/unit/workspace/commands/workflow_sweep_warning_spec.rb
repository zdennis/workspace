require "spec_helper"

RSpec.describe Workspace::Commands::Workflow, "#run sweep warning" do
  let(:catalog) { instance_double(Workspace::WorkflowCatalog) }
  let(:engine) { instance_double(Workspace::WorkflowEngine, preflight: {"step" => "plan", "inputs" => {}, "packs" => []}) }
  let(:panes) { instance_double(Workspace::WorkflowPanes, default_pane: nil) }
  let(:schedule) { instance_double(Workspace::SweepSchedule) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:installed) { false }

  def definition(extra = "", step_extra = "")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      title: Flow
      #{extra}
      steps:
        plan:
          prompt: Plan.
          #{step_extra}
    YAML
  end

  def run_with(definition, schedule: self.schedule)
    allow(catalog).to receive(:find).and_return(definition)
    command = described_class.new(lint: nil, catalog: catalog, engine: engine, status: nil, store: nil, panes: panes, files: nil, run_files: nil,
      tmux: nil, process_tree: nil, lock_holder: nil, schedule: schedule, output: output, error_output: error_output)
    command.run(id: "flow", workspace: "app", worktree: "/src/app", dry_run: true)
  end

  before { allow(schedule).to receive(:status).and_return("installed" => installed) }

  it "warns once on stderr for a run timeout when the sweep is not installed" do
    run_with(definition("timeout: 2h"))

    expect(error_output.string.lines.size).to eq(1)
    expect(error_output.string).to start_with("Warning: flow sets a timeout").and include("nothing enforces the timeout while no agent is working the run", "workflow sweep --install")
    expect(output.string).not_to include("Warning")
  end

  it "warns for a step timeout too" do
    run_with(definition("", "timeout: 30m"))

    expect(error_output.string).to include("Warning: flow sets a timeout")
  end

  it "says nothing when the sweep is installed" do
    allow(schedule).to receive(:status).and_return("installed" => true)
    run_with(definition("timeout: 2h"))

    expect(error_output.string).to eq("")
  end

  it "says nothing for a definition with no timeout and does not ask the schedule" do
    run_with(definition)

    expect(error_output.string).to eq("")
    expect(schedule).not_to have_received(:status)
  end

  it "says nothing when no schedule was wired or it cannot answer" do
    run_with(definition("timeout: 2h"), schedule: nil)
    allow(schedule).to receive(:status).and_raise(Workspace::Error.new("boom", code: "sweep_launchctl_failed"))
    run_with(definition("timeout: 2h"))

    expect(error_output.string).to eq("")
  end
end
