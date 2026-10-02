require "stringio"
require "json"

RSpec.describe Workspace::Commands::Statusline do
  let(:context_store) { instance_double(Workspace::ContextStore, record: nil) }
  let(:renderer) { instance_double(Workspace::StatuslineRenderer, render: "built-in line") }
  let(:global_config) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_config) }
  let(:output) { StringIO.new }
  let(:env) { {} }
  let(:lock_holder) { instance_double(Workspace::LockHolder, start_time: "Thu Sep 26 09:12:03 2026") }

  def build(input_data, **overrides)
    described_class.new(
      context_store: context_store,
      renderer: renderer,
      project_settings: project_settings,
      env: env,
      input: StringIO.new(input_data),
      output: output,
      delegate_timeout: 1,
      lock_holder: lock_holder,
      **overrides
    )
  end

  it "records the reading and prints the built-in line" do
    env["TMUX_PANE"] = "%1"
    payload = {"context_window" => {"used_percentage" => 42}, "session_id" => "s1", "cwd" => "/tmp/proj"}

    expect(context_store).to receive(:record).with(
      pct: 42, pane_id: "%1", pid: nil, started: nil, session_id: "s1", cwd: "/tmp/proj",
      cost_usd: nil, duration_ms: nil, model: nil
    )

    build(JSON.generate(payload)).call
    expect(output.string).to eq("built-in line")
  end

  it "records cost, duration, and model from the payload" do
    env["TMUX_PANE"] = "%1"
    payload = {"context_window" => {"used_percentage" => 42}, "model" => {"display_name" => "Opus 5.5"},
               "cost" => {"total_cost_usd" => 1.25, "total_duration_ms" => 90_000}}

    expect(context_store).to receive(:record).with(
      hash_including(cost_usd: 1.25, duration_ms: 90_000, model: "Opus 5.5")
    )

    build(JSON.generate(payload)).call
  end

  it "still records the percentage when cost or model is not an object" do
    env["TMUX_PANE"] = "%1"
    payload = {"context_window" => {"used_percentage" => 42}, "cost" => "free", "model" => "opus"}

    expect(context_store).to receive(:record).with(hash_including(pct: 42, cost_usd: nil, duration_ms: nil, model: nil))

    build(JSON.generate(payload)).call
  end

  it "records by CLAUDE_PID when TMUX_PANE isn't set, with its process start time" do
    env["CLAUDE_PID"] = "555"
    payload = {"context_window" => {"used_percentage" => 10}}

    expect(lock_holder).to receive(:start_time).with(555).and_return("Thu Sep 26 09:12:03 2026")
    expect(context_store).to receive(:record).with(
      pct: 10, pane_id: nil, pid: "555", started: "Thu Sep 26 09:12:03 2026", session_id: nil, cwd: nil,
      cost_usd: nil, duration_ms: nil, model: nil
    )

    build(JSON.generate(payload)).call
  end

  it "records a nil start time when the process table can't be read" do
    env["CLAUDE_PID"] = "555"
    payload = {"context_window" => {"used_percentage" => 10}}
    allow(lock_holder).to receive(:start_time).and_raise(Workspace::Error, "ps failed")

    expect(context_store).to receive(:record).with(
      pct: 10, pane_id: nil, pid: "555", started: nil, session_id: nil, cwd: nil,
      cost_usd: nil, duration_ms: nil, model: nil
    )

    build(JSON.generate(payload)).call
  end

  it "exits 0 and prints something for empty stdin" do
    result = build("").call
    expect(result).to eq(exit_code: 0)
    expect(output.string).not_to be_empty
  end

  it "exits 0 and prints something for invalid JSON" do
    result = build("{not json").call
    expect(result).to eq(exit_code: 0)
    expect(output.string).not_to be_empty
  end

  it "records a nil-pct reading when used_percentage is absent (right after /clear)" do
    expect(context_store).to receive(:record).with(hash_including(pct: nil))
    build(JSON.generate({"model" => {"display_name" => "x"}})).call
  end

  it "records a nil-pct reading when used_percentage is JSON null" do
    expect(context_store).to receive(:record).with(hash_including(pct: nil))
    payload = {"context_window" => {"used_percentage" => nil}, "session_id" => "sess-1"}
    build(JSON.generate(payload)).call
  end

  it "swallows a storage error and still renders" do
    allow(context_store).to receive(:record).and_raise(StandardError, "disk full")
    payload = {"context_window" => {"used_percentage" => 1}}

    result = build(JSON.generate(payload)).call
    expect(result).to eq(exit_code: 0)
    expect(output.string).to eq("built-in line")
  end

  context "with statusline.command configured" do
    let(:global_config) { {"statusline" => {"command" => "cat"}} }

    it "prints the delegate's stdout instead of the built-in line" do
      result = build(JSON.generate({"a" => 1})).call
      expect(result).to eq(exit_code: 0)
      expect(output.string).to eq(JSON.generate({"a" => 1}))
    end
  end

  context "when the delegate times out" do
    let(:global_config) { {"statusline" => {"command" => "sleep 5"}} }

    it "falls back to the built-in renderer instead of hanging" do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      build(JSON.generate({})).call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(elapsed).to be < 3
      expect(output.string).to eq("built-in line")
    end
  end

  context "when the delegate exits non-zero" do
    let(:global_config) { {"statusline" => {"command" => "false"}} }

    it "falls back to the built-in renderer" do
      build(JSON.generate({})).call
      expect(output.string).to eq("built-in line")
    end
  end

  context "when the delegate prints more than the output cap" do
    let(:global_config) { {"statusline" => {"command" => "yes | head -c 200000"}} }

    it "truncates the delegate's stdout to the cap" do
      build(JSON.generate({})).call
      expect(output.string.bytesize).to eq(described_class::MAX_DELEGATE_OUTPUT_BYTES)
    end
  end

  context "when the delegate command doesn't exist" do
    let(:global_config) { {"statusline" => {"command" => "/no/such/command-xyz"}} }

    it "falls back to the built-in renderer instead of raising" do
      expect { build(JSON.generate({})).call }.not_to raise_error
      expect(output.string).to eq("built-in line")
    end
  end
end
