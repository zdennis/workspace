require "tmpdir"

RSpec.describe Workspace::EventLog do
  let(:tmpdir) { Dir.mktmpdir }
  let(:event_log_file) { File.join(tmpdir, "events.jsonl") }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:output) { StringIO.new }

  before do
    allow(config).to receive(:event_log_file).and_return(event_log_file)
  end

  after { FileUtils.remove_entry(tmpdir) }

  subject(:event_log) { described_class.new(config: config, output: output) }

  describe "#append" do
    it "creates the file and writes a JSONL line" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})

      lines = File.readlines(event_log_file)
      expect(lines.size).to eq(1)

      event = JSON.parse(lines.first)
      expect(event["type"]).to eq("launched")
      expect(event["project"]).to eq("proj1")
      expect(event["data"]).to eq({"unique_id" => "uid1"})
      expect(event["timestamp"]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it "appends to existing file" do
      event_log.append(type: "launched", project: "proj1")
      event_log.append(type: "launched", project: "proj2")

      lines = File.readlines(event_log_file)
      expect(lines.size).to eq(2)
    end
  end

  describe "#events" do
    it "returns empty array when file does not exist" do
      expect(event_log.events).to eq([])
    end

    it "parses all events from the file" do
      event_log.append(type: "launched", project: "proj1")
      event_log.append(type: "killed", project: "proj1")

      events = event_log.events
      expect(events.size).to eq(2)
      expect(events.map { |e| e["type"] }).to eq(["launched", "killed"])
    end

    it "skips corrupt lines" do
      File.write(event_log_file, "not json\n")
      File.open(event_log_file, "a") do |f|
        f.puts JSON.generate({"type" => "launched", "project" => "proj1", "data" => {}})
      end

      events = event_log.events
      expect(events.size).to eq(1)
    end
  end

  describe "#reconstruct" do
    it "builds state from launch and window discovery events" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "window_discovered", project: "proj1", data: {"iterm_window_id" => 100})

      state = event_log.reconstruct
      expect(state["proj1"]).to eq({"unique_id" => "uid1", "iterm_window_id" => 100})
    end

    it "removes projects on kill/stop/prune events" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "launched", project: "proj2", data: {"unique_id" => "uid2"})
      event_log.append(type: "killed", project: "proj1")

      state = event_log.reconstruct
      expect(state.keys).to eq(["proj2"])
    end

    it "handles state_set and state_removed events" do
      event_log.append(type: "state_set", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "state_removed", project: "proj1")

      state = event_log.reconstruct
      expect(state).to be_empty
    end

    it "last event wins for the same project" do
      event_log.append(type: "state_set", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "state_set", project: "proj1", data: {"unique_id" => "uid2"})

      state = event_log.reconstruct
      expect(state["proj1"]["unique_id"]).to eq("uid2")
    end

    it "handles compacted events" do
      event_log.append(type: "compacted", project: "proj1", data: {"unique_id" => "uid1", "iterm_window_id" => 100})

      state = event_log.reconstruct
      expect(state["proj1"]).to eq({"unique_id" => "uid1", "iterm_window_id" => 100})
    end
  end

  describe "#compact" do
    it "rewrites the log with one event per active project" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "window_discovered", project: "proj1", data: {"iterm_window_id" => 100})
      event_log.append(type: "launched", project: "proj2", data: {"unique_id" => "uid2"})
      event_log.append(type: "killed", project: "proj2")
      event_log.append(type: "launched", project: "proj3", data: {"unique_id" => "uid3"})

      before_lines = File.readlines(event_log_file).size
      expect(before_lines).to eq(5)

      state = event_log.compact

      after_lines = File.readlines(event_log_file).size
      expect(after_lines).to eq(2) # proj1 and proj3

      expect(state.keys).to contain_exactly("proj1", "proj3")
      expect(state["proj1"]).to eq({"unique_id" => "uid1", "iterm_window_id" => 100})

      # Verify compacted events reconstruct correctly
      expect(event_log.reconstruct).to eq(state)
    end
  end

  describe "#size" do
    it "returns 0 when file does not exist" do
      expect(event_log.size).to eq(0)
    end

    it "returns file size in bytes" do
      event_log.append(type: "launched", project: "proj1")
      expect(event_log.size).to be > 0
    end
  end

  describe "#warn_if_large" do
    it "warns when file exceeds threshold" do
      File.write(event_log_file, "x" * 11_000)
      event_log.warn_if_large
      expect(output.string).to include("event-log compact")
    end

    it "does not warn when file is small" do
      event_log.append(type: "launched", project: "proj1")
      event_log.warn_if_large
      expect(output.string).to be_empty
    end
  end
end
