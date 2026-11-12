# frozen_string_literal: true

RSpec.describe Workspace::TemplateVariables do
  let(:shipped) { Dir[File.join(PROJECT_ROOT, "lib/templates/*.yml")] }
  let(:placeholders) { shipped.flat_map { |f| File.read(f).scan(/\{\{([A-Z_]+)\}\}/).flatten }.uniq }
  let(:render_source) { File.read(File.join(PROJECT_ROOT, "lib/workspace/project_config.rb")) }

  it "has a row for every placeholder in the shipped templates" do
    expect(placeholders - described_class::ROWS.map(&:name)).to eq([])
  end

  it "has no row the shipped templates never use" do
    expect(described_class::ROWS.map(&:name) - placeholders).to eq([])
  end

  it "has rows with unique names, frozen, with a required flag for each kind" do
    expect(described_class::ROWS.map(&:name).uniq.size).to eq(described_class::ROWS.size)
    expect(described_class::ROWS).to all(be_frozen)
    expect(described_class::ROWS.map { |r| r.required.keys.sort }.uniq).to eq([%i[project worktree]])
  end

  it "has an input key for every row" do
    expect(described_class::ROWS.map(&:input)).to all(be_a(Symbol))
    expect(described_class::ROWS.map(&:fill) - %i[value line]).to eq([])
  end

  it "renders every value row from its input, and leaves a placeholder with no row unfilled" do
    pc = Workspace::ProjectConfig.allocate.tap { |c| c.instance_variable_set(:@output, StringIO.new) }
    value_rows = described_class::ROWS.select { |r| r.fill == :value }
    inputs = value_rows.to_h { |r| [r.input, "<#{r.name}>"] }
    template = value_rows.map { |r| "{{#{r.name}}}" }.join("\n") + "\n{{NO_SUCH_ROW}}\n"
    out = pc.render(:project, inputs.merge(agent_kind: nil), template)
    expect(out).to eq(value_rows.map { |r| "<#{r.name}>" }.join("\n") + "\n{{NO_SUCH_ROW}}\n")
  end

  it "has a sample and description for every row" do
    expect(described_class::ROWS.map(&:sample)).to all(match(/\S/))
    expect(described_class::ROWS.map(&:description)).to all(match(/\S/))
  end

  it "finds a row by name and lists a kind's rows" do
    expect(described_class.find("PROJECT_NAME").input).to eq(:project_name)
    expect(described_class.find("NOPE")).to be_nil
    expect(described_class.for_kind(:project).map(&:name)).not_to include("WORKTREE_PATH")
  end
end
