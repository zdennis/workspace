require "spec_helper"
require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::RestartAgent do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-restart-cmd", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:config) { instance_double(Workspace::Config, agent_socket_path: socket_path) }
  let(:output) { StringIO.new }
  let(:received) { [] }

  subject(:command) { described_class.new(config: config, output: output) }

  after { FileUtils.remove_entry(tmpdir) }

  # Answers one message with +reply+ and records what it was sent.
  def with_daemon(reply)
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      client = server.accept
      received << JSON.parse(client.gets)
      client.puts(reply.to_json)
      client.close
    end
    yield
  ensure
    thread&.join(2)
    thread&.kill
    server&.close
  end

  def call(**opts)
    command.call(name: "myapp", pane: "%18", prompt: "Read HANDOFF.md", **opts)
  end

  let(:started) do
    {"ok" => true, "status" => "started", "pane" => "0.1", "pane_id" => "%18", "context_pct" => 42}
  end

  it "sends a restart_agent message naming the pane" do
    with_daemon(started) { call(force: true, wait: true, timeout: 45) }

    expect(received).to eq([{"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18",
                             "prompt" => "Read HANDOFF.md", "force" => true, "wait" => true, "timeout" => 45}])
  end

  it "leaves the timeout out when none is given" do
    with_daemon(started) { call }

    expect(received.first).not_to have_key("timeout")
  end

  it "says the restart started and where a failure will show" do
    result = with_daemon(started) { call }

    expect(result).to eq(exit_code: 0)
    expect(output.string).to include("Restart started on pane 0.1 (%18) at 42% context.", "pass --wait")
  end

  it "reports a finished restart with the before and after usage" do
    reply = {"ok" => true, "status" => "restarted", "pane" => "0.1", "pane_id" => "%18",
             "context_before" => 42, "context_after" => 3, "delivery" => "submitted"}
    with_daemon(reply) { call(wait: true) }

    expect(output.string).to include("Restarted pane 0.1 (%18): context 42% -> 3%; prompt submitted.")
  end

  it "prints the daemon's warning" do
    with_daemon(started.merge("warning" => "WC-7 has a pipeline stage running on this pane")) { call(force: true) }

    expect(output.string).to include("Warning: WC-7 has a pipeline stage")
  end

  it "prints the JSON reply with a schema version" do
    with_daemon(started) { call(json: true) }

    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "status" => "started", "pane" => "0.1",
      "pane_id" => "%18", "context_pct" => 42)
  end

  context "when the daemon refuses" do
    let(:refusal) do
      {"ok" => false, "error" => "context_unknown", "message" => "can't read context usage for pane 0.1",
       "pane" => "0.1", "reason" => "no reading recorded", "fix" => "Fix: add a statusLine entry"}
    end

    it "raises with the message and the fix" do
      with_daemon(refusal) do
        expect { call }.to raise_error(Workspace::Error, "can't read context usage for pane 0.1\nFix: add a statusLine entry")
      end
    end

    it "prints the JSON error contract, with the daemon's code and details, and exits 1" do
      result = with_daemon(refusal) { call(json: true) }

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "error" => "can't read context usage for pane 0.1",
        "code" => "context_unknown", "pane" => "0.1", "reason" => "no reading recorded",
        "fix" => "Fix: add a statusLine entry")
    end
  end

  context "when no daemon is running" do
    it "raises naming how to start one" do
      expect { call }.to raise_error(Workspace::Error, /No agent daemon for 'myapp'.*workspace agent --name myapp/)
    end

    it "prints the JSON error contract with --json" do
      expect(call(json: true)).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => a_string_including("No agent daemon"))
    end
  end
end
