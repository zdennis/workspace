require "spec_helper"
require "stringio"

RSpec.describe Workspace::RestartRunner do
  let(:registry) { Workspace::RestartRegistry.new }
  let(:error_output) { StringIO.new }
  let(:client) { StringIO.new }
  let(:started) { {"pane" => "0.1", "pane_id" => "%18"} }
  let(:calls) { [] }
  let(:outcome) { {"ok" => true, "status" => "restarted", "pane_id" => "%18"} }
  let(:restart) do
    results = calls
    result = outcome
    ScriptedCall.new { |**kwargs| results << kwargs and result }
  end

  let(:pane) { FakePane.new(id: "%18", styled_screens: ["screen"]) }
  let(:panes) { FakePaneFactory.new(panes: [pane]) }

  def runner(factory: ->(**) { restart })
    described_class.new(restart_factory: factory, registry: registry, panes: panes, session_name: "workspace-myapp",
      delivery_lock: Mutex.new, pipeline_ref: ->(_index) {}, monitor: nil,
      idle_prompt_check: Workspace::IdlePromptCheck.new, transcript_summary: Workspace::TranscriptSummary.new,
      pane_bindings: nil, error_output: error_output)
  end

  def last_reply = JSON.parse(client.string.lines.last)

  let(:workers) { [] }

  before { registry.claim_pending("%18") }

  after do
    workers.each(&:kill)
    workers.each { |worker| worker.join(2) }
  end

  it "runs the restart for the pane and answers a waiting caller with the pane and outcome" do
    runner.run(started, "go", true, 7, client, run_id: "wr_1")

    expect(calls).to eq([{pane_id: "%18", prompt: "go", force: true, confirm_timeout: 7, run_id: "wr_1", waiting: true}])
    expect(last_reply).to eq("pane" => "0.1", "ok" => true, "status" => "restarted", "pane_id" => "%18")
  end

  it "frees the pane's claim for the worker thread that ran it" do
    registry.release("%18")
    registry.claim_pending("%18")
    workers << registry.start_worker("%18") { runner.run(started, "go", false, 5, nil) }
    workers.last.join

    expect(registry.held?("%18")).to be(false)
  end

  context "when the restart fails" do
    let(:outcome) { {"ok" => false, "error" => "clear_not_confirmed", "message" => "usage did not drop"} }

    it "prints it on stderr, since a caller that did not wait cannot hear it" do
      runner.run(started, "go", false, 5, nil)

      expect(error_output.string).to include("restart_agent for pane 0.1: usage did not drop")
    end
  end

  it "reads the styled screen through the pane's Pane, and none for an id that is no pane" do
    wired = nil
    check = Class.new { def refusal(_facts, screen) = screen }.new
    described_class.new(restart_factory: ->(**kw) { (wired = kw) && restart }, registry: registry, panes: panes,
      session_name: "s", delivery_lock: Mutex.new, pipeline_ref: ->(_index) {}, monitor: nil, idle_prompt_check: check,
      transcript_summary: Workspace::TranscriptSummary.new, pane_bindings: nil, error_output: error_output)
      .run(started, "go", false, 5, nil)

    expect(wired[:screen_ready].call("%18")).to eq("screen")
    expect(wired[:screen_ready].call("five")).to be_nil
  end

  it "answers internal_error when the restart raises" do
    boom = ScriptedCall.new { |**| raise "tmux wedged" }

    runner(factory: ->(**) { boom }).run(started, "go", false, 5, client)

    expect(last_reply).to include("ok" => false, "error" => "internal_error", "message" => "tmux wedged")
  end

  it "closes the caller's connection" do
    runner.run(started, "go", false, 5, client)
    expect(client).to be_closed
  end

  it "tells the caller and stderr when the worker is killed, naming whether /clear was typed" do
    entered = Queue.new
    gated = Class.new(ScriptedCall) { def cleared? = true }.new do |**|
      entered << true
      sleep
    end
    registry.release("%18")
    registry.claim_pending("%18")
    workers << registry.start_worker("%18") { runner(factory: ->(**) { gated }).run(started, "go", false, 5, client) }
    entered.pop(timeout: 2)

    registry.stop_all

    expect(last_reply).to include("ok" => false, "error" => "agent_stopped", "pane_id" => "%18")
    expect(last_reply["message"]).to include("stopped by shutdown", "/clear was typed")
    expect(error_output.string).to include("restart_agent for pane 0.1: stopped by shutdown")
    expect(registry.held?("%18")).to be(false)
  end
end
