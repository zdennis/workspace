require "stringio"
require "json"

RSpec.describe Workspace::Commands::Statusline do
  let(:context_store) { instance_double(Workspace::ContextStore, record: nil) }
  let(:renderer) { instance_double(Workspace::StatuslineRenderer, render: "built-in line") }
  let(:global_config) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_config) }
  let(:output) { StringIO.new }
  let(:env) { {} }

  def build(input_data, **overrides)
    described_class.new(
      context_store: context_store,
      renderer: renderer,
      project_settings: project_settings,
      env: env,
      input: StringIO.new(input_data),
      output: output,
      delegate_timeout: 1,
      **overrides
    )
  end

  it "records the reading and prints the built-in line" do
    env["TMUX_PANE"] = "%1"
    payload = {"context_window" => {"used_percentage" => 42}, "session_id" => "s1", "cwd" => "/tmp/proj"}

    expect(context_store).to receive(:record).with(
      pct: 42, pane_id: "%1", pid: nil, session_id: "s1", cwd: "/tmp/proj"
    )

    build(JSON.generate(payload)).call
    expect(output.string).to eq("built-in line")
  end

  it "records by CLAUDE_PID when TMUX_PANE isn't set" do
    env["CLAUDE_PID"] = "555"
    payload = {"context_window" => {"used_percentage" => 10}}

    expect(context_store).to receive(:record).with(
      pct: 10, pane_id: nil, pid: "555", session_id: nil, cwd: nil
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

  it "never records a reading when used_percentage is absent" do
    expect(context_store).not_to receive(:record)
    build(JSON.generate({"model" => {"display_name" => "x"}})).call
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

  context "when the delegate command doesn't exist" do
    let(:global_config) { {"statusline" => {"command" => "/no/such/command-xyz"}} }

    it "falls back to the built-in renderer instead of raising" do
      expect { build(JSON.generate({})).call }.not_to raise_error
      expect(output.string).to eq("built-in line")
    end
  end
end
