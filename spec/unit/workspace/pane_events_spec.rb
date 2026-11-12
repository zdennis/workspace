RSpec.describe Workspace::PaneEvents do
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:pane) { described_class.new_pane("%2") }

  def apply(name, extra = {}, at = now)
    described_class.apply(pane, {"event" => name, "pane_id" => "%2"}.merge(extra), now: at)
  end

  describe ".new_pane" do
    it "is an unscanned pane with no agents, waits or requests" do
      expect(described_class.new_pane("%7")).to eq(
        pane_id: "%7", agents: [], waits: {}, permission_requests: {}, kind: "unknown", index: nil
      )
    end
  end

  describe ".apply" do
    it "changes the pane it is given and returns it" do
      expect(apply("user_prompt")).to equal(pane)
    end

    it "stamps the event's time, session and agent kind" do
      apply("user_prompt", "session_id" => "s1", "agent_kind" => "codex")

      expect(pane).to include(last_event_at: now, session_id: "s1", hook_kind: "codex", last_user_prompt_at: now)
    end

    it "takes an event with no kind as Claude Code's and keeps the session an event leaves out" do
      apply("user_prompt", "session_id" => "s1")
      apply("stop")

      expect(pane).to include(session_id: "s1", hook_kind: "claude")
    end

    it "records a session start with its source" do
      apply("session_start", "session_id" => "s1", "source" => "clear")

      expect(pane[:last_session_start]).to eq(at: now, source: "clear", session_id: "s1")
    end
  end

  describe "label sources" do
    it "keeps the transcript path and the cleaned last prompt" do
      apply("user_prompt", "session_id" => "s1", "transcript_path" => "/t/a.jsonl", "prompt" => "fix\nthe  bug")

      expect(pane).to include(transcript_path: "/t/a.jsonl", last_prompt: "fix the bug")
    end

    it "forgets them when another session takes the pane" do
      apply("user_prompt", "session_id" => "s1", "transcript_path" => "/t/a.jsonl", "prompt" => "old work")
      apply("session_start", "session_id" => "s2")

      expect(pane).not_to include(:transcript_path, :last_prompt)
    end
  end

  describe "open tools" do
    it "keeps the main agent's tools by id until each ends" do
      apply("tool_start", "tool" => "Bash", "tool_use_id" => "t1")
      apply("tool_start", {"tool" => "Read", "tool_use_id" => "t2"}, now + 1)
      apply("tool_use", "tool" => "Bash", "tool_use_id" => "t1")

      expect(pane[:open_tools]).to eq("t2" => {tool: "Read", since: now + 1})
    end

    it "leaves a sub-agent's tools out" do
      apply("tool_start", "tool" => "Bash", "tool_use_id" => "t1", "agent_id" => "a1")

      expect(pane[:open_tools]).to be_empty
    end

    it "clears them when the turn ends" do
      apply("tool_start", "tool" => "Bash", "tool_use_id" => "t1")
      apply("stop")

      expect(pane[:open_tools]).to be_empty
    end
  end

  describe "the main turn" do
    it "marks a main Stop done and remembers when" do
      apply("stop", "stop_reason" => "max_tokens")

      expect(pane).to include(done: {since: now, stop_reason: "max_tokens"}, main_stopped_at: now, turn_ended: true)
    end

    it "notes main activity after a Stop" do
      apply("stop")
      apply("tool_start", {"tool" => "Bash"}, now + 3)

      expect(pane).to include(main_active_at: now + 3, main_active_event: "tool_start")
    end

    it "ignores a sub-agent's Stop" do
      apply("stop", "agent_id" => "a1")

      expect(pane).not_to include(:done, :main_stopped_at)
    end

    it "keeps a failed turn until a prompt, and through a resume of the same session" do
      apply("turn_failed", "session_id" => "s1")
      apply("session_start", "session_id" => "s1")
      expect(pane[:turn_failed]).to eq(session_id: "s1")

      apply("user_prompt")
      expect(pane).not_to include(:turn_failed)
    end
  end

  describe "waits" do
    it "opens a wait on a notification, with its cleaned message" do
      apply("notification", "message" => "Pick\none")

      expect(pane[:waits]).to eq(nil => {since: now, other_prompt: true, message: "Pick one"})
    end

    it "keeps the first start through a repeat notification" do
      apply("notification", "message" => "Pick one")
      apply("notification", {"message" => "Pick one"}, now + 10)

      expect(pane[:waits][nil][:since]).to eq(now)
    end

    it "ends only the waiting agent's wait on its next event" do
      apply("notification", "agent_id" => "a1")
      apply("notification")
      apply("tool_use", "agent_id" => "a1", "tool" => "Bash")

      expect(pane[:waits].keys).to eq([nil])
    end

    it "clears every wait on a turn event" do
      apply("notification", "agent_id" => "a1")
      apply("notification")
      apply("user_prompt")

      expect(pane[:waits]).to be_empty
    end

    it "opens none for the idle prompt after a Stop" do
      apply("stop")
      apply("notification", "notification_type" => "idle_prompt", "message" => "Claude is waiting for your input")

      expect(pane[:waits]).to be_empty
    end

    it "keeps the start and alerted mark of a wait the last daemon alerted for" do
      pane[:alerted_waits] = {nil => now - 60}
      apply("notification")

      expect(pane[:waits][nil]).to include(since: now - 60, alerted: true)
    end
  end

  describe "permission requests" do
    it "files a permission wait under the one agent with a request pending" do
      apply("permission_request", "agent_id" => "a1", "tool" => "Bash", "input" => {"command" => "ls"})
      apply("notification", "notification_type" => "permission_prompt", "message" => "Allow?")

      expect(pane[:waits].keys).to eq(["a1"])
      expect(pane[:waits]["a1"]).to include(tool: "Bash", message: "Allow?")
    end

    it "names no tool when two requests are pending" do
      apply("permission_request", "agent_id" => "a1", "tool" => "Bash")
      apply("permission_request", "agent_id" => "a2", "tool" => "Edit")
      apply("notification", "notification_type" => "permission_prompt")

      expect(pane[:waits].keys).to eq([nil])
      expect(pane[:waits][nil]).not_to include(:tool)
    end

    it "drops a request when its tool ends" do
      apply("permission_request", "tool" => "Bash")
      apply("tool_use", "tool" => "Bash")

      expect(pane[:permission_requests]).to be_empty
    end
  end

  describe "sub-agents" do
    it "adds a running sub-agent, named and described" do
      apply("subagent_start", "agent" => {"name" => "eval"}, "description" => "check it", "tool_use_id" => "t1")

      expect(pane[:agents]).to eq([{name: "eval", state: "running", started_at: now, description: "check it", tool_use_id: "t1"}])
      expect(pane[:background_subagents]).to eq([{agent_id: nil}])
    end

    it "binds an id to the one unnamed running sub-agent" do
      apply("subagent_start")
      apply("tool_start", "tool" => "Bash", "agent_id" => "a1")

      expect(pane[:agents].first[:agent_id]).to eq("a1")
    end

    it "closes the named sub-agent on its stop, else the oldest" do
      apply("subagent_start", "subagent_id" => "a1")
      apply("subagent_start", "subagent_id" => "a2")
      apply("subagent_stop", {"agent_id" => "a2"}, now + 5)

      expect(pane[:agents].map { |a| [a[:agent_id], a[:state], a[:ended_at]] })
        .to eq([["a1", "running", nil], ["a2", "done", now + 5]])
      expect(pane[:background_subagents]).to eq([{agent_id: "a1"}])
    end

    it "ends running sub-agents on a main Stop but keeps them in the background" do
      apply("subagent_start", "subagent_id" => "a1")
      apply("stop")

      expect(pane[:agents].first[:state]).to eq("done")
      expect(pane[:background_subagents]).to eq([{agent_id: "a1"}])
    end

    it "forgets background sub-agents on a session start" do
      apply("subagent_start", "subagent_id" => "a1")
      apply("session_start")

      expect(pane[:background_subagents]).to be_empty
    end
  end

  describe ".clear_waiting" do
    it "ends every wait, the waiting agents' requests and the alerted marks" do
      pane[:waits] = {"a1" => {since: now}}
      pane[:permission_requests] = {"a1" => {tool: "Bash"}, "a2" => {tool: "Edit"}}
      pane[:alerted_waits] = {nil => now}

      described_class.clear_waiting(pane)

      expect(pane).to include(waits: {}, permission_requests: {"a2" => {tool: "Edit"}})
      expect(pane).not_to include(:alerted_waits)
    end
  end

  describe ".resumed_wait" do
    it "starts a new wait now" do
      expect(described_class.resumed_wait(pane, "screen", now: now)).to eq(since: now)
    end

    it "takes the alerted mark of a wait carried over" do
      pane[:alerted_waits] = {"screen" => now - 30}

      expect(described_class.resumed_wait(pane, "screen", now: now)).to eq(since: now - 30, alerted: true)
      expect(pane[:alerted_waits]).to be_empty
    end
  end
end
