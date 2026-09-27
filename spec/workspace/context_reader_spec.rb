RSpec.describe Workspace::ContextReader do
  let(:context_store) { instance_double(Workspace::ContextStore) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:global_config) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_config) }
  let(:reader) { described_class.new(context_store: context_store, project_settings: project_settings, tmux: tmux) }

  describe "statusline source (default)" do
    it "returns the pane's reading when one is recorded" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(
        {"pct" => 42, "recorded_at" => "2026-09-27T00:00:00Z"}
      )

      result = reader.read(pane_id: "%1")
      expect(result).to eq(pct: 42, error: nil, updated_at: "2026-09-27T00:00:00Z")
    end

    it "falls back to the agent pid when no pane reading exists" do
      allow(context_store).to receive(:reading_for_pane).with("%1").and_return(nil)
      allow(context_store).to receive(:reading_for_pid).with(999).and_return(
        {"pct" => 10, "recorded_at" => "2026-09-27T00:00:00Z"}
      )

      result = reader.read(pane_id: "%1", agent_pid: 999)
      expect(result).to eq(pct: 10, error: nil, updated_at: "2026-09-27T00:00:00Z")
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
