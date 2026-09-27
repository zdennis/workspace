require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"

RSpec.describe "workspace ask concurrency and liveness (adversarial)" do
  let(:tmpdir) { Dir.mktmpdir("ws-ask-adv-conc") }
  let(:path) { File.join(tmpdir, "asks.json") }
  let(:store) { Workspace::AskStore.new(path: path) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  # `workspace ask` is a one-shot CLI: bin/workspace returns straight after
  # Commands::Ask#call, and Notifier#notify only starts a thread. Process exit
  # kills that thread before it spawns the notify command.
  it "AC1: delivers the notify command even though the ask process exits right after recording" do
    lib = File.expand_path("../../lib", __dir__)
    marker = File.join(tmpdir, "notified")
    script = <<~RUBY
      require "workspace"
      dir = ARGV[0]
      config = Object.new
      config.define_singleton_method(:ask_state_path) { |_name| File.join(dir, "asks.json") }
      detector = Object.new
      detector.define_singleton_method(:detect) { |_cwd| "proj" }
      alerts = Object.new
      alerts.define_singleton_method(:for_workspace) { |_name| {notify: "touch notified"} }
      Dir.chdir(dir)
      Workspace::Commands::Ask.new(config: config, project_detector: detector, alert_config: alerts, env: {},
        output: File.open(File::NULL, "w")).call(question: "pg or sqlite?", default: "sqlite", working_dir: dir)
    RUBY

    _out, _err, status = Timeout.timeout(30) { Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script, tmpdir) }
    expect(status).to be_success
    expect(store.list.size).to eq(1)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.05 until File.exist?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(File.exist?(marker)).to be(true), "notify command never ran: the CLI exited before the notifier thread spawned it"
  end

  # AskStore#read_data (ask_store.rb) maps JSON::ParserError to [], and
  # with_lock then rewrites the file from that empty list.
  it "AC2: does not wipe every recorded question when asks.json is unparseable" do
    store.add(question: "q1", default: "d1")
    store.add(question: "q2", default: "d2")
    corrupt = File.read(path)[0..-10]
    File.write(path, corrupt)

    begin
      store.add(question: "q3", default: "d3")
    rescue Workspace::Error
      nil
    end

    survivors = Dir.glob("#{path}*").reject { |f| f.end_with?(".lock") }.select { |f| File.read(f) == corrupt }
    expect(survivors).not_to be_empty, "the only copy of q1/q2 was overwritten with a one-record list"
  end

  # AskStore#list does r["status"] on every entry; Commands::Sessions#apply_ask_column
  # rescues only Workspace::Error, so this breaks all of `workspace sessions`.
  it "AC3: a non-object entry in asks.json surfaces as Workspace::Error, not a crash" do
    File.write(path, JSON.generate([nil, {"id" => "abc123", "status" => "open"}]))

    expect {
      begin
        store.list(open_only: true)
      rescue Workspace::Error
        nil
      end
    }.not_to raise_error
  end

  # AskStore#add takes SecureRandom.hex(3) with no uniqueness check, and asks.json
  # is never pruned, so two open questions can share an id and `ask answer`
  # silently resolves whichever comes first.
  it "AC4: never hands out an id already used by a recorded question" do
    allow(SecureRandom).to receive(:hex).with(3).and_return("aaaaaa", "aaaaaa", "bbbbbb")

    first = store.add(question: "q1", default: "d1")
    second = store.add(question: "q2", default: "d2")

    expect(second["id"]).not_to eq(first["id"])
  end
end
