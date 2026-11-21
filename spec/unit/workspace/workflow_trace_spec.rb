require "spec_helper"
require "json"

RSpec.describe Workspace::WorkflowTrace do
  let(:now) { Time.utc(2026, 11, 1, 12, 0, 0) }
  let(:golden) { File.join(PROJECT_ROOT, "spec/fixtures/workflow_run_golden") }

  def load_pair(name)
    run = JSON.parse(File.read(File.join(golden, "#{name}.json")))
    text = File.read(File.join(golden, "#{name}.events.json"))
    events = JSON.parse("[" + text.gsub(/\}\s*\{/, "},{") + "]")
    [run, events.each_with_index.map { |event, i| event.merge("n" => i + 1) }]
  end

  describe "a run with stamped events" do
    let(:pair) { load_pair("restarted") }
    let(:trace) { described_class.new.read(pair[0], pair[1], now: now) }
    let(:rows) { trace[:transitions] }

    it "is frozen and carries spans, totals and warnings" do
      expect(trace).to be_frozen
      expect(trace.keys).to eq(%i[trace_id transitions spans totals warnings])
      expect(trace[:warnings]).to eq([])
    end

    it "orders rows by event n and keeps stamped states, actor and cause" do
      expect(rows.map { |row| row[:n] }).to eq((1..7).to_a)
      resumed = rows.find { |row| row[:type] == "run_resumed" }
      expect(resumed).to include(from: "running", to: "running", actor: "person", cause: "resume", derived: false, kind: "transition")
    end

    it "derives a row whose stamps are null and marks it" do
      dispatched = rows.find { |row| row[:type] == "step_dispatched" && row[:attempt] == 2 }
      expect(dispatched).to include(from: "running", to: "running", derived: true, actor: "engine")
    end

    it "measures duration against the previous row of the same step" do
      expect(rows.map { |row| row[:duration_ms] }).to eq([nil, nil, 0, 60_000, 0, 0, 0])
    end

    it "orders by n, not by ts" do
      shuffled = pair[1].reverse
      expect(described_class.new.read(pair[0], shuffled, now: now)[:transitions].map { |row| row[:n] }).to eq((1..7).to_a)
    end

    it "has the same trace_id on every read, from the run id" do
      again = described_class.new.read(pair[0], pair[1], now: now + 60)
      expect(again[:trace_id]).to eq(trace[:trace_id])
      expect(trace[:trace_id]).to eq(Digest::SHA256.hexdigest("wr_1")[0, 32])
      expect(trace[:trace_id].length).to eq(32)
    end
  end

  describe "an old run with no stamps and second-resolution ts" do
    let(:usage) { {"input_tokens" => 10, "output_tokens" => 5, "cache_creation_input_tokens" => 2, "cache_read_input_tokens" => 999} }
    let(:run) do
      {"id" => "wr_old", "steps" => {
        "build" => {"attempts" => [{"n" => 1, "outcome" => "failed", "usage" => usage}, {"n" => 2, "outcome" => "passed", "usage" => nil}]},
        "ship" => {"attempts" => [{"n" => 1, "outcome" => "passed", "usage" => usage}]}
      }}
    end
    let(:events) do
      [
        {"n" => 1, "ts" => "2026-10-01T10:00:00Z", "type" => "run_started"},
        {"n" => 2, "ts" => "2026-10-01T10:00:01Z", "type" => "step_dispatching", "step" => "build", "attempt" => 1},
        {"n" => 3, "ts" => "2026-10-01T10:00:31Z", "type" => "step_failed", "step" => "build", "exit_code" => 2},
        {"n" => 4, "ts" => "2026-10-01T10:00:32Z", "type" => "step_dispatching", "step" => "build", "attempt" => 2},
        {"n" => 5, "ts" => "2026-10-01T10:01:00Z", "type" => "step_passed", "step" => "build", "attempt" => 2},
        {"n" => 6, "ts" => "2026-10-01T10:01:00Z", "type" => "command_denied", "step" => "build"},
        {"n" => 7, "type" => "step_dispatching", "step" => "ship", "attempt" => 1},
        {"n" => 8, "ts" => "2026-10-01T10:02:00Z", "type" => "step_passed", "step" => "ship", "attempt" => 1}
      ]
    end
    let(:rows) { described_class.new.read(run, events, now: now)[:transitions] }

    it "derives from and to per row and leaves actor and cause nil" do
      expect(rows.map { |row| row[:derived] }).to all(be(true))
      expect(rows[1]).to include(from: nil, to: "running", actor: nil, cause: nil)
      expect(rows[2]).to include(from: "running", to: "failed", exit_code: 2, attempt: 1)
      expect(rows[4]).to include(from: "running", to: "passed")
    end

    it "marks a type with no state as a marker with nil states" do
      expect(rows[5]).to include(kind: "marker", from: nil, to: nil)
    end

    it "gives nil, never 0, for a missing ts or duration" do
      expect(rows[6]).to include(ts: nil, duration_ms: nil)
      expect(rows[7][:duration_ms]).to be_nil
      expect(rows[2][:duration_ms]).to eq(30_000)
      expect(rows[0]).to include(duration_ms: nil, round: nil, code: nil)
    end

    it "puts tokens on exactly the row that ends each attempt, nil when usage is null" do
      with_tokens = rows.select { |row| row[:tokens] }
      expect(with_tokens.map { |row| row[:n] }).to eq([3, 8])
      expect(rows[2][:tokens]).to eq({total: 17, in: 10, out: 5, cache: 2})
      expect(rows[4][:tokens]).to be_nil
    end

    it "puts the reported status on the row that ends the attempt, and no key on the others" do
      report = {"state" => "done", "detail" => "all green", "at" => "2026-10-01T10:02:00Z", "source" => "report"}
      stated = run.merge("steps" => run["steps"].merge("ship" => run["steps"]["ship"].merge("attempts" => [run["steps"]["ship"]["attempts"][0].merge("status_report" => report)])))
      doc = described_class.new.read(stated, events, now: now)

      expect(doc[:transitions][7][:status_report]).to eq({"state" => "done", "detail" => "all green", "at" => "2026-10-01T10:02:00Z"})
      expect(doc[:transitions].each_index.select { |i| doc[:transitions][i].key?(:status_report) }).to eq([7])
      expect(described_class.text_lines(doc).grep(/ship#1/).last).to end_with("reported=done: all green")

      plain = described_class.new.read(run, events, now: now)
      expect(plain[:transitions][7]).not_to have_key(:status_report)
      expect(described_class.text_lines(plain).grep(/reported=/)).to eq([])
    end

    it "reads a WorkflowRun as well as a Hash" do
      expect(described_class.new.read(Workspace::WorkflowRun.new(run), events, now: now)[:transitions]).to eq(rows)
    end
  end

  it "pairs an attempt that ended at a millisecond stamp with the run-end row stamped to the same whole second" do
    usage = {"input_tokens" => 10, "output_tokens" => 5}
    run = {"id" => "wr_ms", "steps" => {"build" => {"attempts" => [{"n" => 1, "outcome" => "cancelled", "ended_at" => "2026-10-01T10:00:05.900Z", "usage" => usage}]}}}
    events = [
      {"n" => 1, "ts" => "2026-10-01T10:00:00Z", "type" => "step_dispatching", "step" => "build", "attempt" => 1},
      {"n" => 2, "ts" => "2026-10-01T10:00:05Z", "type" => "run_cancelled"}
    ]
    rows = described_class.new.read(run, events, now: now)[:transitions]
    expect(rows.map { |row| row[:tokens] }).to eq([nil, {total: 15, in: 10, out: 5, cache: 0}])
  end

  it "reads a run with no events or steps" do
    trace = described_class.new.read({"id" => "wr_x"}, [], now: now)
    expect(trace[:transitions]).to eq([])
  end

  it "puts an interrupted attempt's tokens on the cancel row when no step event ends it" do
    run = {"id" => "wr_c", "steps" => {"a" => {"attempts" => [{"n" => 1, "ended_at" => "2026-10-01T10:00:30Z", "usage" => {"input_tokens" => 1, "output_tokens" => 2, "cache_creation_input_tokens" => 3}}]}}}
    events = [
      {"n" => 1, "ts" => "2026-10-01T10:00:00Z", "type" => "step_dispatching", "step" => "a", "attempt" => 1},
      {"n" => 2, "ts" => "2026-10-01T10:00:30Z", "type" => "run_cancelled"}
    ]
    rows = described_class.new.read(run, events, now: now)[:transitions]
    expect(rows[1][:tokens]).to eq({total: 6, in: 1, out: 2, cache: 3})
    expect(rows[0][:tokens]).to be_nil
  end
  it "puts a reviewed and gated attempt's tokens only on its final step_passed row" do
    run = {"id" => "wr_g", "steps" => {"a" => {"attempts" => [{"n" => 1, "usage" => {"input_tokens" => 1, "output_tokens" => 2, "cache_creation_input_tokens" => 3}}]}}}
    events = [
      {"n" => 1, "ts" => "2026-10-01T10:00:00Z", "type" => "step_checks_passed", "step" => "a", "attempt" => 1},
      {"n" => 2, "ts" => "2026-10-01T10:00:01Z", "type" => "gate_waiting", "step" => "a", "attempt" => 1},
      {"n" => 3, "ts" => "2026-10-01T10:00:02Z", "type" => "step_passed", "step" => "a", "attempt" => 1}
    ]
    rows = described_class.new.read(run, events, now: now)[:transitions]
    expect(rows.map { |row| row[:tokens] }).to eq([nil, nil, {total: 6, in: 1, out: 2, cache: 3}])
  end

  it "orders by n even when a ts runs backwards" do
    events = [
      {"n" => 1, "ts" => "2026-10-01T10:00:10Z", "type" => "run_started"},
      {"n" => 2, "ts" => "2026-10-01T10:00:05Z", "type" => "run_paused"}
    ]
    rows = described_class.new.read({"id" => "wr_o"}, events.reverse, now: now)[:transitions]
    expect(rows.map { |row| row[:n] }).to eq([1, 2])
    expect(rows[1][:duration_ms]).to be_nil
  end

  describe "spans, totals and warnings" do
    let(:usage) { {"input_tokens" => 100, "output_tokens" => 50, "cache_creation_input_tokens" => 10, "cache_read_input_tokens" => 99_999} }
    let(:reader) { described_class.new }

    def t(clock) = "2026-10-01T#{clock}Z"

    # Non-overlapping stops: failed_check 60s, gate 60s, stall 30s, downtime 60s, plus a retry_backoff of 60s the clock keeps.
    let(:run) do
      {"id" => "wr_t", "state" => "completed", "current" => "build", "loops" => 2,
       "started_at" => t("10:00:00"), "ended_at" => t("10:10:00"),
       "steps" => {"build" => {"attempts" => [
         {"n" => 1, "started_at" => t("10:00:00"), "ended_at" => t("10:10:00"), "outcome" => "passed", "code" => "ok",
          "head" => {"before" => "aaa", "after" => "bbb"}, "usage" => usage,
          "rounds" => [{"round" => 1, "pane" => "%9", "started_at" => t("10:02:00"), "ended_at" => t("10:02:30"), "usage" => usage}],
          "reasons" => [
            {"code" => "failed_check", "since" => t("10:01:00"), "until" => t("10:02:00")},
            {"code" => "retry_backoff", "since" => t("10:03:00"), "until" => t("10:04:00")},
            {"code" => "waiting_you", "since" => t("10:05:00"), "until" => t("10:06:00")}
          ],
          "stalls" => [{"cause" => "pane_gone", "since" => t("10:08:30"), "until" => t("10:09:00")}]}
       ]}}}
    end
    let(:events) do
      [
        {"n" => 1, "ts" => t("10:00:00"), "type" => "run_started"},
        {"n" => 2, "ts" => t("10:05:00"), "type" => "gate_waiting", "step" => "build", "attempt" => 1},
        {"n" => 3, "ts" => t("10:06:00"), "type" => "gate_approved", "step" => "build", "actor" => "person", "note" => "fine"}
      ]
    end
    let(:stops) { [{"since" => t("10:07:00"), "until" => t("10:08:00")}] }
    let(:trace) { reader.read(run, events, now: now, stops: stops) }
    let(:spans) { trace[:spans] }
    let(:totals) { trace[:totals] }

    def kind(name) = spans.select { |span| span[:kind] == name }

    it "makes one attempt span with outcome, heads, tokens and retry_of" do
      expect(kind("attempt").size).to eq(1)
      expect(kind("attempt").first).to include(step: "build", attempt: 1, outcome: "passed", code: "ok", head_before: "aaa", head_after: "bbb",
        tokens: {total: 320, in: 200, out: 100, cache: 20}, retry_of: nil)
    end

    it "makes a review_round span with tokens derived from the round's usage" do
      expect(kind("review_round")).to match([include(step: "build", attempt: 1, round: 1, tokens: {total: 160, in: 100, out: 50, cache: 10})])
      expect(kind("review_round").first).not_to have_key(:usage)
    end

    it "gives every span kind exactly the one key set" do
      keys = %i[span_id kind step attempt round started_at ended_at code outcome actor note tokens head_before head_after retry_of]
      extra = run.merge("reasons" => [{"code" => "parked", "since" => t("10:00:00")}])
      all = reader.read(extra, events, now: now, stops: stops)[:spans]
      expect(all.map { |span| span[:kind] }.uniq).to match_array(%w[attempt review_round gate wait stall downtime])
      all.each { |span| expect(span.keys).to match_array(keys) }
    end

    it "gives a time string or nil for every span time" do
      odd = run.merge("reasons" => [{"code" => "parked", "since" => 5}])
      times = reader.read(odd, events, now: now)[:spans].flat_map { |span| [span[:started_at], span[:ended_at]] }
      expect(times).to all(be_nil.or(be_a(String)))
    end

    it "buckets a wait with no code under unknown, which the clock cuts" do
      odd = run.merge("reasons" => [{"since" => t("10:09:00"), "until" => t("10:09:10")}])
      result = reader.read(odd, events, now: now)
      expect(result[:spans].find { |span| span[:kind] == "wait" && span[:started_at] == t("10:09:00") }).to include(code: "unknown")
      expect(result[:totals][:waiting_seconds]).to include("unknown" => 10.0)
      expect(result[:totals][:stopped_seconds]).to be >= 10.0
    end

    it "ignores a wait whose until is not a usable time, as the clock does" do
      odd = run.merge("reasons" => [{"code" => "paused", "since" => t("10:00:30"), "until" => "soon"}, {"code" => "parked", "since" => t("10:00:30"), "until" => 7}])
      result = reader.read(odd, events, now: now)
      expect(result[:spans].select { |span| span[:kind] == "wait" }.map { |span| span[:code] }).to eq(%w[failed_check retry_backoff])
      expect(result[:totals][:waiting_seconds]).not_to include("parked", "paused")
      expect(result[:totals][:active_seconds]).to eq(reader.read(run, events, now: now)[:totals][:active_seconds])
    end

    it "closes a gate span at the next gate_waiting when nothing closed it" do
      twice = [
        {"n" => 1, "ts" => t("10:05:00"), "type" => "gate_waiting", "step" => "build"},
        {"n" => 2, "ts" => t("10:05:30"), "type" => "gate_waiting", "step" => "build"}
      ]
      gates = reader.read(run, twice, now: now)[:spans].select { |span| span[:kind] == "gate" }
      expect(gates.map { |gate| [gate[:started_at], gate[:ended_at]] }).to eq([[t("10:05:00"), t("10:05:30")], [t("10:05:30"), nil]])
    end

    it "keeps active + stopped == clock to the millisecond with a fractional now and a millisecond stop" do
      live = run.merge("state" => "running", "ended_at" => nil)
      fractional = Time.utc(2026, 10, 1, 10, 20, 0, 333_333, :usec)
      ms_stops = [{"since" => Time.utc(2026, 10, 1, 10, 7, 0, 123_000).iso8601(3), "until" => Time.utc(2026, 10, 1, 10, 7, 30, 777_000).iso8601(3)}]
      result = reader.read(live, [], now: fractional, stops: ms_stops)[:totals]
      expect((result[:active_seconds] + result[:stopped_seconds]) - result[:clock_seconds]).to be_within(0.001).of(0)
    end

    it "carries the events reader's string warnings as event_line_skipped" do
      text = "Line 4 of the history is not a JSON object; skipped."
      expect(reader.read(run, events, now: now, warnings: [text])[:warnings]).to eq([{code: "event_line_skipped", message: text}])
    end

    it "makes a gate span from events with actor and note, and none from the gate's reason entry" do
      expect(kind("gate")).to match([include(step: "build", attempt: 1, started_at: t("10:05:00"), ended_at: t("10:06:00"), actor: "person", note: "fine")])
      expect(kind("wait").map { |span| span[:code] }).to eq(%w[failed_check retry_backoff])
    end

    it "makes two gate spans for a gate rejected then waited on again, the last open" do
      more = events + [
        {"n" => 4, "ts" => t("10:06:10"), "type" => "gate_waiting", "step" => "build"},
        {"n" => 5, "ts" => t("10:06:20"), "type" => "gate_rejected", "step" => "build", "actor" => "person"},
        {"n" => 6, "ts" => t("10:06:30"), "type" => "gate_waiting", "step" => "build"}
      ]
      gates = reader.read(run, more, now: now)[:spans].select { |span| span[:kind] == "gate" }
      expect(gates.map { |gate| gate[:ended_at] }).to eq([t("10:06:00"), t("10:06:20"), nil])
      expect(gates.map { |gate| gate[:span_id] }.uniq.size).to eq(3)
    end

    it "closes a sibling's open gate span on the group_rearmed that dropped its gate, leaving another step's open" do
      more = events + [
        {"n" => 4, "ts" => t("10:06:10"), "type" => "gate_waiting", "step" => "build"},
        {"n" => 5, "ts" => t("10:06:10"), "type" => "gate_waiting", "step" => "other"},
        {"n" => 6, "ts" => t("10:06:40"), "type" => "group_rearmed", "group" => "g", "steps" => %w[build], "dropped_gates" => %w[build], "actor" => "person"}
      ]
      gates = reader.read(run, more, now: now)[:spans].select { |span| span[:kind] == "gate" }
      expect(gates.map { |gate| [gate[:step], gate[:ended_at]] }).to eq([["build", t("10:06:00")], ["build", t("10:06:40")], ["other", nil]])
      expect(reader.read(run, more, now: now)[:transitions].last).to include(type: "group_rearmed", kind: "marker")
    end

    it "makes stall and downtime spans" do
      expect(kind("stall")).to match([include(code: "stalled", step: "build", started_at: t("10:08:30"))])
      expect(kind("downtime")).to match([include(code: "downtime", started_at: t("10:07:00"), ended_at: t("10:08:00"))])
    end

    it "gives each span a stable 16 hex span_id, different per span" do
      ids = spans.map { |span| span[:span_id] }
      expect(ids).to all(match(/\A\h{16}\z/))
      expect(ids.uniq.size).to eq(ids.size)
      expect(reader.read(run, events, now: now, stops: stops)[:spans].map { |span| span[:span_id] }).to eq(ids)
    end

    it "gives a run-owned wait with no step a nil step" do
      old = {"id" => "wr_w", "started_at" => t("10:00:00"), "reasons" => [{"code" => "parked", "since" => t("10:00:00")}],
             "steps" => {"a" => {"attempts" => [{"n" => 1, "started_at" => t("10:00:00")}]}}}
      expect(reader.read(old, [], now: now)[:spans].find { |span| span[:kind] == "wait" }).to include(step: nil, attempt: nil, code: "parked")
    end

    it "reports attempt-owned retry_backoff in machine_waiting_seconds and failed_check in waiting_seconds" do
      expect(totals[:machine_waiting_seconds]).to eq("retry_backoff" => 60.0)
      expect(totals[:waiting_seconds]).to include("failed_check" => 60.0, "stalled" => 30.0, "gate" => 60.0, "downtime" => 60.0)
    end

    it "reports an unowned waiting_lock in machine_waiting_seconds" do
      held = run.merge("reasons" => [{"code" => "waiting_lock", "step" => "build", "since" => t("09:59:00"), "until" => t("10:00:00")}])
      expect(reader.read(held, [], now: now)[:totals][:machine_waiting_seconds]).to include("waiting_lock" => 60.0)
    end

    it "counts the gate under gate only, with no waiting_you bucket" do
      expect(totals[:waiting_seconds]).not_to have_key("waiting_you")
    end

    it "keeps active + stopped == clock, and the buckets sum to stopped when stops do not overlap" do
      expect(totals).to include(wall_seconds: 600.0, clock_seconds: 600.0, active_seconds: 390.0, stopped_seconds: 210.0)
      expect(totals[:active_seconds] + totals[:stopped_seconds]).to eq(totals[:clock_seconds])
      expect(totals[:waiting_seconds].values.sum).to eq(totals[:stopped_seconds])
    end

    it "keeps a waiting_you entry that has no gate span as a waiting_you wait" do
      other = run.merge("reasons" => [])
      other["steps"]["build"]["attempts"][0]["reasons"] = [{"code" => "waiting_you", "since" => t("10:05:00"), "until" => t("10:06:00")}]
      result = reader.read(other, [events.first], now: now, stops: stops)
      expect(result[:spans].count { |span| span[:kind] == "wait" && span[:code] == "waiting_you" }).to eq(1)
      expect(result[:totals][:waiting_seconds]).to include("waiting_you" => 60.0)
    end

    it "keeps a waiting_you entry on the same step that starts after the gate was approved" do
      other = run.merge("reasons" => [])
      other["steps"]["build"]["attempts"][0]["reasons"] = [{"code" => "waiting_you", "since" => t("10:06:30"), "until" => t("10:07:00")}]
      result = reader.read(other, events, now: now, stops: stops)
      expect(result[:spans].count { |span| span[:kind] == "wait" && span[:code] == "waiting_you" }).to eq(1)
      expect(result[:totals][:waiting_seconds]).to include("waiting_you" => 30.0)
    end

    it "keeps a waiting_you entry on another step while a gate is open on a different step" do
      other = run.merge("reasons" => [])
      other["steps"]["build"]["attempts"][0]["reasons"] = []
      other["steps"]["ship"] = {"attempts" => [{"n" => 1, "reasons" => [{"code" => "waiting_you", "since" => t("10:05:10"), "until" => t("10:05:40")}]}]}
      result = reader.read(other, events, now: now, stops: stops)
      expect(result[:spans].count { |span| span[:kind] == "wait" && span[:code] == "waiting_you" && span[:step] == "ship" }).to eq(1)
    end

    it "keeps the waiting_you entry when the gate events were lost" do
      result = reader.read(run, [events.first], now: now, stops: stops)
      expect(result[:spans].select { |span| span[:kind] == "gate" }).to be_empty
      expect(result[:totals][:waiting_seconds]).to include("waiting_you" => 60.0)
    end

    it "keeps the identity with a pause that overlaps a stall, so the buckets can exceed stopped" do
      overlap = run.dup
      overlap["reasons"] = [{"code" => "paused", "since" => t("10:08:40"), "until" => t("10:09:30")}]
      result = reader.read(overlap, events, now: now, stops: stops)[:totals]
      expect(result[:active_seconds] + result[:stopped_seconds]).to eq(result[:clock_seconds])
      expect(result[:waiting_seconds].values.sum).to be > result[:stopped_seconds]
    end

    it "runs wall and clock to now for a live run" do
      live = run.merge("state" => "running", "ended_at" => nil)
      result = reader.read(live, [], now: Time.utc(2026, 10, 1, 10, 20, 0))[:totals]
      expect(result).to include(wall_seconds: 1200.0, clock_seconds: 1200.0)
    end

    it "gives nil clock figures and buckets for a run that never started an attempt" do
      result = reader.read({"id" => "wr_e"}, [], now: now)[:totals]
      expect(result).to include(wall_seconds: nil, clock_seconds: nil, active_seconds: nil, stopped_seconds: nil, waiting_seconds: nil,
        machine_waiting_seconds: nil, attempts: 0)
    end

    it "agrees with WorkflowAttempts#read on the attempt count" do
      rows = Workspace::WorkflowAttempts.new.read(run)["attempts"]
      expect(totals[:attempts]).to eq(rows.size)
      expect(totals[:loops]).to eq(2)
      expect(kind("attempt").map { |span| [span[:started_at], span[:ended_at]] }).to eq(rows.map { |row| [row["started_at"], row["ended_at"]] })
    end

    it "agrees with WorkflowStats token sums over the same fixture" do
      stored = run.merge("workflow" => "rpiv", "workspace" => "app", "created_at" => t("10:00:00"),
        "definition" => {"steps" => [{"id" => "build"}]})
      store = instance_double(Workspace::WorkflowRunStore, events: {"events" => [], "truncated" => false})
      stats = Workspace::WorkflowStats.new(store: store, clock: -> { now })
      plan = stats.read(workflow: "rpiv", loaded: {"runs" => [Workspace::WorkflowRun.new(stored)], "unreadable" => 0, "undated" => 0})["steps"].first
      expect(totals[:tokens]).to eq(total: 320, in: 200, out: 100, cache: 20)
      expect(plan["tokens"]).to include("mean" => totals[:tokens][:total], "runs_counted" => 1)
    end

    it "does not count a going or not_delivered attempt's tokens" do
      live = run.merge("state" => "running", "ended_at" => nil)
      live["steps"] = {"build" => {"attempts" => run["steps"]["build"]["attempts"] + [{"n" => 2, "outcome" => "not_delivered", "usage" => nil}, {"n" => 3, "usage" => nil}]}}
      expect(reader.read(live, [], now: now)[:totals][:tokens]).to eq(total: 320, in: 200, out: 100, cache: 20)
    end

    it "puts no tokens on the row or span of a redelivered attempt, so row tokens never exceed the totals" do
      redelivered = run.merge("steps" => {"build" => {"attempts" => [
        {"n" => 1, "started_at" => t("10:00:00"), "ended_at" => t("10:05:00"), "outcome" => "passed", "usage" => usage},
        {"n" => 2, "started_at" => t("10:05:00"), "ended_at" => t("10:09:00"), "outcome" => "passed", "redelivered" => true, "usage" => usage}
      ]}})
      evs = [{"n" => 1, "ts" => t("10:05:00"), "type" => "step_passed", "step" => "build", "attempt" => 1},
        {"n" => 2, "ts" => t("10:09:00"), "type" => "step_passed", "step" => "build", "attempt" => 2}]
      result = reader.read(redelivered, evs, now: now)
      expect(result[:transitions].map { |row| row[:tokens]&.fetch(:total) }).to eq([160, nil])
      expect(result[:spans].select { |span| span[:kind] == "attempt" }.map { |span| span[:tokens]&.fetch(:total) }).to eq([160, nil])
      expect(result[:totals][:tokens][:total]).to eq(160)
    end

    it "does not crash on a run whose steps are not a Hash, and warns run_steps_unreadable" do
      [["x"], 5, "text"].each do |steps|
        result = reader.read({"id" => "wr_bad", "started_at" => t("10:00:00"), "steps" => steps}, [], now: now)
        expect(result[:totals]).to include(clock_seconds: nil, active_seconds: nil, stopped_seconds: nil, waiting_seconds: nil)
        expect(result[:spans].map { |span| span[:kind] }).not_to include("wait", "stall")
        expect(result[:warnings].map { |warning| warning[:code] }).to eq(["run_steps_unreadable"])
      end
    end

    it "gives null token totals, never 0, when a counted attempt has null usage" do
      old = {"id" => "wr_n", "steps" => {"a" => {"attempts" => [{"n" => 1, "outcome" => "passed", "usage" => usage}, {"n" => 2, "outcome" => "passed", "usage" => nil}]}}}
      expect(reader.read(old, [], now: now)[:totals][:tokens]).to eq(total: nil, in: nil, out: nil, cache: nil)
    end

    it "warns events_lost for a degraded run and passes the caller's warnings through" do
      errors = [{"type" => "step_passed", "errno" => "ENOSPC"}, {"type" => "step_passed"}, {"type" => "gate_waiting"}]
      bad = {code: "bad_line", line: 3}
      result = reader.read(run, events, now: now, event_errors: errors, warnings: [bad])
      expect(result[:warnings]).to match([bad, include(code: "events_lost", message: a_kind_of(String), count: 3, types: %w[step_passed gate_waiting])])
      expect(trace[:warnings]).to eq([])
    end
  end

  describe "text and table formatting" do
    let(:run) do
      {"id" => "wr_t", "state" => "passed", "started_at" => "2026-11-01T09:00:00Z", "ended_at" => "2026-11-01T09:30:00Z",
       "definition" => {"steps" => [{"id" => "plan"}]},
       "steps" => {"plan" => {"state" => "passed", "attempts" => [{"n" => 1, "started_at" => "2026-11-01T09:00:00Z", "ended_at" => "2026-11-01T09:10:00Z", "outcome" => "passed", "usage" => {"input_tokens" => 20000, "output_tokens" => 0}}]}}}
    end
    let(:events) do
      [{"n" => 1, "ts" => "2026-11-01T09:00:00Z", "type" => "run_started", "from_state" => "pending", "to_state" => "running"},
        {"n" => 2, "ts" => "2026-11-01T09:10:00Z", "type" => "gate_waiting", "step" => "plan", "attempt" => 1},
        {"n" => 3, "ts" => "2026-11-01T09:22:00Z", "type" => "gate_approved", "step" => "plan", "attempt" => 1, "actor" => "person"},
        {"n" => 4, "ts" => "2026-11-01T09:30:00Z", "type" => "step_passed", "step" => "plan", "attempt" => 1, "from_state" => "running", "to_state" => "passed", "actor" => "engine", "cause" => "checks_passed"}]
    end
    let(:doc) { described_class.new.read(run, events, now: now) }
    let(:lines) { described_class.text_lines(doc) }

    it "prints a row per event with actor, cause, duration and tokens" do
      expect(lines).to include("09:30:00  plan#1 running -> passed  actor=engine  cause=checks_passed  480s  20k tok")
    end

    it "prints a waited line after the row that opens the gap, only past the threshold" do
      waited = lines.index("          waited 12m (gate)")
      expect(waited).not_to be_nil
      expect(lines[waited - 1]).to start_with("09:10:00")
      expect(lines[waited + 1]).to start_with("09:22:00")
    end

    it "omits a short wait" do
      short = events.map { |event| (event["n"] == 3) ? event.merge("ts" => "2026-11-01T09:10:30Z") : event }
      expect(described_class.text_lines(described_class.new.read(run, short, now: now)).grep(/waited/)).to eq([])
    end

    it "ends with totals, a reasons-overlap note and no zeros for unknowns" do
      expect(lines).to include("wall:    30m", "attempts: 1")
      expect(lines.grep(/^waiting: gate 12m .*overlap/)).not_to be_empty
      empty = described_class.new.read({"id" => "wr_e", "steps" => {}}, [], now: now)
      expect(described_class.text_lines(empty)).to include("wall:    -", "tokens:  -", "active:  -")
    end

    it "prints loops as none when empty and as edge counts otherwise" do
      expect(described_class.totals_lines({loops: {}})).to include("loops:   none")
      expect(described_class.totals_lines({loops: {"a->b" => 2, "c->d" => 1}})).to include("loops:   a->b 2, c->d 1")
    end

    it "gives table rows matching the header, with - for unknowns" do
      rows = described_class.table_rows(doc)
      expect(rows.first(1)).to eq([%w[1 2026-11-01T09:00:00Z transition - pending running - - - -]])
      expect(rows.all? { |row| row.size == described_class::TABLE_HEADER.size }).to be(true)
    end
  end

  describe ".format_tokens" do
    it "uses the k and M tiers" do
      expect([950, 20_000, 1_500_000].map { |count| described_class.format_tokens(count) }).to eq(%w[950 20k 1.5M])
      expect(described_class.token_text({total: 1_500_000})).to eq("1.5M")
    end
  end
end
