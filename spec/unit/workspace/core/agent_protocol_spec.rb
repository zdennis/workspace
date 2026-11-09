require "spec_helper"

RSpec.describe Workspace::AgentProtocol do
  # Recorded from the clients' own code before any caller moved onto the
  # builders: `wire` is the exact line each one wrote to the socket.
  fixture = JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/agent_protocol_messages.json")))
  session_event_base = %w[event agent_kind pane_id session_id cwd transcript_path agent_id agent message
    notification_type prompt stop_reason error background_tasks workspace]

  def build(builder, args)
    described_class.method(builder).call(**args.transform_keys(&:to_sym))
  end

  describe "builders against the recorded wire bytes" do
    fixture.fetch("cases").each do |name, kase|
      it "writes #{name} byte for byte" do
        args = kase["args"]
        if kase["builder"] == "session_event"
          base = session_event_base.to_h { |key| [key, args[key]] }
          args = base.merge("fields" => args.except(*session_event_base))
        end
        message = build(kase["builder"], args)
        message = message.merge("workspace" => "pf") if kase["transport_workspace"]
        expect(JSON.generate(message)).to eq(kase["wire"])
      end
    end
  end

  it "covers all twelve types but coordinator_restart, which has no sender" do
    recorded = fixture.fetch("cases").values.map { |kase| kase["builder"] }.uniq
    expect(recorded.sort).to eq((described_class::TYPES - [described_class::COORDINATOR_RESTART]).sort)
    expect(described_class::TYPES.size).to eq(12)
  end

  it "builds every type with the type string first" do
    expect(JSON.generate(described_class.coordinator_restart)).to eq('{"type":"coordinator_restart"}')
    expect(described_class.sessions.keys).to eq(["type"])
  end

  it "returns frozen string-keyed hashes" do
    expect(described_class.version).to be_frozen
    expect(described_class.status_request(pane_id: "%1").keys).to all(be_a(String))
  end

  describe "optional keys" do
    it "leaves out nil workspace, timeout, run_id, task, progress, reply_to and expected_token" do
      expect(described_class.restart_agent(pane: "%1", prompt: "p", force: false, wait: false).keys)
        .to eq(%w[type pane prompt force wait])
      expect(described_class.status_post(pane_id: "%1", summary: "s").keys).to eq(%w[type pane_id summary])
      expect(described_class.inject(work_item_ref: "W", interrupt: false, body: "b").keys)
        .to eq(%w[type work_item_ref interrupt body])
    end

    it "writes the keys the old clients always wrote as null when nil" do
      expect(JSON.generate(described_class.inject(work_item_ref: "W", interrupt: true, expected_token: nil, body: "b")))
        .to eq('{"type":"inject","work_item_ref":"W","interrupt":true,"expected_token":null,"body":"b"}')
      expect(JSON.generate(described_class.handoff_watch(workspace: "pf", pane_id: "%1", sent_at: "t", interval: nil, max: 3,
        text: "x", sent_text: "y")))
        .to eq('{"type":"handoff_watch","workspace":"pf","pane_id":"%1","sent_at":"t","interval":null,"max":3,"text":"x","sent_text":"y"}')
      expect(JSON.generate(described_class.command(work_item_ref: nil, dispatch_id: "d", body: "b")))
        .to eq('{"type":"command","work_item_ref":null,"dispatch_id":"d","body":"b"}')
      expect(JSON.generate(described_class.restart_agent(pane: "%1", prompt: nil, force: false, wait: false)))
        .to eq('{"type":"restart_agent","pane":"%1","prompt":null,"force":false,"wait":false}')
      expect(JSON.generate(described_class.status_post(pane_id: "%1", summary: nil)))
        .to eq('{"type":"status_post","pane_id":"%1","summary":null}')
      expect(JSON.generate(described_class.status_request(pane_id: nil))).to eq('{"type":"status_request","pane_id":null}')
      expect(JSON.generate(described_class.prompt_send(pane_id: "%1", text: nil))).to eq('{"type":"prompt_send","pane_id":"%1","text":null}')
      expect(JSON.generate(described_class.prompt_interrupt_send(pane_id: nil, text: "t")))
        .to eq('{"type":"prompt_interrupt_send","pane_id":null,"text":"t"}')
    end

    it "keeps false values" do
      message = described_class.prompt_send(pane_id: "%1", text: "t", clear_first: true, when_idle: false)
      expect(message).to include("when_idle" => false)
    end

    it "leaves clear_first and when_idle out unless clear_first is set" do
      expect(described_class.prompt_send(pane_id: "%1", text: "t", when_idle: true).keys).to eq(%w[type pane_id text])
    end
  end

  describe ".type_of and .known?" do
    it "reads the type of a Hash and nothing from anything else" do
      expect(described_class.type_of({"type" => "inject"})).to eq("inject")
      expect(described_class.type_of({})).to be_nil
      expect(described_class.type_of([1])).to be_nil
      expect(described_class.type_of(nil)).to be_nil
    end

    it "knows the twelve types" do
      described_class::TYPES.each { |type| expect(described_class.known?(type)).to be(true) }
      expect(described_class.known?("nope")).to be(false)
      expect(described_class.known?(nil)).to be(false)
    end
  end

  describe "replies" do
    it "builds ok replies in field order" do
      expect(JSON.generate(described_class.ok)).to eq('{"ok":true}')
      expect(JSON.generate(described_class.ok(version: "1.2"))).to eq('{"ok":true,"version":"1.2"}')
    end

    it "builds error replies as the daemon writes them" do
      expect(JSON.generate(described_class.error("wrong_workspace"))).to eq('{"ok":false,"error":"wrong_workspace"}')
      expect(JSON.generate(described_class.error("internal_error", "boom"))).to eq('{"ok":false,"error":"internal_error","message":"boom"}')
      expect(JSON.generate(described_class.error("bad", "m", pane: "%1"))).to eq('{"ok":false,"error":"bad","message":"m","pane":"%1"}')
    end

    it "names the four protocol errors" do
      expect(described_class::ERRORS).to eq(%w[wrong_workspace unknown_type malformed_message internal_error])
    end
  end

  it "holds the restart reply timeout workflow_panes waits with today" do
    expect(described_class::RESTART_REPLY_TIMEOUT).to eq(150)
    expect(Workspace::WorkflowPanes::REPLY_TIMEOUT).to eq(described_class::RESTART_REPLY_TIMEOUT)
  end
end
