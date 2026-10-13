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

  let(:locator) { instance_double(Workspace::PaneLocator) }

  subject(:command) { described_class.new(config: config, locator: locator, output: output) }

  before do
    allow(locator).to receive(:locate).with("myapp", "%18").and_return({id: "%18", window: 0, index: 1, session: "myapp-session"})
  end

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
    expect(locator).to have_received(:locate).with("myapp", "%18")
  end

  # The daemon is a long-lived process and may be older than this
  # command, so the pane is resolved here, inside the workspace's own tmux
  # session, and named to the daemon by its id: an id is one pane on the
  # whole tmux server, where an index is a pane of whatever session the
  # daemon lists.
  describe "resolving the pane before the daemon is asked" do
    def located(spec, detail)
      allow(locator).to receive(:locate).with("myapp", spec).and_return(detail.merge(session: "myapp-session"))
    end

    it "names a pane given as window.pane by its pane id" do
      located("0.1", {id: "%2", window: 0, index: 1})

      with_daemon(started) { call(pane: "0.1") }

      expect(received.first["pane"]).to eq("%2")
    end

    it "reads a bare index as a pane of window 0" do
      located("0.1", {id: "%2", window: 0, index: 1})

      with_daemon(started) { call(pane: "1") }

      expect(received.first["pane"]).to eq("%2")
    end

    ["myapp:1.0", "myapp-session:1.0"].each do |spec|
      it "accepts #{spec}, the pane prefixed with the workspace's name or its tmux session" do
        located("1.0", {id: "%9", window: 1, index: 0})

        with_daemon(started) { call(pane: spec) }

        expect(received.first["pane"]).to eq("%9")
      end
    end

    it "refuses a pane of another session without asking the daemon" do
      located("0.1", {id: "%2", window: 0, index: 1})
      allow(UNIXSocket).to receive(:open)

      expect { call(pane: "myapp-ui:0.1") }
        .to raise_error(Workspace::Error, "Pane myapp-ui:0.1 is not in tmux session 'myapp-session' (workspace 'myapp').") { |e| expect(e.code).to eq("wrong_session") }
      expect(UNIXSocket).not_to have_received(:open)
    end

    # The case that went wrong: workspace "workspace" beside "workspace-ui".
    it "refuses a pane of a session whose name only starts with the workspace's" do
      allow(locator).to receive(:locate).with("workspace", "0.1").and_return({id: "%2", window: 0, index: 1, session: "workspace"})
      allow(UNIXSocket).to receive(:open)

      expect { command.call(name: "workspace", pane: "workspace-ui:0.1", prompt: "Read HANDOFF.md") }
        .to raise_error(Workspace::Error, /not in tmux session 'workspace'/) { |e| expect(e.code).to eq("wrong_session") }
      expect(UNIXSocket).not_to have_received(:open)
    end

    it "refuses a pane id the workspace's session doesn't have, without asking the daemon" do
      allow(locator).to receive(:locate).with("myapp", "%6").and_raise(
        Workspace::Error.new("Pane %6 belongs to tmux session 'myapp-ui', not 'myapp' (workspace 'myapp').", code: "wrong_session")
      )
      allow(UNIXSocket).to receive(:open)

      result = call(pane: "%6", json: true)

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "wrong_session",
        "error" => "Pane %6 belongs to tmux session 'myapp-ui', not 'myapp' (workspace 'myapp').")
      expect(UNIXSocket).not_to have_received(:open)
    end

    it "refuses anything that is not a pane id, window.pane or an index" do
      allow(locator).to receive(:locate).with("myapp", "Claude Code").and_raise(
        Workspace::Error.new("\"Claude Code\" is not a pane id (%19) or window.pane (0.1).", code: "bad_pane")
      )
      allow(UNIXSocket).to receive(:open)

      expect { call(pane: "Claude Code") }.to raise_error(Workspace::Error, /not a pane id/) { |e| expect(e.code).to eq("bad_pane") }
      expect(UNIXSocket).not_to have_received(:open)
    end
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

  it "reports a new conversation that has no usage reading yet" do
    reply = {"ok" => true, "status" => "restarted", "pane" => "0.1", "pane_id" => "%18",
             "context_before" => 42, "context_after" => nil, "delivery" => "submitted"}
    with_daemon(reply) { call(wait: true) }

    expect(output.string).to include("context 42% -> a new conversation; prompt submitted.")
  end

  it "says context usage isn't known yet instead of a blank percentage" do
    reply = started.merge("context_pct" => nil)
    with_daemon(reply) { call }

    expect(output.string).to include("Restart started on pane 0.1 (%18); context usage isn't known yet.")
  end

  it "reports a closed connection, not 'no daemon', when the socket fails after connecting" do
    socket = instance_double(UNIXSocket, puts: nil, close: nil)
    allow(socket).to receive(:gets).and_raise(Errno::EPIPE)
    allow(UNIXSocket).to receive(:open).and_return(socket)

    expect { call }.to raise_error(Workspace::Error, "The agent for myapp closed the connection without replying")
  end

  it "prints the daemon's warning" do
    with_daemon(started.merge("warning" => "WC-7 has a pipeline stage running on this pane")) { call(force: true) }

    expect(output.string).to include("Warning: WC-7 has a pipeline stage")
  end

  it "prints the JSON reply with a schema version" do
    with_daemon(started) { call(json: true) }

    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "status" => "started", "pane" => "0.1",
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
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "error" => "can't read context usage for pane 0.1",
        "code" => "context_unknown", "pane" => "0.1", "reason" => "no reading recorded",
        "fix" => "Fix: add a statusLine entry")
    end
  end

  it "emits only registered codes for the daemon's refusals" do
    refusal = {"ok" => false, "error" => "pane_busy", "message" => "busy"}
    with_daemon(refusal) { call(json: true) }

    expect(Workspace::ErrorCodes.known?(JSON.parse(output.string)["code"])).to be true
  end

  it "does not let extra reply keys overwrite the envelope's own" do
    refusal = {"ok" => false, "error" => "pane_busy", "message" => "busy", "code" => "x", "schema_version" => 9, "details" => {"a" => 1}}
    with_daemon(refusal) { call(json: true) }

    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "error" => "busy", "code" => "pane_busy")
  end

  context "when no daemon is running" do
    it "raises naming how to start one" do
      expect { call }.to raise_error(Workspace::Error, /No agent daemon for 'myapp'.*workspace agentd --name myapp/)
    end

    it "prints the JSON error contract with --json" do
      expect(call(json: true)).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => a_string_including("No agent daemon"),
        "code" => "no_daemon")
    end
  end
end
