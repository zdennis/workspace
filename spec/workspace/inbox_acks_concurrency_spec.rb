require "spec_helper"
require "tmpdir"
require "rbconfig"
require "timeout"

RSpec.describe "workspace inbox acks concurrency" do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-acks-conc") }
  let(:path) { File.join(tmpdir, ".inbox", "acks.json") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it "keeps every entry when two processes each ack 40 distinct ids" do
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "workspace"
      acks = Workspace::InboxAcks.new(path: ARGV[0])
      40.times { |i| acks.ack("plan:blocked:\#{ARGV[1]}\#{i}", "f") }
    RUBY

    pids = %w[a b].map do |tag|
      Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, path, tag, out: File::NULL, err: File::NULL)
    end
    Timeout.timeout(60) { pids.each { |pid| Process.wait(pid) } }

    ids = JSON.parse(File.read(path)).map { |entry| entry["id"] }
    expect(ids.size).to eq(80)
    expect(ids.uniq.size).to eq(80)
  end
end
