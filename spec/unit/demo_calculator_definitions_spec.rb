require "spec_helper"

RSpec.describe "the calculator demo's workflow definitions" do
  dir = File.join(PROJECT_ROOT, "demo", "calculator", "workflows")
  files = Dir.glob(File.join(dir, "calc-*.yml")).sort

  let(:lookup) do
    lambda do |id, below: nil|
      path = File.join(dir, "#{id}.yml")
      File.file?(path) ? {"text" => File.read(path), "path" => path, "source" => "global"} : nil
    end
  end

  def resolve(file, lookup)
    id = File.basename(file, ".yml")
    Workspace::WorkflowDefinition.parse(File.read(file), id: id, source: "global", path: file, parent_lookup: lookup)
  end

  it "finds all seven" do
    expect(files.size).to eq(7)
  end

  files.each do |file|
    it "#{File.basename(file)} resolves with a deny for commands that name the acceptance tests" do
      expect(Workspace::WorkflowDefinition.deny(resolve(file, lookup).to_h)).to include("*acceptance*")
    end
  end

  it "tells calc-01's agent that a lone negative number prints itself, as the hidden group expects" do
    instructions = resolve(files.first, lookup).to_h["instructions"]
    expect(instructions).to match(/lone number .*calc "-8"/m)
    expect(instructions).not_to include("a leading minus sign allowed")
  end

  it "does not copy the hidden groups' example inputs into the briefs" do
    briefs = files.map { |file| File.read(file) }.join
    ['calc "-3"', "-6 * 7", "10 - 3 - 2"].each { |input| expect(briefs).not_to include(input) }
  end
end
