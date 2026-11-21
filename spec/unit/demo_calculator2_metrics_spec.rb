require "spec_helper"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2::Metrics do
  describe ".step_wall" do
    it "sums each step's attempt spans and skips unended or other spans" do
      trace = {"spans" => [
        {"kind" => "attempt", "step" => "a", "started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:01:00Z"},
        {"kind" => "attempt", "step" => "a", "started_at" => "2026-01-01T00:02:00Z", "ended_at" => "2026-01-01T00:02:30Z"},
        {"kind" => "attempt", "step" => "b", "started_at" => "2026-01-01T00:02:00Z", "ended_at" => nil},
        {"kind" => "wait", "step" => "a", "started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T09:00:00Z"}
      ]}
      expect(described_class.step_wall(trace)).to eq("a" => 90.0)
    end

    it "is empty without a trace" do
      expect(described_class.step_wall(nil)).to eq({})
    end
  end

  describe ".loops" do
    def attempt(at, outcome = "passed") = {"started_at" => "2026-01-01T00:0#{at}:00Z", "outcome" => outcome}

    def run(implement, acceptance) = {"steps" => {"implement" => {"attempts" => implement}, "acceptance" => {"attempts" => acceptance}}}

    it "counts a return to implement after a failed acceptance attempt" do
      expect(described_class.loops(run([attempt(1), attempt(4)], [attempt(3, "failed"), attempt(6)]))).to eq(1)
    end

    it "does not count acceptance retries" do
      expect(described_class.loops(run([attempt(1)], [attempt(3, "failed"), attempt(4, "failed"), attempt(5)]))).to eq(0)
    end

    it "counts an infra restart of implement inside one pass once" do
      expect(described_class.loops(run([attempt(1), attempt(4, "not_delivered"), attempt(5)], [attempt(3, "failed"), attempt(7)]))).to eq(1)
    end

    it "does not count implement attempts before the first acceptance attempt" do
      expect(described_class.loops(run([attempt(1), attempt(2, "failed")], [attempt(3)]))).to eq(0)
    end
  end

  describe ".acceptance" do
    def run(*outcomes) = {"steps" => {"acceptance" => {"attempts" => outcomes.map { |o| {"outcome" => o} }}}}

    it "passes first time with no loop" do
      expect(described_class.acceptance(run("passed"))).to eq(attempts: 1, first_head: nil, first_recorded: true, loops: 0)
    end

    it "reports the head the first attempt began on and its recorded outcome" do
      stored = {"steps" => {"acceptance" => {"attempts" => [{"outcome" => "failed", "head" => {"before" => "abc"}}, {"outcome" => "passed"}]}}}
      expect(described_class.acceptance(stored)).to include(attempts: 2, first_head: "abc", first_recorded: false, loops: 0)
    end

    it "does not count an attempt that has not ended" do
      expect(described_class.acceptance(run("failed", nil))).to include(attempts: 1, first_recorded: false)
    end

    it "is unknown when the step never ran" do
      expect(described_class.acceptance({"steps" => {}})).to include(attempts: 0, first_recorded: nil, loops: 0)
    end
  end

  describe "the diff scan helpers" do
    let(:long) { "assert_equal 42, run_calc('6 * 7').strip, 'multiplication'" }

    it "builds a signature of long non-comment lines only" do
      expect(described_class.signature(["  #{long}\n# #{long} and more padding to be long enough\nshort\n"])).to eq(Set[long])
    end

    it "finds added lines that are in the signature, once each" do
      diff = "+++ b/x.rb\n+  #{long}\n+  #{long}\n-  #{long}\n+other line that is not in the signature at all\n"
      expect(described_class.copied(diff, Set[long])).to eq([long])
    end

    it "lists added and changed paths, not deleted ones, by their new name" do
      status = "A\tdemo/calculator2/acceptance/x.rb\nD\tdemo/calculator2/acceptance/y.rb\nR100\told.rb\tdemo/calculator2/acceptance/z.rb\nM\tdemo/calculator2/acceptance/w.rb\n"
      expect(described_class.touched(status)).to eq(%w[demo/calculator2/acceptance/x.rb demo/calculator2/acceptance/z.rb demo/calculator2/acceptance/w.rb])
    end

    it "says in a line what the scan found" do
      expect(described_class.diff_line({paths: ["p"], copied: []})).to eq("diff scan: 1 acceptance path touched, 0 copied lines")
      expect(described_class.diff_line(nil)).to eq("diff scan: ?")
    end
  end

  describe ".machine_wait" do
    it "sums the machine buckets, caps them at active and takes them off wall and active" do
      totals = {"machine_waiting_seconds" => {"waiting_lock" => 858.0, "retry_backoff" => 2.0}}
      expect(described_class.machine_wait({wall: 1000.0, active: 900.0}, totals)).to eq(machine_wait: 860.0, wall_ex_wait: 140.0, active_ex_wait: 40.0)
      expect(described_class.machine_wait({wall: 100.0, active: 50.0}, totals)).to eq(machine_wait: 50.0, wall_ex_wait: 50.0, active_ex_wait: 0)
    end

    it "gives zero wait for empty buckets and leaves wall and active as they were" do
      expect(described_class.machine_wait({wall: 100.0, active: 50.0}, {"machine_waiting_seconds" => {}})).to eq(machine_wait: 0, wall_ex_wait: 100.0, active_ex_wait: 50.0)
    end

    it "gives nil for a wall or active that is not a number" do
      totals = {"machine_waiting_seconds" => {"waiting_lock" => 10.0}}
      expect(described_class.machine_wait({wall: nil, active: 50.0}, totals)).to eq(machine_wait: 10.0, wall_ex_wait: nil, active_ex_wait: 40.0)
      expect(described_class.machine_wait({wall: 100.0, active: nil}, totals)).to eq(machine_wait: 10.0, wall_ex_wait: 90.0, active_ex_wait: nil)
    end

    it "does not cap the wait when active is nil" do
      totals = {"machine_waiting_seconds" => {"waiting_lock" => 500.0}}
      expect(described_class.machine_wait({wall: 100.0, active: nil}, totals)).to eq(machine_wait: 500.0, wall_ex_wait: 0, active_ex_wait: nil)
    end

    it "is unknown without buckets" do
      expect(described_class.machine_wait({wall: 1.0, active: 1.0}, nil)).to eq(machine_wait: nil, wall_ex_wait: nil, active_ex_wait: nil)
    end
  end

  describe ".possible_lines" do
    it "gives a line per source and one per near-miss" do
      counts = {false_positive: 1, stat_only: 2, near_miss: 1, unresolved: 0}
      lines = described_class.possible_lines({hook: counts, transcript: counts, near_misses: [{source: "hook", command: "git diff a..b > f"}, {source: "transcript", command: "git diff a..b > f"}]})
      expect(lines).to eq(["possible hits (hook): 1 false positive, 2 stat only, 1 near miss, 0 unresolved",
        "possible hits (transcript): 1 false positive, 2 stat only, 1 near miss, 0 unresolved", "near-miss (hook): git diff a..b > f", "near-miss (transcript): git diff a..b > f"])
      expect(described_class.possible_lines(nil)).to eq([])
    end
  end
end
