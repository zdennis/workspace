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

  def invoke(payload, workspace: nil, agent: nil)
    command = described_class.new(config: config, tmux: tmux,
      input: StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload)), env: env)
    command.call(workspace: workspace, agent: agent)
  end

  # Stands up a listener, runs the hook, and returns what arrived.
  def deliver(payload, agent = nil)
    File.unlink(socket_path) if File.exist?(socket_path)
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      client = server.accept
      received = JSON.parse(client.gets)
      client.puts(JSON.generate("ok" => true))
      client.close
    end
    invoke(payload, agent: agent)
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

    it "says a PermissionRequest is waiting on approval by tool name only, never the command" do
      event = codex("hook_event_name" => "PermissionRequest", "tool_name" => "Bash",
        "tool_input" => {"command" => "rm -rf /secret", "description" => "delete the secret"})

      expect(event["message"]).to eq("Approval requested for Bash")
      expect(JSON.generate(event)).not_to include("secret")
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
