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

    it "is frozen and holds placeholders for the later parts" do
      expect(trace).to be_frozen
      expect(trace.values_at(:spans, :totals, :warnings)).to eq([[], {}, []])
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
      expect(rows[2][:tokens]).to eq({in: 10, out: 5, cache: 2})
      expect(rows[4][:tokens]).to be_nil
    end

    it "reads a WorkflowRun as well as a Hash" do
      expect(described_class.new.read(Workspace::WorkflowRun.new(run), events, now: now)[:transitions]).to eq(rows)
    end
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
    expect(rows[1][:tokens]).to eq({in: 1, out: 2, cache: 3})
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
    expect(rows.map { |row| row[:tokens] }).to eq([nil, nil, {in: 1, out: 2, cache: 3}])
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
end
