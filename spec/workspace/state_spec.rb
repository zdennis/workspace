require "tmpdir"

RSpec.describe Workspace::State do
  let(:tmpdir) { Dir.mktmpdir }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:event_log_file) { File.join(tmpdir, "events.jsonl") }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }

  before do
    allow(config).to receive(:state_file).and_return(state_file)
    allow(config).to receive(:event_log_file).and_return(event_log_file)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def new_state
    event_log = Workspace::EventLog.new(config: config)
    described_class.new(config: config, event_log: event_log)
  end

  describe "#load" do
    it "returns empty state when no event log or state file exists" do
      state = new_state.load
      expect(state).to be_empty
    end

    it "migrates from state file when no event log exists" do
      File.write(state_file, '{"project1": {"unique_id": "abc"}}')
      state = new_state.load
      expect(state["project1"]).to eq({"unique_id" => "abc"})
      expect(File.exist?(event_log_file)).to be true
    end

    it "reconstructs from event log when it exists" do
      event_log = Workspace::EventLog.new(config: config)
      event_log.append(type: "state_set", project: "proj1", data: {"unique_id" => "uid1"})

      state = new_state.load
      expect(state["proj1"]).to eq({"unique_id" => "uid1"})
    end
  end

  describe "round-trip save and load" do
    it "persists and restores state" do
      state = new_state
      state["myproject"] = {"unique_id" => "xyz", "iterm_window_id" => 42}
      state.save

      loaded = new_state.load
      expect(loaded["myproject"]).to eq({"unique_id" => "xyz", "iterm_window_id" => 42})
    end
  end

  describe "hash delegation" do
    subject(:state) do
      s = new_state
      s["a"] = {"nested" => "value"}
      s["b"] = "simple"
      s
    end

    it "returns keys" do
      expect(state.keys).to eq(["a", "b"])
    end

    it "deletes a key" do
      state.delete("a")
      expect(state.keys).to eq(["b"])
    end

    it "reports empty? correctly" do
      expect(state).not_to be_empty
      state.delete("a")
      state.delete("b")
      expect(state).to be_empty
    end

    it "iterates with each" do
      pairs = []
      state.each { |k, v| pairs << k }
      expect(pairs).to eq(["a", "b"])
    end

    it "supports dig for nested access" do
      expect(state.dig("a", "nested")).to eq("value")
    end

    it "returns a copy via to_h" do
      hash = state.to_h
      expect(hash).to eq({"a" => {"nested" => "value"}, "b" => "simple"})
      hash["c"] = "new"
      expect(state["c"]).to be_nil
    end
  end

  describe "backup on save" do
    it "creates a .bak file with previous contents" do
      state = new_state
      state["proj1"] = {"unique_id" => "uid1"}
      state.save

      state["proj2"] = {"unique_id" => "uid2"}
      state.save

      backup = JSON.parse(File.read("#{state_file}.bak"))
      expect(backup.keys).to eq(["proj1"])

      current = JSON.parse(File.read(state_file))
      expect(current.keys).to contain_exactly("proj1", "proj2")
    end

    it "does not create .bak when no prior file exists" do
      state = new_state
      state["proj1"] = {"unique_id" => "uid1"}
      state.save

      expect(File.exist?("#{state_file}.bak")).to be false
    end
  end

  describe "concurrent save via event log" do
    it "merges changes from concurrent processes" do
      # Process A appends an event
      state_a = new_state.load
      state_a["project-a"] = {"unique_id" => "uid-a"}

      # Process B appends an event (same event log file)
      state_b = new_state.load
      state_b["project-b"] = {"unique_id" => "uid-b"}
      state_b.save

      # Process A saves — event log has both, so state file has both
      state_a.save

      loaded = new_state.load
      expect(loaded["project-a"]).to eq({"unique_id" => "uid-a"})
      expect(loaded["project-b"]).to eq({"unique_id" => "uid-b"})
    end

    it "applies deletes from concurrent processes" do
      # Set up initial state
      state = new_state
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"unique_id" => "uid2"}
      state.save

      # Process A deletes proj1
      state_a = new_state.load
      state_a.delete("proj1")

      # Process B adds proj3
      state_b = new_state.load
      state_b["proj3"] = {"unique_id" => "uid3"}
      state_b.save

      # Process A saves
      state_a.save

      loaded = new_state.load
      expect(loaded.keys).to contain_exactly("proj2", "proj3")
    end
  end

  describe "#prune" do
    subject(:state) do
      s = new_state
      s["alive-project"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      s["dead-project"] = {"unique_id" => "uid2", "iterm_window_id" => 200}
      s["also-alive"] = {"unique_id" => "uid3", "iterm_window_id" => 300}
      s
    end

    it "removes entries whose window ID is not in the live set" do
      pruned = state.prune(Set.new([100, 300]))
      expect(pruned).to eq(["dead-project"])
      expect(state.keys).to contain_exactly("alive-project", "also-alive")
    end

    it "removes entries with no iterm_window_id" do
      state["no-wid"] = {"unique_id" => "uid4"}
      pruned = state.prune(Set.new([100, 200, 300]))
      expect(pruned).to eq(["no-wid"])
    end

    it "returns empty array when all entries are live" do
      pruned = state.prune(Set.new([100, 200, 300]))
      expect(pruned).to be_empty
      expect(state.keys.size).to eq(3)
    end

    it "removes all entries when none are live" do
      pruned = state.prune(Set.new)
      expect(pruned).to contain_exactly("alive-project", "dead-project", "also-alive")
      expect(state).to be_empty
    end

    it "does not update the state file" do
      state.save
      state.prune(Set.new)
      # State file still has the old data (save wasn't called after prune)
      on_disk = JSON.parse(File.read(state_file))
      expect(on_disk.keys.size).to eq(3)
    end
  end
end
