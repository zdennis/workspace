require "tmpdir"

RSpec.describe Workspace::PlanProgressWatcher do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "IMPLEMENTATION_PLAN.md") }
  let(:now) { [0.0] }
  let(:event_log) { instance_double(Workspace::EventLog, record: true) }
  let(:resolved) { [path] }
  let(:watcher) do
    described_class.new(workspace: "proj", path_resolver: ->(_) { resolved.first }, event_log: event_log, clock: -> { now.first })
  end

  after { FileUtils.remove_entry(dir) }

  def write_plan(*boxes, extra: "")
    tasks = boxes.each_with_index.map { |box, i| "- [#{box}] T#{i + 1} Task #{i + 1}" }
    File.write(path, "---\nplan: 1\n---\n\n## Tasks\n#{tasks.join("\n")}\n#{extra}")
  end

  # Writes the plan and gives it a modification time no earlier write shared.
  def edit(*boxes, **opts)
    write_plan(*boxes, **opts)
    @edits = (@edits || 0) + 1
    File.utime(Time.at(1_000_000 + @edits), Time.at(1_000_000 + @edits), path)
  end

  def tick(seconds)
    now[0] += seconds
    watcher.poll
  end

  it "records counts, the current task and the changed ids once the file settles" do
    write_plan(" ", " ", " ")
    watcher.baseline

    edit("x", " ", " ")
    expect(tick(0.25)).to be(false)
    expect(event_log).not_to have_received(:record)

    expect(tick(0.5)).to be(true)
    expect(event_log).to have_received(:record).with(
      type: "plan_progress", project: "proj",
      data: {"workspace" => "proj",
             "counts" => {"total" => 3, "done" => 1, "in_progress" => 0, "skipped" => 0, "blocked" => 0, "todo" => 2, "left" => 2},
             "current" => "T2", "changed" => ["T1"]}
    )
  end

  it "coalesces a burst of edits into one line naming every changed task" do
    write_plan(" ", " ", " ")
    watcher.baseline

    edit("x", " ", " ")
    tick(0.25)
    edit("x", "~", " ")
    tick(0.25)
    edit("x", "x", "~")
    tick(0.25)
    tick(0.5)
    tick(0.5)

    expect(event_log).to have_received(:record).once
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("changed" => %w[T1 T2 T3], "current" => "T3")))
  end

  it "records nothing for an edit that leaves every task as it was" do
    write_plan(" ", "x")
    watcher.baseline

    edit(" ", "x", extra: "\nSome prose.\n")
    tick(0.25)
    tick(1)

    expect(event_log).not_to have_received(:record)
  end

  it "records nothing for what was in the file when it started" do
    write_plan("x", " ")
    watcher.baseline
    tick(5)

    expect(event_log).not_to have_received(:record)
  end

  it "records a plan that appears, and one that is removed" do
    watcher.baseline

    edit(" ", " ")
    tick(0.25)
    tick(0.5)
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("changed" => %w[T1 T2], "current" => "T1")))

    File.delete(path)
    tick(0.25)
    tick(0.5)
    expect(event_log).to have_received(:record).with(
      hash_including(data: hash_including("counts" => hash_including("total" => 0), "current" => nil, "changed" => %w[T1 T2]))
    )
  end

  it "survives a path that cannot be resolved" do
    resolved[0] = nil
    watcher.baseline

    expect { tick(1) }.not_to raise_error
    expect(event_log).not_to have_received(:record)
  end

  it "survives a resolver that raises, and finds the file again when it answers" do
    write_plan(" ")
    answers = [path, :boom]
    resolver = ->(_) { ((answer = answers.first) == :boom) ? raise(Workspace::Error, "no") : answer }
    moving = described_class.new(workspace: "proj", path_resolver: resolver, event_log: event_log, clock: -> { now.first })
    moving.baseline

    answers[0] = :boom
    now[0] += 6
    expect { moving.poll }.not_to raise_error
    answers[0] = path
    now[0] += 6
    edit("x")
    moving.poll
    now[0] += 0.5
    expect(moving.poll).to be(true)
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("changed" => ["T1"])))
  end

  it "follows the file when the notes directory moves" do
    write_plan(" ")
    watcher.baseline
    other = File.join(dir, "other.md")
    File.write(other, "## Tasks\n- [x] T1 Done\n")
    resolved[0] = other

    tick(6)
    tick(0.5)
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("changed" => ["T1"])))
  end

  it "keeps its baseline when the file can't be read" do
    write_plan(" ")
    watcher.baseline
    allow(Workspace::PlanFile).to receive(:read).and_return(Workspace::PlanFile.parse("", warnings: [{"code" => "unreadable"}]))

    edit("x")
    tick(0.25)
    expect(tick(0.5)).to be(false)
    expect(event_log).not_to have_received(:record)
  end

  describe "#start and #stop" do
    it "records an edit made while the thread runs" do
      recorded = Queue.new
      allow(event_log).to receive(:record) { |**args| recorded << args }
      write_plan(" ")
      real = described_class.new(workspace: "proj", path_resolver: ->(_) { path }, event_log: event_log)
      real.start
      begin
        edit("x")
        line = Timeout.timeout(5) { recorded.pop }
        expect(line).to include(type: "plan_progress")
        expect(line[:data]).to include("changed" => ["T1"])
      ensure
        real.stop
      end
    end
  end
end
