require "json"

# What the simulator golden specs share about playing a shipped preset: its definition parsed with the
# built-in parent lookup, its required inputs filled, and a transcript with the tmpdir and hashes masked.
module PresetSimulation
  WORKFLOWS = File.join(PROJECT_ROOT, "lib", "workflows")

  def self.definition(preset)
    path = File.join(WORKFLOWS, "#{preset}.yml")
    lookup = lambda do |id, below: nil|
      file = File.join(WORKFLOWS, "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
    Workspace::WorkflowDefinition.parse(File.read(path), id: preset, source: "builtin", path: path, parent_lookup: lookup)
  end

  def self.inputs(definition)
    definition.to_h["inputs"].select { |_, each| each["required"] }.transform_values { "golden" }
  end

  def self.transcript(result, base)
    text = JSON.pretty_generate(result) + "\n"
    [File.realpath(base), base].uniq.each { |dir| text = text.gsub(dir, "<TMP>") }
    text.gsub(/\b[0-9a-f]{40,64}\b/, "<SHA>")
  end
end
