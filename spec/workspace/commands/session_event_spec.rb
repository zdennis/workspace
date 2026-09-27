require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::SessionEvent do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:socket_path) { File.join(tmpdir, "agent.sock") }
  let(:env) { {"TMUX_PANE" => "%2"} }

  after { FileUtils.remove_entry(tmpdir) }

  before do
    allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path)
    allow(tmux).to receive(:session_name_for_pane).with("%2").and_return("proj")
  end

  def invoke(payload, workspace: nil)
    command = described_class.new(config: config, tmux: tmux,
      input: StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload)), env: env)
    command.call(workspace: workspace)
  end

  # Stands up a listener, runs the hook, and returns what arrived.
  def deliver(payload)
    File.unlink(socket_path) if File.exist?(socket_path)
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      client = server.accept
      received = JSON.parse(client.gets)
      client.puts(JSON.generate("ok" => true))
      client.close
    end
    invoke(payload)
    listener.join(2)
    received
  ensure
    server&.close
  end

  describe "#call" do
    it "forwards a sub-agent start with the pane it came from" do
      event = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Task",
        "session_id" => "sess-1", "cwd" => "/project",
        "tool_input" => {"subagent_type" => "eval-baseline"})

      expect(event).to include(
        "type" => "session_event", "event" => "subagent_start",
        "pane_id" => "%2", "workspace" => "proj", "session_id" => "sess-1",
        "agent" => {"name" => "eval-baseline"}
      )
    end

    it "falls back to the task description when no subagent type is given" do
      event = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Task",
        "tool_input" => {"description" => "review the diff"})

      expect(event["agent"]).to eq("name" => "review the diff")
    end

    it "translates each agent event name into workspace's own" do
      {"SessionStart" => "session_start", "SessionEnd" => "session_end",
       "UserPromptSubmit" => "user_prompt", "Stop" => "stop",
       "SubagentStop" => "subagent_stop"}.each do |hook, expected|
        expect(deliver("hook_event_name" => hook)["event"]).to eq(expected)
      end
    end

    it "forwards a notification with the agent's message, so the pane shows as waiting" do
      event = deliver("hook_event_name" => "Notification", "session_id" => "sess-1",
        "message" => "Claude needs your permission to use Bash")

      expect(event).to include("event" => "notification", "pane_id" => "%2",
        "message" => "Claude needs your permission to use Bash")
    end

    it "cuts a long notification message instead of dropping it" do
      event = deliver("hook_event_name" => "Notification", "message" => "x" * 500)

      expect(event["message"].length).to eq(described_class::MAX_MESSAGE_LENGTH)
    end

    it "forwards a PostToolUse as tool use, which ends a wait for permission" do
      event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "message" => "not a notification")

      expect(event["event"]).to eq("tool_use")
      expect(event).not_to have_key("message")
    end

    it "sends to an explicitly named workspace instead of the pane's session" do
      allow(config).to receive(:agent_socket_path).with("other").and_return(socket_path)

      server = UNIXServer.new(socket_path)
      received = nil
      listener = Thread.new do
        client = server.accept
        received = JSON.parse(client.gets)
        client.puts(JSON.generate("ok" => true))
        client.close
      end
      invoke({"hook_event_name" => "Stop"}, workspace: "other")
      listener.join(2)
      server.close

      expect(received["workspace"]).to eq("other")
    end

    context "events it must not forward" do
      it "ignores a PreToolUse for a tool other than Task" do
        expect(UNIXSocket).not_to receive(:open)

        invoke({"hook_event_name" => "PreToolUse", "tool_name" => "Read"})
      end

      it "ignores a hook event it does not subscribe to" do
        expect(UNIXSocket).not_to receive(:open)

        invoke({"hook_event_name" => "PreCompact"})
      end
    end

    context "with a lock idle tracker" do
      let(:tracker) { instance_double(Workspace::LockIdleTracker, update: []) }

      def invoke_tracked(payload)
        described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)),
          env: env, lock_idle_tracker: tracker).call
      end

      it "passes the hook event and cwd to the tracker before delivering" do
        invoke_tracked("hook_event_name" => "Stop", "cwd" => "/project")

        expect(tracker).to have_received(:update).with("Stop", cwd: "/project")
      end

      it "updates lock idle state for every tool use, not only Task" do
        invoke_tracked("hook_event_name" => "PreToolUse", "tool_name" => "Edit")

        expect(tracker).to have_received(:update).with("PreToolUse", cwd: nil)
      end

      it "updates lock idle state outside tmux too" do
        env.delete("TMUX_PANE")

        invoke_tracked("hook_event_name" => "UserPromptSubmit")

        expect(tracker).to have_received(:update).with("UserPromptSubmit", cwd: nil)
      end

      it "skips the tracker on a payload that is not a JSON object" do
        described_class.new(config: config, tmux: tmux, input: StringIO.new("[1]"), env: env, lock_idle_tracker: tracker).call

        expect(tracker).not_to have_received(:update)
      end
    end

    # A hook runs inside the agent's turn: anything that raises here surfaces
    # as a failure in the user's session.
    context "when something is wrong" do
      it "does nothing outside tmux" do
        env.delete("TMUX_PANE")

        expect { invoke({"hook_event_name" => "Stop"}) }.not_to raise_error
      end

      it "does nothing when the pane has no session" do
        allow(tmux).to receive(:session_name_for_pane).with("%2").and_return(nil)

        expect { invoke({"hook_event_name" => "Stop"}) }.not_to raise_error
      end

      it "does not raise when no daemon is listening" do
        expect { invoke({"hook_event_name" => "Stop"}) }.not_to raise_error
      end

      it "does not raise on an unparseable payload" do
        expect { invoke("{ not json") }.not_to raise_error
      end

      it "does not raise on an empty payload" do
        expect { invoke("") }.not_to raise_error
      end
    end
  end
end
