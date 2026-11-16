require "tmpdir"

RSpec.describe Workspace::DaemonWatch do
  let(:root) { Dir.mktmpdir }
  let(:hook_dir) { File.join(root, ".events") }
  let(:now) { [Time.utc(2026, 11, 15, 12, 0, 0)] }
  let(:store) do
    Workspace::WorkflowRunStore.new(dir: File.join(root, "runs"), archive_dir: File.join(root, "archive"), clock: -> { now.first })
  end

  before { FileUtils.mkdir_p(hook_dir) }
  after { FileUtils.remove_entry(root) }

  def at(second)
    Time.utc(2026, 11, 15, 12, 0, second)
  end

  def watch(run: nil, workspace: "alpha", discover_every: described_class::DISCOVER_EVERY)
    stream = Workspace::EventStream.new(lifecycle_path: nil, hook_dir: hook_dir, workspace: workspace)
    clock = double("clock").tap { |c| allow(c).to receive(:now) { now.first } }
    described_class.new(workspace: workspace, stream: stream, store: store, run: run, discover_every: discover_every, clock: clock)
  end

  def hook(second, type, fields = {}, workspace = "alpha")
    @seq = (@seq || 0) + 1
    File.open(File.join(hook_dir, "#{workspace}.jsonl"), "a") do |f|
      f.puts JSON.generate({"type" => type, "at" => at(second).iso8601(3), "workspace" => workspace, "pane_id" => nil,
                            "boot_id" => "B1", "seq" => @seq}.merge(fields))
    end
  end

  def start_run(workspace: "alpha")
    store.create({"workspace" => workspace, "state" => "running", "current" => "s1", "created_at" => now.first.iso8601(3),
                  "definition" => {"steps" => [{"id" => "s1"}]}, "steps" => {"s1" => {"attempts" => []}}})["id"]
  end

  def event(id, second, type)
    now[0] = at(second)
    store.record_event(id, type)
  end

  def finish(id)
    edit_run(store, id) { |run| run.merge!("state" => "completed", "ended_at" => now.first.utc.iso8601) }
    stamp_archived(id)
  end

  # The first half of a finishing change: the terminal state is written, its history lines and the archive not yet.
  def write_terminal_state(id)
    path = File.join(root, "runs", "#{id}.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("state" => "completed", "ended_at" => now.first.utc.iso8601)))
  end

  # The second half: the history lines, then the move to the archive.
  def flush_and_archive(id)
    store.record_event(id, "run_finished")
    expect { store.change(id) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }
    stamp_archived(id)
  end

  # The archived state file's mtime on the spec's clock, as it is on the real one.
  def stamp_archived(id)
    path = File.join(root, "archive", "#{id}.json")
    File.utime(now.first, now.first, path) if File.exist?(path)
  end

  def state_of(cursor)
    Workspace::EventStream.decode_cursor(cursor.delete_prefix("w"))
  end

  def summary(lines)
    lines.map { |line| [line["source"], line["type"], line["run_id"]] }
  end

  it "yields decision lines and run events oldest first across sources, each with the shape and a cursor" do
    id = start_run
    hook(1, "workflow_advance_started", "run_id" => id, "cause" => "tick")
    event(id, 2, "step_dispatched")
    hook(3, "tool_started")
    hook(4, "workflow_sweep_started", "run_ids" => [id])
    event(id, 5, "step_passed")

    w = watch
    expect(w.open(at: :start)).to eq([])
    lines = w.read

    expect(summary(lines)).to eq([
      ["daemon", "workflow_advance_started", id], ["run", "step_dispatched", id],
      ["daemon", "workflow_sweep_started", nil], ["run", "step_passed", id]
    ])
    expect(lines.first).to include("at" => at(1).iso8601(3), "workspace" => "alpha", "event" => include("cause" => "tick", "seq" => 1))
    expect(lines.first["event"]).not_to include("cursor", "source")
    expect(lines[1]).to include("at" => at(2).iso8601(3), "event" => include("n" => 1, "ts" => at(2).iso8601(3)))
    expect(lines.map { |line| line["cursor"] }).to all(start_with("w1."))
    expect(lines.last["cursor"]).to eq(w.cursor_string)
  end

  it "starts at the end of each source without a cursor" do
    id = start_run
    hook(1, "workflow_run_skipped", "run_id" => id, "reason" => "backoff")
    event(id, 2, "step_dispatched")

    w = watch
    w.open
    expect(w.read).to eq([])

    event(id, 3, "step_passed")
    hook(4, "workflow_advance_started", "run_id" => id)
    expect(summary(w.read)).to eq([["run", "step_passed", id], ["daemon", "workflow_advance_started", id]])
  end

  it "resumes from any line's cursor with nothing repeated and nothing missed" do
    id = start_run
    hook(1, "workflow_advance_started", "run_id" => id)
    event(id, 2, "step_dispatched")
    hook(3, "workflow_process_exited", "run_id" => id, "exit_code" => 0)

    first = watch
    first.open(at: :start)
    cursor = first.read[1]["cursor"]

    event(id, 4, "step_passed")
    resumed = watch
    expect(resumed.open(cursor: cursor)).to eq([])
    expect(summary(resumed.read)).to eq([["daemon", "workflow_process_exited", id], ["run", "step_passed", id]])
    expect(watch.tap { |w| w.open(cursor: resumed.cursor_string) }.read).to eq([])
  end

  it "finds a run that starts mid-watch and reads it from its start" do
    w = watch(discover_every: 2)
    w.open
    id = start_run
    event(id, 1, "run_started")
    event(id, 2, "step_dispatched")

    expect(w.read).to eq([])
    expect(summary(w.read)).to eq([["run", "run_started", id], ["run", "step_dispatched", id]])
  end

  it "follows a run through its move to the archive, then lets it go" do
    id = start_run
    w = watch
    w.open
    event(id, 1, "step_passed")
    finish(id)
    event(id, 2, "run_finished")
    expect(File.exist?(File.join(root, "archive", "#{id}.json"))).to be(true)

    expect(summary(w.read)).to eq([["run", "step_passed", id], ["run", "run_finished", id]])
    expect(state_of(w.cursor_string)["r"]).to eq({})
    expect(w.read).to eq([])
  end

  it "follows only the run --run names, and only the decision lines naming it" do
    mine = start_run
    other = start_run
    hook(1, "workflow_advance_started", "run_id" => other)
    hook(2, "workflow_sweep_started", "run_ids" => [other, mine])
    hook(3, "workflow_run_skipped", "run_id" => mine, "reason" => "backoff")
    event(other, 4, "step_dispatched")
    event(mine, 5, "step_dispatched")

    w = watch(run: mine)
    w.open(at: :start)
    expect(summary(w.read(discover: true))).to eq([
      ["daemon", "workflow_sweep_started", nil], ["daemon", "workflow_run_skipped", mine], ["run", "step_dispatched", mine]
    ])
    expect(state_of(w.cursor_string)["r"].keys).to eq([mine])
    expect(w).not_to be_done

    finish(mine)
    w.read
    expect(w).to be_done
  end

  it "leaves out runs of other workspaces" do
    start_run(workspace: "beta").then { |id| event(id, 1, "step_dispatched") }
    hook(2, "workflow_advance_started", {"run_id" => "x"}, "beta")

    w = watch
    w.open(at: :start)
    expect(w.read(discover: true)).to eq([])
  end

  it "raises unknown_run for a --run that names no run" do
    expect { watch(run: "wr_nope").open }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
  end

  ["nonsense", "w1.!!!", "w1.#{["[1]"].pack("m0")}", described_class.encode_cursor("w" => "alpha", "e" => 5, "r" => {}),
    described_class.encode_cursor("w" => "alpha", "e" => "1.e30", "r" => {"wr_a" => -1}),
    described_class.encode_cursor("w" => "alpha", "e" => "garbage", "r" => {})].each do |bad|
    it "raises invalid_cursor for #{bad.inspect}" do
      expect { watch.open(cursor: bad) }.to raise_error(Workspace::EventStream::InvalidCursor) { |e|
        expect(e.code).to eq("invalid_cursor")
        expect(e.message).to include("daemon watch")
      }
    end
  end

  it "keeps a run whose terminal state is written before its last events and its move to the archive" do
    id = start_run
    w = watch(run: id)
    w.open
    write_terminal_state(id)

    expect(w.read).to eq([])
    expect(w).not_to be_done

    flush_and_archive(id)
    expect(summary(w.read)).to eq([["run", "run_finished", id]])
    expect(w).to be_done
  end

  it "keeps a run, --run or not, until it is archived" do
    id = start_run
    w = watch
    w.open
    write_terminal_state(id)
    w.read
    expect(state_of(w.cursor_string)["r"]).to eq(id => 0)

    flush_and_archive(id)
    expect(summary(w.read)).to eq([["run", "run_finished", id]])
    expect(state_of(w.cursor_string)).to include("r" => {}, "d" => {id => now.first.utc.iso8601})
  end

  it "reads, once, a run that started and ended between two watches" do
    first = watch
    first.open
    cursor = first.cursor_string
    id = start_run
    event(id, 1, "step_dispatched")
    finish(id)

    resumed = watch
    resumed.open(cursor: cursor)
    expect(summary(resumed.read)).to eq([["run", "step_dispatched", id]])

    again = watch
    again.open(cursor: resumed.cursor_string)
    expect(again.read).to eq([])
  end

  it "lets go of a finished run in the cursor once it ended long before the last look" do
    id = start_run
    finish(id)
    w = watch
    w.open
    w.read
    now[0] += described_class::FINISHED_MARGIN + 1
    w.read(discover: true)
    expect(state_of(w.cursor_string)["d"]).to eq({})
  end

  it "yields a gap, as a watch line, when the cursor's daemon file is no longer kept" do
    hook(1, "workflow_advance_started", "run_id" => "x")
    w = watch
    w.open(at: :start)
    cursor = w.read.last["cursor"]
    FileUtils.rm(File.join(hook_dir, "alpha.jsonl"))
    hook(2, "workflow_run_skipped", "run_id" => "x", "reason" => "backoff")

    resumed = watch
    gaps = resumed.open(cursor: cursor)
    expect(gaps).to match([include("source" => "watch", "type" => "gap", "workspace" => "alpha", "run_id" => nil,
      "event" => include("reason" => Workspace::EventStream::GAP_NOT_RETAINED), "cursor" => start_with("w1."))])
    expect(summary(resumed.read)).to eq([["daemon", "workflow_run_skipped", "x"]])
  end

  it "finds a run whose terminal state is written but that is not yet archived when it opens" do
    id = start_run
    event(id, 1, "step_dispatched")
    write_terminal_state(id)

    w = watch
    w.open(at: :start)
    expect(summary(w.read)).to eq([["run", "step_dispatched", id]])
    expect(state_of(w.cursor_string)["r"]).to eq(id => 1)

    flush_and_archive(id)
    expect(summary(w.read)).to eq([["run", "run_finished", id]])
  end

  it "ends a --run watch whose run was pruned from the archive" do
    id = start_run
    w = watch(run: id)
    w.open
    finish(id)
    FileUtils.rm(Dir[File.join(root, "archive", "#{id}.*")])

    w.read
    expect(w).to be_done
  end

  it "reads, once, a run that starts and ends between two looks of one watch" do
    w = watch(discover_every: 2)
    w.open
    id = start_run
    event(id, 1, "step_dispatched")
    finish(id)

    expect(w.read).to eq([])
    expect(summary(w.read)).to eq([["run", "step_dispatched", id]])
    w.read
    expect(w.read).to eq([])
  end

  it "does not read runs that had ended before a watch opened without a cursor" do
    id = start_run
    event(id, 1, "step_dispatched")
    finish(id)

    w = watch(discover_every: 1)
    w.open
    expect(w.read).to eq([])
    expect(state_of(w.cursor_string)["d"].keys).to eq([id])
  end

  it "refuses a cursor resumed with another --run filter" do
    id = start_run
    plain = watch.tap(&:open).cursor_string
    narrowed = watch(run: id).tap(&:open).cursor_string

    expect { watch(run: id).open(cursor: plain) }.to raise_error(Workspace::EventStream::InvalidCursor)
    expect { watch.open(cursor: narrowed) }.to raise_error(Workspace::EventStream::InvalidCursor)
    expect { watch(run: id).open(cursor: narrowed) }.not_to raise_error
  end

  it "refuses another workspace's cursor" do
    w = watch(workspace: "beta")
    w.open
    expect { watch.open(cursor: w.cursor_string) }.to raise_error(Workspace::EventStream::InvalidCursor)
  end

  it "refuses a workspace events cursor, and workspace events refuses its cursor" do
    hook(1, "workflow_advance_started", "run_id" => "x")
    events = Workspace::EventStream.new(lifecycle_path: File.join(root, "life.jsonl"), hook_dir: hook_dir)
    events.open(at: :start)
    events_cursor = events.read.last["cursor"]
    w = watch
    w.open

    expect { watch.open(cursor: events_cursor) }.to raise_error(Workspace::EventStream::InvalidCursor)
    expect { Workspace::EventStream.new(lifecycle_path: File.join(root, "life.jsonl"), hook_dir: hook_dir).open(cursor: w.cursor_string) }
      .to raise_error(Workspace::EventStream::InvalidCursor)
  end
end
