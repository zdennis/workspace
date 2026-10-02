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
    described_class.new(config: config, error_output: errors, rotate_threshold: threshold, keep_rotated: keep)
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
    %i[rename link].each do |op|
      allow(File).to receive(op).and_wrap_original do |original, *args|
        seen << File.exist?(event_log_file)
        original.call(*args)
      end
    end

    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
    fill(event_log, count: 20)

    expect(seen).not_to be_empty
    expect(seen).to all(be(true))
    expect(File.exist?(event_log_file)).to be(true)
  end

  it "writes the event even when rotation fails, and does not raise" do
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:link).and_call_original
    allow(File).to receive(:link).with(event_log_file, anything).and_raise(Errno::EACCES)

    expect { fill(event_log, count: 20) }.not_to raise_error
    expect(lines_of(event_log_file).size).to eq(20)
  end

  it "drops no rotated file when the log can't be linked" do
    fill(event_log, count: 20)
    before = Dir["#{event_log_file}.*"].reject { |f| f.end_with?(".lock") }.to_h { |f| [f, File.stat(f).ino] }
    allow(File).to receive(:link).and_call_original
    allow(File).to receive(:link).with(event_log_file, anything).and_raise(Errno::EPERM)

    fill(event_log, count: 40)

    expect(Dir["#{event_log_file}.*"].reject { |f| f.end_with?(".lock") }.to_h { |f| [f, File.stat(f).ino] }).to eq(before)
  end

  it "skips rotation when another process holds the log's lock, and still appends" do
    stub_const("Workspace::EventLog::ROTATE_LOCK_WAIT", 0.05)
    fill(event_log, count: 5)
    holder = File.open("#{event_log_file}.lock", File::RDWR | File::CREAT, 0o600)
    holder.flock(File::LOCK_SH)

    begin
      fill(event_log, count: 15)
    ensure
      holder.close
    end

    expect(File.exist?("#{event_log_file}.1")).to be(false)
    expect(lines_of(event_log_file).size).to eq(20)
  end

  it "loses and interleaves nothing when several processes append and rotate at once" do
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "workspace"
      config = Workspace::Config.new(workspace_dir: ENV["HOME"])
      log = Workspace::EventLog.new(config: config, rotate_threshold: 1500, keep_rotated: 10_000)
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
end
