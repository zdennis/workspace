require "tmpdir"

RSpec.describe Workspace::RunResultCleaner do
  let(:dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 10, 2, 12, 0, 0) }
  let(:live) { [] }
  let(:day) { 24 * 60 * 60 }

  subject(:cleaner) do
    described_class.new(dir: dir, clock: -> { now }, live_projects: -> { live })
  end

  after { FileUtils.remove_entry(dir) }

  def age(path, days)
    time = now - days * day
    File.utime(time, time, path)
  end

  def run_files(uuid, days:, project: "proj", json: true, streams: true)
    paths = []
    paths << File.join(dir, "#{uuid}.json") if json
    paths += %w[stdout stderr].map { |ext| File.join(dir, "#{uuid}.#{ext}") } if streams
    paths.each do |path|
      File.write(path, path.end_with?(".json") ? JSON.generate({"uuid" => uuid, "project" => project}) : "out")
      age(path, days)
    end
    paths
  end

  def remaining
    Dir.children(dir).reject { |f| f.start_with?(".") }.sort
  end

  it "removes every file of a finished run older than the retention" do
    run_files("old", days: 8)

    expect(cleaner.call).to eq(3)
    expect(remaining).to be_empty
  end

  it "keeps a finished run newer than the retention" do
    run_files("new", days: 6)

    expect(cleaner.call).to eq(0)
    expect(remaining.size).to eq(3)
  end

  it "judges a run by its newest file, so a stream written recently keeps the whole run" do
    json, _out, err = run_files("mixed", days: 20)
    age(err, 1)

    cleaner.call

    expect(File.exist?(json)).to be(true)
  end

  it "removes the .cmd and .sh files of an abandoned --wait run, and keeps those of a recent one" do
    %w[cmd sh].each do |ext|
      File.write(File.join(dir, "gone.#{ext}"), "x")
      age(File.join(dir, "gone.#{ext}"), 10)
      File.write(File.join(dir, "fresh.#{ext}"), "x")
      age(File.join(dir, "fresh.#{ext}"), 1)
    end

    expect(cleaner.call).to eq(2)
    expect(remaining).to eq(%w[fresh.cmd fresh.sh])
  end

  it "keeps a run that has no result yet while its streams are recent" do
    run_files("running", days: 2, json: false)

    cleaner.call

    expect(remaining).to eq(%w[running.stderr running.stdout])
  end

  it "removes the streams of a run that never finished once they are past the retention" do
    run_files("orphan", days: 30, json: false)

    cleaner.call

    expect(remaining).to be_empty
  end

  it "keeps the runs of a project with a live session however old they are" do
    run_files("live-run", project: "alive", days: 90)
    run_files("dead-run", project: "dead", days: 90)
    live.replace(["alive"])

    cleaner.call

    expect(remaining).to eq(%w[live-run.json live-run.stderr live-run.stdout])
  end

  it "removes an old result it can't parse, which names no live project" do
    path = File.join(dir, "broken.json")
    File.write(path, "{not json")
    age(path, 30)

    cleaner.call

    expect(remaining).to be_empty
  end

  it "leaves files that aren't run files alone" do
    other = File.join(dir, "notes.txt")
    File.write(other, "hi")
    age(other, 90)

    cleaner.call

    expect(remaining).to eq(["notes.txt"])
  end

  it "removes a stale .tmp left by a writer that died" do
    run_files("tmp", days: 9, streams: false)
    stale = File.join(dir, "tmp.json.tmp")
    File.write(stale, "{")
    age(stale, 9)
    File.delete(File.join(dir, "tmp.json"))

    cleaner.call

    expect(remaining).to be_empty
  end

  it "does nothing within the interval of the last sweep" do
    run_files("old", days: 8)
    cleaner.call
    run_files("old2", days: 8)

    expect(cleaner.call).to eq(0)
    expect(remaining.size).to eq(3)
  end

  it "sweeps again after the interval has passed" do
    cleaner.call
    run_files("old2", days: 8)
    stamp = File.join(dir, ".last-cleanup")
    age(stamp, 1)

    expect(cleaner.call).to eq(3)
  end

  it "does not look up live sessions when the interval hasn't passed" do
    cleaner.call
    lookups = 0
    again = described_class.new(dir: dir, clock: -> { now }, live_projects: -> {
      lookups += 1
      []
    })

    again.call

    expect(lookups).to eq(0)
  end

  it "removes nothing when live sessions can't be looked up" do
    run_files("old", days: 30)
    failing = described_class.new(dir: dir, clock: -> { now }, live_projects: -> { raise Workspace::Error, "tmux broke" })

    expect(failing.call).to eq(0)
    expect(remaining.size).to eq(3)
  end

  it "does nothing, without raising, when the directory doesn't exist" do
    missing = described_class.new(dir: File.join(dir, "nope"), clock: -> { now })

    expect(missing.call).to eq(0)
  end

  it "does not raise when a file can't be removed, and removes the rest" do
    paths = run_files("old", days: 8)
    allow(File).to receive(:delete).and_call_original
    allow(File).to receive(:delete).with(paths.first).and_raise(Errno::EACCES)

    expect(cleaner.call).to eq(2)
  end

  it "does not raise when the directory can't be read" do
    File.chmod(0o000, dir)

    begin
      expect(cleaner.call).to eq(0)
    ensure
      File.chmod(0o700, dir)
    end
  end
end
