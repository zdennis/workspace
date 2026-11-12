RSpec.describe Workspace::PaneScreenRules do
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:pane) { Workspace::PaneEvents.new_pane("%2").merge(kind: "claude", pid: 200, index: 1) }
  let(:claude) { Workspace::AgentProvider.find("claude") }
  let(:codex) { Workspace::AgentProvider.find("codex") }
  let(:rule) { "─" * 40 }
  let(:ready) { "⏺ Bash(touch a.txt)\n  ⎿  Interrupted · What should Claude do instead?\n\n#{rule}\n❯ \n#{rule}\n  status line\n" }
  let(:sign_in) { "Welcome to Codex\n\n  1. Sign in with ChatGPT\n  2. Provide your own API key\n" }

  def bound_wait(agent_id = nil, tool: "Bash", input: "ls")
    pane[:waits][agent_id] = {since: now - 5, tool: tool, input: input}
    pane[:permission_requests][agent_id] = {tool: tool, input: input}
  end

  describe ".end_answered_permission_waits" do
    it "ends each bound wait and its alert entry once the ready prompt is back, keeping a newer request" do
      bound_wait
      bound_wait("a2")
      pane[:permission_requests]["a2"] = {tool: "Write", input: "a.rb"}
      pane[:alerted_waits] = {nil => now - 5}
      pane[:waits]["sub"] = {since: now - 3}

      described_class.end_answered_permission_waits(pane, claude, ready + "\n\n")

      expect(pane[:waits].keys).to eq(["sub"])
      expect(pane[:alerted_waits]).to be_empty
      expect(pane[:permission_requests]).to eq("a2" => {tool: "Write", input: "a.rb"})
    end

    it "changes nothing for a menu row, an empty screen, another agent or no agent" do
      bound_wait
      menu = "  4. Type something.\n#{rule}\n❯ 5. Chat about this\n"

      described_class.end_answered_permission_waits(pane, claude, menu)
      described_class.end_answered_permission_waits(pane, claude, "\n \n")
      described_class.end_answered_permission_waits(pane, codex, ready)
      described_class.end_answered_permission_waits(pane, nil, ready)

      expect(pane[:waits].keys).to eq([nil])
    end
  end

  describe ".screen_wait" do
    it "opens a screen wait with the provider's message, taking up one already alerted for" do
      described_class.screen_wait(pane, codex, sign_in, now)
      expect(pane[:waits].values).to eq([{since: now, message: "Codex is asking you to sign in"}])

      pane[:waits].clear
      pane[:alerted_waits] = {"screen" => now - 60}
      described_class.screen_wait(pane, codex, sign_in, now)
      expect(pane[:waits]["screen"]).to include(since: now - 60, alerted: true)
    end

    it "keeps the wait's start while the screen stays, and drops it with its alert entry once it goes" do
      described_class.screen_wait(pane, codex, sign_in, now)
      described_class.screen_wait(pane, codex, sign_in, now + 10)
      expect(pane[:waits].values.map { |wait| wait[:since] }).to eq([now])

      pane[:alerted_waits] = {"screen" => now}
      described_class.screen_wait(pane, codex, "ordinary output\n", now + 20)
      expect(pane[:waits]).to be_empty
      expect(pane[:alerted_waits]).to be_empty
    end

    it "opens none while a hook's wait is open, and says nothing on an empty screen" do
      pane[:waits]["a1"] = {since: now - 5}
      described_class.screen_wait(pane, codex, sign_in, now)
      expect(pane[:waits].keys).to eq(["a1"])

      pane[:waits] = {"screen" => {since: now - 5}}
      described_class.screen_wait(pane, codex, "", now)
      expect(pane[:waits].keys).to eq(["screen"])
    end
  end

  describe ".question_tools" do
    it "lists the open question tools in the order they opened" do
      pane[:open_tools] = {"t1" => {tool: "Bash"}, "t2" => {tool: "ExitPlanMode"}, "t3" => {tool: "AskUserQuestion"}}

      expect(described_class.question_tools(pane)).to eq(%w[t2 t3])
      expect(described_class.question_tools(Workspace::PaneEvents.new_pane("%3"))).to eq([])
    end
  end

  describe ".hold_question" do
    before do
      pane[:open_tools] = {"t1" => {tool: "AskUserQuestion"}, "t2" => {tool: "Bash"}}
      pane[:waits].merge!(nil => {since: now - 9}, "sub" => {since: now - 9})
      pane[:alerted_waits] = {nil => now - 9}
      pane[:permission_requests][nil] = {tool: "Bash", input: "ls"}
    end

    def hold(reading, at, tools = ["t1"]) = described_class.hold_question(pane, tools, reading, at)

    it "closes the question once one reading held for HOLD seconds, ending the main agent's wait and turn" do
      expect(hold("r1", now)).to be(false)
      expect(hold("r1", now + Workspace::QuestionClosedCheck::HOLD - 1)).to be(false)
      expect(hold("r1", now + Workspace::QuestionClosedCheck::HOLD)).to be(true)

      expect(pane[:open_tools].keys).to eq(["t2"])
      expect(pane[:waits].keys).to eq(["sub"])
      expect(pane[:alerted_waits]).to be_empty
      expect(pane[:permission_requests]).to be_empty
      expect(pane).to include(turn_ended: true)
      expect(pane).not_to have_key(:question_screen)
    end

    it "starts over on another reading, another tool list or a hook event since" do
      hold("r1", now)
      hold("r2", now + 10)
      expect(hold("r2", now + 17)).to be(false)

      hold("r2", now + 20, %w[t1 t3])
      expect(hold("r2", now + 30)).to be(false)

      hold("r3", now + 40)
      pane[:last_event_at] = now + 41
      expect(hold("r3", now + 50)).to be(false)
      expect(pane[:open_tools].keys).to eq(%w[t1 t2])
    end

    it "holds nothing for a nil reading, and drops a held reading with no question open" do
      hold("r1", now)
      hold(nil, now + 1)
      expect(hold("r1", now + 20)).to be(false)
      expect(pane[:question_screen]).to eq(tools: ["t1"], reading: "r1", since: now + 20)

      expect(hold("r1", now + 30, [])).to be(false)
      expect(pane).not_to have_key(:question_screen)
    end
  end
end
