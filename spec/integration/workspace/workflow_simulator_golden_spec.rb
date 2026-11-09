require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Pins the simulator's transcript over each shipped preset, with the simulator's fixed run id and clock,
# so a change to how a run is stored or changed shows up as a difference here. Regenerate a fixture
# deliberately with GOLDEN_UPDATE=1.
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
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace::WorkflowEngine.new(**parts) }, tmpdir: tmpdir) }
  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden") }

  after { FileUtils.rm_rf(base) }

  def transcript(preset)
    path = File.join(PROJECT_ROOT, "lib", "workflows", "#{preset}.yml")
    lookup = lambda do |id, below: nil|
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
    definition = Workspace::WorkflowDefinition.parse(File.read(path), id: preset, source: "builtin", path: path, parent_lookup: lookup)
    script = Workspace::WorkflowSimScript.parse("steps: {}\n", definition: definition.to_h, source: "golden.yml")
    inputs = definition.to_h["inputs"].select { |_, each| each["required"] }.transform_values { "golden" }
    result = simulator.call(definition: definition, script: script, inputs: inputs)
    text = JSON.pretty_generate(result) + "\n"
    text.gsub(base, "<TMP>").gsub(/\b[0-9a-f]{40,64}\b/, "<SHA>")
  end

  %w[rpiv rpiv-auto-approve pr-feedback investigate explore].each do |preset|
    it "reproduces the #{preset} transcript byte for byte" do
      text = transcript(preset)
      golden = File.join(fixtures, "#{preset}.json")
      File.write(golden, text) if ENV["GOLDEN_UPDATE"]

      expect(File.read(golden)).to eq(text)
      expect(transcript(preset)).to eq(text)
    end
  end
end
