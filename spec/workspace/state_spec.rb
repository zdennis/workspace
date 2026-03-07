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
end
