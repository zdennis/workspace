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
  end

  it "treats an unreadable global config as empty rather than raising" do
    allow(project_settings).to receive(:load_global).and_raise(StandardError, "boom")
    allow(context_store).to receive(:reading_for_pane).and_return(nil)

    expect { reader.read(pane_id: "%1") }.not_to raise_error
  end
end
