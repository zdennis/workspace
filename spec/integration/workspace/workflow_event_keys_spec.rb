require "spec_helper"
require "tmpdir"
require "fileutils"

# Plays every shipped preset and every script under spec/fixtures/workflow_event_keys through the simulator and
# checks the keys of each event the real engine queued. Cancel and resume are not in a script (the simulator ends
# when a run waits for a person), so workflow_engine_spec.rb covers their events.
module EventKeysSpec
  # The engine's state-moving types a simulation can reach. The rest are covered in workflow_engine_spec.rb:
  # run_cancelled, run_resumed (a simulation ends when the run waits for a person), step_interrupted, run_timed_out, step_stalled, step_recovered, lock_*, ask_*, *_extended, budget_spent,
  # resume_parked*, guard_*, review_no_change, review_delivery_failed, review_rounds_spent, step_retry_blocked (needs a lost
  # pane, and the simulator's pane is always there).
  REQUIRED_TYPES = %w[
    run_started step_dispatching step_dispatched step_reported step_passed step_failed step_looped
    step_checks_passed check_finished gate_waiting gate_approved gate_rejected
    step_retry_started review_started review_ended review_rerun review_retry run_completed
  ].freeze

  FIXTURES = File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_event_keys")
  PRESETS = File.join(PROJECT_ROOT, "lib", "workflows")
  GOLDEN = File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden")
end

RSpec.describe Workspace::WorkflowSimulator, "event keys" do
  let(:base) { Dir.mktmpdir("wf-event-keys") }
  let(:tmpdir) do
    lambda do |prefix, &block|
      dir = Dir.mktmpdir(prefix, base)
      block.call(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace.build_workflow_engine(**parts) }, tmpdir: tmpdir) }

  after { FileUtils.rm_rf(base) }

  def definition_at(path, id)
    lookup = lambda do |parent, below: nil|
      file = File.join(EventKeysSpec::PRESETS, "#{parent}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
    Workspace::WorkflowDefinition.parse(File.read(path), id: id, source: "builtin", path: path, parent_lookup: lookup, import_lookup: PresetSimulation.import_lookup)
  end

  def play(definition_path, id, script_path)
    definition = definition_at(definition_path, id)
    text = (script_path && File.file?(script_path)) ? File.read(script_path) : "steps: {}\n"
    script = Workspace::WorkflowSimScript.parse(text, definition: definition.to_h, source: "event_keys")
    inputs = definition.to_h["inputs"].select { |_, each| each["required"] }.transform_values { "keys" }
    simulator.call(definition: definition, script: script, inputs: inputs)
  end

  # [label, definition path, id, script path]
  cases = %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2 pr-feedback investigate explore bugfix deliver].map do |preset|
    ["preset #{preset}", File.join(EventKeysSpec::PRESETS, "#{preset}.yml"), preset, File.join(EventKeysSpec::GOLDEN, "#{preset}.script.yml")]
  end
  Dir[File.join(EventKeysSpec::FIXTURES, "*.script.yml")].sort.each do |script|
    id = File.basename(script).split(".").first
    cases << ["fixture #{File.basename(script)}", File.join(EventKeysSpec::FIXTURES, "#{id}.yml"), id, script]
  end

  cases.each do |label, definition_path, id, script_path|
    it "gives every queued event its keys: #{label}" do
      transitions = play(definition_path, id, script_path)["transitions"]
      expect(transitions).not_to be_empty

      expect(EventKeysCheck.problems(transitions, label)).to eq([])
    end
  end

  it "reaches every state-moving event type the simulator can express" do
    seen = cases.flat_map { |_label, path, id, script| play(path, id, script)["transitions"].map { |each| each["type"] } }.uniq
    expect(EventKeysSpec::REQUIRED_TYPES - seen).to eq([])
  end

  it "keeps the exempt types out of the state-moving ones" do
    expect(EventKeysCheck::EXEMPT_TYPES & EventKeysSpec::REQUIRED_TYPES).to eq([])
  end
end
