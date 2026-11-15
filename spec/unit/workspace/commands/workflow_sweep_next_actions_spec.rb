require "spec_helper"

RSpec.describe Workspace::Commands::Workflow, "#sweep next_actions" do
  let(:sweep) { double("sweep", call: [{"outcome" => "nothing"}]) }
  let(:sweep_actions) { instance_double(Workspace::WorkflowSweepActions, call: [{"action" => "workflow resume"}]) }

  it "puts the sweep actions in extra.next_actions" do
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      tmux: nil, process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: sweep_actions, output: StringIO.new)

    result = command.sweep(json: true, name: "app")

    expect(result.dig(:extra, "next_actions")).to eq([{"action" => "workflow resume"}])
    expect(sweep_actions).to have_received(:call).with([{"outcome" => "nothing"}], run: nil, name: "app")
  end

  it "builds no next actions for text output" do
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      tmux: nil, process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: nil, output: StringIO.new)

    expect(command.sweep(name: "app")[:extra]).to eq({})
  end
end
