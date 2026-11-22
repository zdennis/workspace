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

  describe ".review and .step_tokens" do
    let(:trace) do
      {"spans" => [
        {"kind" => "attempt", "step" => "plan", "attempt" => 1, "tokens" => {"total" => 180}},
        {"kind" => "review_round", "step" => "plan", "attempt" => 1, "round" => 1, "started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:00:45Z", "tokens" => {"total" => 110}},
        {"kind" => "attempt", "step" => "plan", "attempt" => 2, "tokens" => {"total" => 170}},
        {"kind" => "review_round", "step" => "plan", "attempt" => 2, "round" => 2, "started_at" => "2026-01-01T00:01:00Z", "ended_at" => nil, "tokens" => {"total" => 100}},
        {"kind" => "attempt", "step" => "implement", "attempt" => 1, "tokens" => nil}
      ]}
    end

    it "totals the rounds' wall (unended adds none) and tokens" do
      expect(described_class.review(trace)).to eq(wall: 45.0, tokens: 210)
    end

    it "leaves out a step whose attempt span has no token count, as step wall leaves out an unended one" do
      expect(described_class.step_tokens(trace)).not_to have_key("implement")
    end

    it "gives each step its attempts' tokens less their review rounds'" do
      expect(described_class.step_tokens(trace)).to eq("plan" => 140)
    end

    it "is nil without a trace or spans, so a missing trace is not shown as no review" do
      expect(described_class.review(nil)).to be_nil
      expect(described_class.review("spans" => [])).to be_nil
      expect(described_class.step_tokens(nil)).to eq({})
    end

    it "counts a review round that has no attempt span of its own" do
      stray = trace["spans"] + [{"kind" => "review_round", "step" => "verify", "attempt" => 1, "round" => 1, "tokens" => {"total" => 5}}]
      expect(described_class.unmatched_rounds(trace)).to eq(0)
      expect(described_class.unmatched_rounds("spans" => stray)).to eq(1)
      expect(described_class.unmatched_rounds(nil)).to eq(0)
    end
  end

  describe ".usage_by_model and .model_shift" do
    let(:pricing) do
      {"models" => {"opus" => {"input" => 5.0, "output" => 25.0, "cache_creation" => 6.25, "cache_read" => 0.5},
                    "sonnet" => {"input" => 3.0, "output" => 15.0, "cache_creation" => 3.75, "cache_read" => 0.3}}}
    end
    let(:lines) do
      [{"type" => "assistant", "timestamp" => "2026-01-01T00:00:10Z", "message" => {"id" => "m1", "model" => "sonnet", "usage" => {"input_tokens" => 1, "output_tokens" => 1}}},
        {"type" => "assistant", "timestamp" => "2026-01-01T00:00:11Z", "message" => {"id" => "m1", "model" => "sonnet", "usage" => {"input_tokens" => 1, "output_tokens" => 10, "cache_read_input_tokens" => 1_000_000}}},
        {"type" => "assistant", "timestamp" => "2026-01-01T00:00:12Z", "message" => {"id" => "m2", "model" => "opus", "usage" => {"input_tokens" => 2}}},
        {"type" => "assistant", "timestamp" => "2026-01-01T09:00:00Z", "message" => {"id" => "m3", "model" => "opus", "usage" => {"input_tokens" => 99}}},
        {"type" => "user", "message" => {"content" => "x"}}]
    end

    it "sums each model's messages once by id, inside the window" do
      by_model = described_class.usage_by_model(lines, from: Time.parse("2026-01-01T00:00:00Z"), to: Time.parse("2026-01-01T00:01:00Z"))
      expect(by_model).to eq("sonnet" => {input: 1, output: 10, cache_creation: 0, cache_read: 1_000_000}, "opus" => {input: 2, output: 0, cache_creation: 0, cache_read: 0})
    end

    it "prices a sub-agent on another model at its own rates, the round's own model at no change, and flags an unpriced model" do
      by_model = {"sonnet" => {input: 0, output: 0, cache_creation: 0, cache_read: 1_000_000}, "opus" => {input: 5, output: 0, cache_creation: 0, cache_read: 0}}
      shift = described_class.model_shift(by_model, "opus", pricing)
      expect(shift[:dollars]).to be_within(1e-9).of(0.3 - 0.5)
      expect(shift).to include(models: %w[sonnet opus], unpriced: false)
      expect(described_class.model_shift({"mystery" => {input: 1}}, "opus", pricing)).to include(unpriced: true, dollars: 0.0)
    end
  end

  describe ".machine_wait" do
    it "takes a review round's redelivery wait out of wall and active, but not out of the lock wait" do
      row = {wall: 383.0, active: 382.0, review_deliver_wait: 102.0}
      expect(described_class.machine_wait(row, {"machine_waiting_seconds" => {"lock" => 10.0}}))
        .to eq(machine_wait: 10.0, wall_ex_wait: 271.0, active_ex_wait: 270.0)
    end
  end

  describe ".review with a nil-token round" do
    it "skips the round rather than counting it as zero" do
      span = {"kind" => "review_round", "started_at" => "2026-11-21T05:00:00Z", "ended_at" => "2026-11-21T05:00:10Z", "tokens" => nil}
      expect(described_class.review("spans" => [span])).to eq(wall: 10.0, tokens: nil)
      expect(described_class.review("spans" => [span, span.merge("tokens" => {"total" => 7})])).to eq(wall: 20.0, tokens: 7)
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
  describe ".lanes" do
    def at(minutes, seconds = 0) = Time.utc(2026, 11, 21, 5, minutes, seconds).iso8601

    def row(lane, goal, from, to, **extra)
      {ran: true, lane: lane, goal: goal, started_at: at(*from), ended_at: at(*to), wall: Time.parse(at(*to)) - Time.parse(at(*from))}.merge(extra)
    end

    # 01-03 end at 05:12; lane B starts at 05:12:20 and ends 05:30; lane A ends 05:27; integration 05:30:10 to 05:31:00.
    let(:rows) do
      [row("A", "01-add-sub", [0, 5], [4]), row("A", "02-mul-div", [4], [8]), row("A", "03-div-zero", [8], [12]),
        row("A", "04-precedence", [12, 5], [20]), row("A", "05-mod-pow", [20], [27]),
        row("B", "06-json", [12, 20], [21]), row("B", "07-repl", [21], [30])]
    end
    let(:fork) { {"goal" => "03-div-zero"} }
    let(:integration) { {"started_at" => at(30), "ended_at" => at(31), "merge" => "clean", "first_pass" => true, "conflict" => false} }

    it "measures wall from the earliest item start to the end of the integration, and the sequential equivalent from the item walls plus the integration" do
      lanes = described_class.lanes(rows, fork: fork, integration: integration)
      expect(lanes[:wall]).to eq(31 * 60 - 5)
      expect(lanes[:sequential]).to eq(rows.sum { |r| r[:wall] } + 60)
    end

    it "splits the critical path into the 01-03 span, fork latency, the longer tail, and the integration, and checks they add up to wall" do
      path = described_class.lanes(rows, fork: fork, integration: integration)[:critical_path]
      expect(path).to include(span: 12 * 60 - 5, fork_latency: 20, a_tail: 27 * 60 - (12 * 60 + 20), b_tail: 30 * 60 - (12 * 60 + 20), integration: 60, lane: "B", slack: 3 * 60)
      expect(path[:check]).to include(ok: true, delta: 0)
    end

    it "flags a critical path that is negative, as when lane B started before the fork goal ended" do
      early = rows.map { |r| (r[:goal] == "06-json") ? r.merge(started_at: at(11)) : r }
      path = described_class.lanes(early, fork: fork, integration: integration)[:critical_path]
      expect(path[:fork_latency]).to eq(-60)
      expect(path[:check][:ok]).to be(false)
    end

    it "flags a recorded fork time outside the fork goal's end and lane B's first start, though the parts still add up" do
      path = described_class.lanes(rows, fork: fork.merge("at" => at(31)), integration: integration)[:critical_path]
      expect(path[:check]).to include(delta: 0, fork_ordered: false, ok: false)
      expect(described_class.lanes(rows, fork: fork.merge("at" => at(12, 20)), integration: integration)[:critical_path][:check]).to include(fork_ordered: true, ok: true)
    end

    it "shows a gap between the later lane's end and the integration's start as a delta that fails the check" do
      late = integration.merge("started_at" => at(30, 10))
      path = described_class.lanes(rows, fork: fork, integration: late)[:critical_path]
      expect(path[:check]).to include(delta: 10, ok: false)
    end

    it "gives no critical path without a lane B item or a fork goal row" do
      expect(described_class.lanes(rows.reject { |r| r[:lane] == "B" }, fork: fork, integration: integration)[:critical_path]).to be_nil
      expect(described_class.lanes(rows, fork: {"goal" => "09"}, integration: integration)[:critical_path]).to be_nil
      expect(described_class.lanes(rows, fork: fork, integration: nil)).to include(wall: nil, sequential: nil, critical_path: nil)
    end

    it "takes the waits of the items on the critical path off the wall: lane A through 03 and then lane B" do
      waited = rows.map do |r|
        case r[:goal]
        when "01-add-sub" then r.merge(machine_wait: 10, deliver_wait: 5, person_wait: nil)
        when "04-precedence" then r.merge(machine_wait: 999)
        when "07-repl" then r.merge(person_wait: 30)
        else r
        end
      end
      lanes = described_class.lanes(waited, fork: fork, integration: integration)
      expect(lanes[:wall_net_of_waits]).to eq(31 * 60 - 5 - 15 - 30)
    end

    it "shows lock waits per lane and flags a nonzero one" do
      locked = rows.map { |r| (r[:goal] == "06-json") ? r.merge(lock_wait: 42.0) : r }
      expect(described_class.lanes(rows, fork: fork, integration: integration)[:lock_waits]).to eq("A" => {seconds: 0.0, flagged: false}, "B" => {seconds: 0.0, flagged: false})
      expect(described_class.lanes(locked, fork: fork, integration: integration)[:lock_waits]["B"]).to eq(seconds: 42.0, flagged: true)
    end

    it "reports the integration's first pass, conflict and integrate attempts" do
      repaired = integration.merge("merge" => "conflict", "conflict" => true, "first_pass" => false, "integrate_run" => {"passed" => true})
      result = described_class.lanes(rows, fork: fork, integration: repaired, integrate_attempts: 3)[:integration]
      expect(result).to include(merge: "conflict", conflict: true, first_pass: false, integrate_attempts: 3, integrate_passed: true, wall: 60)
    end
  end

  describe ".catches" do
    it "counts failed verify attempts and rejecting verdicts the attempts kept" do
      run = {"steps" => {"verify" => {"attempts" => [{"outcome" => "failed"}, {"outcome" => "passed"}]},
                         "plan" => {"attempts" => [{"reviews" => [{"verdict" => "reject"}, {"verdict" => "approve"}]}]}, "implement" => {"attempts" => [{"outcome" => "passed"}]}}}
      expect(described_class.catches(run)).to eq(verify_fixes: 1, review_rejections: 1)
      expect(described_class.catches({})).to eq(verify_fixes: 0, review_rejections: 0)
    end
  end

  describe ".lanes_lines" do
    it "prints the wall, the critical path, the lock waits and the integration, and says so when the path does not add up" do
      rows = [{ran: true, lane: "A", goal: "01-add-sub", started_at: "2026-11-21T05:00:00Z", ended_at: "2026-11-21T05:04:00Z", wall: 240},
        {ran: true, lane: "B", goal: "06-json", started_at: "2026-11-21T05:03:00Z", ended_at: "2026-11-21T05:08:00Z", wall: 300}]
      lanes = described_class.lanes(rows, fork: {"goal" => "01-add-sub"}, integration: {"started_at" => "2026-11-21T05:08:30Z", "ended_at" => "2026-11-21T05:09:00Z", "merge" => "clean", "first_pass" => true, "conflict" => false})
      lines = described_class.lanes_lines(lanes, {"goal" => "01-add-sub"})
      expect(lines[0]).to start_with("wall: 9m00s  sequential equivalent: 9m30s")
      expect(lines[1]).to include("critical path: 01-03 4m00s + fork -1m00s")
      expect(lines.join("\n")).to include("ERROR: the critical path differs from the wall", "lock waits: A 0s, B 0s", "integration: merge clean, first pass yes, conflict no")
    end

    it "flags a nonzero lock wait" do
      lanes = {wall: nil, sequential: nil, wall_net_of_waits: nil, critical_path: nil, lock_waits: {"A" => {seconds: 0.0, flagged: false}, "B" => {seconds: 90.0, flagged: true}}, integration: {}}
      lines = described_class.lanes_lines(lanes, nil)
      expect(lines).to include(a_string_matching(/lock waits: A 0s, B 1m30s \(nonzero/), "critical path: ?")
    end
  end
end
