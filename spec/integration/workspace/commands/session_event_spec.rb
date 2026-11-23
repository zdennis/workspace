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
    allow(tmux).to receive(:pane_layout).and_return(nil)
    allow(tmux).to receive(:server_pid_for_pane).and_return(nil)
  end

  def invoke(payload, workspace: nil, agent: nil, **options)
    command = described_class.new(config: config, tmux: tmux,
      input: StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload)), env: env, **options)
    command.call(workspace: workspace, agent: agent)
  end

  # Stands up a listener, runs the hook, and returns what arrived.
  def deliver(payload, agent = nil, options = {})
    File.unlink(socket_path) if File.exist?(socket_path)
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      client = server.accept
      received = JSON.parse(client.gets)
      client.puts(JSON.generate("ok" => true))
      client.close
    end
    invoke(payload, agent: agent, **options)
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
      # The staleness rule is PaneBindings' own, so the hook and `binding show` can't disagree.
      rule = Workspace::PaneBindings.new(path: "/nonexistent/bindings.json")
      allow(bindings).to receive(:stale?) { |bound, **now| rule.stale?(bound, **now) }
      allow(tmux).to receive(:pane_slot).with("%2").and_return(nil)
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

    context "with packs listed on the binding" do
      let(:composer) { instance_double(Workspace::InstructionComposer) }
      let(:store) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json")) }
      let(:payload) { {"hook_event_name" => "SessionStart", "source" => "clear", "cwd" => "/work/proj"} }

      before do
        store.bind("%2", "kind" => "play", "id" => "play/notes", "packs" => %w[notes handoff],
          "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")
        allow(composer).to receive(:compose).and_return({"packs" => [], "text" => "## From pack notes (built-in)\n\nKeep notes.\n"})
      end

      def fire_with(composer, source: "clear")
        described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload.merge("source" => source))), env: env,
          output: output, pane_bindings: store, instruction_composer: composer).call
      end

      def context
        JSON.parse(output.string).dig("hookSpecificOutput", "additionalContext")
      end

      it "prints the subject, then the composed packs, for every source" do
        %w[startup clear resume compact].each do |source|
          output.reopen(+"")
          expect(fire_with(composer, source: source)).to eq(exit_code: 0)

          expect(context).to eq("This pane was started with instruction packs in proj.\n\n" \
            "Instructions you were sent when this pane started:\n\n## From pack notes (built-in)\n\nKeep notes.")
        end
        expect(composer).to have_received(:compose).with(packs: %w[notes handoff], cwd: "/work/proj", binding: hash_including("id" => "play/notes")).exactly(4).times
      end

      it "never composes packs into a review pane\x27s context, so the binding pack\x27s step done line stays out" do
        store.bind("%2", "kind" => "run", "id" => "wr_1", "role" => "reviewer", "packs" => %w[binding commits],
          "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")

        fire_with(composer)

        expect(composer).not_to have_received(:compose)
        expect(context).to include("review pane").and include("Do not run `workspace step done`")
        expect(context).not_to include("Instructions you were sent")
      end

      it "cuts packs that are longer than the limit" do
        allow(composer).to receive(:compose).and_return({"packs" => [], "text" => "x" * 20_000})

        fire_with(composer)

        expect(context.length).to be < 12_500
        expect(context).to include("[cut:")
      end

      it "composes from the current directory when the payload has no cwd" do
        payload.delete("cwd")

        fire_with(composer)

        expect(composer).to have_received(:compose).with(hash_including(cwd: Dir.pwd, binding: hash_including("packs" => %w[notes handoff])))
      end

      it "prints the subject alone when a pack can no longer be read" do
        allow(composer).to receive(:compose).and_raise(Workspace::Error.new("No pack", code: "unknown_library_entry"))

        expect(fire_with(composer)).to eq(exit_code: 0)
        expect(context).to eq("This pane was started with instruction packs in proj.")
      end

      it "prints the subject alone when composing fails in any other way" do
        allow(composer).to receive(:compose).and_raise(Errno::EACCES)

        expect(fire_with(composer)).to eq(exit_code: 0)
        expect(context).to eq("This pane was started with instruction packs in proj.")
      end

      it "prints what it printed before when no composer was wired" do
        expect(fire_with(nil)).to eq(exit_code: 0)
        expect(context).to eq("This pane was started with instruction packs in proj.")
      end

      it "composes nothing for a binding with no packs" do
        store.bind("%2", "kind" => "play", "id" => "play/kickoff", "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")

        fire_with(composer)

        expect(composer).not_to have_received(:compose)
        expect(context).to eq("This pane is following play play/kickoff in proj.")
      end

      it "ignores a packs value that someone edited into something else" do
        File.write(File.join(tmpdir, "bindings.json"), JSON.generate("%2" => {"kind" => "play", "id" => "play/x", "packs" => {"a" => 1}, "session" => "proj"}))

        expect(fire_with(composer)).to eq(exit_code: 0)
        expect(composer).not_to have_received(:compose)
        expect(context).to eq("This pane is following play play/x.")
      end

      it "prints nothing, and exits 0, when the bindings file is not JSON" do
        File.write(File.join(tmpdir, "bindings.json"), "{not json")

        expect(fire_with(composer)).to eq(exit_code: 0)
        expect(output.string).to eq("")
      end

      it "prints nothing for a stale binding, composing nothing" do
        allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.7")

        fire_with(composer)

        expect(output.string).to eq("")
        expect(composer).not_to have_received(:compose)
      end
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

    it "counts the Agent tool Claude Code 2.1.314 reports as a sub-agent start" do
      event = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Agent", "tool_use_id" => "toolu_415751845",
        "tool_input" => {"description" => "bg", "prompt" => "T11SUB do it", "subagent_type" => "general-purpose"})

      expect(event).to include("event" => "subagent_start", "tool" => "Agent", "tool_use_id" => "toolu_415751845",
        "description" => "bg", "subagent_type" => "general-purpose", "agent" => {"name" => "general-purpose"})
      expect(JSON.generate(event)).not_to include("T11SUB")
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

    it "forwards a notification's type, and none for other events" do
      expect(deliver("hook_event_name" => "Notification", "notification_type" => "idle_prompt", "message" => "x"))
        .to include("notification_type" => "idle_prompt")
      expect(deliver("hook_event_name" => "Notification", "message" => "x")).not_to have_key("notification_type")
      expect(deliver("hook_event_name" => "Stop", "notification_type" => "idle_prompt")).not_to have_key("notification_type")
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

    it "translates a StopFailure into turn_failed with its error kind and session id" do
      event = deliver("hook_event_name" => "StopFailure", "session_id" => "sess-1", "error" => "rate_limit")

      expect(event).to include("event" => "turn_failed", "error" => "rate_limit", "session_id" => "sess-1")
      expect(event["event"]).not_to eq("stop")
    end

    it "leaves out a StopFailure error that is not a bare kind name" do
      ["Rate limit: try later", "rate-limit", "", 3, nil].each do |bad|
        expect(deliver("hook_event_name" => "StopFailure", "error" => bad)).not_to have_key("error")
      end
    end

    it "forwards an error only from a StopFailure" do
      expect(deliver("hook_event_name" => "Stop", "error" => "rate_limit")).not_to have_key("error")
    end

    it "drops a StopFailure from a sub-agent" do
      expect(deliver("hook_event_name" => "StopFailure", "error" => "rate_limit", "agent_id" => "sub-1")).to be_nil
    end

    describe "background tasks of a Stop" do
      def tasks_of(payload, agent = nil) = deliver({"hook_event_name" => "Stop"}.merge(payload), agent)["background_tasks"]

      it "keeps only id and type of each allowlisted task, never the description or command" do
        listed = [
          {"id" => "b1a2c3d4e", "type" => "shell", "description" => "npm run dev", "command" => "secret"},
          {"id" => "a1b2c3d4e", "type" => "subagent", "description" => "review"},
          {"id" => "k12345678", "type" => "MCP task", "status" => "running"}
        ]

        expect(tasks_of("background_tasks" => listed)).to eq([
          {"id" => "b1a2c3d4e", "type" => "shell"}, {"id" => "a1b2c3d4e", "type" => "subagent"}, {"id" => "k12345678", "type" => "MCP task"}
        ])
      end

      it "drops types off the allowlist (dream, teammate) and malformed ids and entries" do
        listed = [{"id" => "d1", "type" => "dream"}, {"id" => "t1", "type" => "teammate"}, {"id" => "bad id!", "type" => "shell"},
          {"id" => "x" * 65, "type" => "shell"}, {"id" => 7, "type" => "shell"}, "shell", {"id" => "ok-1", "type" => "monitor"}]

        expect(tasks_of("background_tasks" => listed)).to eq([{"id" => "ok-1", "type" => "monitor"}])
      end

      it "keeps at most 32 tasks" do
        listed = Array.new(40) { |i| {"id" => "t#{i}", "type" => "shell"} }

        expect(tasks_of("background_tasks" => listed).length).to eq(32)
      end

      it "sends an empty list as empty, and no key for a missing field or a non-array" do
        expect(tasks_of("background_tasks" => [])).to eq([])
        expect(deliver("hook_event_name" => "Stop")).not_to have_key("background_tasks")
        expect(deliver("hook_event_name" => "Stop", "background_tasks" => "shell")).not_to have_key("background_tasks")
        expect(deliver("hook_event_name" => "Stop", "background_tasks" => {"id" => "a"})).not_to have_key("background_tasks")
      end

      it "sends none for another event, a sub-agent's Stop, or Codex" do
        listed = [{"id" => "b1", "type" => "shell"}]

        expect(deliver("hook_event_name" => "SubagentStop", "background_tasks" => listed)).not_to have_key("background_tasks")
        expect(deliver("hook_event_name" => "Stop", "agent_id" => "sub-1", "background_tasks" => listed)).not_to have_key("background_tasks")
        expect(deliver({"hook_event_name" => "Stop", "background_tasks" => listed}, "codex")).not_to have_key("background_tasks")
      end
    end

    it "forwards a PostToolUse as tool use, which ends a wait for permission" do
      event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "message" => "not a notification")

      expect(event["event"]).to eq("tool_use")
      expect(event).not_to have_key("message")
    end

    it "forwards a PostToolUseFailure as a failed tool use, closing the tool by id" do
      event = deliver("hook_event_name" => "PostToolUseFailure", "tool_name" => "AskUserQuestion", "tool_use_id" => "toolu_1",
        "error" => "not forwarded", "is_interrupt" => true, "duration_ms" => 12)

      expect(event).to include("event" => "tool_use", "tool" => "AskUserQuestion", "tool_use_id" => "toolu_1", "ok" => false, "duration_ms" => 12)
      expect(event).not_to have_key("error")
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

    describe "a permission request" do
      it "is sent as permission_request with the tool and a summary of its input" do
        event = deliver("hook_event_name" => "PermissionRequest", "tool_name" => "Bash", "tool_use_id" => "toolu_1",
          "tool_input" => {"command" => "git push\nrm -rf x", "description" => "Push"})

        expect(event).to include("event" => "permission_request", "tool" => "Bash", "input" => "git push")
        expect(event).not_to have_key("path")
        expect(event).not_to have_key("tool_use_id")
        expect(event).not_to have_key("notification_type")
      end

      it "prints nothing to stdout" do
        expect { deliver("hook_event_name" => "PermissionRequest", "tool_name" => "Bash") }.not_to output.to_stdout
      end

      it "carries the agent_id of a sub-agent" do
        expect(deliver("hook_event_name" => "PermissionRequest", "tool_name" => "Bash", "agent_id" => "sub-1"))
          .to include("agent_id" => "sub-1")
      end

      it "cuts a multi-byte command past the limit to 4096 bytes of valid UTF-8" do
        event = deliver("hook_event_name" => "PermissionRequest", "tool_name" => "Bash",
          "tool_input" => {"command" => "echo " + "é" * 5000})

        expect(event["input"].bytesize).to be <= 4096
        expect(event["input"]).to be_valid_encoding
      end
    end

    describe "the permission policy" do
      let(:output) { StringIO.new }
      let(:error_output) { StringIO.new }
      let(:policy_config) { instance_double(Workspace::PermissionPolicyConfig) }
      let(:request) { {"hook_event_name" => "PermissionRequest", "tool_name" => "Bash", "cwd" => tmpdir, "tool_input" => {"command" => "ls"}} }
      let(:allow_policy) { Workspace::PermissionPolicy.new(layers: [{source: "project", rules: [{"tool" => "Bash", "pattern" => "ls", "action" => "allow"}], default: nil}]) }
      let(:deny_policy) { Workspace::PermissionPolicy.new(layers: [{source: "project", rules: [{"tool" => "Read", "action" => "allow"}, {"tool" => "Bash", "action" => "deny"}], default: nil}]) }
      let(:ask_policy) { Workspace::PermissionPolicy.new(layers: [{source: "project", rules: [], default: "ask"}]) }

      def decide(payload = request, agent: nil)
        event = deliver(payload, agent, output: output, error_output: error_output, permission_policy_config: policy_config)
        [event, output.string]
      end

      def reply
        JSON.parse(output.string)
      end

      it "prints one allow line and forwards the decision and rule" do
        allow(policy_config).to receive(:policy).with(workspace: "proj", project: nil).and_return(allow_policy)

        event, out = decide

        expect(out.lines.size).to eq(1)
        expect(reply).to eq("hookSpecificOutput" => {"hookEventName" => "PermissionRequest", "decision" => {"behavior" => "allow"}})
        expect(event).to include("event" => "permission_request", "tool" => "Bash", "decision" => "allow", "rule" => "project:rules[0]")
      end

      it "prints a deny line whose message names the rule" do
        allow(policy_config).to receive(:policy).and_return(deny_policy)

        event, out = decide

        expect(out.lines.size).to eq(1)
        expect(reply["hookSpecificOutput"]["decision"]).to eq("behavior" => "deny", "message" => "Denied by workspace permission policy (project:rules[1])")
        expect(event).to include("decision" => "deny", "rule" => "project:rules[1]")
      end

      it "never prints reserved fields" do
        allow(policy_config).to receive(:policy).and_return(deny_policy)

        decide

        expect(output.string).not_to match(/updatedInput|updatedPermissions|interrupt/)
      end

      it "prints nothing for an ask and forwards decision ask" do
        allow(policy_config).to receive(:policy).and_return(ask_policy)

        event, out = decide

        expect(out).to eq("")
        expect(event).to include("event" => "permission_request", "decision" => "ask", "rule" => "project:default")
      end

      it "prints nothing, and forwards no decision, when no policy is configured" do
        allow(policy_config).to receive(:policy).and_return(nil)

        event, out = decide

        expect(out).to eq("")
        expect(event).not_to have_key("decision")
        expect(event).not_to have_key("rule")
      end

      it "prints nothing for a broken configuration (policy gives nil)" do
        allow(policy_config).to receive(:policy).and_return(nil)

        expect(decide.last).to eq("")
      end

      it "prints nothing, and still forwards the event, when building the policy raises" do
        allow(policy_config).to receive(:policy).and_raise(Workspace::ConfigParseError, "boom")

        event, out = decide

        expect(out).to eq("")
        expect(event).to include("event" => "permission_request")
        expect(event).not_to have_key("decision")
      end

      it "prints nothing when the policy raises while deciding" do
        broken = instance_double(Workspace::PermissionPolicy)
        allow(broken).to receive(:decide).and_raise(RuntimeError, "boom")
        allow(policy_config).to receive(:policy).and_return(broken)

        event, out = decide

        expect(out).to eq("")
        expect(event).not_to have_key("decision")
      end

      it "decides before the daemon is reached, and exits 0 with no daemon" do
        allow(policy_config).to receive(:policy).and_return(deny_policy)
        File.unlink(socket_path) if File.exist?(socket_path)

        result = invoke(request, output: output, permission_policy_config: policy_config)

        expect(result).to eq(exit_code: 0)
        expect(reply["hookSpecificOutput"]["decision"]["behavior"]).to eq("deny")
      end

      it "still exits 0 with the reply printed when delivery raises a workspace error" do
        allow(policy_config).to receive(:policy).and_return(allow_policy)
        allow(config).to receive(:agent_socket_path).and_raise(Workspace::Error, "socket dir is too deep")

        result = invoke(request, output: output, permission_policy_config: policy_config)

        expect(result).to eq(exit_code: 0)
        expect(reply["hookSpecificOutput"]["decision"]["behavior"]).to eq("allow")
      end

      it "exits 0 on an ask when delivery raises a workspace error, and logs it to the delivery log" do
        allow(policy_config).to receive(:policy).and_return(ask_policy)
        allow(config).to receive(:agent_socket_path).and_raise(Workspace::Error, "socket dir is too deep")
        log_path = File.join(tmpdir, "delivery2.log")

        result = invoke(request, output: output, permission_policy_config: policy_config, delivery_log: Workspace::DeliveryLog.new(path: log_path))

        expect(result).to eq(exit_code: 0)
        expect(output.string).to eq("")
        expect(File.read(log_path)).to include("undeliverable event=permission_request workspace=proj", "socket dir is too deep")
      end

      describe "a failure before or during delivery" do
        let(:log_path) { File.join(tmpdir, "failure.log") }
        let(:delivery_log) { Workspace::DeliveryLog.new(path: log_path) }

        it "exits 0 and logs when the socket path lookup raises" do
          allow(config).to receive(:agent_socket_path).and_raise(Workspace::Error, "socket dir is too deep")

          expect(invoke({"hook_event_name" => "Stop"}, delivery_log: delivery_log)).to eq(exit_code: 0)
          expect(File.read(log_path)).to include("undeliverable event=stop workspace=proj pane=%2", "socket dir is too deep")
        end

        it "exits 0 and logs when delivery raises a non-IO error" do
          allow(Socket).to receive(:new).and_raise(ArgumentError, "boom")

          expect(invoke({"hook_event_name" => "Stop"}, delivery_log: delivery_log)).to eq(exit_code: 0)
          expect(File.read(log_path)).to include("undeliverable event=stop workspace=proj", "ArgumentError: boom")
        end

        it "exits 0 and logs only the class when translate raises" do
          command = described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate("hook_event_name" => "Stop")), env: env, delivery_log: delivery_log)
          allow(command).to receive(:translate).and_raise(KeyError, "secret payload text")

          expect(command.call).to eq(exit_code: 0)
          expect(File.read(log_path)).to include("undeliverable event=stop workspace=proj pane=%2", "(KeyError)")
          expect(File.read(log_path)).not_to include("secret payload text")
        end

        it "treats a raising ambiguity check as ambiguous: logs, exits 0, prints no decision, still delivers" do
          policy_config = instance_double(Workspace::PermissionPolicyConfig)
          expect(policy_config).not_to receive(:policy)
          out = StringIO.new

          event = deliver({"hook_event_name" => "PermissionRequest", "tool_name" => "Bash"}, nil, output: out, permission_policy_config: policy_config, session_ambiguous: ->(_s) { raise "ambiguity broke" }, delivery_log: delivery_log)

          expect(event).to include("event" => "permission_request")
          expect(out.string).to eq("")
          expect(File.read(log_path)).to include("RuntimeError: ambiguity broke")
        end

        it "exits 0 with stdout unchanged when the ledger write raises" do
          ledger = instance_double(Workspace::SessionLedger)
          allow(ledger).to receive(:record).and_raise(Errno::EACCES)
          allow(tmux).to receive(:pane_slot).and_return(nil)
          out = StringIO.new

          expect(invoke({"hook_event_name" => "SessionStart"}, session_ledger: ledger, output: out)).to eq(exit_code: 0)
          expect(out.string).to eq("")
        end

        it "exits 0 with stdout unchanged when the binding lookup raises" do
          bindings = instance_double(Workspace::PaneBindings)
          allow(bindings).to receive(:binding_for).and_raise(Errno::EACCES)
          out = StringIO.new

          expect(invoke({"hook_event_name" => "SessionStart"}, pane_bindings: bindings, output: out)).to eq(exit_code: 0)
          expect(out.string).to eq("")
        end

        it "exits 0 and prints no decision when the permission policy raises" do
          policy_config = instance_double(Workspace::PermissionPolicyConfig)
          allow(policy_config).to receive(:policy).and_raise(Errno::EIO)
          out = StringIO.new

          expect(invoke({"hook_event_name" => "PermissionRequest", "tool_name" => "Bash"}, permission_policy_config: policy_config, output: out)).to eq(exit_code: 0)
          expect(out.string).to eq("")
        end

        it "exits 0 and logs when the workspace lookup raises" do
          lookup = ->(_session) { raise "lookup broke" }

          expect(invoke({"hook_event_name" => "Stop"}, workspace_for_session: lookup, delivery_log: delivery_log)).to eq(exit_code: 0)
          expect(File.read(log_path)).to include("undeliverable event=stop workspace=proj pane=%2", "RuntimeError: lookup broke")
        end

        it "still exits 2 with the deny message when a guard denied and delivery would raise" do
          allow(config).to receive(:agent_socket_path).and_raise(Workspace::Error, "socket dir is too deep")
          guard = instance_double(Workspace::LockEnforcer, check: "denied by lock")
          err = StringIO.new

          result = invoke({"hook_event_name" => "PreToolUse", "tool_name" => "Edit"}, lock_enforcer: guard, error_output: err, delivery_log: delivery_log)

          expect(result).to eq(exit_code: 2)
          expect(err.string).to eq("denied by lock\n")
          expect(File.exist?(log_path)).to be(false)
        end
      end

      it "makes no decision and prints nothing for an ambiguous session, but still forwards the request" do
        expect(policy_config).not_to receive(:policy)

        event = deliver(request, nil, output: output, permission_policy_config: policy_config, session_ambiguous: ->(session) { session == "proj" })

        expect(output.string).to eq("")
        expect(event).to include("event" => "permission_request")
        expect(event).not_to have_key("decision")
      end

      it "decides for the payload's own cwd" do
        policy = instance_double(Workspace::PermissionPolicy)
        allow(policy_config).to receive(:policy).and_return(policy)
        expect(policy).to receive(:decide).with(tool_name: "Bash", tool_input: {"command" => "ls"}, cwd: tmpdir).and_return({action: "ask", rule: "global:default"})

        decide
      end

      it "writes nothing to stdout from the logger when debugging" do
        allow(policy_config).to receive(:policy).and_raise("boom")
        logger = Workspace::Logger.new(output: error_output, enabled: true)

        deliver(request, nil, output: output, logger: logger, permission_policy_config: policy_config)

        expect(output.string).to eq("")
        expect(error_output.string).to include("permission decision")
      end

      it "records the decision and rule in the delivery log line when delivery fails" do
        allow(policy_config).to receive(:policy).and_return(deny_policy)
        log_path = File.join(tmpdir, "delivery.log")

        invoke(request, output: output, permission_policy_config: policy_config, delivery_log: Workspace::DeliveryLog.new(path: log_path))

        expect(File.read(log_path)).to match(/undeliverable event=permission_request workspace=proj pane=%2 decision=deny rule=project:rules\[1\] socket=/)
      end

      it "is not consulted for any other hook" do
        expect(policy_config).not_to receive(:policy)

        deliver({"hook_event_name" => "PreToolUse", "tool_name" => "Bash"}, nil, output: output, permission_policy_config: policy_config)
      end

      describe "the hang guard" do
        let(:counter_path) { File.join(tmpdir, "hang-guard.json") }
        let(:counter) { Workspace::HangGuardCounter.new(path: counter_path, wait: 0.05) }
        let(:binding) { {"kind" => "run", "id" => "wr_1", "step" => "implement", "attempt" => 1} }
        let(:context) { {mode: "deny_with_hint", max_denies: 2, binding: binding} }
        let(:hints) { described_class::HANG_GUARD_HINTS }
        let(:explicit_ask_policy) { Workspace::PermissionPolicy.new(layers: [{source: "project", rules: [{"tool" => "Bash", "action" => "ask"}], default: nil}]) }

        before do
          allow(policy_config).to receive(:policy).and_return(nil)
          allow(policy_config).to receive(:hang_guard_context).with(workspace: "proj", project: nil) { context }
        end

        def unbound = context.merge!(binding: nil)

        def guard(payload = request, agent: nil)
          event = deliver(payload.merge("session_id" => "s1"), agent, output: output, error_output: error_output,
            permission_policy_config: policy_config, hang_guard_counter: counter, command_pieces: Workspace::BashCommandPieces.new)
          [event, output.string]
        end

        def bash(command) = request.merge("tool_input" => {"command" => command})

        def message = reply["hookSpecificOutput"]["decision"]["message"]

        def stored
          JSON.parse(File.read(counter_path))
        end

        it "denies an undecided plain Bash call in a bound pane with the unattended hint and counts it under the attempt" do
          event, out = guard

          expect(out.lines.size).to eq(1)
          expect(reply).to eq("hookSpecificOutput" => {"hookEventName" => "PermissionRequest",
                                                       "decision" => {"behavior" => "deny", "message" => hints.fetch([:bound, :other])}})
          expect(out).not_to match(/updatedInput|updatedPermissions|interrupt/)
          expect(event).to include("event" => "permission_request", "decision" => "deny", "rule" => "hang_guard")
          expect(stored["run:wr_1:implement:1"]).to include("count" => 1)
        end

        {
          "a substitution" => "for f in $(ls); do echo $f; done",
          "a pipe into a loop" => "ls | while read f; do echo \"$f\"; done",
          "backticks" => "echo `date`",
          "an array" => "files=(a b); echo ok"
        }.each do |shape, command|
          it "gives a compound Bash command with #{shape} the compound hint in a bound pane" do
            guard(bash(command))

            expect(message).to eq(hints.fetch([:bound, :compound]))
          end
        end

        it "gives any other tool the unattended hint, AskUserQuestion included, in a bound pane" do
          guard({"hook_event_name" => "PermissionRequest", "tool_name" => "AskUserQuestion", "tool_input" => {}})

          expect(message).to eq(hints.fetch([:bound, :other]))
        end

        it "words its hints by binding, names the status line only in a bound pane and the script only for a bound pane" do
          expect(hints.values).to all(include("workspace config set agent.permissions.hang_guard off"))
          expect(hints.fetch([:bound, :other])).to include("WORKFLOW_STATUS: needs_input — <question>", "workspace ask")
          expect(hints.fetch([:bound, :compound])).to include("bash <path>", "$(...)")
          expect(hints.fetch([:unbound, :compound])).to include("$(...)", "ask the person in chat")
          expect(hints.fetch([:unbound, :other])).to include("Ask the person in chat to approve it", "do without it")
          expect(hints.select { |(where, _), _| where == :unbound }.values.join).not_to match(/WORKFLOW_STATUS|bash <path>|unattended|nobody|workflow definition/)
          expect(hints.select { |(where, _), _| where == :bound }.values).to all(include("`hang_guard: off` in the workflow definition"))
        end

        it "denies an undecided Bash call in an unbound pane with the unbound hint, counted under the pane and session" do
          unbound

          event, = guard(bash("a=$(pwd); echo $a"))

          expect(event).to include("decision" => "deny", "rule" => "hang_guard")
          expect(message).to eq(hints.fetch([:unbound, :compound]))
          expect(stored.keys).to eq(["pane:%2:s1"])
        end

        it "gives a plain Bash call in an unbound pane the ask-the-person hint" do
          unbound

          guard

          expect(message).to eq(hints.fetch([:unbound, :other]))
        end

        %w[AskUserQuestion ExitPlanMode].each do |tool|
          it "never denies #{tool} in an unbound pane" do
            unbound

            event, out = guard({"hook_event_name" => "PermissionRequest", "tool_name" => tool, "tool_input" => {}})

            expect(out).to eq("")
            expect(event).not_to have_key("decision")
            expect(File.exist?(counter_path)).to be(false)
          end
        end

        it "denies a request a person's own ask rule left to the dialog in a bound pane" do
          allow(policy_config).to receive(:policy).and_return(explicit_ask_policy)

          expect(guard.first).to include("decision" => "deny", "rule" => "hang_guard")
        end

        it "shows the dialog for a person's own ask rule in an unbound pane" do
          allow(policy_config).to receive(:policy).and_return(explicit_ask_policy)
          unbound

          event, out = guard

          expect(out).to eq("")
          expect(event).to include("decision" => "ask", "rule" => "project:rules[0]")
          expect(File.exist?(counter_path)).to be(false)
        end

        it "denies a request the policy's default left to ask, bound or not" do
          allow(policy_config).to receive(:policy).and_return(ask_policy)
          expect(guard.first).to include("decision" => "deny", "rule" => "hang_guard")

          unbound
          output.truncate(0)
          output.rewind
          expect(guard.first).to include("decision" => "deny", "rule" => "hang_guard")
        end

        it "prints nothing past the cap and forwards ask with hang_guard:cap" do
          2.times { guard }
          output.truncate(0)
          output.rewind

          event, out = guard

          expect(out).to eq("")
          expect(event).to include("decision" => "ask", "rule" => "hang_guard:cap")
          expect(stored["run:wr_1:implement:1"]["count"]).to eq(2)
        end

        it "prints nothing and counts nothing when the mode is off" do
          context[:mode] = "off"

          event, out = guard

          expect(out).to eq("")
          expect(event).not_to have_key("decision")
          expect(File.exist?(counter_path)).to be(false)
        end

        it "leaves an explicit allow and deny to the policy and reads no hang guard context" do
          expect(policy_config).not_to receive(:hang_guard_context)
          allow(policy_config).to receive(:policy).and_return(allow_policy)
          expect(guard.first).to include("decision" => "allow", "rule" => "project:rules[0]")
          output.truncate(0)
          output.rewind

          allow(policy_config).to receive(:policy).and_return(deny_policy)
          event, = guard

          expect(event).to include("decision" => "deny", "rule" => "project:rules[1]")
          expect(message).to eq("Denied by workspace permission policy (project:rules[1])")
          expect(File.exist?(counter_path)).to be(false)
        end

        it "prints nothing and keeps the policy's ask when the count's lock is held" do
          allow(policy_config).to receive(:policy).and_return(ask_policy)
          event, out = File.open("#{counter_path}.lock", File::RDWR | File::CREAT, 0o600) do |held|
            held.flock(File::LOCK_EX)
            guard
          end

          expect(out).to eq("")
          expect(event).to include("decision" => "ask", "rule" => "project:default")
        end

        it "prints nothing when reading its context raises" do
          allow(policy_config).to receive(:hang_guard_context).and_raise(RuntimeError, "boom")

          event, out = guard

          expect(out).to eq("")
          expect(event).not_to have_key("decision")
        end

        it "makes no decision for an ambiguous session" do
          event = deliver(request, nil, output: output, permission_policy_config: policy_config, hang_guard_counter: counter,
            session_ambiguous: ->(_session) { true })

          expect(output.string).to eq("")
          expect(event).not_to have_key("decision")
        end

        it "is skipped with no counter" do
          event, out = decide

          expect(out).to eq("")
          expect(event).not_to have_key("decision")
        end

        it "replies to Codex with the same shape and forwards the deny as a decided permission_request" do
          event, out = guard(request, agent: "codex")

          expect(out).not_to match(/updatedInput|updatedPermissions|interrupt/)
          expect(reply["hookSpecificOutput"]["decision"]).to eq("behavior" => "deny", "message" => hints.fetch([:bound, :other]))
          expect(event).to include("event" => "permission_request", "decision" => "deny", "rule" => "hang_guard", "agent_kind" => "codex")
          expect(event).not_to have_key("notification_type")
        end
      end

      describe "for Codex" do
        it "replies without reserved fields and forwards a decided request as permission_request" do
          allow(policy_config).to receive(:policy).and_return(deny_policy)

          event, out = decide(request, agent: "codex")

          expect(out).not_to match(/updatedInput|updatedPermissions|interrupt/)
          expect(reply["hookSpecificOutput"]["decision"].keys).to eq(%w[behavior message])
          expect(event).to include("event" => "permission_request", "decision" => "deny", "rule" => "project:rules[1]", "tool" => "Bash", "agent_kind" => "codex")
          expect(event).not_to have_key("notification_type")
          expect(event).not_to have_key("message")
        end

        it "forwards an ask as the approval notification with tool, input, decision and rule" do
          allow(policy_config).to receive(:policy).and_return(ask_policy)

          event, out = decide(request, agent: "codex")

          expect(out).to eq("")
          expect(event).to include("event" => "notification", "notification_type" => "permission_request", "message" => "Approval requested for Bash",
            "tool" => "Bash", "input" => "ls", "decision" => "ask", "rule" => "project:default")
        end

        it "keeps today's notification when no decision was made" do
          allow(policy_config).to receive(:policy).and_return(nil)

          event, = decide(request, agent: "codex")

          expect(event).to include("event" => "notification", "notification_type" => "permission_request", "tool" => "Bash", "input" => "ls")
          expect(event).not_to have_key("decision")
        end
      end
    end

    describe "verdict hashes" do
      let(:checkout) { File.join(tmpdir, "repo") }
      let(:round_dir) { File.join(checkout, ".workflow", "wr_1", "reviews", "review.1.r2") }
      let(:bindings) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json")) }
      let(:verdict) { File.join(round_dir, "skeptic.md") }

      before do
        FileUtils.mkdir_p(round_dir)
        FileUtils.mkdir_p(File.join(checkout, ".git"))
        bindings.bind("%2", "kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "review", "attempt" => 1, "round" => 2,
          "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
      end

      def finish(tool, path, hook: "PostToolUse", cwd: checkout, response: {})
        payload = {"hook_event_name" => hook, "tool_name" => tool, "cwd" => cwd, "tool_input" => {"file_path" => path}, "tool_response" => response}
        File.unlink(socket_path) if File.exist?(socket_path)
        server = UNIXServer.new(socket_path)
        received = nil
        listener = Thread.new do
          client = server.accept
          received = JSON.parse(client.gets)
          client.puts(JSON.generate("ok" => true))
          client.close
        end
        described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env, pane_bindings: bindings).call
        listener.join(2)
        received
      ensure
        server&.close
      end

      it "hashes the file on disk after a Write, an Edit and a MultiEdit" do
        File.write(verdict, "verdict: approve\n")
        expected = Digest::SHA256.hexdigest("verdict: approve\n")

        %w[Write Edit MultiEdit].each do |tool|
          expect(finish(tool, verdict)["sha256"]).to eq(expected)
        end
      end

      it "takes the path relative to the hook's cwd" do
        File.write(verdict, "x")

        expect(finish("Write", "reviews/review.1.r2/skeptic.md", cwd: File.join(checkout, ".workflow", "wr_1"))["sha256"]).to eq(Digest::SHA256.hexdigest("x"))
      end

      it "gives none for a Read, a PreToolUse or a failed tool" do
        File.write(verdict, "x")

        expect(finish("Read", verdict)).not_to have_key("sha256")
        expect(finish("Write", verdict, hook: "PreToolUse")).not_to have_key("sha256")
        expect(finish("Write", verdict, response: {"is_error" => true})).not_to have_key("sha256")
      end

      it "gives none for a link, a file outside the round directory, a missing file or one over the cap" do
        File.write(File.join(tmpdir, "real"), "x")
        File.symlink(File.join(tmpdir, "real"), verdict)
        expect(finish("Write", verdict)).not_to have_key("sha256")

        File.write(File.join(checkout, "other.md"), "x")
        expect(finish("Write", File.join(checkout, "other.md"))).not_to have_key("sha256")

        other_round = File.join(checkout, ".workflow", "wr_1", "reviews", "review.1.r1")
        FileUtils.mkdir_p(other_round)
        File.write(File.join(other_round, "a.md"), "x")
        expect(finish("Write", File.join(other_round, "a.md"))).not_to have_key("sha256")

        expect(finish("Write", File.join(round_dir, "missing.md"))).not_to have_key("sha256")

        File.delete(verdict)
        File.write(verdict, "x" * (described_class::VERDICT_MAX_BYTES + 1))
        expect(finish("Write", verdict)).not_to have_key("sha256")
      end

      it "gives none when a directory on the way is a link" do
        elsewhere = File.join(tmpdir, "elsewhere")
        FileUtils.mkdir_p(elsewhere)
        File.write(File.join(elsewhere, "a.md"), "x")
        File.symlink(elsewhere, File.join(round_dir, "sub"))

        expect(finish("Write", File.join(round_dir, "sub", "a.md"))).not_to have_key("sha256")
      end

      context "with the binding's artifacts directory" do
        let(:artifacts) { File.join(checkout, ".workflow", "wr_1") }

        before do
          bindings.bind("%2", "kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "review", "attempt" => 1, "round" => 2,
            "artifacts" => artifacts, "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        end

        it "hashes a verdict when the hook's cwd is in a nested repository" do
          nested = File.join(checkout, "vendor", "lib")
          FileUtils.mkdir_p(File.join(nested, ".git"))
          File.write(verdict, "x")

          expect(finish("Write", verdict, cwd: nested)["sha256"]).to eq(Digest::SHA256.hexdigest("x"))
        end

        it "gives none when reviews/, the run directory or the artifacts directory is a link" do
          File.write(verdict, "x")
          moved = File.join(tmpdir, "moved")
          FileUtils.mv(File.join(artifacts, "reviews"), moved)
          File.symlink(moved, File.join(artifacts, "reviews"))
          expect(finish("Write", verdict)).not_to have_key("sha256")

          File.unlink(File.join(artifacts, "reviews"))
          FileUtils.mv(artifacts, File.join(tmpdir, "run"))
          File.symlink(File.join(tmpdir, "run"), artifacts)
          expect(finish("Write", verdict)).not_to have_key("sha256")
        end
      end

      it "gives none when the run directory is a link, with no artifacts recorded" do
        File.write(verdict, "x")
        FileUtils.mv(File.join(checkout, ".workflow", "wr_1"), File.join(tmpdir, "run"))
        File.symlink(File.join(tmpdir, "run"), File.join(checkout, ".workflow", "wr_1"))

        expect(finish("Write", verdict)).not_to have_key("sha256")
      end

      it "never raises on a corrupt bindings file" do
        File.write(File.join(tmpdir, "bindings.json"), "{not json")
        allow(bindings).to receive(:binding_for).and_raise(JSON::ParserError)

        expect(finish("Write", verdict)).to include("event" => "tool_use")
      end

      it "gives none for a pane that is not a reviewer's" do
        bindings.bind("%2", "kind" => "run", "id" => "wr_1", "step" => "review", "attempt" => 1, "round" => 2,
          "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        File.write(verdict, "x")

        expect(finish("Write", verdict)).not_to have_key("sha256")
      end
    end

    describe "tool uses" do
      let(:checkout) { File.join(tmpdir, "repo") }

      before do
        FileUtils.mkdir_p(File.join(checkout, "src", "app"))
        FileUtils.mkdir_p(File.join(checkout, ".git"))
      end

      it "forwards a PreToolUse for any tool as a tool start with its name and id" do
        event = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Bash", "tool_use_id" => "toolu_1",
          "tool_input" => {"command" => "rm -rf secret", "description" => "Delete the secret"})

        expect(event).to include("event" => "tool_start", "tool" => "Bash", "tool_use_id" => "toolu_1")
        expect(event).not_to have_key("agent")
        expect(event).not_to have_key("path")
      end

      it "never forwards the tool's input, its response, or more of a command than its first line" do
        event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "cwd" => checkout,
          "tool_input" => {"command" => "echo ok\nexport TOKEN=hunter2"}, "tool_response" => {"stdout" => "hunter2"})

        expect(JSON.generate(event)).not_to include("hunter2")
        expect(event["input"]).to eq("echo ok")
        expect(event.keys).not_to include("tool_input", "tool_response")
      end

      it "forwards an input summary on a start and a finish, and none for a tool without a rule" do
        start = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Grep", "tool_input" => {"pattern" => "todo", "path" => "lib"})
        done = deliver("hook_event_name" => "PostToolUse", "tool_name" => "WebFetch", "tool_input" => {"url" => "https://example.com/a"})
        other = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Skill", "tool_input" => {"skill" => "x"})

        expect(start["input"]).to eq("todo (in lib)")
        expect(done["input"]).to eq("https://example.com/a")
        expect(other).not_to have_key("input")
      end

      it "names a sub-agent only on a Task start, never from another tool's description" do
        event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash",
          "tool_input" => {"command" => "ls", "description" => "List files"})

        expect(event).not_to have_key("agent")
        expect(JSON.generate(event)).not_to include("List files")
      end

      it "forwards a PostToolUse with the tool, whether it worked, and a duration the payload gives" do
        event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "tool_use_id" => "toolu_1",
          "duration_ms" => 1234.4, "tool_response" => {"stdout" => "x"})

        expect(event).to include("event" => "tool_use", "tool" => "Bash", "ok" => true, "duration_ms" => 1234)
      end

      it "reads a failed tool from the response, and leaves out a duration that is not a number" do
        [{"is_error" => true}, {"success" => false}, {"interrupted" => true}].each do |response|
          event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "Write", "tool_response" => response, "duration_ms" => "5")

          expect(event).to include("ok" => false)
          expect(event).not_to have_key("duration_ms")
        end
      end

      it "counts a response that is not an object as a tool that worked" do
        expect(deliver("hook_event_name" => "PostToolUse", "tool_name" => "Read", "tool_response" => "text")).to include("ok" => true)
      end

      it "forwards a file tool's path relative to the checkout, from a directory inside it" do
        %w[Edit Write Read MultiEdit].each do |tool|
          event = deliver("hook_event_name" => "PreToolUse", "tool_name" => tool, "cwd" => File.join(checkout, "src"),
            "tool_input" => {"file_path" => File.join(checkout, "src", "app", "x.ts"), "content" => "secret"})

          expect(event["path"]).to eq("src/app/x.ts")
          expect(JSON.generate(event)).not_to include("secret")
        end
      end

      it "reads a notebook tool's notebook_path, and resolves a relative path against cwd" do
        event = deliver("hook_event_name" => "PostToolUse", "tool_name" => "NotebookEdit", "cwd" => File.join(checkout, "src"),
          "tool_input" => {"notebook_path" => "../nb/a.ipynb"})

        expect(event["path"]).to eq("nb/a.ipynb")
      end

      it "leaves out a path outside the checkout, one with control characters, and a non-file tool's" do
        outside = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Read", "cwd" => checkout,
          "tool_input" => {"file_path" => "/etc/passwd"})
        control = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Read", "cwd" => checkout,
          "tool_input" => {"file_path" => File.join(checkout, "a\e[31m.rb")})
        grep = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Grep", "cwd" => checkout,
          "tool_input" => {"path" => File.join(checkout, "src")})
        nowhere = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Read", "cwd" => "/",
          "tool_input" => {"file_path" => "/etc/passwd"})

        [outside, control, grep, nowhere].each { |event| expect(event).not_to have_key("path") }
      end

      it "forwards a Task start as a sub-agent start with its description and type, cut and cleaned" do
        event = deliver("hook_event_name" => "PreToolUse", "tool_name" => "Task", "tool_use_id" => "toolu_9",
          "tool_input" => {"description" => "Review\nthe #{"x" * 300}", "subagent_type" => "reviewer", "prompt" => "the secret plan"})

        expect(event).to include("event" => "subagent_start", "tool" => "Task", "tool_use_id" => "toolu_9", "subagent_type" => "reviewer")
        expect(event["description"]).to start_with("Review the x")
        expect(event["description"].length).to eq(described_class::MAX_DESCRIPTION_LENGTH)
        expect(JSON.generate(event)).not_to include("secret plan")
      end

      it "cuts a tool name and leaves out one that is not text" do
        expect(deliver("hook_event_name" => "PreToolUse", "tool_name" => "T" * 100)["tool"].length).to eq(described_class::MAX_NAME_LENGTH)
        expect(deliver("hook_event_name" => "PreToolUse", "tool_name" => 7)).not_to have_key("tool")
      end
    end

    it "forwards a session start's source and a session end's reason, with the agent kind" do
      expect(deliver("hook_event_name" => "SessionStart", "source" => "resume")).to include("kind" => "claude", "source" => "resume")
      expect(deliver("hook_event_name" => "SessionEnd", "reason" => "logout")).to include("kind" => "claude", "reason" => "logout")
      expect(deliver("hook_event_name" => "Stop")).not_to have_key("kind")
    end

    describe "a daemon that doesn't answer" do
      let(:fast) { {connect_timeout: 0.05, reply_timeout: 0.05} }

      def invoke_fast(payload)
        described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env, **fast)
          .call
      end

      it "gives up on the reply in time, and the line still reaches the daemon" do
        server = UNIXServer.new(socket_path)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(invoke_fast("hook_event_name" => "PreToolUse", "tool_name" => "Bash")).to eq(exit_code: 0)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        client = server.accept
        expect(JSON.parse(client.gets)).to include("event" => "tool_start")
        client.close
      ensure
        server&.close
      end

      it "exits 0 when the socket is there but nothing listens on it" do
        server = UNIXServer.new(socket_path)
        server.close

        expect(invoke_fast("hook_event_name" => "Stop")).to eq(exit_code: 0)
      end
    end

    it "still denies an edit with exit 2, and forwards nothing for it" do
      enforcer = instance_double(Workspace::LockEnforcer, check: "edit lock held by another agent")
      error_output = StringIO.new
      result = described_class.new(config: config, tmux: tmux, env: env, error_output: error_output, lock_enforcer: enforcer,
        input: StringIO.new(JSON.generate("hook_event_name" => "PreToolUse", "tool_name" => "Edit"))).call

      expect(result).to eq(exit_code: 2)
      expect(error_output.string).to include("edit lock held")
      expect(config).not_to have_received(:agent_socket_path)
    end

    it "denies with exit 2 when the workflow deny check refuses a Bash command, and the lock check allows it" do
      enforcer = instance_double(Workspace::LockEnforcer, check: nil)
      deny = instance_double(Workspace::WorkflowDeny)
      allow(deny).to receive(:check).with(tool_name: "Bash", tool_input: {"command" => "git push"}).and_return("denied by workflow x")
      error_output = StringIO.new
      payload = {"hook_event_name" => "PreToolUse", "tool_name" => "Bash", "tool_input" => {"command" => "git push"}}
      result = described_class.new(config: config, tmux: tmux, env: env, error_output: error_output, lock_enforcer: enforcer, workflow_deny: deny,
        input: StringIO.new(JSON.generate(payload))).call

      expect(result).to eq(exit_code: 2)
      expect(error_output.string).to include("denied by workflow x")
    end

    context "with a review write guard over a real reviewer binding" do
      let(:checkout) { File.join(tmpdir, "repo") }
      let(:round_dir) { File.join(checkout, ".workflow", "wr_1", "reviews", "review.1.r2") }
      let(:bindings) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json")) }
      let(:guard) { Workspace::ReviewWriteGuard.new(pane_bindings: bindings, tmux: tmux, env: env) }

      before do
        FileUtils.mkdir_p(round_dir)
        FileUtils.mkdir_p(File.join(checkout, ".git"))
        allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")
      end

      def pre(tool, path, agent_id: nil)
        payload = {"hook_event_name" => "PreToolUse", "tool_name" => tool, "cwd" => checkout, "tool_input" => {"file_path" => path}}
        payload["agent_id"] = agent_id if agent_id
        error_output = StringIO.new
        result = described_class.new(config: config, tmux: tmux, env: env, error_output: error_output, review_write_guard: guard,
          input: StringIO.new(JSON.generate(payload))).call
        [result, error_output.string]
      end

      context "in a reviewer pane" do
        before do
          bindings.bind("%2", "kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "review", "attempt" => 1, "round" => 2,
            "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        end

        it "refuses the main thread's Write inside the round directory" do
          result, stderr = pre("Write", File.join(round_dir, "skeptic.md"))

          expect(result).to eq(exit_code: 2)
          expect(stderr).to include("main thread")
        end

        it "allows a sub-agent's Write of a verdict file" do
          expect(pre("Write", File.join(round_dir, "skeptic.md"), agent_id: "sub1").first).to eq(exit_code: 0)
        end

        it "refuses a sub-agent's Edit elsewhere" do
          result, stderr = pre("Edit", File.join(checkout, "lib.rb"), agent_id: "sub1")

          expect(result).to eq(exit_code: 2)
          expect(stderr).to include("verdict files")
        end
      end

      context "in a direct round's reviewer pane" do
        before do
          bindings.bind("%2", "kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "review", "attempt" => 1, "round" => 2, "direct" => true,
            "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        end

        it "allows the main thread's Write of the verdict file" do
          expect(pre("Write", File.join(round_dir, "skeptic.md")).first).to eq(exit_code: 0)
        end

        it "refuses the main thread's write outside the round directory and to summary.md" do
          [File.join(checkout, "lib.rb"), File.join(round_dir, "summary.md")].each do |path|
            result, stderr = pre("Write", path)

            expect(result).to eq(exit_code: 2)
            expect(stderr).to include("verdict files")
          end
        end
      end

      it "leaves an unbound pane alone" do
        expect(pre("Write", File.join(checkout, "lib.rb")).first).to eq(exit_code: 0)
      end
    end

    context "with a reflection write guard over a real reflection binding" do
      let(:evidence) { File.join(tmpdir, "evidence") }
      let(:bindings) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json")) }
      let(:ref_config) { instance_double(Workspace::Config, workflow_evidence_dir: evidence) }
      let(:guard) { Workspace::ReflectionWriteGuard.new(pane_bindings: bindings, tmux: tmux, config: ref_config, env: env) }

      before do
        FileUtils.mkdir_p(File.join(evidence, "wr_1"))
        allow(tmux).to receive(:pane_slot).with("%2").and_return("proj:0.1")
        bindings.bind("%2", "kind" => "reflection", "id" => "wr_1", "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
      end

      def pre(path)
        payload = {"hook_event_name" => "PreToolUse", "tool_name" => "Write", "cwd" => tmpdir, "tool_input" => {"file_path" => path}}
        error_output = StringIO.new
        result = described_class.new(config: config, tmux: tmux, env: env, error_output: error_output, reflection_write_guard: guard,
          input: StringIO.new(JSON.generate(payload))).call
        [result, error_output.string]
      end

      it "allows reflection.md and refuses any other write" do
        expect(pre(File.join(evidence, "wr_1", "reflection.md")).first).to eq(exit_code: 0)

        result, stderr = pre(File.join(tmpdir, "lib.rb"))

        expect(result).to eq(exit_code: 2)
        expect(stderr).to include("reflection pane for run wr_1", "workspace binding clear --pane %2")
      end

      def hook(name)
        described_class.new(config: config, tmux: tmux, env: env, reflection_write_guard: guard,
          input: StringIO.new(JSON.generate({"hook_event_name" => name, "cwd" => tmpdir}))).call
      end

      it "ends the binding on Stop once reflection.md is written, and on SessionEnd whatever the file's state" do
        hook("Stop")
        expect(bindings.binding_for("%2")).not_to be_nil

        File.write(File.join(evidence, "wr_1", "reflection.md"), "x")
        hook("Stop")
        expect(bindings.binding_for("%2")).to be_nil

        bindings.bind("%2", "kind" => "reflection", "id" => "wr_1", "workspace" => "proj", "session" => "proj", "pane_slot" => "proj:0.1")
        hook("SessionEnd")
        expect(bindings.binding_for("%2")).to be_nil
      end
    end

    context "events it must not forward" do
      it "ignores a hook event it does not subscribe to" do
        expect(Socket).not_to receive(:new)

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

    context "with a dev session release" do
      let(:release) { instance_double(Workspace::DevSessionRelease, call: false) }

      def invoke_releasing(payload, hook_env = env)
        described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)),
          env: hook_env, dev_session_release: release).call
      end

      it "hands the ended session, its directory and the reason to it on SessionEnd" do
        invoke_releasing("hook_event_name" => "SessionEnd", "session_id" => "s1", "cwd" => "/project", "reason" => "logout")

        expect(release).to have_received(:call).with(session_id: "s1", cwd: "/project", reason: "logout")
      end

      it "hands it a clear too, so the release itself can refuse it" do
        invoke_releasing("hook_event_name" => "SessionEnd", "session_id" => "s1", "reason" => "clear")

        expect(release).to have_received(:call).with(session_id: "s1", cwd: nil, reason: "clear")
      end

      it "does nothing on a SessionStart, clear or not, or on any other hook" do
        invoke_releasing("hook_event_name" => "SessionStart", "session_id" => "s1", "source" => "clear")
        invoke_releasing("hook_event_name" => "Stop", "session_id" => "s1")
        invoke_releasing("hook_event_name" => "UserPromptSubmit", "session_id" => "s1")

        expect(release).not_to have_received(:call)
      end

      it "still releases when the hook runs outside tmux" do
        invoke_releasing({"hook_event_name" => "SessionEnd", "session_id" => "s1"}, {})

        expect(release).to have_received(:call)
      end

      it "skips a payload that is not a JSON object" do
        described_class.new(config: config, tmux: tmux, input: StringIO.new("[1]"), env: env, dev_session_release: release).call

        expect(release).not_to have_received(:call)
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
        "event" => "session_start", "workspace" => "proj", "pane_slot" => "proj:0.1", "pane_id" => "%2", "tmux_server" => nil, "layout" => nil,
        "session_id" => "s1", "transcript_path" => "/t.jsonl", "cwd" => "/p", "source" => "resume", "reason" => nil
      )
    end

    it "marks both events of a review session with the reviewer role when WORKSPACE_REVIEW_RUN is set" do
      env["WORKSPACE_REVIEW_RUN"] = "wr_1"

      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1"})
      invoke_with_ledger({"hook_event_name" => "SessionEnd", "session_id" => "s1"})

      expect(ledger).to have_received(:record).with(hash_including("event" => "session_start", "role" => "reviewer"))
      expect(ledger).to have_received(:record).with(hash_including("event" => "session_end", "role" => "reviewer"))
    end

    it "leaves the role out without WORKSPACE_REVIEW_RUN" do
      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1"})

      expect(ledger).to have_received(:record).with(hash_excluding("role"))
    end

    it "records the layout of the pane's window with both events, so restore can put a pane back" do
      allow(tmux).to receive(:pane_layout).with("%2").and_return("b25f,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")

      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1"})
      invoke_with_ledger({"hook_event_name" => "SessionEnd", "session_id" => "s1"})

      expect(ledger).to have_received(:record).with(hash_including("event" => "session_start", "layout" => "b25f,80x24,0,0[80x12,0,0,1,80x11,0,13,2]"))
      expect(ledger).to have_received(:record).with(hash_including("event" => "session_end", "layout" => "b25f,80x24,0,0[80x12,0,0,1,80x11,0,13,2]"))
    end

    it "records the tmux server's pid with both events, so restore knows whether the pane id still names the pane" do
      allow(tmux).to receive(:server_pid_for_pane).with("%2").and_return("14794")

      invoke_with_ledger({"hook_event_name" => "SessionStart", "session_id" => "s1"})
      invoke_with_ledger({"hook_event_name" => "SessionEnd", "session_id" => "s1"})

      expect(ledger).to have_received(:record).with(hash_including("event" => "session_start", "tmux_server" => "14794"))
      expect(ledger).to have_received(:record).with(hash_including("event" => "session_end", "tmux_server" => "14794"))
    end

    it "still exits 0 when the server lookup raises" do
      allow(tmux).to receive(:server_pid_for_pane).and_raise(Errno::ENOENT, "tmux")

      expect(invoke_with_ledger({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
    end

    it "still exits 0 when the layout lookup raises" do
      allow(tmux).to receive(:pane_layout).and_raise(Errno::ENOENT, "tmux")

      expect(invoke_with_ledger({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
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
      expect(tmux).not_to have_received(:pane_layout)
      expect(tmux).not_to have_received(:server_pid_for_pane)
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
        expect(entry).not_to have_key("kind")
      end
    end

    it "names the agent on a Codex session, so restore leaves it alone" do
      described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate("hook_event_name" => "SessionStart")),
        env: env, session_ledger: ledger).call(agent: "codex")

      expect(ledger).to have_received(:record).with(hash_including("event" => "session_start", "kind" => "codex"))
    end
  end

  it "reads every hook event an agent is installed with, and only those, per agent" do
    described_class::AGENT_EVENTS.each do |key, table|
      expect(table.keys).to match_array(Workspace::AgentProvider.find(key).events.keys), key
    end
  end

  describe "Codex hooks (--agent codex)" do
    def codex(payload)
      deliver(payload, "codex")
    end

    it "marks every event with the agent's kind, and Claude Code's as claude" do
      expect(codex("hook_event_name" => "Stop")).to include("event" => "stop", "agent_kind" => "codex")
      expect(deliver("hook_event_name" => "Stop")).to include("agent_kind" => "claude")
    end

    it "maps Codex's events onto workspace's" do
      {
        "SessionStart" => "session_start", "SessionEnd" => "session_end", "UserPromptSubmit" => "user_prompt",
        "Stop" => "stop", "Interrupt" => "stop", "SubagentStop" => "subagent_stop", "PreToolUse" => "tool_start",
        "PostToolUse" => "tool_use", "PermissionRequest" => "notification", "SubagentStart" => "subagent_start"
      }.each do |hook, event|
        expect(codex("hook_event_name" => hook)["event"]).to eq(event), hook
      end
    end

    it "drops Codex events it does not map" do
      expect(Socket).not_to receive(:new)

      %w[PreCompact PostCompact Notification].each { |hook| invoke({"hook_event_name" => hook}, agent: "codex") }
    end

    it "says a PermissionRequest is waiting on approval by tool name only, and forwards the command's first line alone" do
      event = codex("hook_event_name" => "PermissionRequest", "tool_name" => "Bash",
        "tool_input" => {"command" => "rm -rf build\ncat /secret", "description" => "delete the secret"})

      expect(event["message"]).to eq("Approval requested for Bash")
      expect(event).to include("event" => "notification", "notification_type" => "permission_request", "tool" => "Bash", "input" => "rm -rf build")
      expect(JSON.generate(event)).not_to include("secret")
    end

    it "marks only a PermissionRequest as a permission_request notification" do
      expect(codex("hook_event_name" => "Stop")["notification_type"]).to be_nil
      expect(codex("hook_event_name" => "PreToolUse", "tool_name" => "Bash")["notification_type"]).to be_nil
    end

    it "never forwards the prompt, tool input, tool response or last assistant message" do
      events = [
        codex("hook_event_name" => "UserPromptSubmit", "prompt" => "my secret prompt"),
        codex("hook_event_name" => "PreToolUse", "tool_name" => "Bash", "tool_use_id" => "c1", "tool_input" => {"command" => "ls\ncat secret"}),
        codex("hook_event_name" => "PostToolUse", "tool_name" => "Bash", "tool_use_id" => "c1",
          "tool_input" => {"command" => "ls\ncat secret"}, "tool_response" => "secret output"),
        codex("hook_event_name" => "Stop", "last_assistant_message" => "secret reply"),
        codex("hook_event_name" => "SubagentStop", "agent_id" => "a1", "last_assistant_message" => "secret reply")
      ]

      events.each { |event| expect(JSON.generate(event)).not_to include("secret") }
      expect(events[1]).to include("tool" => "Bash", "tool_use_id" => "c1")
      expect(events[2]).to include("tool" => "Bash", "ok" => true, "input" => "ls")
    end

    it "sends a SubagentStart as the main agent's, naming the sub-agent it starts" do
      event = codex("hook_event_name" => "SubagentStart", "agent_id" => "sub-7", "agent_type" => "explorer")

      expect(event).not_to have_key("agent_id")
      expect(event).to include("subagent_id" => "sub-7", "subagent_type" => "explorer", "agent" => {"name" => "explorer"})
    end

    it "sends a SubagentStop with the stopping sub-agent's id" do
      expect(codex("hook_event_name" => "SubagentStop", "agent_id" => "sub-7")).to include("agent_id" => "sub-7")
    end

    it "does not take a PreToolUse for a tool named Task as a sub-agent start" do
      expect(codex("hook_event_name" => "PreToolUse", "tool_name" => "Task")["event"]).to eq("tool_start")
    end

    it "gives an Interrupt the stop reason interrupted" do
      expect(codex("hook_event_name" => "Interrupt")).to include("event" => "stop", "stop_reason" => "interrupted")
    end

    it "names codex as the session's kind" do
      expect(codex("hook_event_name" => "SessionStart", "source" => "startup")).to include("kind" => "codex", "source" => "startup")
    end

    it "gates Codex's apply_patch on the edit lock, with exit 2" do
      enforcer = instance_double(Workspace::LockEnforcer)
      allow(enforcer).to receive(:check) { |tool_name:, **| (tool_name == "apply_patch") ? "edit lock held by another agent" : nil }

      result = described_class.new(config: config, tmux: tmux, env: env, error_output: StringIO.new, lock_enforcer: enforcer,
        input: StringIO.new(JSON.generate("hook_event_name" => "PreToolUse", "tool_name" => "apply_patch"))).call(agent: "codex")

      expect(result).to eq(exit_code: 2)
    end

    it "drops an agent it has no table for, exiting 0, rather than read it by Claude Code's names" do
      expect(Socket).not_to receive(:new)

      expect(invoke({"hook_event_name" => "PreToolUse", "tool_name" => "Edit"}, agent: "opencode")).to eq(exit_code: 0)
    end

    it "takes the agent's name in any case" do
      expect(deliver({"hook_event_name" => "Stop"}, "Codex")).to include("agent_kind" => "codex")
    end
  end

  describe "a worktree workspace's session" do
    let(:worktree_socket) { File.join(tmpdir, "worktree.sock") }
    let(:resolver) { ->(session) { (session == "lab-wc-wt-lab-1") ? "lab-wc.worktree-lab-1" : nil } }
    let(:log_path) { File.join(tmpdir, "state", "session-event.log") }
    let(:delivery_log) { Workspace::DeliveryLog.new(path: log_path) }
    let(:ledger) { instance_double(Workspace::SessionLedger, record: true) }

    before do
      allow(config).to receive(:agent_socket_path).with("lab-wc.worktree-lab-1").and_return(worktree_socket)
      allow(config).to receive(:agent_socket_path).with("lab-wc-wt-lab-1").and_return(File.join(tmpdir, "wrong.sock"))
      allow(tmux).to receive(:session_name_for_pane).with("%2").and_return("lab-wc-wt-lab-1")
    end

    def fire(payload, workspace: nil)
      described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env,
        workspace_for_session: resolver, delivery_log: delivery_log, session_ledger: ledger).call(workspace: workspace)
    end

    it "delivers a Stop to the socket of the workspace, not the session name, and records the workspace" do
      server = UNIXServer.new(worktree_socket)
      received = nil
      listener = Thread.new do
        client = server.accept
        received = JSON.parse(client.gets)
        client.puts(JSON.generate("ok" => true))
        client.close
      end

      fire({"hook_event_name" => "Stop", "session_id" => "s1"})
      listener.join(2)

      expect(received).to include("event" => "stop", "workspace" => "lab-wc.worktree-lab-1", "pane_id" => "%2")
      expect(File.exist?(log_path)).to be(false)
    ensure
      server&.close
    end

    it "records a session start in the ledger under the workspace name" do
      allow(tmux).to receive(:pane_slot).with("%2").and_return("lab-wc-wt-lab-1:0.1")
      fire({"hook_event_name" => "SessionStart", "session_id" => "s1"})

      expect(ledger).to have_received(:record).with(hash_including("workspace" => "lab-wc.worktree-lab-1", "event" => "session_start"))
    end

    it "does nothing for a session that is no workspace's: no ledger entry, no socket tried" do
      allow(tmux).to receive(:session_name_for_pane).with("%2").and_return("stray")
      expect(config).not_to receive(:agent_socket_path)

      expect(fire({"hook_event_name" => "SessionStart"})).to eq(exit_code: 0)
      expect(ledger).not_to have_received(:record)
      expect(File.exist?(log_path)).to be(false)
    end

    it "records an event the daemon of a resolved workspace never got, once for repeats" do
      2.times { fire({"hook_event_name" => "Stop"}) }

      lines = File.readlines(log_path)
      expect(lines.size).to eq(1)
      expect(lines.first).to match(/undeliverable event=stop workspace=lab-wc\.worktree-lab-1 pane=%2 socket=#{Regexp.escape(worktree_socket)} \(Errno::ENOENT/)
    end

    it "lets --workspace win over the session lookup" do
      allow(config).to receive(:agent_socket_path).with("other").and_return(File.join(tmpdir, "other.sock"))

      fire({"hook_event_name" => "Stop"}, workspace: "other")

      expect(File.read(log_path)).to include("workspace=other")
    end

    it "does not fail the hook when the delivery log cannot be written" do
      FileUtils.mkdir_p(log_path)

      expect(fire({"hook_event_name" => "Stop"})).to eq(exit_code: 0)
    end
  end
  describe "regression: the socket is named after the workspace, not the tmux session" do
    it "writes a worktree session's Stop to workspace-lab-wc.worktree-lab-1.sock" do
      dir = Dir.mktmpdir("s", "/tmp")
      allow(config).to receive(:agent_socket_path) { |name| File.join(dir, "workspace-#{name}.sock") }
      allow(tmux).to receive(:session_name_for_pane).with("%2").and_return("lab-wc-wt-lab-1")
      allow(tmux).to receive(:session_option).with("lab-wc-wt-lab-1", "@workspace").and_return("lab-wc.worktree-lab-1")
      resolver = Workspace::SessionWorkspace.new(tmux: tmux, project_config: instance_double(Workspace::ProjectConfig), config: config)
      server = UNIXServer.new(File.join(dir, "workspace-lab-wc.worktree-lab-1.sock"))
      received = nil
      listener = Thread.new do
        client = server.accept
        received = JSON.parse(client.gets)
        client.puts(JSON.generate("ok" => true))
        client.close
      end

      described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate("hook_event_name" => "Stop")), env: env,
        workspace_for_session: resolver).call
      listener.join(2)

      expect(received).to include("event" => "stop", "workspace" => "lab-wc.worktree-lab-1")
    ensure
      server&.close
      FileUtils.remove_entry(dir) if dir
    end
  end
end
