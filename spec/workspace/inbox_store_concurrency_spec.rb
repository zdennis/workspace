require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"

RSpec.describe "workspace inbox store concurrency" do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-conc") }
  let(:path) { File.join(tmpdir, ".inbox", "global.json") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it "leaves 100 distinct records when two processes each add 50 to one scope" do
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "workspace"
      store = Workspace::InboxStore.new(path: ARGV[0])
      50.times { |i| store.add("title" => "item \#{ARGV[1]}-\#{i}") }
    RUBY

    pids = %w[a b].map do |tag|
      Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, path, tag, out: File::NULL, err: File::NULL)
    end
    Timeout.timeout(60) { pids.each { |pid| Process.wait(pid) } }

    items = Workspace::InboxStore.new(path: path).list
    expect(items.size).to eq(100)
    expect(items.map { |i| i["id"] }.uniq.size).to eq(100)
    expect(items.map { |i| i["title"] }.uniq.size).to eq(100)
  end

  it "keeps every record when a reader and a writer overlap" do
    store = Workspace::InboxStore.new(path: path)
    10.times { |i| store.add("title" => "seed #{i}") }
    reader = Thread.new { 20.times.map { store.list.size } }

    10.times { |i| store.add("title" => "more #{i}") }

    expect(reader.value).to all(be_between(10, 20))
    expect(store.list.size).to eq(20)
  end
end
