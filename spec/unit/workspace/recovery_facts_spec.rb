require "spec_helper"

RSpec.describe Workspace::RecoveryFacts do
  let(:now) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:calls) { [] }
  let(:log) { StringIO.new }
  let(:row) { {id: "%3", window: 0, index: 1, pid: 77, command: "zsh"} }
  let(:screens) { ["❯ "] }
  let(:pane) do
    FakePane.new(id: "%3", row: row, start_command: nil).tap do |fake|
      fake.tmux.screen_script = -> {
        calls << [:capture]
        (screens.size > 1) ? screens.shift : screens.first
      }
    end
  end
  let(:panes) { FakePaneFactory.new(panes: [pane]) }
  let(:process_tree) { RecordingProcessTree.new(calls: calls) }
  let(:stopper) { RecordingRecoveryStopper.new(agents: {77 => {pid: 90, started: "Mon"}}, calls: calls) }
  let(:ledger) { RecordingRecoveryLedger.new(calls: calls) }
  let(:transcript) { RecordingTurnTranscript.new(record: {"uuid" => "u1", "api_error" => true}, calls: calls) }
  let(:monitor) { RecordingRecoveryMonitor.new(delivery_facts: {last_user_prompt_at: now - 120}, calls: calls) }
  let(:typer) { RecordingInputCheck.new(calls: calls) }
  let(:entry) { {"failed_at" => (now - 60).iso8601, "session_id" => "s1", "transcript_path" => "/no/such/transcript.jsonl"} }

  def facts(**overrides)
    described_class.new(panes: panes, process_tree: process_tree, stopper: stopper, detector: :detector, ledger: ledger,
      transcript: transcript, session_monitor: monitor, prompt_typer: typer, clock: BlockClock.new { now },
      sleeper: ->(seconds) { calls << [:sleep, seconds] }, logger: Workspace::Logger.new(output: log, enabled: true),
      **overrides)
  end

  describe "#pane_detail" do
    it "answers a listed pane's details" do
      expect(facts.pane_detail("%3")).to eq(row)
    end

    it "answers nil for a pane the session doesn't list" do
      expect(facts.pane_detail("%9")).to be_nil
    end

    it "answers :unknown when tmux lists no pane and the session isn't gone, nil when it is" do
      expect(facts(panes: FakePaneFactory.new(unlisted: true)).pane_detail("%3")).to eq(:unknown)
      gone = FakePaneFactory.new(panes: [FakePane.new(id: "%3", session_gone: true)], unlisted: true)
      expect(facts(panes: gone).pane_detail("%3")).to be_nil
    end
  end

  describe "#agent" do
    it "reads the process table, then finds the agent under the pane in it" do
      reading = facts.agent(row)

      expect(reading.found).to eq(pid: 90, started: "Mon")
      expect(reading.tree).to eq(:tree)
      expect(calls).to eq([[:snapshot], [:find_agent, 77, :tree]])
    end

    it "answers a reading with no agent for a pane with none" do
      expect(facts.agent(row.merge(pid: 5)).found).to be_nil
    end

    it "answers nil, logged, when the table can't be read, and looks for no agent" do
      broken = RecordingProcessTree.new(error: Workspace::Error.new("ps failed"), calls: calls)

      expect(facts(process_tree: broken).agent(row)).to be_nil
      expect(calls).to eq([[:snapshot]])
      expect(log.string).to include("agent recovery: ps failed")
    end
  end

  describe "#live_agent" do
    it "looks the pane up, then finds the agent under it" do
      expect(facts.live_agent("%3")).to eq(pid: 90, started: "Mon")
      expect(calls).to eq([[:snapshot], [:find_agent, 77, :tree]])
    end

    it "answers nil for a pane it can't look up, reading no table" do
      expect(facts.live_agent("%9")).to be_nil
      expect(facts(panes: FakePaneFactory.new(unlisted: true)).live_agent("%3")).to be_nil
      expect(calls).to eq([])
    end

    it "answers nil when the table can't be read" do
      broken = RecordingProcessTree.new(error: Workspace::Error.new("ps failed"), calls: calls)

      expect(facts(process_tree: broken).live_agent("%3")).to be_nil
    end
  end

  it "#foreground? asks about the agent's pid against the pane's" do
    expect(facts.foreground?({pid: 90}, row)).to be(true)
    expect(calls).to eq([[:foreground?, 90, 77]])
  end

  it "#pane_clear? asks with the pane's pid, its command and the table" do
    expect(facts.pane_clear?(row, :tree)).to be(true)
    expect(calls).to eq([[:pane_clear?, 77, "zsh", :tree]])
  end

  describe "#session_held?" do
    it "reads the process table, then asks the stopper whether a process holds the session" do
      held = facts(stopper: RecordingRecoveryStopper.new(held: true, calls: calls))

      expect(held.session_held?("s1")).to be(true)
      expect(calls).to eq([[:snapshot], [:session_held?, "s1", :tree]])
    end

    it "answers false when no process holds it" do
      expect(facts.session_held?("s1")).to be(false)
    end

    it "counts a process table that can't be read as held, and asks nothing more" do
      broken = facts(process_tree: RecordingProcessTree.new(error: Workspace::Error.new("no ps"), calls: calls))

      expect(broken.session_held?("s1")).to be(true)
      expect(calls).to eq([[:snapshot]])
    end
  end

  describe "#held_off?" do
    it "reads the input line, the prompt, the sub-agents and then the screen twice across the wait" do
      expect(facts.held_off?("%3", entry, nil)).to be(false)
      expect(calls).to eq([[:check, "%3", {}], [:delivery_facts, "%3"], [:running_subagents, "%3"],
        [:capture], [:sleep, Workspace::AgentRestart::QUIET_FOR], [:capture]])
    end

    it "takes the input line as free when it holds only our own draft" do
      facts.held_off?("%3", entry.merge("draft_text" => "Continue"), nil)

      expect(calls.first).to eq([:check, "%3", {exact: "Continue"}])
      expect(calls[1]).to eq([:delivery_facts, "%3"])
    end

    it "checks the whole input line when the draft is not all that is there" do
      typer = RecordingInputCheck.new(exact_refusal: :input_not_empty, calls: calls)

      facts(prompt_typer: typer).held_off?("%3", entry.merge("draft_text" => "Continue"), nil)

      expect(calls.first(2)).to eq([[:check, "%3", {exact: "Continue"}], [:check, "%3", {}]])
    end

    it "holds off on a draft and reads nothing more" do
      typer = RecordingInputCheck.new(refusal: :input_not_empty, calls: calls)

      expect(facts(prompt_typer: typer).held_off?("%3", entry, nil)).to be(true)
      expect(calls).to eq([[:check, "%3", {}]])
    end

    it "holds off on a prompt since the failure, before reading the sub-agents" do
      monitor = RecordingRecoveryMonitor.new(delivery_facts: {last_user_prompt_at: now - 1}, calls: calls)

      expect(facts(session_monitor: monitor).held_off?("%3", entry, nil)).to be(true)
      expect(calls.last).to eq([:delivery_facts, "%3"])
    end

    it "holds off with no failure time, reading no monitor fact" do
      expect(facts.held_off?("%3", entry.except("failed_at"), nil)).to be(true)
      expect(calls).to eq([[:check, "%3", {}]])
    end

    it "holds off while sub-agents run and were heard from lately, before reading the screen" do
      monitor = RecordingRecoveryMonitor.new(delivery_facts: {last_user_prompt_at: now - 120}, running: 1, calls: calls)

      expect(facts(session_monitor: monitor).held_off?("%3", entry, nil)).to be(true)
      expect(calls.last).to eq([:running_subagents, "%3"])
    end

    it "holds off on a busy screen" do
      screens.replace(["esc to interrupt"])

      expect(facts.held_off?("%3", entry, nil)).to be(true)
    end

    it "compares a screen already quiet with one capture and no wait" do
      expect(facts.held_off?("%3", entry, "❯ ")).to be(false)
      expect(calls.last(2)).to eq([[:running_subagents, "%3"], [:capture]])
    end
  end

  describe "#still_screen" do
    it "answers the screen when the second capture matches the first" do
      expect(facts.still_screen("%3")).to eq("❯ ")
    end

    it "answers nil when the screen moved during the wait" do
      screens.replace(["one", "two"])

      expect(facts.still_screen("%3")).to be_nil
    end

    it "answers nil for a pane it can't build, with no wait" do
      expect(facts.still_screen("five")).to be_nil
      expect(calls).to be_empty
    end
  end

  describe "#ledger_session" do
    it "reads the tmux server, then the record open in the pane" do
      ledger = RecordingRecoveryLedger.new(open_record: {"session_id" => "s1"}, calls: calls)

      expect(facts(ledger: ledger).ledger_session("%3")).to eq("session_id" => "s1")
      expect(calls).to eq([[:read_open_record, "%3", "4242"]])
    end

    it "answers :unreadable with no server, without reading the ledger" do
      pane.tmux.server_pid = ""

      expect(facts.ledger_session("%3")).to eq(:unreadable)
      expect(calls).to be_empty
    end

    it "answers :unreadable, logged, when the ledger can't be read" do
      ledger = RecordingRecoveryLedger.new(error: Errno::EACCES.new("ledger.jsonl"), calls: calls)

      expect(facts(ledger: ledger).ledger_session("%3")).to eq(:unreadable)
      expect(log.string).to include("agent recovery: ledger not readable (Errno::EACCES")
    end
  end

  describe "#prompt_after?" do
    it "is true for a prompt the monitor holds after the time, false for one before" do
      expect(facts.prompt_after?("%3", now - 180)).to be(true)
      expect(facts.prompt_after?("%3", now - 60)).to be(false)
      expect(calls).to eq([[:delivery_facts, "%3"], [:delivery_facts, "%3"]])
    end

    it "is true when the monitor has no facts for the pane" do
      monitor = RecordingRecoveryMonitor.new(delivery_facts: nil, calls: calls)

      expect(facts(session_monitor: monitor).prompt_after?("%3", now)).to be(true)
    end
  end

  describe "#prompt_since_failure?" do
    it "compares the monitor's last prompt with the entry's failure" do
      expect(facts.prompt_since_failure?("%3", entry)).to be(false)
      expect(calls).to eq([[:delivery_facts, "%3"]])
    end

    it "is true with no failure time, without asking the monitor" do
      expect(facts.prompt_since_failure?("%3", entry.except("failed_at"))).to be(true)
      expect(calls).to be_empty
    end
  end

  it "#ledger_start reads the last start of the entry's session" do
    ledger = RecordingRecoveryLedger.new(starts: {"s1" => now.iso8601}, calls: calls)

    expect(facts(ledger: ledger).ledger_start(entry)).to eq(now.iso8601)
    expect(calls).to eq([[:last_start_at, "s1"]])
  end

  it "#transcript_error reads the last turn record of the entry's transcript" do
    expect(facts.transcript_error(entry)).to eq("uuid" => "u1", "api_error" => true)
    expect(calls).to eq([[:last_turn_record, "/no/such/transcript.jsonl"]])
  end

  it "#transcript_file? says whether the entry's transcript is a file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.jsonl")
      File.write(path, "")

      expect(facts.transcript_file?(entry.merge("transcript_path" => path))).to be(true)
      expect(facts.transcript_file?(entry.merge("transcript_path" => dir))).to be(false)
      expect(facts.transcript_file?(entry.except("transcript_path"))).to be(false)
    end
  end

  it "#start_command answers the pane's start command, :gone for a pane it can't build" do
    expect(facts.start_command("%3")).to be_nil
    expect(facts.start_command("five")).to eq(:gone)
    expect(facts(panes: FakePaneFactory.new(panes: [FakePane.new(id: "%3", start_command: "make")])).start_command("%3")).to eq("make")
  end
end
