require "spec_helper"

RSpec.describe Workspace::WorkflowConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  it "defaults to binding, orchestrator and commits" do
    expect(config.default_packs).to eq(%w[binding orchestrator commits])
  end

  it "reads workflows.defaults.include as `config set` writes it, or as a list written by hand" do
    global["workflows"] = {"defaults" => {"include" => "binding, commits"}}
    expect(config.default_packs).to eq(%w[binding commits])

    global["workflows"] = {"defaults" => {"include" => %w[binding review]}}
    expect(config.default_packs).to eq(%w[binding review])
  end

  it "uses the default for a value `config set` would refuse" do
    ["", "Not A Pack!", [], [1], {"a" => 1}].each do |bad|
      global["workflows"] = {"defaults" => {"include" => bad}}
      expect(config.default_packs).to eq(%w[binding orchestrator commits])
    end
  end

  it "lets a config file that can't be parsed raise" do
    allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

    expect { config.default_packs }.to raise_error(Workspace::ConfigParseError)
  end

  it "reads the global value for a worktree without opening the worktree's or project's file" do
    global["workflows"] = {"defaults" => {"include" => "binding, review"}}
    allow(project_settings).to receive(:load).and_raise(Workspace::ConfigParseError.new("/c/app.yml", "bad"))

    expect(config.default_packs(workspace: "app.worktree-x")).to eq(%w[binding review])
  end

  describe "#default_stall" do
    def stall(value)
      global["workflows"] = {"default_stall" => value}
      config.default_stall
    end

    it "is 600 seconds when unset" do
      expect(config.default_stall).to eq(600)
    end

    it "reads a duration" do
      expect(stall("15m")).to eq(900)
    end

    it "is nil for off and 0" do
      expect(stall("off")).to be_nil
      expect(stall("0")).to be_nil
    end

    it "is nil for an unquoted off, which YAML reads as false, and 600 for true" do
      expect(stall(false)).to be_nil
      expect(stall(true)).to eq(600)
    end

    it "is 600 for a value `config set` would refuse" do
      expect(stall("soon")).to eq(600)
      expect(stall("-1")).to eq(600)
    end

    it "is 600 when the global file can't be parsed" do
      allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

      expect(config.default_stall).to eq(600)
    end
  end

  describe "#turn_failed_after" do
    def after(value)
      global["workflows"] = {"turn_failed_after" => value}
      config.turn_failed_after
    end

    it "is 1800 seconds when unset" do
      expect(config.turn_failed_after).to eq(1800)
    end

    it "reads a duration" do
      expect(after("10m")).to eq(600)
    end

    it "is nil for off and 0" do
      expect(after("off")).to be_nil
      expect(after("0")).to be_nil
    end

    it "is 1800 for a value `config set` would refuse" do
      expect(after("soon")).to eq(1800)
    end

    it "is 1800 when the global file can't be parsed" do
      allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

      expect(config.turn_failed_after).to eq(1800)
    end
  end

  describe "#downtime_after" do
    def after(value)
      global["workflows"] = {"downtime_after" => value}
      config.downtime_after
    end

    it "is 120 seconds when unset" do
      expect(config.downtime_after).to eq(120)
    end

    it "reads a duration" do
      expect(after("5m")).to eq(300)
    end

    it "is 120 for a value under 30s, off, or one `config set` would refuse" do
      expect(%w[10s off soon].map { |v| after(v) }).to eq([120, 120, 120])
    end

    it "is 120 when the global file can't be parsed" do
      allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

      expect(config.downtime_after).to eq(120)
    end
  end

  describe "#infra_retry_max" do
    def max(value)
      global["workflows"] = {"infra_retry" => {"max" => value}}
      config.infra_retry_max
    end

    it "is 2 when unset" do
      expect(config.infra_retry_max).to eq(2)
    end

    it "reads a set value" do
      expect(max(5)).to eq(5)
      expect(max("3")).to eq(3)
    end

    it "reads 0, which turns restarts off" do
      expect(max(0)).to eq(0)
    end

    it "is 2 for a value `config set` would refuse" do
      expect([-1, "many", "", 1.5].map { |v| max(v) }).to eq([2, 2, 2, 2])
    end

    it "is 2 when the global file can't be parsed" do
      allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

      expect(config.infra_retry_max).to eq(2)
    end
  end
end
