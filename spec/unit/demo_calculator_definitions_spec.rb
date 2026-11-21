require "spec_helper"
require "yaml"

RSpec.describe "the calculator demo's workflow definitions" do
  dir = File.join(PROJECT_ROOT, "demo", "calculator", "workflows")
  files = Dir.glob(File.join(dir, "calc-*.yml")).sort

  def defined_deny(file, dir)
    own = YAML.load_file(file)
    return own["deny"] if own.key?("deny")
    parent = own["extends"]
    parent && defined_deny(File.join(dir, "#{parent}.yml"), dir)
  end

  it "finds all seven" do
    expect(files.size).to eq(7)
  end

  files.each do |file|
    it "#{File.basename(file)} denies the agent a command that names the acceptance tests" do
      expect(defined_deny(file, dir)).to include("*acceptance*")
    end
  end

  it "tells calc-01's agent that a lone negative number prints itself, as the hidden group expects" do
    instructions = YAML.load_file(File.join(dir, "calc-01-add-sub.yml"))["instructions"]
    expect(instructions).to match(/lone number .*calc "-3"/m)
    expect(instructions).not_to include("a leading minus sign allowed")
  end
end
