require "spec_helper"
require "timeout"

RSpec.describe Workspace::HandoffWatcher do
  let(:empty_prompt) { "────────\n❯ \n" }
  let(:text) { "Are you handing off? Run workspace handoff new once the state is saved." }
  let(:sent_text) { "Your context is nearly full.\n\nSave your state, then run workspace handoff new." }

  # A paste shows in the input line and Enter empties it again.
  let(:tmux) do
    Class.new do
      attr_accessor :details, :screen, :scripted, :statuses, :on_paste
      attr_reader :delivered, :detail_calls

      def initialize(screen)
        @details = [{id: "%5", window: 0, index: 1, pid: 100}, {id: "%6", window: 0, index: 2, pid: 200}]
        @screen = screen
        @empty = screen
        @delivered = []
        @statuses = []
        @detail_calls = 0
      end

      def pane_details(_session, window: "0")
        raise ArgumentError, "expected every window" unless window.nil?
        @detail_calls += 1
        @details
      end

      def capture_screen(_pane_id) = @scripted ? @scripted.call : @screen

      def deliver(session, target, text, enter: true)
        on_paste&.call unless enter
        @delivered << [session, target, text, enter]
        @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n")
        status = @statuses.shift || (enter ? :submitted : :pasted)
        Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
      end

      def pastes = @delivered.reject(&:last).map { |d| d[2] }
    end.new(empty_prompt)
  end

  let(:t0) { Time.utc(2026, 10, 30, 12, 0, 0) }
  let(:now) { [t0] }
  let(:facts) do
    {kind: "claude", pane_pid: 100, agent_pid: 101, session_id: "s1", hooks: true,
     last_activity_at: t0 - 100, open_tools: 0, agents_running: 0}
  end
  let(:panes) { {"%5" => facts} }
  let(:typing) { {kind: "claude", state: "idle", open_tools: []} }
  let(:alerts) { [] }
  let(:monitor) do
    double("monitor").tap do |m|
      allow(m).to receive(:followup_facts) { |id| panes[id] }
      allow(m).to receive(:typing_facts) { typing }
      allow(m).to receive(:alert_handoff_stalled) { |id, seconds:, followups:| alerts << [id, seconds, followups] && true }
    end
  end
  let(:events) { [] }
  let(:on_record) { [] }
  let(:event_log) do
    double("event_log").tap do |log|
      allow(log).to receive(:record) do |type:, project:, data:|
        events << [type, project, data]
        on_record.first&.call(type)
        true
      end
    end
  end
  let(:restarting) { [] }
  let(:paused) { [false] }
  let(:lock_wait) { [] }

  # Runs what is scheduled for the wait on the lock, in place of a real wait.
  let(:delivery_lock) do
    wait = lock_wait
    Object.new.tap do |lock|
      lock.define_singleton_method(:synchronize) do |&block|
        wait.shift&.call
        block.call
      end
    end
  end
  let(:typer) { Workspace::PromptTyper.new(tmux: tmux, session_monitor: monitor) }
  let(:watcher) do
    described_class.new(tmux: tmux, session_name: "ws", workspace: "ws", session_monitor: monitor, typer: typer,
      delivery_lock: delivery_lock, restarting: ->(id) { restarting.include?(id) }, plan_paused: -> { paused.first },
      event_log: event_log, clock: -> { now.first })
  end

  def arm(pane_id: "%5", sent_at: now.first, interval: 30, max: 3, text: self.text, sent_text: self.sent_text)
    watcher.arm(pane_id: pane_id, sent_at: sent_at, interval: interval, max: max, text: text, sent_text: sent_text)
  end

  def tick(seconds)
    now[0] += seconds
    watcher.poll
  end

  def event(name, **fields)
    {"session_id" => "s1", "pane_id" => "%5", "event" => name}.merge(fields.transform_keys(&:to_s))
  end

  def prompt(text) = watcher.session_event(event("user_prompt", prompt: text))

  def ends = events.select { |type, _, _| type == "handoff_watch_ended" }.map(&:last)

  def followups = events.select { |type, _, _| type == "handoff_followup" }.map(&:last)

  def expect_end(reason, tries: 0)
    expect(ends).to eq([{"pane_id" => "%5", "reason" => reason, "tries" => tries}])
  end

  # A screen that runs the block at the typer's first check, right before before_paste.
  def at_first_check(&block)
    done = false
    tmux.scripted = lambda do
      unless done
        done = true
        block.call
      end
      tmux.screen
    end
  end

  describe "#arm" do
    it "opens a watch and records it" do
      expect(arm).to eq({watching: true, reason: nil})
      expect(events).to eq([["handoff_watch_started", "ws", {"pane_id" => "%5"}]])
    end

    it "refuses a pane the monitor has not scanned" do
      panes.clear
      expect(arm).to eq({watching: false, reason: "not_scanned"})
    end

    it "refuses a pane that is not Claude Code" do
      facts[:kind] = "codex"
      expect(arm).to eq({watching: false, reason: "not_claude"})
    end

    it "refuses a pane whose agent has sent no hook event" do
      facts[:hooks] = false
      expect(arm).to eq({watching: false, reason: "no_hooks"})
      expect(events).to be_empty
    end

    it "keeps one watch, its tries and its first arm when armed again" do
      arm(max: 2)
      tick(30)
      arm(sent_at: now.first, max: 2)
      expect(events.count { |type, _, _| type == "handoff_watch_started" }).to eq(1)

      tick(30)
      arm(sent_at: now.first, max: 2)
      tick(30)
      expect(tmux.pastes.size).to eq(2)
      expect_end("stalled", tries: 2)
    end

    it "keeps the hour when armed again" do
      arm
      tick(3500)
      facts[:last_activity_at] = now.first
      arm(sent_at: now.first)
      tick(101)
      expect_end("expired", tries: 1)
    end

    it "keeps tries and the first arm on a repeat arm with the same identity" do
      arm(max: 2)
      tick(30)
      arm(sent_at: now.first, max: 2)
      tick(3571)
      expect(ends).to eq([{"pane_id" => "%5", "reason" => "expired", "tries" => 1}])
      expect(alerts).to eq([["%5", 3601.0, 1]])
    end

    [[:agent_pid, 999, "pane_gone"], [:pane_pid, 999, "pane_gone"], [:session_id, "s2", "session_changed"]].each do |field, value, reason|
      it "opens a new watch when #{field} changed" do
        arm(max: 2)
        tick(30)
        facts[field] = value
        tmux.details.first[:pid] = value if field == :pane_pid
        expect(arm(sent_at: now.first, max: 2, text: "New text", sent_text: "New prompt")).to eq({watching: true, reason: nil})
        expect(ends).to eq([{"pane_id" => "%5", "reason" => reason, "tries" => 1}])
        expect(events.count { |type, _, _| type == "handoff_watch_started" }).to eq(2)
        expect(alerts).to be_empty

        prompt(text)
        expect(ends.last).to eq({"pane_id" => "%5", "reason" => "other_prompt", "tries" => 0})
      end

      it "counts tries and the hour afresh when #{field} changed" do
        arm(max: 1)
        tick(30)
        facts[field] = value
        tmux.details.first[:pid] = value if field == :pane_pid
        arm(sent_at: now.first, max: 1)
        tmux.delivered.clear

        tick(30)
        expect(tmux.pastes).to eq([text])
        expect(ends.size).to eq(1)

        tick(30)
        expect(ends.last).to eq({"pane_id" => "%5", "reason" => "stalled", "tries" => 1})
        expect(alerts).to eq([["%5", 60.0, 1]])
      end
    end

    it "refuses bad settings" do
      [{interval: 0}, {interval: "30"}, {interval: -1}, {max: 0}, {max: 1.5}, {max: nil}, {sent_at: "2026-10-30"}, {sent_at: nil}].each do |bad|
        expect(arm(**bad)).to eq({watching: false, reason: "invalid"})
      end
      expect(events).to be_empty
    end

    it "counts a sent_at in the future as now" do
      arm(sent_at: now.first + 1000)
      tick(30)
      expect(tmux.pastes).to eq([text])
    end

    it "never moves sent_at backwards on a repeat arm" do
      arm
      tick(20)
      arm(sent_at: now.first)
      arm(sent_at: t0 - 1000)
      tick(10)
      expect(tmux.delivered).to be_empty

      tick(20)
      expect(tmux.pastes).to eq([text])
    end

    it "takes the new settings, text and fingerprints when armed again" do
      arm
      arm(interval: 60, text: "Second text", sent_text: "Second save-state prompt")
      tick(30)
      expect(tmux.pastes).to be_empty

      tick(30)
      expect(tmux.pastes).to eq(["Second text"])
      [text, sent_text, "Second text", "Second save-state prompt"].each { |p| prompt(p) }
      expect(ends).to be_empty
    end
  end

  describe "timing" do
    it "sends nothing before the interval" do
      arm
      tick(29)
      expect(tmux.delivered).to be_empty
    end

    it "sends one follow-up after the interval and another one interval later" do
      arm
      tick(30)
      expect(tmux.delivered).to eq([["ws", "0.1", text, false], ["ws", "0.1", "", true]])
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "submitted"}])

      tick(29)
      expect(tmux.pastes.size).to eq(1)

      tick(1)
      expect(tmux.pastes).to eq([text, text])
      expect(followups.last).to eq({"pane_id" => "%5", "attempt" => 2, "outcome" => "submitted"})
    end
  end

  describe "the quiet test" do
    it "moves the next follow-up on screen activity and keeps the watch" do
      arm
      tick(25)
      facts[:last_activity_at] = now.first
      tick(25)
      expect(tmux.delivered).to be_empty
      expect(ends).to be_empty

      tick(5)
      expect(tmux.pastes).to eq([text])
    end

    it "holds on an open tool" do
      arm
      facts[:open_tools] = 1
      tick(60)
      expect(tmux.delivered).to be_empty

      facts[:open_tools] = 0
      watcher.poll
      expect(tmux.pastes).to eq([text])
    end

    it "holds on a running sub-agent" do
      arm
      facts[:agents_running] = 1
      tick(60)
      expect(tmux.delivered).to be_empty
    end

    it "holds during a restart" do
      arm
      restarting << "%5"
      tick(60)
      expect(tmux.delivered).to be_empty
      expect(ends).to be_empty
    end

    it "waits a full interval after a restart that failed" do
      arm
      restarting << "%5"
      tick(60)
      restarting.clear

      tick(29)
      expect(tmux.delivered).to be_empty

      tick(1)
      expect(tmux.pastes).to eq([text])
    end
  end

  describe "#session_event" do
    it "changes nothing for the save-state prompt arriving before arm" do
      prompt(sent_text)
      arm
      tick(30)
      expect(tmux.pastes).to eq([text])
    end

    it "changes nothing for the save-state prompt arriving long after arm" do
      arm
      tick(3000)
      prompt(sent_text)
      expect(ends).to be_empty
    end

    it "changes nothing for our follow-up with its whitespace changed" do
      arm
      prompt("  #{text.gsub(" ", "\n  ")}\n")
      expect(ends).to be_empty
    end

    it "changes nothing for a long prompt cut short" do
      long = "Please save your state and hand off. " * 20
      arm(text: long)
      prompt(long[0, described_class::FINGERPRINT_LENGTH + 5])
      prompt(long[0, 1000])
      expect(ends).to be_empty
    end

    it "ends the watch on a person's prompt" do
      arm
      prompt("what about the failing test?")
      expect_end("other_prompt")
      tick(30)
      expect(tmux.delivered).to be_empty
    end

    it "changes nothing for a message with no prompt string" do
      arm
      watcher.session_event(event("user_prompt"))
      watcher.session_event(event("user_prompt", prompt: 12))
      expect(ends).to be_empty
    end

    it "changes nothing for the paste placeholder" do
      arm
      prompt("[Pasted text #3 +12 lines]")
      expect(ends).to be_empty
    end

    it "ends on a prompt that only starts with a short save-state prompt" do
      arm(sent_text: "continue")
      prompt("continue")
      expect(ends).to be_empty

      prompt("continue with the migration")
      expect_end("other_prompt")
    end

    it "ends on a prompt that only starts with a text of exactly the fingerprint's length" do
      exact = "x" * described_class::FINGERPRINT_LENGTH
      arm(text: exact)
      prompt(exact)
      expect(ends).to be_empty

      prompt("#{exact} and more")
      expect_end("other_prompt")
    end

    it "ignores a sub-agent's event" do
      arm
      watcher.session_event(event("user_prompt", prompt: "sub-agent brief", agent_id: "a1"))
      watcher.session_event(event("session_end", reason: "other", agent_id: "a1"))
      expect(ends).to be_empty
    end

    it "ignores an event for a pane with no watch" do
      arm
      watcher.session_event(event("user_prompt", prompt: "hello", pane_id: "%6"))
      expect(ends).to be_empty
    end

    it "ends carried_out on a session start from clear" do
      arm
      watcher.session_event(event("session_end", reason: "clear"))
      expect(ends).to be_empty
      watcher.session_event(event("session_start", source: "clear"))
      expect_end("carried_out")
    end

    it "ends session_changed on any other session start" do
      arm
      watcher.session_event(event("session_start", source: "resume"))
      expect_end("session_changed")
    end

    it "ends session_ended on a session end" do
      arm
      watcher.session_event(event("session_end", reason: "logout"))
      expect_end("session_ended")
    end
  end

  describe "#poll ending a watch" do
    it "ends pane_gone when the facts are gone" do
      arm
      panes.clear
      tick(5)
      expect_end("pane_gone")
    end

    it "holds through a changed agent pid until the grace has passed, then ends pane_gone" do
      arm
      tick(30)
      tmux.delivered.clear
      facts[:agent_pid] = 999
      6.times { tick(5) }
      expect(tmux.delivered).to be_empty
      expect(ends).to be_empty

      tick(5)
      expect_end("pane_gone", tries: 1)
    end

    it "does not end the watch on repeated polls reading the same facts inside the grace" do
      arm
      tick(1)
      facts[:agent_pid] = 999
      20.times { watcher.poll }
      expect(ends).to be_empty
    end

    it "counts a nil agent pid as a change" do
      arm
      facts[:agent_pid] = nil
      tick(5)
      expect(ends).to be_empty

      tick(described_class::AGENT_CHANGE_GRACE)
      expect_end("pane_gone")
    end

    it "clears the mark when the agent pid matches again" do
      arm
      facts[:agent_pid] = 999
      tick(5)
      tick(25)
      facts[:agent_pid] = 101
      facts[:open_tools] = 1
      tick(5)
      facts[:agent_pid] = 999
      tick(5)
      tick(25)
      expect(ends).to be_empty

      tick(5)
      expect_end("pane_gone")
    end

    it "ends session_changed when the pane's conversation changed, typing nothing" do
      arm
      facts[:session_id] = "s2"
      tick(30)
      expect(tmux.delivered).to be_empty
      expect_end("session_changed")
    end

    it "does not compare session ids unless both are known" do
      facts[:session_id] = nil
      arm
      facts[:session_id] = "s2"
      tick(5)
      expect(ends).to be_empty
    end

    it "ends pane_gone when the pane's process changed" do
      arm
      facts[:pane_pid] = 999
      tick(5)
      expect_end("pane_gone")
    end

    it "ends plan_paused on a pause made after arming" do
      arm
      paused[0] = true
      tick(5)
      expect_end("plan_paused")
      expect(alerts).to be_empty
    end

    it "ends expired past the hour and alerts once" do
      arm
      tick(3601)
      tick(30)
      expect_end("expired")
      expect(alerts).to eq([["%5", 3601.0, 0]])
    end

    it "ends stalled when a follow-up is due at the cap and alerts once" do
      arm(max: 1)
      tick(30)
      tick(30)
      tick(30)
      expect(tmux.pastes).to eq([text])
      expect_end("stalled", tries: 1)
      expect(alerts).to eq([["%5", 60.0, 1]])
    end

    it "reaches stalled through repeated refusals" do
      arm(max: 2)
      tmux.screen = "────────\n❯ a draft\n"
      3.times { tick(30) }
      expect(tmux.delivered).to be_empty
      expect(followups.map { |f| f["outcome"] }).to eq(["refused", "refused"])
      expect_end("stalled", tries: 2)
      expect(alerts.size).to eq(1)
    end

    it "does not alert for an end that a person caused" do
      arm
      prompt("carry on")
      expect(alerts).to be_empty
    end

    it "lets one bad watch leave the others their turn" do
      panes["%6"] = facts.merge(pane_pid: 200)
      arm
      arm(pane_id: "%6")
      allow(monitor).to receive(:followup_facts) do |id|
        raise Workspace::Error, "boom" if id == "%5"
        panes[id]
      end
      expect { tick(30) }.not_to raise_error
      expect(tmux.delivered.map { |d| d[1] }.uniq).to eq(["0.2"])
    end

    it "makes no tmux call with no watches" do
      tick(60)
      expect(tmux.detail_calls).to eq(0)
      expect(monitor).not_to have_received(:followup_facts)
    end
  end

  describe "typing" do
    it "counts :submitted" do
      arm
      tick(30)
      expect(followups.map { |f| f["outcome"] }).to eq(["submitted"])
    end

    it "counts :refused and tries again one interval later" do
      arm
      typing[:state] = "waiting"
      tick(30)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "refused"}])
      tick(29)
      expect(followups.size).to eq(1)
      tick(1)
      expect(followups.size).to eq(2)
    end

    it "counts :not_landed" do
      arm
      tmux.statuses = [:not_landed]
      tick(30)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "not_landed"}])
      expect(ends).to be_empty
    end

    it "counts :failed" do
      arm
      tmux.statuses = [:failed]
      tick(30)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "failed"}])
      expect(ends).to be_empty
    end

    it "ends not_submitted, types no more and alerts once" do
      arm
      tmux.statuses = [:unverified]
      tick(30)
      tick(30)
      expect(tmux.pastes).to eq([text])
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "not_submitted"}])
      expect_end("not_submitted", tries: 1)
      expect(alerts).to eq([["%5", 30.0, 1]])
    end

    it "does not count :aborted and tries again at the next poll" do
      arm
      at_first_check { restarting << "%5" }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(followups).to be_empty

      restarting.clear
      tmux.scripted = nil
      tick(29)
      expect(tmux.delivered).to be_empty

      tick(1)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "submitted"}])
    end

    it "waits a full interval after a restart claimed while waiting on the lock fails" do
      arm
      lock_wait << -> { restarting << "%5" }
      tick(30)
      restarting.clear
      tick(29)
      expect(tmux.delivered).to be_empty

      tick(1)
      expect(tmux.pastes).to eq([text])
    end

    {"a tool opened" => ->(f, _) { f[:open_tools] = 1 },
     "a sub-agent started" => ->(f, _) { f[:agents_running] = 1 },
     "activity moved" => ->(f, t) { f[:last_activity_at] = t }}.each do |what, change|
      it "types nothing when #{what} during the wait on the lock" do
        arm
        lock_wait << -> { change.call(facts, now.first) }
        tick(30)
        expect(tmux.delivered).to be_empty
        expect(followups).to be_empty
        expect(ends).to be_empty
      end

      it "types nothing when #{what} right before the paste" do
        arm
        at_first_check { change.call(facts, now.first) }
        tick(30)
        expect(tmux.delivered).to be_empty
        expect(followups).to be_empty
      end
    end

    it "types nothing when a repeat arm moves sent_at during the wait on the lock" do
      arm
      lock_wait << -> { arm(sent_at: now.first) }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(followups).to be_empty
    end

    it "types nothing when the pane's facts go during the wait on the lock" do
      arm
      lock_wait << -> { panes.clear }
      tick(30)
      expect(tmux.delivered).to be_empty
    end

    it "counts a raise while typing as a try, up to the cap" do
      arm(max: 2)
      tmux.on_paste = -> { raise Workspace::Error, "boom" }
      tick(30)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "raised"}])

      tick(29)
      expect(followups.size).to eq(1)

      tick(1)
      tick(30)
      expect_end("stalled", tries: 2)
    end

    it "counts a raise before the paste as a try" do
      arm(max: 1)
      tmux.scripted = -> { raise Workspace::Error, "boom" }
      tick(30)
      tick(30)
      expect_end("stalled", tries: 1)
    end

    it "records a follow-up typed into a watch that closed during the paste" do
      arm
      tmux.on_paste = -> { prompt("hold on") }
      tick(30)
      expect_end("other_prompt", tries: 0)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "submitted"}])
      expect(alerts).to be_empty
    end

    it "records nothing when the watch closes and the pane refused" do
      arm
      at_first_check do
        prompt("hold on")
        tmux.screen = "────────\n❯ a draft\n"
      end
      tick(30)
      expect(followups).to be_empty
      expect_end("other_prompt")
    end

    it "alerts once for text left in a pane whose watch closed during the paste" do
      arm
      tmux.statuses = [:unverified]
      tmux.on_paste = -> { prompt("hold on") }
      tick(30)
      tick(30)
      expect_end("other_prompt", tries: 0)
      expect(followups).to eq([{"pane_id" => "%5", "attempt" => 1, "outcome" => "not_submitted"}])
      expect(alerts).to eq([["%5", 30.0, 1]])
    end

    it "takes the watch out with the not_submitted count, so an event in the gap changes nothing" do
      arm
      tmux.statuses = [:unverified]
      on_record << ->(type) { prompt("hold on") if type == "handoff_followup" }
      tick(30)
      expect_end("not_submitted", tries: 1)
      expect(alerts).to eq([["%5", 30.0, 1]])
    end

    it "types nothing when a restart is claimed before the lock is taken" do
      arm
      lock_wait << -> { restarting << "%5" }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(followups).to be_empty
      expect(ends).to be_empty
    end

    it "types nothing when a person's prompt arrives while the poll waits on the lock" do
      arm
      lock_wait << -> { prompt("hold on") }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect_end("other_prompt")
    end

    it "types nothing when carried_out arrives while the poll waits on the lock" do
      arm
      lock_wait << -> { watcher.session_event(event("session_start", source: "clear")) }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect_end("carried_out")
    end

    it "types nothing when a person's prompt arrives right before the paste" do
      arm
      at_first_check { prompt("hold on") }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(followups).to be_empty
      expect_end("other_prompt")
    end

    it "types nothing when carried_out arrives right before the paste" do
      arm
      at_first_check { watcher.session_event(event("session_start", source: "clear")) }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(followups).to be_empty
      expect_end("carried_out")
    end

    it "types nothing for a watch ended and armed again during the wait" do
      arm
      at_first_check do
        prompt("hold on")
        arm
      end
      tick(30)
      expect(tmux.delivered).to be_empty
    end

    it "ends pane_gone and types nothing when the pane has no target" do
      arm
      tmux.details = []
      tick(30)
      expect(tmux.delivered).to be_empty
      expect_end("pane_gone")
    end

    it "ends pane_gone and types nothing when the target's pid changed" do
      arm
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 999}]
      tick(30)
      expect(tmux.delivered).to be_empty
      expect_end("pane_gone")
    end

    it "types nothing once stop lands right before the paste" do
      arm
      at_first_check { watcher.stop }
      tick(30)
      expect(tmux.delivered).to be_empty
      expect(ends).to be_empty
    end
  end

  describe "the thread" do
    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    before { watcher }

    # A stop before the thread reaches its sleep would prove nothing.
    def start_and_settle
      watcher.start
      thread = watcher.instance_variable_get(:@thread)
      Thread.pass until thread.stop?
    end

    it "stops within 1s with no watches" do
      start_and_settle
      expect(elapsed { watcher.stop }).to be < 1
    end

    it "stops within 1s with watches open" do
      arm
      start_and_settle
      expect(elapsed { watcher.stop }).to be < 1
    end

    it "polls on its ticks and survives a poll that raises" do
      stub_const("#{described_class}::TICK", 0.001)
      stub_const("#{described_class}::POLL_EVERY", 0.002)
      polled = Queue.new
      arm
      allow(monitor).to receive(:followup_facts) do
        polled << true
        raise Workspace::Error, "boom"
      end
      watcher.start
      Timeout.timeout(5) { 2.times { polled.pop } }
      watcher.stop
    end

    context "with a real Mutex as the delivery lock" do
      let(:delivery_lock) { Mutex.new }

      it "types a follow-up from the thread, which a re-entrant take would stop" do
        stub_const("#{described_class}::TICK", 0.001)
        stub_const("#{described_class}::POLL_EVERY", 0.001)
        arm
        now[0] += 30
        watcher.start
        Timeout.timeout(5) { Thread.pass until tmux.delivered.size == 2 }
        watcher.stop
        expect(tmux.delivered).to eq([["ws", "0.1", text, false], ["ws", "0.1", "", true]])
      end
    end

    it "lets a started typing finish and types nothing further" do
      stub_const("#{described_class}::TICK", 0.001)
      stub_const("#{described_class}::POLL_EVERY", 0.001)
      panes["%6"] = facts.merge(pane_pid: 200)
      arm
      arm(pane_id: "%6")
      pasting = Queue.new
      release = Queue.new
      tmux.on_paste = lambda do
        pasting << true
        release.pop
      end
      now[0] += 30

      watcher.start
      Timeout.timeout(5) do
        pasting.pop
        stopper = Thread.new { watcher.stop }
        Thread.pass until stopper.stop?
        release << true
        stopper.join
      end

      expect(tmux.delivered).to eq([["ws", "0.1", text, false], ["ws", "0.1", "", true]])
    end
  end
end
