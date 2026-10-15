require "tmpdir"

RSpec.describe Workspace::ContextReader do
  let(:context_store) { instance_double(Workspace::ContextStore) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:global_config) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_config) }
  let(:lock_holder) { instance_double(Workspace::LockHolder) }
  let(:reader) do
    described_class.new(context_store: context_store, project_settings: project_settings, tmux: tmux, lock_holder: lock_holder)
  end

  describe "statusline source (default)" do
    it "returns the pane's reading when one is recorded" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => 42, "recorded_at" => "2026-09-27T00:00:00Z"}
      )

      result = reader.read(pane_id: "%1")
      expect(result).to eq(pct: 42, error: nil, updated_at: "2026-09-27T00:00:00Z",
        recorded_at: Time.utc(2026, 9, 27), session_id: nil)
    end

    it "returns the same result for a record that also carries cost, duration, and model" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => 42, "session_id" => "sess-1", "recorded_at" => "2026-09-27T00:00:00Z",
         "cost_usd" => 1.25, "duration_ms" => 90_000, "model" => "Opus 5.5"}
      )

      expect(reader.read(pane_id: "%1")).to eq(pct: 42, error: nil, updated_at: "2026-09-27T00:00:00Z",
        recorded_at: Time.utc(2026, 9, 27), session_id: "sess-1")
    end

    it "returns the stored session id" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => 42, "session_id" => "sess-1", "recorded_at" => "2026-09-27T00:00:00Z"}
      )

      expect(reader.read(pane_id: "%1")[:session_id]).to eq("sess-1")
    end

    it "keeps a sub-second stamp in recorded_at but reports updated_at in whole seconds" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => 42, "recorded_at" => "2026-09-27T00:00:00.250000Z"}
      )

      result = reader.read(pane_id: "%1")
      expect(result[:recorded_at]).to eq(Time.utc(2026, 9, 27, 0, 0, 0.25r))
      expect(result[:updated_at]).to eq("2026-09-27T00:00:00Z")
    end

    it "reports undetermined (not 0) when the stored reading has a nil pct" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => nil, "session_id" => "sess-1", "recorded_at" => "2026-09-27T00:00:00Z"}
      )

      result = reader.read(pane_id: "%1")
      expect(result).to eq(pct: nil, error: Workspace::ContextReasons::NO_READING_YET, updated_at: "2026-09-27T00:00:00Z",
        recorded_at: Time.utc(2026, 9, 27), session_id: "sess-1")
    end

    describe "pid fallback" do
      let(:started) { "Sun Sep 27 10:00:00 2026" }

      before do
        allow(context_store).to receive(:reading_for_pane).with("%1").and_return(nil)
        allow(context_store).to receive(:reading_for_pid).with(999).and_return(
          {"pct" => 10, "recorded_at" => "2026-09-27T00:00:00Z", "started" => started}
        )
      end

      it "uses the pid reading when the pid is alive with the recorded start time" do
        allow(lock_holder).to receive(:alive?).with(pid: 999, started: started).and_return(true)

        result = reader.read(pane_id: "%1", agent_pid: 999)
        expect(result).to include(pct: 10, error: nil, updated_at: "2026-09-27T00:00:00Z")
      end

      it "uses the pid reading when the status-line process had no pane id" do
        allow(lock_holder).to receive(:alive?).with(pid: 999, started: started).and_return(true)

        expect(reader.read(pane_id: nil, agent_pid: 999)[:pct]).to eq(10)
      end

      it "reports undetermined when the pid is no longer running" do
        allow(lock_holder).to receive(:alive?).with(pid: 999, started: started).and_return(false)

        result = reader.read(pane_id: "%1", agent_pid: 999)
        expect(result).to eq(pct: nil, error: Workspace::ContextReasons::PID_UNVERIFIED, updated_at: nil)
      end

      it "reports undetermined when the pid is alive but was started at a different time" do
        process_tree = instance_double(Workspace::ProcessTree)
        snapshot = Workspace::ProcessTree::Snapshot.new([{pid: 999, ppid: 1, lstart: "Mon Sep 28 09:00:00 2026", command: "claude", args: "claude"}])
        allow(process_tree).to receive(:snapshot).and_return(snapshot)
        real_reader = described_class.new(context_store: context_store, project_settings: project_settings,
          lock_holder: Workspace::LockHolder.new(process_tree: process_tree, env: {}))

        result = real_reader.read(pane_id: "%1", agent_pid: 999)
        expect(result).to eq(pct: nil, error: Workspace::ContextReasons::PID_UNVERIFIED, updated_at: nil)
      end

      it "trusts a live pid whose start time matches, checked against the process table" do
        process_tree = instance_double(Workspace::ProcessTree)
        snapshot = Workspace::ProcessTree::Snapshot.new([{pid: 999, ppid: 1, lstart: started, command: "claude", args: "claude"}])
        allow(process_tree).to receive(:snapshot).and_return(snapshot)
        real_reader = described_class.new(context_store: context_store, project_settings: project_settings,
          lock_holder: Workspace::LockHolder.new(process_tree: process_tree, env: {}))

        expect(real_reader.read(pane_id: "%1", agent_pid: 999)[:pct]).to eq(10)
      end

      it "reports undetermined when the process table can't be read" do
        process_tree = instance_double(Workspace::ProcessTree)
        allow(process_tree).to receive(:snapshot)
          .and_raise(Workspace::Error, "could not read the process table (ps timed out after 5s)")
        real_reader = described_class.new(context_store: context_store, project_settings: project_settings,
          lock_holder: Workspace::LockHolder.new(process_tree: process_tree, env: {}))

        result = real_reader.read(pane_id: "%1", agent_pid: 999)
        expect(result).to eq(pct: nil, error: Workspace::ContextReasons::PID_UNVERIFIED, updated_at: nil)
      end

      it "never trusts a pid reading stored without a start time" do
        allow(context_store).to receive(:reading_for_pid).with(999).and_return(
          {"pct" => 10, "recorded_at" => "2026-09-27T00:00:00Z"}
        )
        expect(lock_holder).not_to receive(:alive?)

        result = reader.read(pane_id: "%1", agent_pid: 999)
        expect(result).to eq(pct: nil, error: Workspace::ContextReasons::PID_UNVERIFIED, updated_at: nil)
      end
    end

    it "reports 'no reading recorded' when nothing was ever stored" do
      allow(context_store).to receive(:reading_for_pane).and_return(nil)

      result = reader.read(pane_id: "%1")
      expect(result[:pct]).to be_nil
      expect(result[:error]).to eq(Workspace::ContextReasons::NO_READING)
      expect(result[:updated_at]).to be_nil
    end

    it "never queries by pid when no agent_pid is given" do
      allow(context_store).to receive(:reading_for_pane).and_return(nil)
      expect(context_store).not_to receive(:reading_for_pid)

      reader.read(pane_id: "%1")
    end
  end

  describe "scrape source" do
    let(:global_config) { {"context" => {"source" => "scrape", "pattern" => '(\d+)% ctx'}} }

    it "extracts the percentage from the pane's captured text" do
      allow(tmux).to receive(:capture_screen).with("%1").and_return("stuff 37% ctx more")

      result = reader.read(pane_id: "%1")
      expect(result[:pct]).to eq(37)
      expect(result[:error]).to be_nil
      expect(result[:updated_at]).not_to be_nil
    end

    it "reports a pattern mismatch when the pane text doesn't match" do
      allow(tmux).to receive(:capture_screen).with("%1").and_return("nothing here")

      result = reader.read(pane_id: "%1")
      expect(result[:pct]).to be_nil
      expect(result[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    it "reports a pattern mismatch when the pane can't be captured" do
      allow(tmux).to receive(:capture_screen).with("%1").and_return(nil)

      result = reader.read(pane_id: "%1")
      expect(result[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    context "with no pattern configured" do
      let(:global_config) { {"context" => {"source" => "scrape"}} }

      it "reports no pattern configured" do
        result = reader.read(pane_id: "%1")
        expect(result[:error]).to eq(Workspace::ContextReasons::NO_PATTERN)
      end
    end

    it "never guesses on an invalid pattern" do
      global_config["context"]["pattern"] = "(unterminated"
      allow(tmux).to receive(:capture_screen).and_return("50% ctx")

      result = reader.read(pane_id: "%1")
      expect(result[:pct]).to be_nil
      expect(result[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    describe "scan slot gating" do
      let(:scan_slots) { instance_double(Workspace::ScanSlotLimiter) }
      let(:now) { [Time.utc(2026, 10, 5, 12, 0, 0)] }
      let(:gated_reader) do
        described_class.new(context_store: context_store, project_settings: project_settings, tmux: tmux,
          lock_holder: lock_holder, scan_slots: scan_slots, clock: -> { now[0] })
      end

      it "scrapes under a slot and caches the reading for a later busy read" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return("37% ctx")

        first = gated_reader.read(pane_id: "%1")
        expect(first).to include(pct: 37, error: nil, updated_at: "2026-10-05T12:00:00Z")

        # Every slot busy, and the cached reading still fresh at the TTL edge.
        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
        now[0] += described_class::SCRAPE_CACHE_TTL

        expect(gated_reader.read(pane_id: "%1")).to eq(first)
        expect(tmux).to have_received(:capture_screen).with("%1").exactly(1).time
      end

      it "reports undetermined when every slot is busy and the pane was never scraped" do
        allow(tmux).to receive(:capture_screen).and_return("37% ctx")
        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)

        result = gated_reader.read(pane_id: "%1")
        expect(result[:pct]).to be_nil
        expect(result[:error]).to eq(Workspace::ContextReasons::SCAN_BUSY)
        expect(tmux).not_to have_received(:capture_screen)
      end

      it "reports undetermined when every slot is busy and the cached reading is stale" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return("37% ctx")
        gated_reader.read(pane_id: "%1")

        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
        now[0] += described_class::SCRAPE_CACHE_TTL + 1

        result = gated_reader.read(pane_id: "%1")
        expect(result[:pct]).to be_nil
        expect(result[:error]).to eq(Workspace::ContextReasons::SCAN_BUSY)
      end

      it "caches only per pane, so one pane's busy read doesn't serve another's reading" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return("37% ctx")
        allow(tmux).to receive(:capture_screen).with("%2").and_return(nil)
        gated_reader.read(pane_id: "%1")

        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)

        result = gated_reader.read(pane_id: "%2")
        expect(result[:error]).to eq(Workspace::ContextReasons::SCAN_BUSY)
      end

      it "reports a pattern mismatch, not busy, when the slot was taken and the capture returned no text" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return(nil)

        result = gated_reader.read(pane_id: "%1")
        expect(result[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
      end

      it "caches a mismatched scrape too, so a busy read after it answers no-match from the cache" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return("nothing here")
        first = gated_reader.read(pane_id: "%1")
        expect(first[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)

        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)

        result = gated_reader.read(pane_id: "%1")
        expect(result[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
        expect(tmux).to have_received(:capture_screen).with("%1").exactly(1).time
      end

      it "scrapes and caches inside a scan already holding a slot, as the daemon's monitor does" do
        slot_dir = Dir.mktmpdir("ws-scan-slots")
        begin
          # Separate limiter instances over one slot directory, as the daemon
          # wires the monitor's limiter apart from the reader's.
          monitor_slots = Workspace::ScanSlotLimiter.new(dir: slot_dir, limit: 1)
          reader_slots = Workspace::ScanSlotLimiter.new(dir: slot_dir, limit: 1)
          in_scan = described_class.new(context_store: context_store, project_settings: project_settings,
            tmux: tmux, lock_holder: lock_holder, scan_slots: reader_slots, clock: -> { now[0] })
          allow(tmux).to receive(:capture_screen).with("%1").and_return("37% ctx")

          first = monitor_slots.with_scan_slot { in_scan.read(pane_id: "%1") }
          expect(first).to include(pct: 37, error: nil)

          # The scan populated the reader's cache, so a later busy read of
          # the pane serves the reading the scan scraped.
          holder = reader_slots.send(:take_slot)
          begin
            expect(in_scan.read(pane_id: "%1")).to eq(first)
          ensure
            holder&.close
          end
        ensure
          FileUtils.remove_entry(slot_dir)
        end
      end

      it "refreshes the cache on a later successful scrape, so the window counts from it" do
        allow(scan_slots).to receive(:with_scan_slot).and_yield
        allow(tmux).to receive(:capture_screen).with("%1").and_return("37% ctx")
        gated_reader.read(pane_id: "%1")

        now[0] += 60
        allow(tmux).to receive(:capture_screen).with("%1").and_return("82% ctx")
        second = gated_reader.read(pane_id: "%1")
        expect(second[:pct]).to eq(82)

        # 85s past the first scrape (stale), 25s past the second: the second
        # keeps the reading fresh.
        now[0] += 25
        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)

        expect(gated_reader.read(pane_id: "%1")).to eq(second)
      end
    end
  end

  it "treats an unreadable global config as empty rather than raising" do
    allow(project_settings).to receive(:load_global).and_raise(StandardError, "boom")
    allow(context_store).to receive(:reading_for_pane).and_return(nil)

    expect { reader.read(pane_id: "%1") }.not_to raise_error
  end

  describe "a pane read by its agent kind" do
    let(:codex_screen) { "earlier: Context 12% used in a quote\n\n  gpt-5  Context 72% used · Context 28% left\n? for shortcuts ⚠ 4 warnings · f2 to view\n" }

    it "reads Codex from its own footer, as the percent used, whatever context.source says" do
      allow(tmux).to receive(:capture_screen).with("%1").and_return(codex_screen)

      result = reader.read(pane_id: "%1", kind: "codex")

      expect(result).to include(pct: 72, error: nil, session_id: nil)
      expect(result[:recorded_at]).to be_a(Time)
    end

    it "takes the last match on the screen, which is the footer, and never its 'left' half" do
      allow(tmux).to receive(:capture_screen).and_return("Context 10% used · Context 90% left\n  Context 90% used · Context 10% left")

      expect(reader.read(pane_id: "%1", kind: "codex")[:pct]).to eq(90)
    end

    it "reads the used half of the footer directly, clamped into 0..100" do
      allow(tmux).to receive(:capture_screen).and_return("Context 0% used · Context 100% left")
      expect(reader.read(pane_id: "%1", kind: "codex")[:pct]).to eq(0)
      allow(tmux).to receive(:capture_screen).and_return("Context 130% used")
      expect(reader.read(pane_id: "%1", kind: "codex")[:pct]).to eq(100)
    end

    it "reports a pattern mismatch when the footer is not on the screen" do
      allow(tmux).to receive(:capture_screen).and_return("working...")

      expect(reader.read(pane_id: "%1", kind: "codex")).to include(pct: nil, error: Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    it "uses context.patterns for the kind, whose capture is the percent used" do
      global_config["context"] = {"patterns" => {"codex" => 'ctx (\d+)%'}}
      allow(tmux).to receive(:capture_screen).and_return("ctx 41% Context 72% used")

      expect(reader.read(pane_id: "%1", kind: "codex")[:pct]).to eq(41)
    end

    it "scrapes a kind with a configured pattern even when it has no built-in one" do
      global_config["context"] = {"patterns" => {"opencode" => '(\d+)% used'}}
      allow(tmux).to receive(:capture_screen).and_return("55% used")

      expect(reader.read(pane_id: "%1", kind: "opencode")[:pct]).to eq(55)
    end

    it "never guesses on an invalid configured pattern" do
      global_config["context"] = {"patterns" => {"codex" => "(unterminated"}}
      allow(tmux).to receive(:capture_screen).and_return("Context 72% used")

      expect(reader.read(pane_id: "%1", kind: "codex")).to include(pct: nil, error: Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    it "reports a pattern mismatch when the pane cannot be captured, or no tmux was given" do
      allow(tmux).to receive(:capture_screen).and_return(nil)
      expect(reader.read(pane_id: "%1", kind: "codex")[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)

      no_tmux = described_class.new(context_store: context_store, project_settings: project_settings, lock_holder: lock_holder)
      expect(no_tmux.read(pane_id: "%1", kind: "codex")[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    it "leaves Claude on the status line when context.patterns has no entry for it" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return({"pct" => 42, "recorded_at" => "2026-09-27T00:00:00Z"})

      expect(reader.read(pane_id: "%1", kind: "claude")[:pct]).to eq(42)
    end

    it "falls back to context.pattern in scrape mode for a kind with no pattern of its own" do
      global_config["context"] = {"source" => "scrape", "pattern" => '(\d+)% ctx'}
      allow(tmux).to receive(:capture_screen).and_return("37% ctx")

      expect(reader.read(pane_id: "%1", kind: "opencode")[:pct]).to eq(37)
    end

    it "reports a mismatch, not an error, for a configured pattern with no capture group" do
      global_config["context"] = {"patterns" => {"codex" => "context left"}}
      allow(tmux).to receive(:capture_screen).and_return("72% context left")

      expect(reader.read(pane_id: "%1", kind: "codex")).to include(pct: nil, error: Workspace::ContextReasons::PATTERN_NO_MATCH)
    end

    it "ignores a context.patterns that is not a mapping, and uses the built-in Codex pattern" do
      global_config["context"] = {"patterns" => "codex"}
      allow(tmux).to receive(:capture_screen).and_return("Context 72% used")

      expect(reader.read(pane_id: "%1", kind: "codex")[:pct]).to eq(72)
    end

    describe "under the scan slots" do
      let(:scan_slots) { instance_double(Workspace::ScanSlotLimiter) }
      let(:now) { [Time.utc(2026, 10, 5, 12, 0, 0)] }
      let(:gated) do
        described_class.new(context_store: context_store, project_settings: project_settings, tmux: tmux,
          lock_holder: lock_holder, scan_slots: scan_slots, clock: -> { now[0] })
      end

      it "serves the last reading while it is fresh when every slot is busy, and reports busy otherwise" do
        allow(scan_slots).to receive(:with_scan_slot) { |&block| block.call }
        allow(tmux).to receive(:capture_screen).and_return("Context 72% used")
        expect(gated.read(pane_id: "%1", kind: "codex")[:pct]).to eq(72)

        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
        now[0] += 5
        expect(gated.read(pane_id: "%1", kind: "codex")[:pct]).to eq(72)
        now[0] += 60
        expect(gated.read(pane_id: "%1", kind: "codex")).to include(pct: nil, error: Workspace::ContextReasons::SCAN_BUSY)
      end

      it "caches a mismatched kind scrape too, so a later busy read answers no-match" do
        allow(scan_slots).to receive(:with_scan_slot) { |&block| block.call }
        allow(tmux).to receive(:capture_screen).and_return("working...")
        expect(gated.read(pane_id: "%1", kind: "codex")[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)

        allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
        now[0] += 5

        expect(gated.read(pane_id: "%1", kind: "codex")[:error]).to eq(Workspace::ContextReasons::PATTERN_NO_MATCH)
      end
    end

    it "treats an unknown kind or nil like no kind" do
      allow(context_store).to receive(:reading_for_pane).and_return({"pct" => 5, "recorded_at" => "2026-09-27T00:00:00Z"})

      expect(reader.read(pane_id: "%1", kind: "mystery")[:pct]).to eq(5)
      expect(reader.read(pane_id: "%1", kind: nil)[:pct]).to eq(5)
    end
  end
end
