require "spec_helper"

# The rules that read a run one step at a time while a fan_out group is under way: which siblings are under way, the
# run read on one of them, the views a step-aware reader goes through, what wakes a sibling off the cursor, and the
# sweep marks a sibling keeps under its own step.
RSpec.describe Workspace::WorkflowTransitions, "with a fan_out group" do
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }

  def grouped(steps, current: "lint")
    {"id" => "wr_1", "state" => "running", "current" => current,
     "definition" => {"steps" => [{"id" => "lint", "group" => "checks"}, {"id" => "test", "group" => "checks"}, {"id" => "docs", "group" => "checks"}, {"id" => "report"}]},
     "steps" => {"lint" => {"state" => "running", "attempts" => [{"n" => 1}]}, "test" => {"state" => "pending", "attempts" => []},
                 "docs" => {"state" => "pending", "attempts" => []}, "report" => {"state" => "pending", "attempts" => []}}.merge(steps)}
  end

  def plain(current: "build")
    {"id" => "wr_1", "state" => "running", "current" => current, "definition" => {"steps" => [{"id" => "build"}, {"id" => "ship"}]},
     "steps" => {"build" => {"state" => "running", "attempts" => [{"n" => 1}]}, "ship" => {"state" => "pending", "attempts" => []}}}
  end

  describe ".under_way_siblings" do
    it "lists the cursor's group's siblings that are not pending, nor passed with nothing held" do
      run = grouped({"test" => {"state" => "passed", "attempts" => [{"n" => 1}]}, "docs" => {"state" => "failed", "attempts" => [{"n" => 1}]}})

      expect(described_class.under_way_siblings(run)).to eq(%w[lint docs])
    end

    it "keeps a passed sibling whose gate waits or that holds a reason" do
      gated = grouped({"test" => {"state" => "passed", "gate" => {"state" => "waiting"}, "attempts" => [{"n" => 1}]}})
      held = grouped({"test" => {"state" => "passed", "attempts" => [{"n" => 1}], "reason" => {"code" => "waiting_you"}}})

      expect(described_class.under_way_siblings(gated)).to eq(%w[lint test])
      expect(described_class.under_way_siblings(held)).to eq(%w[lint test])
    end

    it "is empty when the cursor's step is in no group" do
      expect(described_class.under_way_siblings(plain)).to eq([])
      expect(described_class.under_way_siblings(grouped({}, current: "report"))).to eq([])
    end
  end

  describe ".at_step" do
    it "moves the cursor to a sibling with a state, leaving the run as it was" do
      run = grouped({})

      view = described_class.at_step(run, "test")

      expect(view["current"]).to eq("test")
      expect(run["current"]).to eq("lint")
      expect(view["steps"]).to equal(run["steps"])
    end

    it "is the run itself for nil, the cursor's step, a step in no group or an unknown one" do
      run = grouped({})

      [nil, "lint", "report", "ghost"].each { |step| expect(described_class.at_step(run, step)).to equal(run) }
      flat = plain
      expect(described_class.at_step(flat, "ship")).to equal(flat)
    end
  end

  describe ".step_views" do
    it "is the run alone outside a group" do
      run = plain

      expect(described_class.step_views(run)).to eq([run])
      expect(described_class.step_views(run).first).to equal(run)
    end

    it "is the run first, then the run read on each other sibling under way" do
      run = grouped({"docs" => {"state" => "running", "attempts" => [{"n" => 1}]}})

      expect(described_class.step_views(run).map { |view| view["current"] }).to eq(%w[lint docs])
      expect(described_class.step_views(run).first).to equal(run)
    end
  end

  describe ".step_wake" do
    it "answers the cursor's cause first, and nil when nothing wakes" do
      expect(described_class.step_wake(plain, now)).to be_nil
      locked = plain.merge("reason" => {"code" => "waiting_lock"})
      expect(described_class.step_wake(locked, now)).to eq([:lock, locked])
    end

    it "answers a sibling off the cursor whose continue line is due, read on its own step" do
      mark = {"step" => "test", "attempt" => 1, "pane" => "%7", "pid" => 9, "kind" => "claude", "since" => now.utc.iso8601}
      run = grouped({"test" => {"state" => "running", "attempts" => [{"n" => 1}], "continue_pending" => mark}})

      cause, view = described_class.step_wake(run, now)

      expect(cause).to eq(:continue)
      expect(view["current"]).to eq("test")
    end

    it "leaves a sibling's lock wait to the sibling's own path, waking nothing for it" do
      run = grouped({"test" => {"state" => "running", "attempts" => [{"n" => 1}], "reason" => {"code" => "waiting_lock"}}})

      expect(described_class.step_wake(run, now)).to be_nil
    end
  end

  describe ".sweep_marks" do
    it "reads a sibling's marks from its own step, and the run's for any other step" do
      marks = {"step" => "test", "attempt" => 1, "stalled" => {"pane_gone" => "t"}}
      run = grouped({"test" => {"state" => "running", "attempts" => [{"n" => 1}], "sweep" => marks}})

      expect(described_class.sweep_marks(described_class.at_step(run, "test"))).to eq(marks)
      expect(described_class.sweep_marks(run)).to eq({})
      flat = plain.merge("sweep" => {"step" => "build", "attempt" => 1, "stalled" => {}})
      expect(described_class.sweep_marks(flat)).to eq(flat["sweep"])
    end
  end

  describe ".held_reason" do
    it "answers for a gated sibling that is not the cursor's step" do
      run = grouped({"test" => {"state" => "passed", "gate" => {"state" => "waiting"}, "attempts" => [{"n" => 1}]}})

      expect(described_class.held_reason(run)).to be_nil
      expect(described_class.held_reason(run, step: "test")).to eq("gate_waiting")
      expect(described_class.held_reason(described_class.at_step(run, "test"))).to eq("gate_waiting")
    end
  end

  describe ".after_failure under a group's on_fail goto" do
    let(:failure) { {"cause" => "check", "code" => "check_failed"} }

    # plan, then the group reviews (r1, r2, r3) whose on_fail goes to plan, then tally.
    def group_goto(on_fail = {"goto" => "plan", "max" => 2}, loops: {}, max_attempts: 20, plan_cap: nil)
      plan = {"id" => "plan"}
      plan["max_attempts"] = plan_cap if plan_cap
      steps = [plan, {"id" => "r1", "group" => "reviews"}, {"id" => "r2", "group" => "reviews"},
        {"id" => "r3", "group" => "reviews"}, {"id" => "tally"}]
      {"id" => "wr_1", "state" => "running", "current" => "r3", "loops" => loops, "reason" => nil,
       "definition" => {"max_attempts" => max_attempts, "steps" => steps, "groups" => {"reviews" => {"on_fail" => on_fail}}},
       "steps" => {"plan" => {"state" => "passed", "attempts" => [{"n" => 1}]},
                   "r1" => {"state" => "running", "attempts" => [{"n" => 1}]},
                   "r2" => {"state" => "running", "attempts" => [{"n" => 1}]},
                   "r3" => {"state" => "running", "attempts" => [{"n" => 1}]},
                   "tally" => {"state" => "pending", "attempts" => []}}}
    end

    def own_on_fail(run, step, on_fail)
      run["definition"]["steps"].find { |each| each["id"] == step }["on_fail"] = on_fail
      run
    end

    def owe_move(run, step)
      run["steps"][step]["state"] = "failed"
      run["steps"][step]["pending_move"] = {"to" => "plan", "group" => "reviews", "was" => nil}
      run["loops"]["reviews->plan"] = 1
      run
    end

    it "routes the first sibling and a later one to the group's goto on edge GROUP->STEP" do
      expected = {kind: :loop, group: "reviews", edge: "reviews->plan", to: "plan", count: 1, wait: nil}

      expect(described_class.after_failure(group_goto, failure, step: "r1")).to eq(expected)
      expect(described_class.after_failure(group_goto, failure, step: "r3")).to eq(expected)
    end

    it "counts on from the edge's loops and carries the group's backoff as the wait" do
      run = group_goto({"goto" => "plan", "max" => 3, "backoff" => 30}, loops: {"reviews->plan" => 1})

      expect(described_class.after_failure(run, failure, step: "r2")).to eq(kind: :loop, group: "reviews", edge: "reviews->plan", to: "plan", count: 2, wait: 30)
    end

    it "lets a sibling's own stop and its own in-group goto win over the group's" do
      stopped = own_on_fail(group_goto, "r2", "stop")
      looping = own_on_fail(group_goto, "r3", {"goto" => "r1", "max" => 2, "backoff" => 5})

      expect(described_class.after_failure(stopped, failure, step: "r2")).to eq(kind: :stop)
      expect(described_class.after_failure(looping, failure, step: "r3")).to eq(kind: :loop, edge: "r3->r1", to: "r1", count: 1, wait: 5)
    end

    it "stops when the edge's loops reach max" do
      expect(described_class.after_failure(group_goto(loops: {"reviews->plan" => 2}), failure, step: "r1")).to eq(kind: :stop)
    end

    it "stops on a failure whose code or cause is excepted" do
      by_code = group_goto({"goto" => "plan", "max" => 2, "except" => ["check_failed"]})
      by_cause = group_goto({"goto" => "plan", "max" => 2, "except" => ["check"]})

      expect(described_class.after_failure(by_code, failure, step: "r1")).to eq(kind: :stop)
      expect(described_class.after_failure(by_cause, failure, step: "r1")).to eq(kind: :stop)
    end

    it "stops when the run's attempts are spent" do
      expect(described_class.after_failure(group_goto(max_attempts: 4), failure, step: "r1")).to eq(kind: :stop)
    end

    it "stops with the goto step named when its own cap is spent" do
      expect(described_class.after_failure(group_goto(plan_cap: 1), failure, step: "r1")).to eq(kind: :stop, limit: :step, step: "plan")
    end

    it "stops with a sibling named when its own cap is spent, since the loop runs every sibling again" do
      capped = group_goto
      capped["definition"]["steps"].find { |each| each["id"] == "r2" }["max_attempts"] = 1

      expect(described_class.after_failure(capped, failure, step: "r1")).to eq(kind: :stop, limit: :step, step: "r2")
      expect(described_class.after_failure(capped, failure, step: "r2")).to eq(kind: :stop, limit: :step, step: "r2")
      expect(described_class.after_failure(owe_move(capped, "r1"), failure, step: "r3")).to eq(kind: :loop, group: "reviews", joined: true)
    end

    it "joins a second failure to the move already owed, never stopping it at max" do
      run = owe_move(group_goto({"goto" => "plan", "max" => 1}), "r1")

      expect(described_class.group_move_owed?(run, "reviews")).to be(true)
      expect(described_class.after_failure(run, failure, step: "r2")).to eq(kind: :loop, group: "reviews", joined: true)
    end

    it "joins a second failure to the move owed even when the run's attempts or the goto step's cap are spent" do
      spent_run = owe_move(group_goto(max_attempts: 4), "r1")
      spent_plan = owe_move(group_goto(plan_cap: 1), "r1")

      expect(described_class.after_failure(spent_run, failure, step: "r2")).to eq(kind: :loop, group: "reviews", joined: true)
      expect(described_class.after_failure(spent_plan, failure, step: "r2")).to eq(kind: :loop, group: "reviews", joined: true)
    end

    it "still stops a second failure that is excepted while a move is owed" do
      run = owe_move(group_goto({"goto" => "plan", "max" => 2, "except" => ["check_failed"]}), "r1")

      expect(described_class.after_failure(run, failure, step: "r2")).to eq(kind: :stop)
    end

    it "keeps today's implicit move under a group on_fail: stop" do
      run = group_goto("stop")

      expect(described_class.after_failure(run, failure, step: "r2")).to eq(kind: :loop, edge: "r2->r1", to: "r1", count: 1, wait: nil)
      expect(described_class.after_failure(run, failure, step: "r1")).to eq(kind: :stop)
    end

    it "loops a guard failure under a group goto" do
      guard = {"cause" => "guard", "code" => "head_moved"}

      expect(described_class.after_failure(group_goto, guard, step: "r1")).to eq(kind: :loop, group: "reviews", edge: "reviews->plan", to: "plan", count: 1, wait: nil)
      expect(described_class.after_failure(group_goto("stop"), guard, step: "r2")).to eq(kind: :stop)
    end
  end

  describe ".group_move_owed?" do
    it "is false with no pending move, or one a sibling holds of its own" do
      run = {"definition" => {"steps" => [{"id" => "r1", "group" => "reviews"}, {"id" => "r2", "group" => "reviews"}]},
             "steps" => {"r1" => {"state" => "failed", "attempts" => [{"n" => 1}], "pending_move" => {"to" => "r2"}},
                         "r2" => {"state" => "running", "attempts" => [{"n" => 1}]}}}

      expect(described_class.group_move_owed?(run, "reviews")).to be(false)
      expect(described_class.group_move_owed?(run, "ghost")).to be(false)
    end

    it "is true for a pending move tagged with this group, and false for one tagged with another" do
      run = {"definition" => {"steps" => [{"id" => "r1", "group" => "reviews"}, {"id" => "r2", "group" => "reviews"}]},
             "steps" => {"r1" => {"state" => "running", "attempts" => [{"n" => 1}]},
                         "r2" => {"state" => "failed", "attempts" => [{"n" => 1}], "pending_move" => {"to" => "plan", "group" => "reviews"}}}}
      other = Marshal.load(Marshal.dump(run))
      other["steps"]["r2"]["pending_move"]["group"] = "checks"

      expect(described_class.group_move_owed?(run, "reviews")).to be(true)
      expect(described_class.group_move_owed?(other, "reviews")).to be(false)
    end
  end
end
