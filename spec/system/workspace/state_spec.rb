require "tmpdir"
require "timeout"
require "rbconfig"

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

  def new_state(**options)
    event_log = Workspace::EventLog.new(config: config)
    described_class.new(config: config, event_log: event_log, **options)
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

    it "migrates from the state file once, even when load runs again" do
      File.write(state_file, '{"project1": {"unique_id": "abc"}}')
      Workspace::EventLog.new(config: config).record(type: "lock_wait_started", project: "project1")

      new_state.load
      new_state.load

      types = Workspace::EventLog.new(config: config).events.map { |e| e["type"] }
      expect(types).to eq(["lock_wait_started", "migrated"])
    end

    it "does not migrate over a log that already holds state events" do
      File.write(state_file, '{"stale": {"unique_id": "old"}}')
      event_log = Workspace::EventLog.new(config: config)
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "uid1"})
      event_log.append(type: "killed", project: "proj1")

      expect(new_state.load).to be_empty
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

    it "raises and leaves the state file alone when the event log can't be read" do
      state = new_state
      state["proj1"] = {"unique_id" => "uid1"}
      state.save
      before = File.read(state_file)
      File.chmod(0o000, event_log_file)

      expect { state.save }.to raise_error(Workspace::Error, /could not read the event log #{Regexp.escape(event_log_file)}/)
      expect(File.read(state_file)).to eq(before)
    ensure
      File.chmod(0o600, event_log_file)
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

    # A second process sets an entry and saves while this save sits between
    # reading the log and renaming its file into place. Without a lock around
    # the read and the rename, this save's older view lands last and the state
    # file loses the other process's entry until some later save.
    it "keeps another process's entry when its save lands while this save is writing" do
      home = Dir.mktmpdir
      home_config = Workspace::Config.new(workspace_dir: home)
      # The child process reads these paths from its HOME.
      allow(home_config).to receive(:state_file).and_return(File.join(home, ".workspace-state.json"))
      allow(home_config).to receive(:event_log_file).and_return(File.join(home, ".workspace-events.jsonl"))
      marker = File.join(home, "saving")
      script = <<~CHILD
        require "workspace"
        config = Workspace::Config.new(workspace_dir: ENV["HOME"])
        state = Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config)).load
        state["proj-b"] = {"unique_id" => "uid-b"}
        File.write(#{marker.inspect}, "")
        state.save
      CHILD
      env = {"HOME" => home, "XDG_STATE_HOME" => File.join(home, "state"),
             "XDG_CONFIG_HOME" => File.join(home, "config"), "SKIP_SIMPLECOV" => "1"}
      pid = nil
      writer = lambda do |path, text|
        if path.end_with?(".tmp") && pid.nil?
          pid = Process.spawn(env, RbConfig.ruby, "-I", File.join(PROJECT_ROOT, "lib"), "-e", script,
            out: File::NULL, err: File::NULL)
          Timeout.timeout(30) { sleep 0.01 until File.exist?(marker) }
          sleep 0.5
        end
        File.write(path, text)
      end
      first = described_class.new(config: home_config, event_log: Workspace::EventLog.new(config: home_config), writer: writer)
      first.load
      first["proj-a"] = {"unique_id" => "uid-a"}

      begin
        first.save
      ensure
        Timeout.timeout(30) { Process.wait(pid) } if pid
      end

      expect($?.success?).to be(true)
      expect(JSON.parse(File.read(home_config.state_file)).keys).to contain_exactly("proj-a", "proj-b")
    ensure
      FileUtils.remove_entry(home)
    end

    it "saves without the lock once another holder keeps it past the wait" do
      state = new_state(lock_wait: 0.05).load
      state["proj1"] = {"unique_id" => "uid1"}

      File.open("#{state_file}.lock", File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        state.save
      end

      expect(JSON.parse(File.read(state_file)).keys).to eq(["proj1"])
    end

    it "saves without the lock when the lock file can't be opened" do
      FileUtils.touch("#{state_file}.lock")
      FileUtils.chmod(0o000, "#{state_file}.lock")
      state = new_state.load
      state["proj1"] = {"unique_id" => "uid1"}

      state.save

      expect(JSON.parse(File.read(state_file)).keys).to eq(["proj1"])
    end

    it "logs why it saves without the lock when the lock file can't be opened" do
      FileUtils.touch("#{state_file}.lock")
      FileUtils.chmod(0o000, "#{state_file}.lock")
      out = StringIO.new
      state = new_state(logger: Workspace::Logger.new(output: out, enabled: true)).load
      state["proj1"] = {"unique_id" => "uid1"}

      state.save

      expect(out.string).to include("state: can't open the lock file (Errno::EACCES: ")
      expect(out.string).to include("state: saving without the state file lock")
    end

    it "logs why it saves without the lock when the lock can't be taken" do
      out = StringIO.new
      state = new_state(logger: Workspace::Logger.new(output: out, enabled: true)).load
      state["proj1"] = {"unique_id" => "uid1"}
      allow_any_instance_of(Workspace::FileLock).to receive(:flock_mode).and_raise(Errno::ENOLCK)

      state.save

      expect(out.string).to include("state: can't lock the state file (Errno::ENOLCK: ")
    end

    it "does not make the state file's directory for the lock, and still reaches the write" do
      missing = File.join(tmpdir, "gone", "state.json")
      allow(config).to receive(:state_file).and_return(missing)
      out = StringIO.new
      state = new_state(logger: Workspace::Logger.new(output: out, enabled: true)).load
      state["proj1"] = {"unique_id" => "uid1"}

      expect { state.save }.to raise_error(Errno::ENOENT)
      expect(File.exist?(File.dirname(missing))).to be(false)
      expect(out.string).to include("state: can't open the lock file")
    end

    it "writes each save through its own temp file and leaves none behind" do
      temp_files = []
      renamer = lambda do |from, to|
        temp_files << from
        File.rename(from, to)
      end
      first = described_class.new(config: config, event_log: Workspace::EventLog.new(config: config), renamer: renamer).load
      first["proj1"] = {"headless" => true}
      first.save
      first.save

      expect(temp_files.uniq.size).to eq(2)
      expect(Dir.children(tmpdir).grep(/\.tmp\z/)).to be_empty
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
