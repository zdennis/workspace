require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::Sessions do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }
  let(:socket_path) { File.join(tmpdir, "agent.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  let(:payload) do
    {
      "workspace" => "proj",
      "updated_at" => "2026-09-26T12:00:00Z",
      "panes" => [
        {"pane_id" => "%1", "index" => 0, "kind" => "claude", "label" => "Claude Code",
         "state" => "working", "idle_seconds" => 0,
         "agents" => [{"name" => "eval-baseline", "state" => "running"}]},
        {"pane_id" => "%2", "index" => 1, "kind" => "shell", "label" => "zsh",
         "state" => "idle", "idle_seconds" => 192, "agents" => []}
      ]
    }
  end

  subject(:command) do
    described_class.new(config: config, output: output, error_output: error_output)
  end

  before { allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path) }

  after { FileUtils.remove_entry(tmpdir) }

  # Stands in for the agent daemon: answers one request with the payload.
  def with_daemon(reply: payload)
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      client = server.accept
      received = JSON.parse(client.gets)
      client.puts(JSON.generate(reply)) if reply
      client.close
    end
    yield
    listener.join(2)
    received
  ensure
    server&.close
  end

  describe "#call" do
    it "asks the daemon for its sessions" do
      request = with_daemon { command.call(name: "proj") }

      expect(request).to eq("type" => "sessions", "workspace" => "proj")
    end

    it "renders a table with a row per pane and its sub-agents" do
      with_daemon { command.call(name: "proj") }

      expect(output.string).to include("workspace: proj")
      expect(output.string).to match(/0\.0\s+claude\s+Claude Code\s+working/)
      expect(output.string).to match(/0\.1\s+shell\s+zsh\s+idle\s+3m12s/)
      expect(output.string).to include("└─ eval-baseline")
    end

    it "emits the payload unchanged with --json" do
      with_daemon { command.call(name: "proj", json: true) }

      expect(JSON.parse(output.string)).to eq(payload)
    end

    it "says so when the workspace has no panes" do
      with_daemon(reply: {"workspace" => "proj", "panes" => []}) { command.call(name: "proj") }

      expect(output.string).to include("no panes")
    end

    it "tells the user how to start a daemon when none is listening" do
      expect { command.call(name: "proj") }
        .to raise_error(Workspace::Error, /No agent daemon for 'proj'.*workspace agent proj/m)
    end

    it "reports a daemon that closes without answering" do
      expect {
        with_daemon(reply: nil) { command.call(name: "proj") }
      }.to raise_error(Workspace::Error, /closed the connection/)
    end
  end

  describe "--watch" do
    it "redraws on an interval until interrupted" do
      draws = 0
      sleeper = ->(_seconds) {
        draws += 1
        raise Interrupt if draws >= 2
      }
      watcher = described_class.new(config: config, output: output,
        error_output: error_output, sleeper: sleeper)

      server = UNIXServer.new(socket_path)
      listener = Thread.new do
        2.times do
          client = server.accept
          client.gets
          client.puts(JSON.generate(payload))
          client.close
        end
      end
      watcher.call(name: "proj", watch: true)
      listener.join(2)
      server.close

      expect(draws).to eq(2)
      expect(output.string.scan("workspace: proj").size).to eq(2)
      expect(output.string).to include("\e[2J")
    end
  end
end
