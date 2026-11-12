require "spec_helper"
require "socket"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Workspace::AgentMessageClient do
  let(:dir) { Dir.mktmpdir("ws-amc", "/tmp") }
  let(:config) do
    socket_dir = dir
    Class.new(Workspace::Config) do
      define_method(:agent_socket_path) { |name| File.join(socket_dir, "#{name}.sock") }
    end.new
  end
  let(:client) { described_class.new(config: config) }

  after { FileUtils.remove_entry(dir) }

  # Answers one connection with +reply+ (a line, or nil to hang up) and records the line it read.
  def with_agent(reply)
    server = UNIXServer.new(config.agent_socket_path("app"))
    received = []
    accepter = Thread.new do
      connection = server.accept
      received << connection.gets
      connection.write(reply) if reply
      connection.close
    end
    yield received
  ensure
    accepter&.join(2)
    server&.close
  end

  it "writes the message as one JSON line and answers the parsed reply" do
    with_agent(%({"ok":true,"queued":2}\n)) do |received|
      expect(client.call("app", {"type" => "command", "body" => "go"})).to eq("ok" => true, "queued" => 2)
      expect(received).to eq([%({"type":"command","body":"go"}\n)])
    end
  end

  it "refuses no_daemon when nothing listens on the socket" do
    expect { client.call("app", {"type" => "command"}) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("no_daemon")
      expect(e.message).to eq("No agent is running for app. Start one with: workspace agentd --name app")
    }
  end

  it "refuses connection_failed when the daemon hangs up without a reply" do
    with_agent(nil) do
      expect { client.call("app", {"type" => "command"}) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("connection_failed")
        expect(e.message).to eq("The agent for app closed the connection without replying")
      }
    end
  end

  it "refuses unreadable_reply when the reply is not JSON" do
    with_agent("not json\n") do
      expect { client.call("app", {"type" => "command"}) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unreadable_reply")
        expect(e.message).to eq("Unreadable reply from the agent for app")
      }
    end
  end
end
