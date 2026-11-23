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

  it "puts a permission-wait stop's focus, resume and cancel in extra.next_actions" do
    stopped = {"workspace" => "app", "outcome" => "timed_out", "reason" => nil, "run_id" => "wr_1", "step" => "plan", "cause" => "permission_wait", "action" => "fail"}
    store = instance_double(Workspace::WorkflowRunStore, run: Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "app", "state" => "waiting", "current" => "plan",
      "reason" => {"code" => "failed_check", "details" => {"cause" => "permission_wait", "pane" => "%5"}}, "steps" => {"plan" => {"state" => "failed"}}))
    actions = Workspace::WorkflowSweepActions.new(store: store, panes: nil, status: nil)
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      process_tree: nil, lock_holder: nil, sweep: double("sweep", call: [stopped]), sweep_actions: actions, output: StringIO.new)

    found = command.sweep(json: true, name: "app").dig(:extra, "next_actions")

    expect(found.map { |each| [each["action"], each["args"]] }).to eq([["focus", ["app", "--pane", "%5"]], ["workflow resume", ["wr_1"]], ["workflow cancel", ["wr_1"]]])
  end

  it "builds no next actions for text output" do
    command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
      process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: nil, output: StringIO.new)

    expect(command.sweep(name: "app")[:extra]).to eq({})
  end
  describe "scheduled" do
    it "passes the flag to the sweep, false by default" do
      command = described_class.new(lint: nil, catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil,
        process_tree: nil, lock_holder: nil, sweep: sweep, sweep_actions: sweep_actions, output: StringIO.new)
      command.sweep(name: "app", scheduled: true)
      expect(sweep).to have_received(:call).with(hash_including(scheduled: true))
      command.sweep(name: "app")
      expect(sweep).to have_received(:call).with(hash_including(scheduled: false))
    end
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
