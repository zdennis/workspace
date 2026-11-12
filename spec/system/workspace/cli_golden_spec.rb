# The CLI golden fixture (S8 T39): every help page, every verb's usage error in text and
# `--json`, the reviewed no-argument verbs and their exit codes, as `script/record-cli-golden`
# recorded them. System tier: `build_cli` runs git while it builds the CLI.
RSpec.describe "CLI golden fixture" do
  cases = CliGolden.cases

  it "has one fixture file per verb and no other" do
    recorded = Dir[File.join(CliGolden::FIXTURE_DIR, "*.txt")].map { |path| File.basename(path, ".txt") }.sort
    expect(recorded).to eq(cases.keys)
  end

  cases.each do |name, argvs|
    it "prints what spec/fixtures/cli_golden/#{name}.txt recorded" do
      expect(CliGolden.render(argvs)).to eq(File.read(CliGolden.fixture_path(name)))
    end
  end
end
