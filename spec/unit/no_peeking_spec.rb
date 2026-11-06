require "spec_helper"

# Specs observe behaviour through public paths. This reads the spec files as
# text (no process is started) and names every line that reaches inside an
# object. There is no allowlist; the one file excluded is this one.
RSpec.describe "specs that peek inside objects" do
  let(:peeks) do
    [
      /instance_variable_get/,
      /instance_variable_set/,
      /instance_variable_defined\?/,
      /\.instance_variables/,
      /any_instance_of/,
      /class_eval/,
      /\.allocate\b/,
      /\.send\(/,
      /__send__\(/
    ]
  end

  it "finds none in spec/**/*_spec.rb or spec/support/**/*.rb" do
    files = Dir[File.join(PROJECT_ROOT, "spec", "**", "*_spec.rb"), File.join(PROJECT_ROOT, "spec", "support", "**", "*.rb")].uniq - [File.expand_path(__FILE__)]
    hits = files.sort.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        "#{path.delete_prefix("#{PROJECT_ROOT}/")}:#{index + 1}: #{line.strip}" if peeks.any? { |pattern| line.match?(pattern) }
      end
    end

    expect(files).not_to be_empty
    expect(hits).to eq([]), "specs reach inside objects; use public paths instead:\n#{hits.join("\n")}"
  end
end
