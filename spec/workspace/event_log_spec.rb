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

  subject(:event_log) { described_class.new(config: config, error_output: output) }

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

  describe "#record" do
    it "appends an activity event that reconstruct ignores" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      expect(event_log.record(type: "dispatched", project: "proj1", data: {"work_item_ref" => "W-1"})).to be true

      expect(event_log.events.map { |e| e["type"] }).to eq(["launched", "dispatched"])
      expect(event_log.reconstruct).to eq({"proj1" => {"unique_id" => "uid1"}})
    end

    it "warns once on the error stream and carries on when the log can't be written" do
      allow(config).to receive(:event_log_file).and_return(File.join(tmpdir, "missing-dir", "events.jsonl"))

      expect(event_log.record(type: "dispatched", project: "proj1")).to be false
      expect(event_log.record(type: "dispatched", project: "proj1")).to be false

      expect(output.string.scan("could not write to the event log").size).to eq(1)
    end

    it "writes each event as one whole line when several processes append at once" do
      payload = "x" * 6_000
      pids = 4.times.map do |n|
        fork do
          log = described_class.new(config: config, error_output: StringIO.new)
          50.times { |i| log.record(type: "dispatched", project: "p#{n}", data: {"i" => i, "pad" => payload}) }
          exit!(0)
        end
      end
      pids.each { |pid| Process.wait(pid) }

      lines = File.readlines(event_log_file)
      expect(lines.size).to eq(200)
      expect(lines.map { |line| JSON.parse(line)["data"]["pad"].size }.uniq).to eq([6_000])
    end
  end

  describe "#latest_agent_states" do
    it "returns the last agent_state per pane for the project" do
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "working"})
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "idle"})
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%2", "state" => "waiting"})
      event_log.record(type: "agent_state", project: "other", data: {"pane_id" => "%1", "state" => "working"})

      states = event_log.latest_agent_states("proj1")
      expect(states.transform_values { |d| d["state"] }).to eq({"%1" => "idle", "%2" => "waiting"})
    end

    it "skips lines that are not event objects" do
      File.write(event_log_file, "3\n[1]\n")
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "idle"})

      expect(event_log.latest_agent_states("proj1").keys).to eq(["%1"])
    end

    it "adds when each state was logged" do
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "idle"})

      logged_at = event_log.latest_agent_states("proj1")["%1"]["logged_at"]
      expect(logged_at).to eq(event_log.events.last["timestamp"])
    end
  end

  describe "#compact with activity" do
    it "keeps each live pane's latest agent_state and drops other activity" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.record(type: "dispatched", project: "proj1")
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "working"})
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%1", "state" => "idle"})
      event_log.record(type: "agent_state", project: "proj1", data: {"pane_id" => "%2", "state" => "closed"})

      event_log.compact

      expect(event_log.events.map { |e| [e["type"], e.dig("data", "state")] })
        .to eq([["compacted", nil], ["agent_state", "idle"]])
      expect(event_log.latest_agent_states("proj1")["%1"]["state"]).to eq("idle")
    end
  end

  describe "#compact housekeeping" do
    let(:now) { Time.utc(2026, 9, 27, 12, 0, 0) }
    let(:clock) { class_double(Time, now: now) }

    subject(:event_log) { described_class.new(config: config, error_output: output, clock: clock) }

    def agent_state(project, pane_id, since)
      event_log.record(type: "agent_state", project: project,
        data: {"pane_id" => pane_id, "state" => "idle", "since" => since.utc.iso8601(3)})
    end

    it "drops agent_state of projects no longer in state, and of panes quiet for over a week" do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      agent_state("proj1", "%1", now - 3600)
      agent_state("proj1", "%2", now - 8 * 24 * 3600)
      agent_state("gone", "%1", now - 60)

      event_log.compact

      kept = event_log.events.select { |e| e["type"] == "agent_state" }
      expect(kept.map { |e| [e["project"], e["data"]["pane_id"]] }).to eq([["proj1", "%1"]])
    end

    it "writes the rewrite owner-only and leaves no temp file behind" do
      File.write(event_log_file, "")
      File.chmod(0o644, event_log_file)
      event_log.append(type: "launched", project: "proj1")

      event_log.compact

      expect(File.stat(event_log_file).mode & 0o777).to eq(0o600)
      expect(Dir.children(tmpdir).grep(/\.tmp\z/)).to be_empty
    end

    it "raises a Workspace::Error and leaves the log alone when it can't be read" do
      event_log.append(type: "launched", project: "proj1")
      before = File.read(event_log_file)
      File.chmod(0o000, event_log_file)

      expect { event_log.compact }.to raise_error(Workspace::Error, /could not compact/)
    ensure
      File.chmod(0o600, event_log_file)
      expect(File.read(event_log_file)).to eq(before)
    end
  end

  describe "locking" do
    let(:lock_file) { "#{event_log_file}.lock" }

    before { stub_const("Workspace::EventLog::LOCK_WAIT", 0.05) }

    def holding_lock
      File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    it "still appends when another process holds the lock past the wait" do
      holding_lock { event_log.append(type: "launched", project: "proj1") }

      expect(event_log.reconstruct.keys).to eq(["proj1"])
    end

    it "refuses to compact while another process holds the lock" do
      event_log.append(type: "launched", project: "proj1")

      holding_lock do
        expect { event_log.compact }.to raise_error(Workspace::Error, /busy/)
      end
    end
  end

  describe "a torn last line" do
    it "starts the next event on a new line" do
      File.write(event_log_file, '{"type":"launch')

      event_log.append(type: "launched", project: "proj1")

      expect(File.read(event_log_file).lines.last).to start_with('{"timestamp"')
      expect(event_log.reconstruct.keys).to eq(["proj1"])
    end
  end

  describe "an unreadable log" do
    before do
      File.write(event_log_file, JSON.generate({"type" => "launched", "project" => "p", "data" => {}}) + "\n")
      File.chmod(0o000, event_log_file)
    end

    after { File.chmod(0o600, event_log_file) }

    it "reads as empty and warns once" do
      expect(event_log.events).to eq([])
      expect(event_log.reconstruct).to eq({})

      expect(output.string.scan("could not read the event log").size).to eq(1)
    end

    it "counts as holding state events, so nothing migrates over it" do
      expect(event_log.state_events?).to be(true)
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
      File.write(event_log_file, "x" * 1_100_000)
      event_log.warn_if_large
      expect(output.string).to include("event-log compact")
    end

    it "does not warn when file is small" do
      event_log.append(type: "launched", project: "proj1")
      event_log.warn_if_large
      expect(output.string).to be_empty
    end

    it "uses threshold from global config" do
      project_settings = instance_double(Workspace::ProjectSettings)
      allow(project_settings).to receive(:load_global).and_return({"event_log_compact_threshold" => "1kb"})

      el = described_class.new(config: config, project_settings: project_settings, error_output: output)
      File.write(event_log_file, "x" * 2_000) # 2KB > 1KB threshold
      el.warn_if_large
      expect(output.string).to include("event-log compact")
    end

    it "does not warn when below custom threshold" do
      project_settings = instance_double(Workspace::ProjectSettings)
      allow(project_settings).to receive(:load_global).and_return({"event_log_compact_threshold" => "1mb"})

      el = described_class.new(config: config, project_settings: project_settings, error_output: output)
      File.write(event_log_file, "x" * 11_000) # 11KB < 1MB threshold
      el.warn_if_large
      expect(output.string).to be_empty
    end
  end

  describe "#compact_threshold" do
    it "parses kb" do
      ps = instance_double(Workspace::ProjectSettings)
      allow(ps).to receive(:load_global).and_return({"event_log_compact_threshold" => "50kb"})
      el = described_class.new(config: config, project_settings: ps)
      expect(el.compact_threshold).to eq(50 * 1024)
    end

    it "parses mb" do
      ps = instance_double(Workspace::ProjectSettings)
      allow(ps).to receive(:load_global).and_return({"event_log_compact_threshold" => "2mb"})
      el = described_class.new(config: config, project_settings: ps)
      expect(el.compact_threshold).to eq(2 * 1024 * 1024)
    end

    it "parses plain number as bytes" do
      ps = instance_double(Workspace::ProjectSettings)
      allow(ps).to receive(:load_global).and_return({"event_log_compact_threshold" => "5000"})
      el = described_class.new(config: config, project_settings: ps)
      expect(el.compact_threshold).to eq(5000)
    end

    it "falls back to default when not configured" do
      expect(event_log.compact_threshold).to eq(Workspace::EventLog::DEFAULT_COMPACT_THRESHOLD)
    end
  end
end
