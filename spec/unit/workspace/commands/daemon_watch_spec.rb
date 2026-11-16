require "spec_helper"
require "stringio"

RSpec.describe Workspace::Commands::Daemon, "watch" do
  let(:output) { StringIO.new }
  let(:sleeps) { [] }
  let(:exists) { true }
  let(:project_config) { instance_double(Workspace::ProjectConfig, exists?: exists) }
  let(:built) { [] }

  around do |example|
    zone = ENV["TZ"]
    ENV["TZ"] = "UTC"
    example.run
  ensure
    ENV["TZ"] = zone
  end
  let(:wall_clock) { double("clock", now: Time.utc(2026, 11, 15, 12, 0, 58)) }

  # Stands for DaemonWatch: hands out one batch of lines per read, then nothing.
  let(:watch_class) do
    Class.new do
      attr_reader :opened, :reads

      def state = "completed"

      def initialize(batches, gaps: [], done_after: nil, more: false)
        @batches = batches
        @gaps = gaps
        @done_after = done_after
        @more = more
        @reads = 0
      end

      def open(cursor:, at:)
        @opened = {cursor: cursor, at: at}
        @gaps
      end

      def read(discover: nil)
        @reads += 1
        @batches.shift || []
      end

      def more? = @more

      def done? = !@done_after.nil? && @reads >= @done_after

      def cursor_string = "wcur#{@reads}"
    end
  end

  def line(source, type, run_id, event, at: "2026-11-15T12:01:02.114Z")
    {"source" => source, "at" => at, "type" => type, "workspace" => "api", "run_id" => run_id, "event" => event.merge("type" => type, "at" => at), "cursor" => "c"}
  end

  def command(watch)
    factory = ->(workspace:, run:) {
      built << {workspace: workspace, run: run}
      watch
    }
    described_class.new(config: instance_double(Workspace::Config), project_config: project_config, ensure_agent: double("ensure_agent"),
      version_client: double("version_client"), watch_factory: factory, wall_clock: wall_clock, sleeper: ->(seconds) { sleeps << seconds }, output: output)
  end

  it "prints each kind of line as one plain sentence and sleeps between reads" do
    batch = [
      line("daemon", "workflow_advance_started", "wr_x", {"pane_id" => "%3", "cause" => "turn_ended"}),
      line("daemon", "workflow_advance_started", "wr_x", {"pane_id" => nil, "cause" => "tick", "reason" => "retry_backoff"}),
      line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "retry_backoff"}),
      line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "paused"}),
      line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "not_due"}),
      line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "odd_code"}),
      line("daemon", "workflow_sweep_started", nil, {"run_ids" => %w[wr_x wr_y]}),
      line("daemon", "workflow_process_exited", "wr_x", {"kind" => "advance", "exit_code" => 0, "seconds" => 3.0}),
      line("daemon", "workflow_process_exited", nil, {"kind" => "sweep", "run_ids" => %w[wr_x], "signal" => "TERM", "seconds" => 1.25}),
      line("run", "step_dispatched", "wr_x", {"n" => 7, "step" => "plan"}, at: "2026-11-15T12:01:03.000Z"),
      line("watch", "gap", nil, {"reason" => "cursor_not_retained", "source" => "hook"})
    ]
    command(watch_class.new([batch])).watch(name: "api", max_polls: 2)

    expect(output.string.lines.map(&:chomp)).to eq([
      "12:00:58 watching api from now; Ctrl-C stops",
      "12:01:02 advance started for run wr_x in pane %3 after its turn ended",
      "12:01:02 advance started for run wr_x by the tick (retry_backoff)",
      "12:01:02 run wr_x skipped: waiting out its retry backoff",
      "12:01:02 run wr_x skipped: paused",
      "12:01:02 run wr_x skipped: nothing to do yet",
      "12:01:02 run wr_x skipped: odd_code",
      "12:01:02 sweep started for runs wr_x, wr_y",
      "12:01:02 advance for run wr_x exited with code 0 after 3s",
      "12:01:02 sweep for run wr_x was ended by signal TERM after 1.3s",
      "12:01:03 run wr_x  line 7  step_dispatched  step=plan",
      "12:01:02 lines before the cursor are gone (cursor_not_retained) from the hook log"
    ])
    expect(sleeps).to eq([0.25])
  end

  it "escapes pane and file text" do
    batch = [line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "a\e[31mb"}), line("run", "x", "wr_x", {"note" => "c\nd"})]
    command(watch_class.new([batch])).watch(name: "api", max_polls: 1)

    expect(output.string).not_to match(/\e|c\nd/)
    expect(output.string).to include('skipped: a\e[31mb', 'note=c\nd')
  end

  it "prints one JSON object per line, started first, and hands the cursor and run to the watch" do
    watch = watch_class.new([[line("daemon", "workflow_run_skipped", "wr_x", {"reason" => "backoff"})]], gaps: [line("watch", "gap", nil, {})])
    command(watch).watch(name: "api", run: nil, since: "wprev", json: true, max_polls: 1)

    docs = output.string.lines.map { |l| JSON.parse(l) }
    expect(docs.map { |d| d["type"] }).to eq(%w[follow_started gap workflow_run_skipped])
    expect(docs.first).to include("source" => "watch", "at" => "2026-11-15T12:00:58.000Z", "workspace" => "api", "run_id" => nil, "cursor" => "wcur0")
    expect(docs.last).to include("source" => "daemon", "run_id" => "wr_x", "cursor" => "c")
    expect(watch.opened).to eq(cursor: "wprev", at: :end)
    expect(built).to eq([{workspace: "api", run: nil}])
  end

  it "ends a --run watch when the run is done, with a final line" do
    watch = watch_class.new([[], []], done_after: 2)
    result = command(watch).watch(name: "api", run: "wr_x", max_polls: 50)

    expect(result).to eq(exit_code: 0)
    expect(watch.reads).to eq(2)
    expect(output.string.lines.last.chomp).to eq("12:00:58 run wr_x completed; no more events (earlier events: workspace workflow events wr_x)")
    expect(output.string.lines.first.chomp).to eq("12:00:58 watching api for run wr_x from now; Ctrl-C stops (earlier events: workspace workflow events wr_x)")
    expect(built).to eq([{workspace: "api", run: "wr_x"}])
  end

  it "ends with a follow_ended document under --json" do
    command(watch_class.new([[]], done_after: 1)).watch(name: "api", run: "wr_x", json: true)

    expect(JSON.parse(output.string.lines.last)).to include("type" => "follow_ended", "run_id" => "wr_x", "source" => "watch", "state" => "completed")
  end

  it "does not sleep while the watch has more lines waiting" do
    command(watch_class.new([[], []], more: true)).watch(name: "api", max_polls: 2)

    expect(sleeps).to eq([])
  end

  it "stops quietly on Ctrl-C and on a closed pipe" do
    [Interrupt, Errno::EPIPE].each do |error|
      watch = watch_class.new([])
      allow(watch).to receive(:read).and_raise(error)

      expect(command(watch).watch(name: "api")).to eq(exit_code: 0)
    end
  end

  it "turns an unreadable file into a Workspace::Error" do
    watch = watch_class.new([])
    allow(watch).to receive(:read).and_raise(Errno::EACCES)

    expect { command(watch).watch(name: "api") }.to raise_error(Workspace::Error, /could not read the event files/)
  end

  it "refuses an unknown workspace before building a watch" do
    allow(project_config).to receive(:exists?).and_return(false)

    expect { command(watch_class.new([])).watch(name: "nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    expect(built).to eq([])
  end

  it "passes an unreadable cursor on as the watch's error" do
    watch = watch_class.new([])
    allow(watch).to receive(:open).and_raise(Workspace::EventStream::InvalidCursor)

    expect { command(watch).watch(name: "api", since: "x") }.to raise_error(Workspace::EventStream::InvalidCursor)
  end
end
