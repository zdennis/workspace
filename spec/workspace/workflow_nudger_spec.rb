require "spec_helper"
require "rbconfig"

RSpec.describe Workspace::WorkflowNudger do
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:spawned) { [] }
  let(:now) { Time.utc(2026, 10, 4, 12, 30, 0) }
  subject(:nudger) do
    described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(workspace) { "/log/#{workspace}.log" },
      spawner: ->(argv, log) { spawned << [argv, log] }, clock: -> { now }, error_output: error_output)
  end
  let(:error_output) { StringIO.new }

  def run(id, workspace, reason: nil, state: "running", check_started: nil, timeout: 600)
    {"id" => id, "workspace" => workspace, "current" => "verify", "reason" => reason && {"code" => reason},
     "definition" => {"steps" => [{"id" => "verify", "status" => {"run" => "bin/check", "timeout" => timeout}}]},
     "steps" => {"verify" => {"state" => state, "attempts" => [{"n" => 1, "check" => check_started && {"started_at" => check_started}}.compact]}}}
  end

  describe "#turn_ended" do
    it "starts `workflow advance` for the run the pane is bound to, logging beside the daemon" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")

      expect(nudger.turn_ended("app", "%5")).to eq("wr_1")
      expect(spawned).to eq([[[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z"], "/log/app.log"]])
    end

    it "passes on when the turn began, to the millisecond, when the daemon knows" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")

      nudger.turn_ended("app", "%5", turn_started: Time.utc(2026, 10, 4, 12, 29, 58, 123_456))

      expect(spawned.first.first.last(7)).to eq(["--turn-ended", "--pane", "%5", "--turn-started", "2026-10-04T12:29:58.123Z", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "adds one --background-task TYPE:ID per task, in order, and nothing else of a task" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      tasks = [{"id" => "b1a2c3d4e", "type" => "shell", "description" => "secret"}, {"id" => "k12345678", "type" => "MCP task"}]

      nudger.turn_ended("app", "%5", background: tasks)
      nudger.turn_ended("app", "%5", background: nil)

      expect(spawned.first.first.drop(5)).to eq(["--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z", "--background-task", "shell:b1a2c3d4e", "--background-task", "MCP task:k12345678"])
      expect(spawned.last.first.drop(5)).to eq(["--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "starts nothing for a pane bound to no run" do
      allow(panes).to receive(:run_on).with("%5").and_return(nil)

      expect(nudger.turn_ended("app", "%5")).to be_nil
      expect(spawned).to eq([])
    end

    it "does not raise when the binding can't be read or the process can't be started" do
      allow(panes).to receive(:run_on).and_raise(Errno::EACCES)
      expect(nudger.turn_ended("app", "%5")).to be_nil

      allow(panes).to receive(:run_on).and_return("wr_1")
      failing = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(_) { "/log" },
        spawner: ->(*) { raise Errno::ENOENT })
      expect(failing.turn_ended("app", "%5")).to be_nil
    end
  end

  describe "starting the process" do
    it "clears TMUX_PANE, so a daemon started from a pane does not count as that pane" do
      allow(panes).to receive(:run_on).with("%5").and_return("wr_1")
      allow(Process).to receive(:spawn).and_return(1234)
      allow(Process).to receive(:detach)
      real = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(_) { "/log" }, clock: -> { now })

      real.turn_ended("app", "%5")

      expect(Process).to have_received(:spawn).with({"TMUX_PANE" => nil}, RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1",
        "--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z", in: File::NULL, out: ["/log", "a"], err: ["/log", "a"])
    end
  end

  describe "#tick" do
    it "wakes this workspace's runs that wait for a lock or whose check never reported back, and no others" do
      allow(store).to receive(:active).and_return([
        run("wr_1", "app", reason: "waiting_lock"),
        run("wr_2", "app"),
        run("wr_3", "app", reason: "waiting_you"),
        run("wr_4", "other", reason: "waiting_lock"),
        run("wr_5", "app", state: "checking", check_started: "2026-10-04T12:19:00Z"),
        run("wr_6", "app", state: "checking", check_started: "2026-10-04T12:18:59Z"),
        run("wr_7", "app", state: "checking")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1 wr_6 wr_7])
      expect(spawned.map(&:first)).to eq(%w[wr_1 wr_6 wr_7].map { |id| [RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", id] })
    end

    it "wakes a hold for background tasks only once it is more than 90 minutes old" do
      held = ->(id, seen_at) { run(id, "app").merge("reason" => {"code" => "turn_ended_background", "seen_at" => seen_at}) }
      allow(store).to receive(:active).and_return([
        held.call("wr_1", "2026-10-04T11:00:00Z"),
        held.call("wr_2", "2026-10-04T11:00:01Z"),
        held.call("wr_3", "2026-10-04T10:59:59Z")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_3])
    end

    it "wakes a run with a parked resume, with no note on the command line" do
      allow(store).to receive(:active).and_return([
        run("wr_1", "app").merge("parked" => {"id" => "p1", "note" => "secret", "pane" => "%5", "expires_at" => "2026-10-04T13:00:00Z"})
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1])
      expect(spawned.map(&:first)).to eq([[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1"]])
    end

    it "picks up a parked run a turn's end could not wake, its pane being bound to no run" do
      allow(panes).to receive(:run_on).with("%5").and_return(nil)
      allow(store).to receive(:active).and_return([run("wr_1", "app").merge("parked" => {"id" => "p1", "expires_at" => "2026-10-04T13:00:00Z"})])

      expect(nudger.turn_ended("app", "%5")).to be_nil
      expect(nudger.tick("app")).to eq(%w[wr_1])
    end

    it "wakes the other runs, and says which one it could not look at, when a run file is malformed" do
      allow(store).to receive(:active).and_return([
        run("wr_1", "app", reason: "waiting_lock").except("steps"),
        run("wr_2", "app", state: "checking", check_started: "not a time"),
        run("wr_3", "app", reason: "waiting_lock")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1 wr_3])
      expect(error_output.string).to match(/\Aworkflow: could not look at run wr_2 \(ArgumentError: .*\); its run file may be malformed\n\z/)
    end

    it "does not raise when the store can't be read" do
      allow(store).to receive(:active).and_raise(Workspace::Error, "no store")

      expect(nudger.tick("app")).to eq([])
    end
  end
end
