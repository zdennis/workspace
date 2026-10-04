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

  describe "pane bindings" do
    let(:bindings) { instance_double(Workspace::PaneBindings) }
    let(:output) { StringIO.new }
    let(:entry) { {"kind" => "run", "id" => "wr_1", "session" => "proj"} }

    before do
      allow(bindings).to receive(:binding_for).with("%2").and_return(entry)
      allow(bindings).to receive(:context_for).with(entry).and_return("This pane is bound to workflow run wr_1.")
    end

    def fire(payload, pane_bindings: bindings)
      described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env,
        output: output, pane_bindings: pane_bindings).call
    end

    it "prints additionalContext on SessionStart for a bound pane, for every source" do
      %w[startup clear resume compact].each do |source|
        output.reopen(+"")
        result = fire({"hook_event_name" => "SessionStart", "source" => source})

        expect(result).to eq(exit_code: 0)
        expect(JSON.parse(output.string)).to eq("hookSpecificOutput" => {
          "hookEventName" => "SessionStart", "additionalContext" => "This pane is bound to workflow run wr_1."
        })
      end
    end

    it "points the agent back at a play bound to its pane after /clear" do
      store = Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json"))
      store.bind("%2", "kind" => "play", "id" => "play/kickoff", "instructions" => "/lib/play/kickoff.md",
        "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
      allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")

      fire({"hook_event_name" => "SessionStart", "source" => "clear"}, pane_bindings: store)

      expect(JSON.parse(output.string).dig("hookSpecificOutput", "additionalContext")).to eq(
        "This pane is following play play/kickoff in proj.\nInstructions: /lib/play/kickoff.md. Read it again and keep following it if it is no longer in your context."
      )
    end

    it "prints nothing for other events and for unbound panes" do
      fire({"hook_event_name" => "Stop"})
      allow(bindings).to receive(:binding_for).with("%2").and_return(nil)
      fire({"hook_event_name" => "SessionStart"})

      expect(output.string).to eq("")
    end

    it "ignores a binding made for another tmux session, as a reused pane id would be" do
      allow(tmux).to receive(:session_name_for_pane).with("%2").and_return("other")
      allow(config).to receive(:agent_socket_path).with("other").and_return(socket_path)

      fire({"hook_event_name" => "SessionStart"})

      expect(output.string).to eq("")
    end

    it "ignores a binding made for another pane slot, as a pane id reused after a tmux restart would be" do
      entry["pane_slot"] = "proj:0.1"
      allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.3")

      fire({"hook_event_name" => "SessionStart"})

      expect(output.string).to eq("")
    end

    it "prints the binding when the pane is still in its slot" do
      entry["pane_slot"] = "proj:0.1"
      allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")

      fire({"hook_event_name" => "SessionStart"})

      expect(output.string).to include("additionalContext")
    end

    it "never fails the hook when the session lookup raises" do
      allow(tmux).to receive(:session_name_for_pane).with("%2").and_invoke(->(_) { "proj" }, ->(_) { raise Errno::ENOENT })

      expect(fire({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
    end

    it "never fails the hook when the bindings can't be read" do
      allow(bindings).to receive(:binding_for).and_raise(Errno::EACCES)

      expect(fire({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
      expect(output.string).to eq("")
    end

    it "still forwards the event to the daemon" do
      File.unlink(socket_path) if File.exist?(socket_path)
      server = UNIXServer.new(socket_path)
      received = nil
      listener = Thread.new do
        client = server.accept
        received = JSON.parse(client.gets)
        client.puts(JSON.generate("ok" => true))
        client.close
      end
      fire({"hook_event_name" => "SessionStart"})
      listener.join(2)
      server.close

      expect(received).to include("event" => "session_start", "pane_id" => "%2")
    end
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

    it "forwards the agent_id a sub-agent's hook carries, and none for the main agent" do
      expect(deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "agent_id" => "sub-1"))
        .to include("agent_id" => "sub-1")
      expect(deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash")).not_to have_key("agent_id")
    end

    it "cuts a long notification message instead of dropping it" do
      event = deliver("hook_event_name" => "Notification", "message" => "x" * 500)

      expect(event["message"].length).to eq(described_class::MAX_MESSAGE_LENGTH)
    end

    it "forwards the transcript path the agent reports, and none when it reports none" do
      expect(deliver("hook_event_name" => "Stop", "transcript_path" => "/home/u/.claude/projects/p/sess-1.jsonl"))
        .to include("transcript_path" => "/home/u/.claude/projects/p/sess-1.jsonl")
      expect(deliver("hook_event_name" => "Stop")).not_to have_key("transcript_path")
    end

    it "drops a transcript path that is not text" do
      expect(deliver("hook_event_name" => "Stop", "transcript_path" => ["a"])).not_to have_key("transcript_path")
    end

    it "cuts a multibyte prompt by character" do
      event = deliver("hook_event_name" => "UserPromptSubmit", "prompt" => "é" * 2000)

      expect(event["prompt"]).to eq("é" * described_class::MAX_PROMPT_LENGTH)
    end

    it "forwards the prompt a user submits" do
      event = deliver("hook_event_name" => "UserPromptSubmit", "prompt" => "fix the login bug")

      expect(event).to include("event" => "user_prompt", "prompt" => "fix the login bug")
    end

    it "cuts a long prompt instead of dropping it" do
      event = deliver("hook_event_name" => "UserPromptSubmit", "prompt" => "x" * 5000)

      expect(event["prompt"].length).to eq(described_class::MAX_PROMPT_LENGTH)
    end

    it "forwards a prompt only from a UserPromptSubmit" do
      event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "prompt" => "not a prompt")

      expect(event).not_to have_key("prompt")
    end

    it "drops a prompt that is not text" do
      event = deliver("hook_event_name" => "UserPromptSubmit", "prompt" => {"a" => 1})

      expect(event).not_to have_key("prompt")
    end

    it "forwards the stop reason of a Stop hook" do
      event = deliver("hook_event_name" => "Stop", "stop_reason" => "max_tokens")

      expect(event).to include("event" => "stop", "stop_reason" => "max_tokens")
    end

    it "sends no stop reason when the Stop hook has none, or it is not text" do
      expect(deliver("hook_event_name" => "Stop")).not_to have_key("stop_reason")
      expect(deliver("hook_event_name" => "Stop", "stop_reason" => 3)).not_to have_key("stop_reason")
    end

    it "cuts a long stop reason" do
      event = deliver("hook_event_name" => "Stop", "stop_reason" => "x" * 200)

      expect(event["stop_reason"].length).to eq(described_class::MAX_STOP_REASON_LENGTH)
    end

    it "forwards a stop reason only from a Stop" do
      expect(deliver("hook_event_name" => "SubagentStop", "stop_reason" => "end_turn")).not_to have_key("stop_reason")
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

      it "replaces invalid UTF-8 in the payload instead of failing the hook" do
        raw = %({"hook_event_name":"UserPromptSubmit","prompt":"a\xFFb"}).b.force_encoding("UTF-8")

        event = deliver(raw)

        expect(event).to include("event" => "user_prompt", "prompt" => "a\uFFFDb")
      end

      it "keeps valid UTF-8 when the locale tags stdin as ASCII" do
        raw = JSON.generate("hook_event_name" => "UserPromptSubmit", "prompt" => "caf\u00e9").b.force_encoding(Encoding::US_ASCII)

        expect(deliver(raw)).to include("prompt" => "caf\u00e9")
      end

      it "does not raise on a lone surrogate escape" do
        raw = %q({"hook_event_name":"UserPromptSubmit","prompt":"a\ud800b"})

        expect { invoke(raw) }.not_to raise_error
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
  describe "session ledger" do
    let(:ledger) { instance_double(Workspace::SessionLedger, record: true) }

    before do
      allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")
      allow(config).to receive(:agent_socket_path).with("other").and_return(socket_path)
    end

    def invoke_with_ledger(payload, workspace: nil, with: ledger)
      described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env,
        session_ledger: with).call(workspace: workspace)
    end

    it "records a SessionStart with the pane slot, pane id and session" do
      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1", "cwd" => "/p",
        "transcript_path" => "/t.jsonl", "source" => "resume"})

      expect(ledger).to have_received(:record).with(
        "event" => "session_start", "workspace" => "proj", "pane_slot" => "proj:0.1", "pane_id" => "%2",
        "session_id" => "s1", "transcript_path" => "/t.jsonl", "cwd" => "/p", "source" => "resume", "reason" => nil
      )
    end

    it "records a SessionEnd with its reason" do
      invoke_with_ledger({"hook_event_name" => "SessionEnd", "session_id" => "s1", "reason" => "logout"})

      expect(ledger).to have_received(:record).with(hash_including("event" => "session_end", "reason" => "logout"))
    end

    it "uses the --workspace override as the recorded workspace" do
      invoke_with_ledger({"hook_event_name" => "SessionStart"}, workspace: "other")

      expect(ledger).to have_received(:record).with(hash_including("workspace" => "other"))
    end

    it "records even when no daemon is listening" do
      expect(invoke_with_ledger({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
      expect(ledger).to have_received(:record)
    end

    it "does not record other events or look up the slot for them" do
      %w[Stop UserPromptSubmit PostToolUse Notification].each do |hook|
        invoke_with_ledger({"hook_event_name" => hook})
      end

      expect(ledger).not_to have_received(:record)
      expect(tmux).not_to have_received(:pane_slot)
    end

    it "does not record outside tmux" do
      command = described_class.new(config: config, tmux: tmux, session_ledger: ledger, env: {},
        input: StringIO.new(JSON.generate("hook_event_name" => "SessionStart")))

      command.call

      expect(ledger).not_to have_received(:record)
    end

    it "ignores a non-string session id" do
      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => 7})

      expect(ledger).to have_received(:record).with(hash_including("session_id" => nil))
    end

    it "still exits 0 and delivers when the ledger raises" do
      allow(ledger).to receive(:record).and_raise(IOError, "disk full")

      expect(invoke_with_ledger({"hook_event_name" => "SessionEnd"})).to eq(exit_code: 0)
    end

    it "still exits 0 when the slot lookup raises" do
      allow(tmux).to receive(:pane_slot).and_raise(Errno::ENOENT, "tmux")

      expect(invoke_with_ledger({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
    end

    it "writes a real ledger line end to end" do
      Dir.mktmpdir do |dir|
        real = Workspace::SessionLedger.new(path: File.join(dir, "ledger.jsonl"))
        invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1"}, with: real)

        entry = JSON.parse(File.read(File.join(dir, "ledger.jsonl")))
        expect(entry).to include("event" => "session_start", "pane_slot" => "proj:0.1", "session_id" => "s1")
      end
    end
  end
end
