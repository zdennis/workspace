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
end
