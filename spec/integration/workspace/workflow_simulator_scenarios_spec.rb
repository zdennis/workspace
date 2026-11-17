require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

module WorkflowSimulatorScenarios
  PRESETS = %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2 pr-feedback investigate explore].freeze
  SCENARIOS = %w[check-retry gate-reject review-reject].freeze
  NOT_APPLICABLE = {
    ["rpiv", "review-reject"] => "no step has a review:",
    ["rpiv-auto-approve", "gate-reject"] => "no step has a gate",
    ["rpiv-auto-approve", "review-reject"] => "its reviews are plain steps, not review: rounds",
    ["rpiv-auto-approve-v2", "gate-reject"] => "no step has a gate",
    ["pr-feedback", "check-retry"] => "no step has a status: check",
    ["pr-feedback", "review-reject"] => "no step has a review:",
    ["investigate", "check-retry"] => "no step has a status: check",
    ["investigate", "review-reject"] => "no step has a review:",
    ["explore", "check-retry"] => "no step has a status: check",
    ["explore", "review-reject"] => "no step has a review:"
  }.freeze
end

# Pins the simulator's transcript for each scenario script `<preset>.<scenario>.script.yml` in the golden fixtures,
# beside its `<preset>.<scenario>.json`. Regenerate a fixture deliberately with GOLDEN_UPDATE=1. Every preset and
# scenario pair has a script or an entry in NOT_APPLICABLE saying why not, so a new preset or scenario cannot go
# unplayed unnoticed.
RSpec.describe Workspace::WorkflowSimulator, "scenario transcripts of the presets" do
  let(:base) { Dir.mktmpdir("wf-scenario") }
  let(:tmpdir) do
    lambda do |prefix, &block|
      dir = Dir.mktmpdir(prefix, base)
      block.call(dir)
    end
  end
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace.build_workflow_engine(**parts) }, tmpdir: tmpdir) }
  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden") }

  after { FileUtils.rm_rf(base) }

  def self.script_names
    Dir.glob(File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden", "*.*.script.yml")).map { |path| File.basename(path, ".script.yml") }.sort
  end

  def split(name)
    name.split(".", 2)
  end

  def play(preset, scenario)
    definition = PresetSimulation.definition(preset)
    script = Workspace::WorkflowSimScript.parse(File.read(File.join(fixtures, "#{preset}.#{scenario}.script.yml")), definition: definition.to_h, source: "golden.yml")
    simulator.call(definition: definition, script: script, inputs: PresetSimulation.inputs(definition))
  end

  def transcript(preset, scenario)
    PresetSimulation.transcript(play(preset, scenario), base)
  end

  # The pairs left without a script or an n/a entry, both, and the scripts and entries naming a preset or scenario not listed.
  def problems(names, not_applicable)
    pairs = names.map { |name| split(name) }
    missing = WorkflowSimulatorScenarios::PRESETS.product(WorkflowSimulatorScenarios::SCENARIOS).reject { |pair| pairs.include?(pair) || not_applicable.key?(pair) }
    both = pairs.select { |pair| not_applicable.key?(pair) }
    unknown = (pairs + not_applicable.keys).reject { |preset, scenario| WorkflowSimulatorScenarios::PRESETS.include?(preset) && WorkflowSimulatorScenarios::SCENARIOS.include?(scenario) }
    missing.map { |pair| "#{pair.join(" ")}: has neither a script nor a NOT_APPLICABLE entry" } +
      both.map { |pair| "#{pair.join(" ")}: has both a script and a NOT_APPLICABLE entry" } +
      unknown.map { |pair| "#{pair.join(" ")}: names a preset or scenario that is not listed" }
  end

  it "has a script or a reason for every preset and scenario pair" do
    expect(problems(self.class.script_names, WorkflowSimulatorScenarios::NOT_APPLICABLE)).to eq([])
  end

  it "names the pair that has neither, both, or an unlisted name" do
    names = self.class.script_names
    expect(problems(names - ["rpiv.check-retry"], WorkflowSimulatorScenarios::NOT_APPLICABLE)).to eq(["rpiv check-retry: has neither a script nor a NOT_APPLICABLE entry"])
    expect(problems(names + ["rpiv.review-reject"], WorkflowSimulatorScenarios::NOT_APPLICABLE)).to eq(["rpiv review-reject: has both a script and a NOT_APPLICABLE entry"])
    expect(problems(names + ["rpiv.nonsense"], WorkflowSimulatorScenarios::NOT_APPLICABLE)).to eq(["rpiv nonsense: names a preset or scenario that is not listed"])
    expect(problems(names, WorkflowSimulatorScenarios::NOT_APPLICABLE.merge(["bogus", "check-retry"] => "x"))).to eq(["bogus check-retry: names a preset or scenario that is not listed"])
  end

  script_names.each do |name|
    it "reproduces the #{name} transcript byte for byte" do
      preset, scenario = split(name)
      text = transcript(preset, scenario)
      golden = File.join(fixtures, "#{name}.json")
      File.write(golden, text) if ENV["GOLDEN_UPDATE"]

      expect(File.read(golden)).to eq(text)
      # A second play proves the transcript is deterministic, not only that it matches.
      expect(transcript(preset, scenario)).to eq(text)
    end
  end

  it "hands the rejection note to the next attempt of rpiv's plan" do
    play("rpiv", "gate-reject")

    prompts = Dir.glob(File.join(base, "**", "steps", "plan.2.prompt.md"), File::FNM_DOTMATCH)
    expect(prompts).not_to be_empty
    expect(prompts.map { |file| File.read(file) }.join).to include("the findings miss the flaky retry path, cover it")
  end
end
