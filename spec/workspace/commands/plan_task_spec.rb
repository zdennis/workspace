require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::Commands::PlanTask do
  around do |example|
    Dir.mktmpdir("plan-task-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:events) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog).tap do |log|
      allow(log).to receive(:record) { |type:, project:, data: {}| events << [project, type, data] }
    end
  end
  let(:access) { Workspace::PlanAccess.new(notes: notes, tmux: tmux, event_log: event_log) }
  subject(:command) { described_class.new(access: access, output: output) }

  let(:plan_text) do
    "---\nstatus: active\n---\n## Tasks\n### One\n- [x] T1 First\n- [~] T2 Second <!-- owner: %4 -->\n### Two\n- [ ] T3 Third\n## Task details\n"
  end

  before do
    allow(notes).to receive(:info) { |name:, create: false| {"workspace" => name, "dir" => @dir} }
  end

  def plan_path = File.join(@dir, "IMPLEMENTATION_PLAN.md")

  def write_plan(text = plan_text) = File.write(plan_path, text)

  def revision = Workspace::PlanFile.read(plan_path).revision

  describe "#add" do
    it "adds a task with the next id, reports the new revision and counts, and records plan_changed" do
      write_plan

      row = command.add(name: "api", title: "Fourth", phase: "Two")

      expect(row).to include("outcome" => "added", "task" => "T4", "state" => "todo", "phase" => "Two", "line" => 10, "revision" => revision,
        "path" => plan_path, "pane" => nil, "percent" => 25)
      expect(row["counts"]).to include("total" => 4, "todo" => 2)
      expect(events).to eq([["api", "plan_changed", {"workspace" => "api", "status" => "active"}]])
      expect(output.string).to eq("Added task T4 to the plan for api.\n")
    end

    it "refuses an id in use and a stale revision, writing and recording nothing" do
      write_plan

      expect { command.add(name: "api", title: "x", id: "T2") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("task_exists") }
      expect { command.add(name: "api", title: "x", if_revision: "00000000") }
        .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["revision"]]).to eq(["stale_revision", revision]) }
      expect(File.read(plan_path)).to eq(plan_text)
      expect(events).to be_empty
    end

    it "fails with no_plan when there is no plan" do
      expect { command.add(name: "api", title: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
    end

    it "passes the writer's refusals through" do
      write_plan

      expect { command.add(name: "api", title: "x", state: "blocked") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("reason_required") }
      expect { command.add(name: "api", title: "x", phase: "Nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_phase") }
    end

    it "accepts the revision from the previous result, so edits can be chained" do
      write_plan
      first = command.add(name: "api", title: "Fourth")

      second = command.add(name: "api", title: "Fifth", if_revision: first["revision"])

      expect(second["task"]).to eq("T5")
    end
  end

  describe "#set_state" do
    it "changes the box, keeps the owner, and reports the previous state" do
      write_plan

      row = command.set_state(name: "api", id: "T2", state: "done")

      expect(row).to include("outcome" => "changed", "task" => "T2", "state" => "done", "previous_state" => "in_progress", "revision" => revision)
      expect(File.read(plan_path)).to eq(plan_text.sub("[~] T2", "[x] T2"))
      expect(events.size).to eq(1)
    end

    it "blocks with a reason" do
      write_plan

      command.set_state(name: "api", id: "T3", state: "blocked", reason: "needs db")

      expect(Workspace::PlanFile.read(plan_path).tasks.last).to have_attributes(state: "blocked", reason: "needs db")
    end

    it "is unchanged, recording nothing, when the task already reads that way" do
      write_plan

      row = command.set_state(name: "api", id: "T1", state: "done")

      expect(row).to include("outcome" => "unchanged", "previous_state" => "done")
      expect(events).to be_empty
      expect(output.string).to include("already done")
    end

    it "refuses an unknown task, a missing reason and a stale revision" do
      write_plan

      expect { command.set_state(name: "api", id: "T9", state: "done") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_task") }
      expect { command.set_state(name: "api", id: "T3", state: "skipped") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("reason_required") }
      expect { command.set_state(name: "api", id: "T3", state: "done", if_revision: "00000000") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("stale_revision") }
      expect(File.read(plan_path)).to eq(plan_text)
    end

    it "refuses a stale edit after someone else changed the file" do
      write_plan
      seen = revision
      File.write(plan_path, plan_text.sub("Third", "Third!"))

      expect { command.set_state(name: "api", id: "T3", state: "done", if_revision: seen) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("stale_revision") }
    end
  end

  describe "#move" do
    it "moves a task and reports its new phase and line" do
      write_plan

      row = command.move(name: "api", id: "T1", after: "T3")

      expect(row).to include("outcome" => "moved", "task" => "T1", "phase" => "Two", "line" => 9)
      expect(Workspace::PlanFile.read(plan_path).tasks.map(&:id)).to eq(%w[T2 T3 T1])
    end

    it "is unchanged when the task is already there" do
      write_plan

      expect(command.move(name: "api", id: "T1", before: "T2")["outcome"]).to eq("unchanged")
      expect(events).to be_empty
    end

    it "refuses an unknown anchor and a task moved relative to itself" do
      write_plan

      expect { command.move(name: "api", id: "T1", after: "T9") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_task") }
      expect { command.move(name: "api", id: "T1", after: "T1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_task") }
    end
  end

  it "turns a plan the process cannot write into notes_dir_unwritable" do
    write_plan
    allow(Workspace::PlanFile).to receive(:add_task).and_raise(Errno::EACCES)

    expect { command.add(name: "api", title: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("notes_dir_unwritable") }
  end
end
