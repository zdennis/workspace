require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Pins the simulator's transcript over each shipped preset, with the simulator's fixed run id and clock,
# so a change to how a run is stored or changed shows up as a difference here. Regenerate a fixture
# deliberately with GOLDEN_UPDATE=1. A fixture with a `<name>.script.yml` beside its fixture plays that script (v2's
# reviewers write nothing without one); the others play an empty one.
RSpec.describe Workspace::WorkflowSimulator, "golden transcripts of the presets" do
  let(:base) { Dir.mktmpdir("wf-golden") }
  let(:tmpdir) do
    lambda do |prefix, &block|
      dir = Dir.mktmpdir(prefix, base)
      block.call(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace.build_workflow_engine(**parts) }, tmpdir: tmpdir) }
  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden") }

  after { FileUtils.rm_rf(base) }

  def transcript(name, preset = name)
    definition = PresetSimulation.definition(preset)
    scripted = File.join(fixtures, "#{name}.script.yml")
    script = Workspace::WorkflowSimScript.parse(File.file?(scripted) ? File.read(scripted) : "steps: {}\n", definition: definition.to_h, source: "golden.yml")
    PresetSimulation.transcript(simulator.call(definition: definition, script: script, inputs: PresetSimulation.inputs(definition)), base)
  end

  {"rpiv" => "rpiv", "rpiv-auto-approve" => "rpiv-auto-approve", "rpiv-auto-approve-v2" => "rpiv-auto-approve-v2", "pr-feedback" => "pr-feedback",
   "investigate" => "investigate", "explore" => "explore", "bugfix" => "bugfix", "rpiv-pause" => "rpiv"}.each do |name, preset|
    it "reproduces the #{name} transcript byte for byte" do
      text = transcript(name, preset)
      golden = File.join(fixtures, "#{name}.json")
      File.write(golden, text) if ENV["GOLDEN_UPDATE"]

      expect(File.read(golden)).to eq(text)
      expect(transcript(name, preset)).to eq(text)
    end
  end
end
