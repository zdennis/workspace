require "spec_helper"
require "rbconfig"

RSpec.describe Workspace::WorkflowNudger do
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:spawned) { [] }
  let(:now) { Time.utc(2026, 10, 4, 12, 30, 0) }
  subject(:nudger) do
    described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(workspace) { "/log/#{workspace}.log" },
      spawner: ->(argv, log) { spawned << [argv, log] and nil }, clock: -> { clock_time[:now] }, error_output: error_output)
  end
  let(:clock_time) { {now: now} }
  let(:error_output) { StringIO.new }

  def run(id, workspace, reason: nil, state: "running", check_started: nil, timeout: 600)
    {"id" => id, "workspace" => workspace, "current" => "verify", "reason" => reason && {"code" => reason},
     "definition" => {"steps" => [{"id" => "verify", "status" => {"run" => "bin/check", "timeout" => timeout}}]},
     "steps" => {"verify" => {"state" => state, "attempts" => [{"n" => 1, "check" => check_started && {"started_at" => check_started}}.compact]}}}
  end

  def advances
    spawned.map(&:first).select { |argv| argv[3] == "advance" }
  end

  def sweeps
    spawned.select { |argv, _log| argv[3] == "sweep" }
  end

  def going(runs)
    allow(store).to receive(:going).and_return(runs.map { |each| Workspace::WorkflowRun.from_h(each) })
  end

  let(:hook_log) do
    Class.new do
      attr_reader :lines

      def initialize = @lines = []

      def append(type, pane_id, fields) = @lines << [type, pane_id, fields]
    end.new
  end

  describe "the exit line" do
    let(:status) { Struct.new(:signaled?, :termsig, :exitstatus) }

    def fake_thread(pid, value) = Struct.new(:pid, :value).new(pid, value)

    def nudger_with(thread)
      described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
        spawner: ->(*) { thread.respond_to?(:call) ? thread.call : thread }, waiter: ->(&block) { block.call },
        clock: -> { (clock_time[:now] += 2.5) }, error_output: error_output)
    end

    before { allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1"}) }

    it "logs the exit code, pid and seconds of an advance to the log of its start line" do
      nudger_with(fake_thread(77, status.new(false, nil, 3))).turn_ended("app", "%5", hook_log: hook_log)

      expect(hook_log.lines.last).to eq(["workflow_process_exited", nil, {"kind" => "advance", "run_id" => "wr_1", "pid" => 77, "exit_code" => 3, "seconds" => 2.5}])
    end

    it "logs the signal name when the process was killed" do
      nudger_with(fake_thread(78, status.new(true, 9, nil))).turn_ended("app", "%5", hook_log: hook_log)

      expect(hook_log.lines.last.last).to include("signal" => "KILL", "pid" => 78)
      expect(hook_log.lines.last.last).not_to have_key("exit_code")
    end

    it "logs a sweep's exit with the run ids of its start line" do
      going([run("wr_1", "app", reason: "waiting_you")])
      nudger_with(fake_thread(5, status.new(false, nil, 0))).tick("app", hook_log: hook_log)

      expect(hook_log.lines.last).to eq(["workflow_process_exited", nil, {"kind" => "sweep", "run_ids" => ["wr_1"], "pid" => 5, "exit_code" => 0, "seconds" => 2.5}])
    end

    it "writes no exit line when the spawner returns nil" do
      nudger_with(nil).turn_ended("app", "%5", hook_log: hook_log)

      expect(hook_log.lines.map(&:first)).to eq(["workflow_advance_started"])
    end

    it "writes no exit line when the spawn raises" do
      expect(nudger_with(-> { raise Errno::ENOENT }).turn_ended("app", "%5", hook_log: hook_log)).to be_nil
      expect(hook_log.lines.map(&:first)).to eq(["workflow_advance_started"])
    end

    it "writes no exit line when reading the thread raises" do
      thread = Object.new
      def thread.pid = 1
      def thread.value = raise("gone")
      nudger_with(thread).turn_ended("app", "%5", hook_log: hook_log)

      expect(hook_log.lines.map(&:first)).to eq(["workflow_advance_started"])
    end

    it "writes no exit line without a log" do
      nudger_with(fake_thread(1, status.new(false, nil, 0))).turn_ended("app", "%5")

      expect(hook_log.lines).to eq([])
    end
  end

  describe "the follow-up once a turn's advance has exited" do
    let(:status) { Struct.new(:signaled?, :termsig, :exitstatus) }
    let(:order) { [] }
    let(:follow_up) { -> { order << :follow_up } }

    def nudger_with(thread, waiter: ->(&block) { block.call })
      described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
        spawner: ->(*) { thread.respond_to?(:call) ? thread.call : thread }, waiter: waiter, clock: -> { now }, error_output: error_output)
    end

    # A reaping thread whose +value+ (the process's exit) notes itself in +order+.
    let(:exiting_thread_class) do
      Class.new do
        def initialize(order, result)
          @order = order
          @result = result
        end

        def pid = 7

        def value
          @order << :exited
          @result
        end
      end
    end

    def exiting_thread = exiting_thread_class.new(order, status.new(false, nil, 0))

    before { allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1"}) }

    it "is called on the waiter only after the advance process has exited, after its exit line" do
      waited = []
      nudger_with(exiting_thread, waiter: ->(&block) { waited << block }).turn_ended("app", "%5", hook_log: hook_log, on_exit: follow_up)
      expect(order).to eq([])

      waited.first.call

      expect(order).to eq(%i[exited follow_up])
      expect(hook_log.lines.last.first).to eq("workflow_process_exited")
    end

    it "is called after the exit with no hook log to write to" do
      nudger_with(exiting_thread).turn_ended("app", "%5", on_exit: follow_up)

      expect(order).to eq(%i[exited follow_up])
    end

    it "is called at once when the spawner gives no thread to wait on" do
      nudger_with(nil).turn_ended("app", "%5", on_exit: follow_up)

      expect(order).to eq([:follow_up])
    end

    it "is still called when reading the thread raises" do
      thread = Object.new
      def thread.value = raise("gone")
      nudger_with(thread).turn_ended("app", "%5", on_exit: follow_up)

      expect(order).to eq([:follow_up])
    end

    it "is not called for a pane bound to no run, nor when the advance can't be started" do
      allow(panes).to receive(:bound_on).with("%9").and_return(nil)
      expect(nudger_with(exiting_thread).turn_ended("app", "%9", on_exit: follow_up)).to be_nil
      expect(nudger_with(-> { raise Errno::ENOENT }).turn_ended("app", "%5", on_exit: follow_up)).to be_nil

      expect(order).to eq([])
    end

    it "logs a follow-up that raises and leaves the nudger standing" do
      logger_output = StringIO.new
      nudger = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
        spawner: ->(*) {}, clock: -> { now }, logger: Workspace::Logger.new(output: logger_output, enabled: true), error_output: error_output)

      expect(nudger.turn_ended("app", "%5", on_exit: -> { raise "boom" })).to eq("wr_1")
      expect(logger_output.string).to include("the follow-up after an advance failed (RuntimeError: boom)")
    end
  end

  describe "#turn_ended" do
    it "logs one workflow_advance_started line for the pane and run, to the log it is given" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})

      nudger.turn_ended("app", "%5", hook_log: hook_log)

      expect(hook_log.lines).to eq([["workflow_advance_started", "%5", {"run_id" => "wr_1", "cause" => "turn_ended"}]])
    end

    it "logs nothing for an unbound pane, and nothing without a log" do
      allow(panes).to receive(:bound_on).with("%5").and_return(nil)
      nudger.turn_ended("app", "%5", hook_log: hook_log)
      expect(hook_log.lines).to eq([])

      allow(panes).to receive(:bound_on).with("%6").and_return({run_id: "wr_1", role: "author"})
      expect(nudger.turn_ended("app", "%6", hook_log: nil)).to eq("wr_1")
    end

    it "still starts the advance when the log raises" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      broken = Class.new { def append(*) = raise(IOError) }.new

      expect(nudger.turn_ended("app", "%5", hook_log: broken)).to eq("wr_1")
      expect(advances.size).to eq(1)
    end

    it "hands the step an author pane is bound for to the advance, so a fan_out sibling's turn end reaches its own step" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      allow(panes).to receive(:step_on).with("%5").and_return("lint")

      nudger.turn_ended("app", "%5")

      expect(spawned.first.first).to eq([RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--step", "lint", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "hands the fan_out group a pane is bound to whole to the advance, when the binding names no step" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      allow(panes).to receive(:step_on).with("%5").and_return(nil)
      allow(panes).to receive(:group_on).with("%5").and_return("checks")

      nudger.turn_ended("app", "%5")

      expect(spawned.first.first).to eq([RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--group", "checks", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "starts `workflow advance` for the run the pane is bound to, logging beside the daemon" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})

      expect(nudger.turn_ended("app", "%5")).to eq("wr_1")
      expect(spawned).to eq([[[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1", "--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z"], "/log/app.log"]])
    end

    it "wakes the run a review pane is bound to, since its turn ends the round" do
      allow(panes).to receive(:bound_on).with("%9").and_return({run_id: "wr_1", role: "reviewer"})

      expect(nudger.turn_ended("app", "%9")).to eq("wr_1")
      expect(spawned.first.first).to include("advance", "wr_1", "--turn-ended", "--pane", "%9")
    end

    it "passes on when the turn began, to the millisecond, when the daemon knows" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})

      nudger.turn_ended("app", "%5", turn_started: Time.utc(2026, 10, 4, 12, 29, 58, 123_456))

      expect(spawned.first.first.last(7)).to eq(["--turn-ended", "--pane", "%5", "--turn-started", "2026-10-04T12:29:58.123Z", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "adds one --background-task TYPE:ID per task, in order, and nothing else of a task" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      tasks = [{"id" => "b1a2c3d4e", "type" => "shell", "description" => "secret"}, {"id" => "k12345678", "type" => "MCP task"}]

      nudger.turn_ended("app", "%5", background: tasks)
      nudger.turn_ended("app", "%5", background: nil)

      expect(spawned.first.first.drop(5)).to eq(["--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z", "--background-task", "shell:b1a2c3d4e", "--background-task", "MCP task:k12345678"])
      expect(spawned.last.first.drop(5)).to eq(["--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z"])
    end

    it "adds --transcript-path last when given a path, and leaves it out for nil or an empty one" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})

      nudger.turn_ended("app", "%5", transcript_path: "/t/my s.jsonl")
      nudger.turn_ended("app", "%5", transcript_path: nil)
      nudger.turn_ended("app", "%5", transcript_path: "")

      expect(spawned.first.first.last(2)).to eq(["--transcript-path", "/t/my s.jsonl"])
      expect(spawned[1].first).not_to include("--transcript-path")
      expect(spawned[2].first).not_to include("--transcript-path")
    end

    it "still starts `workflow advance --turn-ended` for a pane bound to a paused run" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      going([run("wr_1", "app").merge("paused" => {"since" => "2026-10-04T12:00:00Z", "by" => "person", "text" => nil})])

      expect(nudger.turn_ended("app", "%5")).to eq("wr_1")
      expect(spawned.first.first).to include("advance", "wr_1", "--turn-ended", "--pane", "%5")
    end

    it "starts nothing for a pane bound to no run" do
      allow(panes).to receive(:bound_on).with("%5").and_return(nil)

      expect(nudger.turn_ended("app", "%5")).to be_nil
      expect(spawned).to eq([])
    end

    it "does not raise when the binding can't be read or the process can't be started" do
      allow(panes).to receive(:bound_on).and_raise(Errno::EACCES)
      expect(nudger.turn_ended("app", "%5")).to be_nil

      allow(panes).to receive(:bound_on).and_return({run_id: "wr_1", role: "author"})
      failing = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(_) { "/log" },
        spawner: ->(*) { raise Errno::ENOENT })
      expect(failing.turn_ended("app", "%5")).to be_nil
    end
  end

  describe "starting the process" do
    it "clears TMUX_PANE, so a daemon started from a pane does not count as that pane" do
      allow(panes).to receive(:bound_on).with("%5").and_return({run_id: "wr_1", role: "author"})
      allow(Process).to receive(:spawn).and_return(1234)
      allow(Process).to receive(:detach)
      real = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(_) { "/log" }, clock: -> { now })

      real.turn_ended("app", "%5")

      expect(Process).to have_received(:spawn).with({"TMUX_PANE" => nil}, RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1",
        "--turn-ended", "--pane", "%5", "--stopped-at", "2026-10-04T12:30:00.000Z", in: File::NULL, out: ["/log", "a"], err: ["/log", "a"])
    end
  end

  describe "#tick" do
    describe "the decision lines" do
      def types = hook_log.lines.map(&:first)

      it "logs a wake as workflow_advance_started with cause tick and the wake reason, then the sweep start" do
        going([run("wr_1", "app", reason: "waiting_lock")])

        nudger.tick("app", hook_log: hook_log)

        expect(hook_log.lines).to eq([
          ["workflow_advance_started", nil, {"run_id" => "wr_1", "cause" => "tick", "reason" => "lock"}],
          ["workflow_sweep_started", nil, {"run_ids" => ["wr_1"]}]
        ])
      end

      it "logs a skipped run once, again only when its reason changes, and a paused run as paused" do
        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)
        nudger.tick("app", hook_log: hook_log)
        skipped = hook_log.lines.select { |l| l.first == "workflow_run_skipped" }
        expect(skipped).to eq([["workflow_run_skipped", nil, {"run_id" => "wr_1", "reason" => "waiting_you"}]])

        going([run("wr_1", "app", reason: "waiting_you").merge("paused" => {"since" => "2026-10-04T12:00:00Z", "by" => "person", "text" => nil})])
        nudger.tick("app", hook_log: hook_log)
        expect(hook_log.lines.reverse.find { |l| l.first == "workflow_run_skipped" }.last).to eq({"run_id" => "wr_1", "reason" => "paused"})
        expect(hook_log.lines.count { |l| l.first == "workflow_run_skipped" }).to eq(2)
      end

      it "forgets a run that is no longer going, so it is logged again when it returns" do
        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)
        going([])
        nudger.tick("app", hook_log: hook_log)

        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)
        expect(hook_log.lines.count { |l| l.first == "workflow_run_skipped" }).to eq(2)
      end

      it "does not repeat an unchanged skip when two workspaces tick alternately" do
        going([run("wr_1", "app", reason: "waiting_you"), run("wr_2", "other", reason: "waiting_you")])

        3.times do
          nudger.tick("app", hook_log: hook_log)
          nudger.tick("other", hook_log: hook_log)
        end

        skipped = hook_log.lines.select { |l| l.first == "workflow_run_skipped" }.map { |l| l.last["run_id"] }
        expect(skipped).to eq(%w[wr_1 wr_2])
      end

      it "logs skip, then the wake, then the same skip again, since the wake changed the reason" do
        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)
        going([run("wr_1", "app", reason: "waiting_lock")])
        nudger.tick("app", hook_log: hook_log)
        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)

        expect(hook_log.lines.map(&:first) - ["workflow_sweep_started"]).to eq(%w[workflow_run_skipped workflow_advance_started workflow_run_skipped])
      end

      it "writes the sweep start only when a sweep starts" do
        going([run("wr_1", "app", reason: "waiting_you")])
        nudger.tick("app", hook_log: hook_log)
        nudger.tick("app", hook_log: hook_log)

        expect(types.count("workflow_sweep_started")).to eq(1)
      end

      it "writes nothing with hook_log nil" do
        going([run("wr_1", "app", reason: "waiting_lock"), run("wr_2", "app", reason: "waiting_you")])

        expect(nudger.tick("app")).to eq(%w[wr_1])
        expect(hook_log.lines).to eq([])
      end
    end

    it "does not run `advance` for a paused run, though it waits for a lock" do
      going([
        run("wr_1", "app", reason: "waiting_lock").merge("paused" => {"since" => "2026-10-04T12:00:00Z", "by" => "person", "text" => nil}),
        run("wr_2", "app", reason: "waiting_lock")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_2])
      expect(advances.map { |argv| argv[4] }).to eq(%w[wr_2])
    end

    it "wakes this workspace's runs that wait for a lock or whose check never reported back, and no others" do
      going([
        run("wr_1", "app", reason: "waiting_lock"),
        run("wr_2", "app"),
        run("wr_3", "app", reason: "waiting_you"),
        run("wr_4", "other", reason: "waiting_lock"),
        run("wr_5", "app", state: "checking", check_started: "2026-10-04T12:19:00Z"),
        run("wr_6", "app", state: "checking", check_started: "2026-10-04T12:18:59Z"),
        run("wr_7", "app", state: "checking")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1 wr_6 wr_7])
      expect(advances).to eq(%w[wr_1 wr_6 wr_7].map { |id| [RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", id] })
    end

    describe "a review round" do
      let(:holder) { {"pid" => 41, "started" => "Sat Oct  4 11:00:00 2026"} }

      def reviewing(id, round, reason: nil)
        run(id, "app", state: "reviewing", reason: reason).tap do |hash|
          hash["definition"]["redeliver"] = 2
          hash["steps"]["verify"]["review"] = {"round" => 1, "started_at" => "2026-10-04T11:00:00.000Z", "redeliveries" => 0}.merge(round)
        end
      end

      def nudger_with(alive)
        described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(workspace) { "/log/#{workspace}.log" },
          spawner: ->(argv, log) { spawned << [argv, log] and nil }, holder_alive: alive, clock: -> { now }, error_output: error_output)
      end

      it "wakes a round whose delivery failed or lapsed with no holder, or whose redeliveries are spent, so tick delivers or stops it" do
        going([reviewing("wr_1", {"delivery" => "delivering"}), reviewing("wr_2", {"delivery" => "failed"}),
          reviewing("wr_3", {"delivery" => "failed", "redeliveries" => 2}), reviewing("wr_4", {"delivery" => nil, "pane" => "%9"})])

        expect(nudger.tick("app")).to eq(%w[wr_1 wr_2 wr_3])
      end

      it "wakes a lapsed round only once its holder is gone, and never a stopped one" do
        going([reviewing("wr_1", {"delivery" => "delivering", "holder" => holder}), reviewing("wr_2", {"delivery" => "failed"}, reason: "review_incomplete")])

        expect(nudger.tick("app")).to eq([])
        expect(nudger_with(->(_found) { true }).tick("app")).to eq([])
        expect(nudger_with(->(_found) { false }).tick("app")).to eq(%w[wr_1])
      end

      it "wakes a round waiting on the lock its review.uses names, so tick asks for it again" do
        going([reviewing("wr_1", {"delivery" => nil, "held" => "waiting_lock"}, reason: "waiting_lock")])

        expect(nudger.tick("app")).to eq(%w[wr_1])
        expect(advances).to eq([[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1"]])
      end
    end

    it "wakes a hold for background tasks only once it is more than 90 minutes old" do
      held = ->(id, seen_at) { run(id, "app").merge("reason" => {"code" => "turn_ended_background", "seen_at" => seen_at}) }
      going([
        held.call("wr_1", "2026-10-04T11:00:00Z"),
        held.call("wr_2", "2026-10-04T11:00:01Z"),
        held.call("wr_3", "2026-10-04T10:59:59Z")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_3])
    end

    it "wakes a run with a parked resume, with no note on the command line" do
      going([
        run("wr_1", "app").merge("parked" => {"id" => "p1", "note" => "secret", "pane" => "%5", "expires_at" => "2026-10-04T13:00:00Z"})
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1])
      expect(advances).to eq([[RbConfig.ruby, "/ws/bin/workspace", "workflow", "advance", "wr_1"]])
    end

    it "picks up a parked run a turn's end could not wake, its pane being bound to no run" do
      allow(panes).to receive(:bound_on).with("%5").and_return(nil)
      going([run("wr_1", "app").merge("parked" => {"id" => "p1", "expires_at" => "2026-10-04T13:00:00Z"})])

      expect(nudger.turn_ended("app", "%5")).to be_nil
      expect(nudger.tick("app")).to eq(%w[wr_1])
    end

    it "wakes the other runs, and says which one it could not look at, when a run file is malformed" do
      going([
        run("wr_1", "app", reason: "waiting_lock").except("steps"),
        run("wr_2", "app", state: "checking", check_started: "not a time"),
        run("wr_3", "app", reason: "waiting_lock")
      ])

      expect(nudger.tick("app")).to eq(%w[wr_1 wr_3])
      expect(error_output.string).to match(/\Aworkflow: could not look at run wr_2 \(ArgumentError: .*\); its run file may be malformed\n\z/)
    end

    describe "the sweep" do
      let(:sweep_argv) { [RbConfig.ruby, "/ws/bin/workspace", "workflow", "sweep", "--name", "app"] }

      before { going([run("wr_1", "app", reason: "waiting_you")]) }

      it "starts on the first tick with a going run, logging beside the advances" do
        expect(nudger.tick("app")).to eq([])
        expect(sweeps).to eq([[sweep_argv, "/log/app.log"]])
      end

      it "runs again only once 300 seconds have passed" do
        nudger.tick("app")
        clock_time[:now] = now + 299
        nudger.tick("app")
        expect(sweeps.size).to eq(1)

        clock_time[:now] = now + 300
        nudger.tick("app")
        expect(sweeps.size).to eq(2)
      end

      it "does not start with no going run" do
        going([])
        nudger.tick("app")
        expect(sweeps).to eq([])
      end

      it "does not start for a going run of another workspace" do
        going([run("wr_1", "other", reason: "waiting_lock")])
        nudger.tick("app")
        expect(sweeps).to eq([])
      end

      it "still wakes the runs, and does not retry within 300 seconds, when starting the sweep raises" do
        attempts = 0
        failing = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
          spawner: ->(argv, log) {
            if argv[3] == "sweep"
              attempts += 1
              raise Errno::ENOENT
            end
            spawned << [argv, log]
          }, clock: -> { clock_time[:now] })
        going([run("wr_1", "app", reason: "waiting_lock")])

        expect(failing.tick("app")).to eq(%w[wr_1])
        clock_time[:now] = now + 15
        expect(failing.tick("app")).to eq(%w[wr_1])
        expect(attempts).to eq(1)
        expect(advances.size).to eq(2)
      end
    end

    describe "the budget sweep" do
      let(:budget_argv) { [RbConfig.ruby, "/ws/bin/workspace", "workflow", "sweep", "--name", "app", "--budget-only"] }

      def budget_run(id, action: "interrupt", state: "running", workspace: "app")
        each = run(id, workspace, state: state)
        each["definition"]["budget"] = {"tokens" => 1000, "action" => action}
        each
      end

      def budget_sweeps = spawned.select { |argv, _log| argv.last == "--budget-only" }

      def tick_at(seconds)
        clock_time[:now] = now + seconds
        nudger.tick("app")
      end

      before do
        # The full sweep's own throttle is spent on the first tick, so only the budget sweep is in view after it.
        going([run("wr_0", "app", reason: "waiting_you")])
        nudger.tick("app")
        spawned.clear
      end

      it "starts on a tick 60 seconds on for a going run with an interrupt budget and a running step" do
        going([budget_run("wr_1")])
        tick_at(60)

        expect(spawned).to eq([[budget_argv, "/log/app.log"]])
      end

      it "starts nothing for a budget with action stop, a run with no budget or a step that is not running" do
        going([budget_run("wr_1", action: "stop"), run("wr_2", "app"), budget_run("wr_3", state: "failed")])
        tick_at(60)

        expect(budget_sweeps).to eq([])
      end

      it "starts nothing for a run of another workspace" do
        going([budget_run("wr_1", workspace: "other")])
        tick_at(60)

        expect(budget_sweeps).to eq([])
      end

      it "is throttled to one start in 60 seconds, and starts again when they have passed" do
        going([budget_run("wr_1")])
        tick_at(60)
        tick_at(75)
        tick_at(119)
        expect(budget_sweeps.size).to eq(1)

        tick_at(120)
        expect(budget_sweeps.size).to eq(2)
      end

      it "spends the throttle on a tick that finds nothing, so the next look is 60 seconds on" do
        going([budget_run("wr_1", action: "stop")])
        tick_at(60)
        going([budget_run("wr_1")])
        tick_at(90)
        expect(budget_sweeps).to eq([])

        tick_at(120)
        expect(budget_sweeps.size).to eq(1)
      end

      it "looks at no run's definition before the throttle has run out" do
        hash = budget_run("wr_1", state: "failed")
        probe = instance_double(Workspace::WorkflowRun, id: "wr_1", workspace: "app", to_h: hash)
        allow(store).to receive(:going).and_return([probe])
        tick_at(30)

        expect(budget_sweeps).to eq([])
      end

      it "starts nothing on the tick that starts the full sweep, and counts that tick as its look" do
        going([budget_run("wr_1")])
        tick_at(300)

        expect(sweeps.map(&:first)).to eq([[RbConfig.ruby, "/ws/bin/workspace", "workflow", "sweep", "--name", "app"]])
        tick_at(330)
        expect(budget_sweeps).to eq([])
        tick_at(360)
        expect(budget_sweeps.size).to eq(1)
      end

      it "logs the start with the run ids that are watched" do
        going([budget_run("wr_1"), run("wr_2", "app", reason: "waiting_you")])
        clock_time[:now] = now + 60
        nudger.tick("app", hook_log: hook_log)

        expect(hook_log.lines.select { |l| l.first == "workflow_sweep_started" }).to eq([["workflow_sweep_started", nil, {"run_ids" => ["wr_1"]}]])
      end

      it "does not retry within 60 seconds when starting it raises" do
        attempts = 0
        failing = described_class.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
          spawner: ->(argv, _log) {
            attempts += 1 if argv.last == "--budget-only"
            raise Errno::ENOENT
          }, clock: -> { clock_time[:now] })
        going([budget_run("wr_1")])
        failing.tick("app")
        clock_time[:now] = now + 60
        failing.tick("app")
        clock_time[:now] = now + 75
        failing.tick("app")

        expect(attempts).to eq(1)
      end
    end

    it "does not raise when the store can't be read" do
      allow(store).to receive(:going).and_raise(Workspace::Error, "no store")

      expect(nudger.tick("app")).to eq([])
    end
  end
end
