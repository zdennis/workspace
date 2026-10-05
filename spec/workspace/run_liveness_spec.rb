require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::RunLiveness do
  let(:dir) { Dir.mktmpdir("ws-run-liveness") }
  let(:liveness) { described_class.new(dir: dir) }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def write_run(id, content)
    File.write(File.join(dir, "#{id}.json"), content.is_a?(String) ? content : JSON.generate(content))
  end

  it "is alive while its run file says the run is not finished" do
    %w[queued running waiting].each do |state|
      write_run("wr_1", {"id" => "wr_1", "state" => state})

      expect(liveness.alive?("wr_1")).to be(true)
    end
  end

  it "is not alive once the run is completed, failed or cancelled" do
    %w[completed failed cancelled].each do |state|
      write_run("wr_1", {"id" => "wr_1", "state" => state})

      expect(liveness.alive?("wr_1")).to be(false)
    end
  end

  it "reads a run file holding non-ASCII text from a process with no UTF-8 locale" do
    File.write(File.join(dir, "wr_1.json"), JSON.generate("id" => "wr_1", "state" => "running", "note" => "café"), encoding: "UTF-8")

    without_utf8_locale { expect(liveness.alive?("wr_1")).to be(true) }
  end

  it "says it could not read a run file whose bytes are not UTF-8, whatever the locale" do
    File.binwrite(File.join(dir, "wr_1.json"), "{\"id\":\"wr_1\",\"state\":\"running\",\"note\":\"caf\xC3\"}".b)

    [-> { without_utf8_locale { liveness.alive?("wr_1") } }, -> { liveness.alive?("wr_1") }].each do |call|
      expect(&call).to raise_error(Workspace::Error, /could not read .*wr_1\.json/)
    end
  end

  it "is not alive without a run file" do
    expect(liveness.alive?("wr_gone")).to be(false)
  end

  it "is not alive when the runs directory does not exist" do
    expect(described_class.new(dir: File.join(dir, "missing")).alive?("wr_1")).to be(false)
  end

  it "never reads outside the runs directory for an id that is not a file name" do
    File.write(File.join(File.dirname(dir), "escape.json"), JSON.generate("state" => "running"))

    ["../escape", "a/b", "", nil, ".", "..", ".hidden"].each do |id|
      expect(liveness.alive?(id)).to be(false)
    end
  ensure
    FileUtils.rm_f(File.join(File.dirname(dir), "escape.json"))
  end

  it "raises for a run file that is not valid JSON, so the caller can count the run as alive" do
    write_run("wr_1", "{not json")

    expect { liveness.alive?("wr_1") }.to raise_error(Workspace::Error, /wr_1\.json/)
  end

  it "raises for a run file that is not an object" do
    write_run("wr_1", "[]")

    expect { liveness.alive?("wr_1") }.to raise_error(Workspace::Error, /wr_1\.json/)
  end

  it "raises for a run file it may not read" do
    write_run("wr_1", {"state" => "running"})
    File.chmod(0o000, File.join(dir, "wr_1.json"))

    expect { liveness.alive?("wr_1") }.to raise_error(Workspace::Error, /wr_1\.json/)
  ensure
    File.chmod(0o600, File.join(dir, "wr_1.json"))
  end

  it "is alive for a run file with no state yet" do
    write_run("wr_1", {"id" => "wr_1"})

    expect(liveness.alive?("wr_1")).to be(true)
  end
end
