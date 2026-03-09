require "tmpdir"

RSpec.describe Workspace::State do
  let(:tmpdir) { Dir.mktmpdir }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }

  before do
    allow(config).to receive(:state_file).and_return(state_file)
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#load" do
    it "returns empty state when file does not exist" do
      state = described_class.new(config: config).load
      expect(state).to be_empty
    end

    it "returns empty state when file contains invalid JSON" do
      File.write(state_file, "not json{{{")
      state = described_class.new(config: config).load
      expect(state).to be_empty
    end

    it "loads valid JSON state" do
      File.write(state_file, '{"project1": {"unique_id": "abc"}}')
      state = described_class.new(config: config).load
      expect(state["project1"]).to eq({"unique_id" => "abc"})
    end
  end

  describe "round-trip save and load" do
    it "persists and restores state" do
      state = described_class.new(config: config)
      state["myproject"] = {"unique_id" => "xyz", "iterm_window_id" => 42}
      state.save

      loaded = described_class.new(config: config).load
      expect(loaded["myproject"]).to eq({"unique_id" => "xyz", "iterm_window_id" => 42})
    end
  end

  describe "hash delegation" do
    subject(:state) do
      s = described_class.new(config: config)
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
      state = described_class.new(config: config)
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
      state = described_class.new(config: config)
      state["proj1"] = {"unique_id" => "uid1"}
      state.save

      expect(File.exist?("#{state_file}.bak")).to be false
    end
  end

  describe "concurrent save" do
    it "merges in-memory changes with state written by another process" do
      # Simulate process A loading state
      state_a = described_class.new(config: config).load
      state_a["project-a"] = {"unique_id" => "uid-a"}

      # Simulate process B saving state while A is still running
      state_b = described_class.new(config: config).load
      state_b["project-b"] = {"unique_id" => "uid-b"}
      state_b.save

      # Process A saves — should merge, not clobber B's entry
      state_a.save

      loaded = described_class.new(config: config).load
      expect(loaded["project-a"]).to eq({"unique_id" => "uid-a"})
      expect(loaded["project-b"]).to eq({"unique_id" => "uid-b"})
    end

    it "applies deletes even when disk state has changed" do
      # Set up initial state with two projects
      state = described_class.new(config: config)
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"unique_id" => "uid2"}
      state.save

      # Process A loads, then deletes proj1
      state_a = described_class.new(config: config).load
      state_a.delete("proj1")

      # Process B adds proj3 concurrently
      state_b = described_class.new(config: config).load
      state_b["proj3"] = {"unique_id" => "uid3"}
      state_b.save

      # Process A saves — should remove proj1, keep proj2 and proj3
      state_a.save

      loaded = described_class.new(config: config).load
      expect(loaded.keys).to contain_exactly("proj2", "proj3")
    end
  end

  describe "#prune" do
    subject(:state) do
      s = described_class.new(config: config)
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

    it "does not call save" do
      state.save
      state.prune(Set.new)
      loaded = described_class.new(config: config).load
      expect(loaded.keys.size).to eq(3)
    end
  end
end
