require "spec_helper"

RSpec.describe Workspace::ProjectAgents do
  let(:calls) { [] }
  let(:reply) { nil }
  let(:failure) { nil }

  let(:client) do
    recorded = calls
    answer = reply
    error = failure
    Class.new do
      define_method(:fetch) do |name, timeout: nil|
        recorded << {name: name, timeout: timeout}
        raise error if error
        answer
      end
    end.new
  end

  subject(:agents) { described_class.new(client: client) }

  it "summarizes panes, their sub-agents and per-state counts, dropping the daemon's extra fields" do
    snapshot = {"workspace" => "app", "panes" => [
      {"pane_id" => "%1", "index" => 0, "kind" => "claude", "state" => "waiting", "idle_seconds" => 4,
       "waiting_message" => "approve?", "agents" => [{"name" => "eval", "state" => "running", "extra" => 1}]},
      {"pane_id" => "%2", "kind" => "shell", "state" => "idle", "idle_seconds" => 9}
    ]}
    client_reply = snapshot
    allow(client).to receive(:fetch).and_return(client_reply)

    facts = agents.facts("app", timeout: 0.5)

    expect(client).to have_received(:fetch).with("app", timeout: 0.5)
    expect(facts).to eq(
      "available" => true,
      "panes" => [
        {"pane_id" => "%1", "kind" => "claude", "state" => "waiting", "idle_seconds" => 4, "agents" => [{"name" => "eval", "state" => "running"}]},
        {"pane_id" => "%2", "kind" => "shell", "state" => "idle", "idle_seconds" => 9, "agents" => []}
      ],
      "counts" => {"working" => 0, "idle" => 1, "waiting" => 1}
    )
  end

  context "with a daemon that has no panes" do
    let(:reply) { {"workspace" => "app"} }

    it "reports available with zero counts" do
      expect(agents.facts("app")).to eq("available" => true, "panes" => [], "counts" => {"working" => 0, "idle" => 0, "waiting" => 0})
    end
  end

  context "with no daemon" do
    let(:failure) { Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon) }

    it "reports unavailable with the reason" do
      expect(agents.facts("app")).to eq("available" => false, "reason" => "no_daemon")
    end
  end

  context "with a daemon that is too slow" do
    let(:failure) { Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout) }

    it "reports unavailable with the timeout reason" do
      expect(agents.facts("app")).to eq("available" => false, "reason" => "timeout")
    end
  end

  context "with a daemon that sends a bad reply" do
    let(:failure) { Workspace::Error.new("Malformed reply") }

    it "reports unavailable with the error reason instead of raising" do
      expect(agents.facts("app")).to eq("available" => false, "reason" => "error", "detail" => "Malformed reply")
    end
  end
end
