require "spec_helper"

RSpec.describe Workspace::RecoveryConfirmer do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:now) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:calls) { [] }
  let(:agent) { {pid: 20, started: "Mon", flags: ["--model", "opus"]} }
  let(:details) { {"%5" => {id: "%5", pid: 10}} }
  let(:agents) { {10 => agent} }
  let(:tree) { :tree }
  let(:ledger) { {"session_id" => sid, "cwd" => "/work"} }
  let(:transcript) { {"uuid" => "u-err", "api_error" => true} }
  let(:unknown_panes) { [] }
  let(:store) { RecordingRecoveryStore.new(calls: calls) }
  let(:facts) do
    RecordingConfirmerFacts.new(details: details, agents: agents, tree: tree, ledger: ledger, transcript: transcript,
      calls: calls)
  end
  let(:monitor) { RecordingRecoveryMonitor.new(unknown_panes: unknown_panes, calls: calls) }
  let(:marker) { RecordingStopMarker.new(calls: calls) }
  let(:event_log) { RecordingRecoveryEventLog.new(calls: calls) }
  let(:cleared) { [] }
  let(:gave_up) { [] }
  let(:resolved) { [] }

  subject(:confirmer) do
    described_class.new(workspace: "api", store: store, facts: facts, session_monitor: monitor, marker: marker,
      clear: ->(pane_id, entry) { cleared << [pane_id, entry] },
      report_give_up: ->(pane_id, entry) { gave_up << [pane_id, entry] }, resolve: ->(session_id) { resolved << session_id },
      event_log: event_log, max_attempts: 3, clock: BlockClock.new { now })
  end

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  def waiting(**fields)
    {"session_id" => sid, "transcript_path" => "/t/session.jsonl", "error" => "server_error", "attempts" => 0,
     "phase" => "waiting", "stopped" => false, "failed_at" => stamp(now - 30), "next_attempt_at" => stamp(now + 60),
     "agent_pid" => 20, "agent_started" => "Mon"}.merge(fields.transform_keys(&:to_s))
  end

  def attempting(**fields)
    waiting(phase: "attempting", attempts: 2, stopped: true, agent_pid: 1, attempt_session_id: sid, prompt_seen: true,
      **fields)
  end

  def entry = store.get("%5")

  def marked = calls.select { |call| call.first == :mark_turn_failed }.map(&:last)

  describe "#mark_failed_panes" do
    it "marks the failed panes once, and skips a fresh_conversation record" do
      entries = {"%1" => {"phase" => "waiting"}, "%2" => {"phase" => "attempting"}, "%3" => {"phase" => "watching"},
                 "%4" => {"phase" => "gave_up", "give_up_reason" => "deferred"},
                 "%6" => {"phase" => "gave_up", "give_up_reason" => "fresh_conversation"}}

      2.times { confirmer.mark_failed_panes(entries) }

      expect(marked).to eq(%w[%1 %2 %4])
    end

    it "keeps a pane the monitor doesn't know yet for the next call, until it is marked" do
      entries = {"%5" => {"phase" => "waiting"}}
      unknown_panes << "%5"
      confirmer.mark_failed_panes(entries)
      expect(marked).to eq([])

      unknown_panes.clear
      2.times { confirmer.mark_failed_panes(entries) }
      expect(marked).to eq(["%5"])
    end

    it "lists panes on the first call only" do
      confirmer.mark_failed_panes({})
      confirmer.mark_failed_panes({"%5" => {"phase" => "waiting"}})

      expect(marked).to eq([])
    end

    it "drops a listed pane whose entry is gone, or whose failure no longer stands" do
      unknown_panes.push("%5", "%6")
      confirmer.mark_failed_panes({"%5" => {"phase" => "waiting"}, "%6" => {"phase" => "waiting"}})
      unknown_panes.clear
      confirmer.mark_failed_panes({"%6" => {"phase" => "watching"}})
      confirmer.mark_failed_panes({"%5" => {"phase" => "waiting"}, "%6" => {"phase" => "waiting"}})

      expect(marked).to eq([])
    end
  end

  describe "#settle" do
    it "reads nothing before #{described_class::SETTLE} seconds, and answers the entry" do
      seen = waiting(failed_at: stamp(now - 29))

      expect(confirmer.settle("%5", seen)).to eq(seen)
      expect(calls).to eq([])
    end

    it "reads nothing for a failure time that doesn't parse" do
      seen = waiting(failed_at: "bad")

      expect(confirmer.settle("%5", seen)).to eq(seen)
      expect(calls).to eq([])
    end

    it "stores the error's uuid and the ledger's cwd, reading the transcript, the agent and the ledger in that order" do
      seen = waiting(agent_pid: nil, agent_started: nil)
      store.put("%5", seen)
      calls.clear

      stored = confirmer.settle("%5", seen)

      expect(stored).to include("last_turn_uuid" => "u-err", "cwd" => "/work", "agent_pid" => 20, "agent_started" => "Mon",
        "agent_flags" => ["--model", "opus"])
      expect(calls.map(&:first)).to eq(%i[transcript_error live_agent ledger_session update])
    end

    it "reads only what the entry lacks" do
      seen = waiting(last_turn_uuid: "u-old", cwd: "/old")
      store.put("%5", seen)
      calls.clear

      expect(confirmer.settle("%5", seen)).to eq(seen)
      expect(calls).to eq([])
    end

    it "clears when Claude Code recovered by itself, reading nothing more" do
      seen = waiting
      store.put("%5", seen)
      facts = RecordingConfirmerFacts.new(details: details, agents: agents, transcript: {"uuid" => "u-ok"}, calls: calls)
      settler = described_class.new(workspace: "api", store: store, facts: facts, session_monitor: monitor, marker: marker,
        clear: ->(pane_id, read) { cleared << [pane_id, read] }, report_give_up: ->(*) {}, resolve: ->(*) {},
        clock: BlockClock.new { now })
      calls.clear

      expect(settler.settle("%5", seen)).to be_nil
      expect(cleared).to eq([["%5", seen]])
      expect(calls.map(&:first)).to eq([:transcript_error])
    end

    context "when the ledger names another session" do
      let(:ledger) { {"session_id" => other_sid, "cwd" => "/elsewhere"} }

      it "clears and writes nothing" do
        seen = waiting
        store.put("%5", seen)
        calls.clear

        expect(confirmer.settle("%5", seen)).to be_nil
        expect(cleared).to eq([["%5", seen]])
        expect(calls.map(&:first)).not_to include(:update)
      end
    end

    context "when the ledger has no answer" do
      let(:ledger) { :unreadable }

      it "stores the uuid and leaves cwd for later" do
        store.put("%5", waiting)

        expect(confirmer.settle("%5", entry)).to include("last_turn_uuid" => "u-err")
        expect(entry["cwd"]).to be_nil
      end
    end

    context "when nothing is found" do
      let(:transcript) { nil }
      let(:ledger) { nil }

      it "writes nothing and answers the entry" do
        seen = waiting
        store.put("%5", seen)
        calls.clear

        expect(confirmer.settle("%5", seen)).to eq(seen)
        expect(calls.map(&:first)).not_to include(:update)
      end
    end

    it "doesn't write a stale read over a newer failure" do
      store.put("%5", waiting(failed_at: stamp(now - 5)))

      expect(confirmer.settle("%5", waiting)).to include("failed_at" => stamp(now - 5))
      expect(entry["last_turn_uuid"]).to be_nil
    end

    it "keeps a pid a hook stored meanwhile" do
      store.put("%5", waiting(agent_pid: 7, agent_started: "Sun"))

      confirmer.settle("%5", waiting(agent_pid: nil, agent_started: nil))

      expect(entry).to include("agent_pid" => 7, "agent_started" => "Sun", "last_turn_uuid" => "u-err")
    end
  end

  describe "#reconcile" do
    it "goes back to waiting with its next wait, the agent stored and an interrupted line, keeping the marker" do
      store.put("%5", attempting)

      confirmer.reconcile("%5")

      expect(entry).to include("phase" => "waiting", "stopped" => false, "agent_pid" => 20, "attempts" => 2,
        "next_attempt_at" => stamp(now + Workspace::AgentRecoveryStore.wait_before(3)), "last_turn_uuid" => nil)
      expect(entry).not_to include("prompt_seen", "attempt_session_id")
      line = {"attempt" => 2, "session_id" => sid, "pane_id" => "%5", "error" => "server_error", "mode" => "restart",
              "outcome" => "interrupted"}
      expect(event_log.lines).to eq([["agent_recovery_attempt", "api", line]])
      expect(calls.map(&:first)).not_to include(:clear_marker)
      expect(gave_up).to eq([])
    end

    it "names a first attempt typed" do
      store.put("%5", attempting(attempts: 1))

      confirmer.reconcile("%5")

      expect(event_log.lines[0][2]).to include("mode" => "typed")
    end

    it "reads the pane, the agent and the ledger before it writes" do
      store.put("%5", attempting)
      calls.clear

      confirmer.reconcile("%5")

      expect(calls.map(&:first)).to eq(%i[pane_detail agent ledger_session update record])
    end

    context "with no agent left in the pane" do
      let(:agents) { {} }

      it "keeps stopped, clears the marker and waits for a resume" do
        store.put("%5", attempting)

        confirmer.reconcile("%5")

        expect(entry).to include("phase" => "waiting", "stopped" => true, "agent_pid" => 1)
        expect(calls).to include([:clear_marker, sid])
      end

      it "gives up unconfirmed when no signal of ours explains it" do
        store.put("%5", attempting(stopped: false))

        confirmer.reconcile("%5")

        expect(entry).to include("phase" => "gave_up", "give_up_reason" => "unconfirmed")
        expect(gave_up).to eq([["%5", entry]])
      end
    end

    it "resolves the item when the turn completed during the attempt, and drops the entry" do
      store.put("%5", attempting(turn_completed: true))

      confirmer.reconcile("%5")

      expect(entry).to be_nil
      expect(resolved).to eq([sid])
      expect(event_log.lines.map(&:first)).to eq(["agent_recovery_attempt"])
    end

    context "when the ledger shows another session open" do
      let(:ledger) { {"session_id" => other_sid, "cwd" => "/work"} }

      it "gives up fresh_conversation" do
        store.put("%5", attempting)

        confirmer.reconcile("%5")

        expect(entry).to include("phase" => "gave_up", "give_up_reason" => "fresh_conversation")
        expect(gave_up.map(&:first)).to eq(["%5"])
      end
    end

    it "gives up not_retryable on a failure during the attempt that trying again won't fix" do
      store.put("%5", attempting(failed_during_attempt: true, error: "authentication_failed"))

      confirmer.reconcile("%5")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "not_retryable")
      expect(entry).not_to include("failed_during_attempt")
    end

    it "dates a retryable failure during the attempt now" do
      store.put("%5", attempting(failed_during_attempt: true))

      confirmer.reconcile("%5")

      expect(entry).to include("phase" => "waiting", "failed_at" => stamp(now))
    end

    it "gives up attempts_exhausted once the attempts are used up" do
      store.put("%5", attempting(attempts: 3))

      confirmer.reconcile("%5")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted")
      expect(gave_up.size).to eq(1)
    end

    it "does nothing to an entry that isn't attempting" do
      store.put("%5", waiting)

      confirmer.reconcile("%5")

      expect(entry).to eq(waiting)
      expect(event_log.lines).to eq([])
    end

    context "when tmux listed no pane at all" do
      let(:details) { {"%5" => :unknown} }

      it "decides nothing" do
        store.put("%5", attempting)
        calls.clear

        confirmer.reconcile("%5")

        expect(calls.map(&:first)).to eq([:pane_detail])
      end
    end

    context "when the process table can't be read" do
      let(:tree) { nil }

      it "decides nothing on a live pane" do
        store.put("%5", attempting)
        calls.clear

        confirmer.reconcile("%5")

        expect(calls.map(&:first)).to eq(%i[pane_detail agent])
      end

      it "decides nothing on a closed pane" do
        store.put("%6", attempting)
        calls.clear

        confirmer.reconcile("%6")

        expect(calls.map(&:first)).to eq(%i[pane_detail tree])
      end
    end

    context "when the ledger can't be read" do
      let(:ledger) { :unreadable }

      it "decides nothing" do
        store.put("%5", attempting)
        calls.clear

        confirmer.reconcile("%5")

        expect(calls.map(&:first)).to eq(%i[pane_detail agent ledger_session])
      end
    end

    it "reads no ledger for a closed pane and keeps the marker" do
      store.put("%6", attempting(stopped: true))
      calls.clear

      confirmer.reconcile("%6")

      expect(calls.map(&:first)).to eq(%i[pane_detail tree update record])
      expect(store.get("%6")).to include("phase" => "waiting", "stopped" => true)
    end
  end
end
