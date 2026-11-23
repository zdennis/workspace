require "tmpdir"
require "timeout"
require "rbconfig"

RSpec.describe Workspace::EventLog, "rotation" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:event_log_file) { File.join(tmpdir, ".workspace-events.jsonl") }
  let(:config) do
    Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
      allow(c).to receive(:event_log_file).and_return(event_log_file)
    end
  end
  let(:errors) { StringIO.new }
  let(:threshold) { 1_000 }
  let(:keep) { 3 }

  subject(:event_log) do
    described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def fill(log, count: 30)
    count.times { |i| log.append(type: "dispatched", project: "proj1", data: {"n" => i, "pad" => "x" * 50}) }
  end

  def lines_of(path)
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  it "keeps appending to a log below the threshold without rotating" do
    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})

    expect(File.exist?("#{event_log_file}.1")).to be(false)
    expect(lines_of(event_log_file).size).to eq(1)
  end

  it "renames the full log to .1 and starts a new file, so a tail sees a new inode" do
    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
    fill(event_log, count: 5)
    inode_before = File.stat(event_log_file).ino
    fill(event_log, count: 15)

    rotated = "#{event_log_file}.1"
    expect(File.exist?(rotated)).to be(true)
    expect(File.stat(event_log_file).ino).not_to eq(inode_before)
    expect(File.stat(rotated).size).to be >= threshold
    expect(File.stat(event_log_file).size).to be < File.stat(rotated).size
  end

  it "seeds the new log with the current state, so state survives rotation" do
    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1", "iterm_window_id" => 7})
    event_log.append(type: "launched", project: "gone", data: {"unique_id" => "u2"})
    event_log.append(type: "killed", project: "gone")
    fill(event_log)

    expect(File.exist?("#{event_log_file}.1")).to be(true)
    expect(event_log.reconstruct).to eq({"proj1" => {"unique_id" => "u1", "iterm_window_id" => 7}})
    expect(lines_of(event_log_file).map { |e| e["type"] }).to include("compacted")
  end

  it "keeps the activity history in the rotated file" do
    fill(event_log, count: 30)

    kept = (1..keep).flat_map { |n| ((p = "#{event_log_file}.#{n}") && File.exist?(p)) ? lines_of(p) : [] }
    expect(kept.select { |e| e["type"] == "dispatched" }).not_to be_empty
  end

  it "keeps at most keep_rotated rotated files, dropping the oldest" do
    fill(event_log, count: 400)

    expect(Dir[File.join(tmpdir, ".workspace-events.jsonl.*")].reject { |f| f.end_with?(".lock") }.sort)
      .to eq((1..keep).map { |n| "#{event_log_file}.#{n}" })
  end

  it "numbers newest rotated file 1" do
    fill(event_log, count: 400)

    newest = lines_of("#{event_log_file}.1").filter_map { |e| e.dig("data", "n") }
    oldest = lines_of("#{event_log_file}.#{keep}").filter_map { |e| e.dig("data", "n") }
    expect(newest.min).to be > oldest.max
  end

  it "rotates once, not again on the next append" do
    event_log.append(type: "dispatched", project: "proj1", data: {"pad" => "x" * 2_000})
    first = File.stat("#{event_log_file}.1").ino
    event_log.append(type: "dispatched", project: "proj1")

    expect(File.stat("#{event_log_file}.1").ino).to eq(first)
    expect(File.exist?("#{event_log_file}.2")).to be(false)
  end

  it "never leaves a moment without a log for readers, which take no lock" do
    seen = []
    renamer = lambda do |*args|
      seen << File.exist?(event_log_file)
      File.rename(*args)
    end
    linker = lambda do |*args|
      seen << File.exist?(event_log_file)
      File.link(*args)
    end
    event_log = described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep,
      renamer: renamer, linker: linker)

    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
    fill(event_log, count: 20)

    expect(seen).not_to be_empty
    expect(seen).to all(be(true))
    expect(File.exist?(event_log_file)).to be(true)
  end

  it "writes the event even when rotation fails, and does not raise" do
    event_log = described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep,
      linker: ->(*) { raise Errno::EACCES })

    expect { fill(event_log, count: 20) }.not_to raise_error
    expect(lines_of(event_log_file).size).to eq(20)
  end

  it "drops no rotated file when the log can't be linked" do
    fill(event_log, count: 20)
    before = Dir["#{event_log_file}.*"].reject { |f| f.end_with?(".lock") }.to_h { |f| [f, File.stat(f).ino] }
    refusing = described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep,
      linker: ->(*) { raise Errno::EPERM })

    fill(refusing, count: 40)

    expect(Dir["#{event_log_file}.*"].reject { |f| f.end_with?(".lock") }.to_h { |f| [f, File.stat(f).ino] }).to eq(before)
  end

  it "skips rotation when another process holds the log's lock, and still appends" do
    event_log = described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep, rotate_lock_wait: 0.05)
    fill(event_log, count: 5)
    holder = File.open("#{event_log_file}.lock", File::RDWR | File::CREAT, 0o600)
    holder.flock(File::LOCK_SH)

    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fill(event_log, count: 15)
      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ensure
      holder.close
    end

    expect(waited).to be < 3
    expect(File.exist?("#{event_log_file}.1")).to be(false)
    expect(lines_of(event_log_file).size).to eq(20)
  end

  it "loses and interleaves nothing when several processes append and rotate at once" do
    lib = File.join(PROJECT_ROOT, "lib")
    script = <<~RUBY
      require "workspace"
      config = Workspace::Config.new(workspace_dir: ENV["HOME"])
      log = Workspace::EventLog.new(config: config, compact_threshold: 1500, keep_rotated: 10_000)
      50.times { |i| log.append(type: "dispatched", project: "w" + ENV["WORKER"], data: {"i" => i, "pad" => "y" * 40}) }
    RUBY
    env = {"HOME" => tmpdir, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"),
           "XDG_STATE_HOME" => File.join(tmpdir, "state"), "SKIP_SIMPLECOV" => "1"}
    pids = (1..4).map do |worker|
      Process.spawn(env.merge("WORKER" => worker.to_s), RbConfig.ruby, "-I", lib, "-e", script,
        err: File::NULL, out: File::NULL)
    end
    statuses = pids.map { |pid| Timeout.timeout(60) { Process.wait2(pid).last } }

    expect(statuses.map(&:success?)).to all(be(true))
    files = Dir[File.join(tmpdir, ".workspace-events.jsonl*")].reject { |f| f.end_with?(".lock") }
    expect(files.size).to be > 1
    events = files.flat_map { |f| File.readlines(f) }.map { |l| JSON.parse(l) }
    sent = events.select { |e| e["type"] == "dispatched" }.map { |e| [e["project"], e["data"]["i"]] }
    expect(sent.sort).to eq((1..4).flat_map { |w| (0...50).map { |i| ["w#{w}", i] } }.sort)
    expect(sent.uniq.size).to eq(sent.size)
  end

  describe "automatic compaction by the configured threshold" do
    def log_with(threshold, **opts)
      described_class.new(config: config, error_output: errors, compact_threshold: threshold, keep_rotated: keep, **opts)
    end

    it "compacts on the append that passes the threshold, keeps .1 and leaves a seeded log" do
      log = log_with(threshold)
      log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
      log.append(type: "dispatched", project: "proj1", data: {"pad" => "x" * 2_000})

      expect(File.exist?("#{event_log_file}.1")).to be(true)
      expect(lines_of("#{event_log_file}.1").map { |e| e["type"] }).to eq(["launched", "dispatched"])
      expect(lines_of(event_log_file).map { |e| e["type"] }).to eq(["compacted"])
    end

    it "never compacts when the threshold is nil" do
      log = log_with(nil)
      fill(log, count: 200)

      expect(File.exist?("#{event_log_file}.1")).to be(false)
      expect(lines_of(event_log_file).size).to eq(200)
    end

    it "never compacts when the callable answers nil" do
      log = log_with(-> {})
      fill(log, count: 100)

      expect(File.exist?("#{event_log_file}.1")).to be(false)
    end

    it "calls a raising threshold callable once, turns compaction off and still writes the events" do
      calls = 0
      log = log_with(-> {
        calls += 1
        raise "config unreadable"
      })
      fill(log, count: 60)

      expect(calls).to eq(1)
      expect(File.exist?("#{event_log_file}.1")).to be(false)
      expect(lines_of(event_log_file).size).to eq(60)
    end

    it "calls a threshold callable once over many appends" do
      calls = 0
      log = log_with(-> {
        calls += 1
        threshold
      })
      fill(log, count: 60)

      expect(calls).to eq(1)
      expect(File.exist?("#{event_log_file}.1")).to be(true)
    end

    it "compacts once when two processes pass the size check together, because the size is checked again under the lock" do
      lib = File.join(PROJECT_ROOT, "lib")
      File.write(event_log_file, JSON.generate({"timestamp" => "2026-01-01T00:00:00.000Z", "type" => "dispatched", "project" => "seed", "data" => {"pad" => "s" * 1_600}}) + "\n")
      script = <<~RUBY
        require "workspace"
        config = Workspace::Config.new(workspace_dir: ENV["HOME"])
        # Each process waits, right after its size check says "over", until the other has passed it too.
        class BarrieredLog < Workspace::EventLog
          def size
            value = super
            unless @barriered
              @barriered = true
              File.write(ENV["READY"], "")
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
              sleep 0.01 until File.exist?(ENV["OTHER"]) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            end
            value
          end
        end
        log = BarrieredLog.new(config: config, compact_threshold: 1500, keep_rotated: 10, rotate_lock_wait: 20)
        log.append(type: "dispatched", project: "w" + ENV["WORKER"], data: {"pad" => "y" * 300})
      RUBY
      env = {"HOME" => tmpdir, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"),
             "XDG_STATE_HOME" => File.join(tmpdir, "state"), "SKIP_SIMPLECOV" => "1"}
      ready = {1 => File.join(tmpdir, "ready1"), 2 => File.join(tmpdir, "ready2")}
      pids = [1, 2].map do |worker|
        Process.spawn(env.merge("WORKER" => worker.to_s, "READY" => ready[worker], "OTHER" => ready[3 - worker]),
          RbConfig.ruby, "-I", lib, "-e", script, err: File::NULL, out: File::NULL)
      end
      statuses = pids.map { |pid| Timeout.timeout(60) { Process.wait2(pid).last } }

      expect(statuses.map(&:success?)).to all(be(true))
      expect(File.exist?("#{event_log_file}.1")).to be(true)
      expect(File.exist?("#{event_log_file}.2")).to be(false)
      written = [event_log_file, "#{event_log_file}.1"].flat_map { |f| lines_of(f) }.select { |e| e["type"] == "dispatched" }
      expect(written.map { |e| e["project"] }.sort).to eq(["seed", "w1", "w2"])
    end

    it "replays the same state after an automatic compaction as before it" do
      log = log_with(threshold)
      log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1", "iterm_window_id" => 7})
      log.append(type: "launched", project: "gone", data: {"unique_id" => "u2"})
      log.append(type: "killed", project: "gone")
      before = log.reconstruct
      fill(log, count: 30)

      expect(File.exist?("#{event_log_file}.1")).to be(true)
      expect(log.reconstruct).to eq(before)
    end

    it "writes the event and does not raise when the compaction fails" do
      log = log_with(threshold, renamer: ->(*) { raise Errno::EACCES })

      expect { log.append(type: "dispatched", project: "proj1", data: {"pad" => "x" * 2_000}) }.not_to raise_error
      expect(lines_of(event_log_file).map { |e| e["type"] }).to eq(["dispatched"])
    end

    it "does not compact again while the log is mostly a seed over the threshold, and resumes once enough is added" do
      log = log_with(threshold)
      15.times { |i| log.append(type: "launched", project: "p#{i}", data: {"pad" => "z" * 80}) }
      log.compact
      seed = File.size(event_log_file)
      expect(seed).to be > threshold
      expect(lines_of(event_log_file).first["seed_bytes"]).to be_within(2).of(seed)
      inode = File.stat(event_log_file).ino

      3.times { log.append(type: "dispatched", project: "p0") }
      expect(File.stat(event_log_file).ino).to eq(inode)

      10.times { log.append(type: "dispatched", project: "p0", data: {"pad" => "x" * 50}) }
      expect(File.stat(event_log_file).ino).not_to eq(inode)
      expect(lines_of(event_log_file).first["seed_bytes"]).to be_within(2).of(seed)
      expect(log.reconstruct["p0"]).to eq({"pad" => "z" * 80})
    end

    it "compacts past 100KB when built with no threshold, the same default ConfigSchema gives" do
      expect(described_class::DEFAULT_AUTO_COMPACT_THRESHOLD).to eq(Workspace::ConfigSchema.default("event_log.compact_threshold"))
      log = described_class.new(config: config, error_output: errors)
      log.append(type: "dispatched", project: "proj1", data: {"pad" => "x" * (100 * 1024 - 200)})
      expect(File.exist?("#{event_log_file}.1")).to be(false)

      log.append(type: "dispatched", project: "proj1", data: {"pad" => "x" * 300})
      expect(File.exist?("#{event_log_file}.1")).to be(true)
    end
  end
end
