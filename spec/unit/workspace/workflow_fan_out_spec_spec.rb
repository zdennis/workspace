require "spec_helper"

RSpec.describe Workspace::WorkflowFanOutSpec do
  def parse(yaml)
    Workspace::WorkflowDefinition.parse(yaml, id: "demo", source: "global", path: "/defs/demo.yml")
  end

  def problems(yaml)
    parse(yaml)
    []
  rescue Workspace::Error => e
    e.details.fetch("problems")
  end

  def group_text(siblings, checkout: nil)
    body = siblings.map { |id, extra, produces| "      #{id}:\n        prompt: P\n        produces: [#{produces || "#{id}.md"}]\n#{extra}" }.join
    "steps:\n  checks:\n#{checkout && "    checkout: #{checkout}\n"}    fan_out:\n#{body}"
  end

  let(:fixture) { File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "workflows", "fan_out.yml")) }

  describe "checkout: shared" do
    it "parses the fan_out fixture with no problems and no warnings" do
      definition = Workspace::WorkflowDefinition.parse(fixture, id: "fan_out", source: "global", path: nil)
      expect(definition.warnings.map { |warning| warning["code"] }).not_to include("fan_out_edits_unverified")
      expect(definition.warnings.select { |warning| warning["step"] == "checks" }).to eq([])
    end

    it "accepts an explicit guard: unchanged" do
      expect(problems(group_text([["lint", "        guard: unchanged\n"], ["test"]]))).to eq([])
    end

    it "refuses a sibling whose guard is below unchanged, naming the step and group" do
      found = problems(group_text([["lint"], ["test", "        guard: config\n"]]))
      expect(found).to include(a_string_matching(/\Astep test \(in fan_out group checks\): guard: config .*checkout: shared-edit/))
    end

    it "refuses two siblings that produce the same file, in either order" do
      [[%w[lint test], "x.md"], [%w[test lint], "x.md"]].each do |ids, file|
        found = problems(group_text(ids.map { |id| [id, "", file] }))
        expect(found).to include(%(fan_out group checks: steps #{ids.join(" and ")} both produce "x.md"; siblings of a fan_out group need separate produces files))
      end
    end

    it "sees one file spelled two ways" do
      found = problems(group_text([["lint", "", "a/x.md"], ["test", "", "a/./x.md"]]))
      expect(found).to include(a_string_matching(/steps lint and test both produce "a\/x.md"/))
    end

    it "ignores a produces file a sibling shares with a step outside the group" do
      text = group_text([["lint"], ["test"]]) + "  report:\n    prompt: P\n    produces: [lint.md]\n"
      expect(problems(text)).to eq([])
    end
  end

  describe "checkout: shared-edit" do
    let(:text) { group_text([["lint", "        guard: config\n"], ["test"]], checkout: "shared-edit") }

    it "drops the guard requirement" do
      expect(problems(text)).to eq([])
    end

    it "warns that the engine can't verify disjoint edits" do
      warning = parse(text).warnings.find { |each| each["code"] == "fan_out_edits_unverified" }
      expect(warning["step"]).to eq("checks")
      expect(warning["message"]).to match(/can't verify.*disjoint paths/)
    end

    it "parses two siblings that produce the same file, with the warning and no problem" do
      same = group_text([["lint", "", "x.md"], ["test", "", "x.md"]], checkout: "shared-edit")
      expect(problems(same)).to eq([])
      expect(parse(same).warnings.map { |warning| warning["code"] }).to include("fan_out_edits_unverified")
    end
  end

  it "still refuses uses: on a sibling" do
    expect(problems(group_text([["lint", "        uses: [edit]\n"]]))).to include(a_string_matching(/fan_out sibling can't take uses: yet/))
  end

  it "leaves an ungrouped definition alone" do
    definition = parse("steps:\n  a:\n    prompt: P\n    produces: [x.md]\n    guard: config\n  b:\n    prompt: P\n    produces: [x.md]\n")
    expect(definition.warnings.map { |warning| warning["code"] }).not_to include("fan_out_edits_unverified")
  end
end
