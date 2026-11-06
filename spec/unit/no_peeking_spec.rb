require "spec_helper"

# Specs observe behaviour through public paths. This reads the spec files as
# text (no process is started) and names every line that reaches inside an
# object.
#
# Not scanned: this file, and spec/support/spawn_guard.rb, which is the guard's
# own tooling and has to reach into the process machinery. The glob for
# spec/*.rb is there for spec_helper.
#
# Exempt: a line whose only hits are and_call_original or and_wrap_original and
# whose every allow( or expect( is on File, Dir, Process, IO, FileUtils or
# Open3. CLAUDE.md says File, Open3 and YAML are called directly, not wrapped,
# and tested with stubs or temp dirs, so a stub on the standard library is not a
# peek inside the object under test.
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
      /__send__\(/,
      /define_singleton_method/,
      /instance_eval/,
      /instance_exec/,
      /public_send/,
      /\.method\(:/,
      /singleton_class/,
      /and_call_original/,
      /and_wrap_original/
    ]
  end

  let(:wrapping) { [/and_call_original/, /and_wrap_original/] }
  let(:stdlib) { %w[File Dir Process IO FileUtils Open3] }

  def stdlib_wrap?(line, found)
    targets = line.scan(/\b(?:allow|expect)\(([^)]*)\)/).flatten.map { |target| target.delete_prefix("::") }
    (found - wrapping).empty? && targets.any? && (targets - stdlib).empty?
  end

  it "finds none in spec/**/*_spec.rb, spec/support/**/*.rb or spec/*.rb" do
    globs = [
      File.join(PROJECT_ROOT, "spec", "**", "*_spec.rb"),
      File.join(PROJECT_ROOT, "spec", "support", "**", "*.rb"),
      File.join(PROJECT_ROOT, "spec", "*.rb")
    ]
    skipped = [File.expand_path(__FILE__), File.join(PROJECT_ROOT, "spec", "support", "spawn_guard.rb")]
    files = Dir[*globs].uniq - skipped
    hits = files.sort.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        found = peeks.select { |pattern| line.match?(pattern) }
        next if found.empty? || stdlib_wrap?(line, found)

        "#{path.delete_prefix("#{PROJECT_ROOT}/")}:#{index + 1}: #{line.strip}"
      end
    end

    expect(files).not_to be_empty
    expect(hits).to eq([]), "specs reach inside objects; use public paths instead:\n#{hits.join("\n")}"
  end
end
