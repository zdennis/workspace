require "spec_helper"

RSpec.describe Workspace::AgentdRouter do
  let(:calls) { [] }
  let(:client) { StringIO.new }
  let(:log_output) { StringIO.new }

  def recording(type, answer = nil)
    ->(message, client) {
      calls << [type, message, client]
      answer
    }
  end

  let(:handlers) do
    {
      "command" => recording("command"),
      "status_request" => recording("status_request", :handed_off),
      "coordinator_restart" => recording("coordinator_restart")
    }
  end

  subject(:router) do
    described_class.new(workspace: "myapp", handlers: handlers, logger: Workspace::Logger.new(output: log_output, enabled: true))
  end

  describe "#handle" do
    it "calls the handler of the message's type with the message and the client, and writes nothing itself" do
      message = {"type" => "command", "workspace" => "myapp", "body" => "go"}

      expect(router.handle(message, client)).to be_nil
      expect(calls).to eq([["command", message, client]])
      expect(client.string).to eq("")
    end

    it "answers what the handler answers, so a handed-off client is reported" do
      expect(router.handle({"type" => "status_request", "workspace" => "myapp"}, client)).to eq(:handed_off)
    end

    it "matches the workspace without regard to case" do
      router.handle({"type" => "command", "workspace" => "MyApp"}, client)

      expect(calls.map(&:first)).to eq(["command"])
    end

    it "refuses a message for another workspace with wrong_workspace, calling no handler" do
      expect(router.handle({"type" => "command", "workspace" => "other"}, client)).to be_nil

      expect(client.string).to eq(%({"ok":false,"error":"wrong_workspace"}\n))
      expect(calls).to be_empty
      expect(log_output.string).to include("dropped message for workspace 'other' (I am 'myapp')")
    end

    it "refuses a message that names no workspace, and every addressed message when it serves none" do
      router.handle({"type" => "command"}, client)
      described_class.new(workspace: nil, handlers: handlers).handle({"type" => "command", "workspace" => "myapp"}, client)

      expect(client.string.lines).to eq([%({"ok":false,"error":"wrong_workspace"}\n)] * 2)
      expect(calls).to be_empty
    end

    it "answers unknown_type for a type with no handler" do
      expect(router.handle({"type" => "nonsense", "workspace" => "myapp"}, client)).to be_nil

      expect(client.string).to eq(%({"ok":false,"error":"unknown_type"}\n))
      expect(log_output.string).to include("unknown message type: nonsense")
    end

    it "checks the workspace before the type" do
      router.handle({"type" => "nonsense", "workspace" => "other"}, client)

      expect(client.string).to eq(%({"ok":false,"error":"wrong_workspace"}\n))
    end

    it "hands the coordinator's restart notice to its handler whatever workspace it names" do
      message = {"type" => "coordinator_restart", "workspace" => "other"}

      router.handle(message, client)

      expect(calls).to eq([["coordinator_restart", message, client]])
      expect(client.string).to eq("")
    end

    it "logs each message it receives" do
      router.handle({"type" => "command", "workspace" => "myapp"}, client)

      expect(log_output.string).to include("received:")
    end
  end

  describe "#reply" do
    it "writes the payload as one JSON line" do
      expect(router.reply(client, {"ok" => true, "x" => 1})).to be_nil

      expect(client.string).to eq(%({"ok":true,"x":1}\n))
    end

    it "writes nothing for no client" do
      expect(router.reply(nil, {"ok" => true})).to be_nil
    end

    it "takes a client that has hung up as nothing to report" do
      gone = Class.new { def puts(_line) = raise(Errno::EPIPE) }.new

      expect(router.reply(gone, {"ok" => true})).to be_nil
      expect(log_output.string).to include("no one was listening for the reply")
    end
  end
end
