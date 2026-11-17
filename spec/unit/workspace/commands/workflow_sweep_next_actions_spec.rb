require "spec_helper"

RSpec.describe Workspace::Commands::Workflow, "#sweep next_actions" do
  let(:sweep) { double("sweep", call: [{"outcome" => "nothing"}]) }
  let(:sweep_actions) { instance_double(Workspace::WorkflowSweepActions, call: [{"action" => "workflow resume"}]) }

  it "puts the sweep actions in extra.next_actions" do
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: sweep_actions, output: StringIO.new)

    result = command.sweep(json: true, name: "app")

    expect(result.dig(:extra, "next_actions")).to eq([{"action" => "workflow resume"}])
    expect(sweep_actions).to have_received(:call).with([{"outcome" => "nothing"}], run: nil, name: "app")
  end

  it "builds no next actions for text output" do
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: nil, output: StringIO.new)

    expect(command.sweep(name: "app")[:extra]).to eq({})
  end
  describe "budget_only" do
    let(:output) { StringIO.new }
    let(:command) do
      described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
        process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: sweep_actions, output: output)
    end

    it "passes the flag to the sweep and adds budget_only: true to the json extra, only when set" do
      expect(command.sweep(json: true, name: "app", budget_only: true)[:extra]).to include("budget_only" => true)
      expect(sweep).to have_received(:call).with(hash_including(budget_only: true))
      expect(command.sweep(json: true, name: "app")[:extra]).not_to have_key("budget_only")
    end

    it "says in the summary that it was a budget-only pass" do
      command.sweep(name: "app", budget_only: true)
      expect(output.string).to include("Budget-only pass: looked at 1 run")
    end
  end
end
