require "spec_helper"

RSpec.describe Workspace::TemplateVariablesDocs do
  let(:doc_path) { File.join(PROJECT_ROOT, "docs/README.template.md") }

  it "leaves docs/README.template.md as the table renders it" do
    text = File.read(doc_path)
    expect(described_class.rewrite(text)).to eq(text), "docs/README.template.md is out of date; run script/generate-template-docs"
  end

  it "fails the drift check once a row is edited without regenerating" do
    text = File.read(doc_path)
    row = Workspace::TemplateVariables::ROWS.first
    edited = text.sub(row.description, "#{row.description} Edited.")
    expect(edited).not_to eq(text)
    expect(described_class.rewrite(edited)).not_to eq(edited)
  end

  it "lists every placeholder once" do
    table = described_class.render("placeholders")
    expect(Workspace::TemplateVariables::ROWS.map(&:name)).to all(satisfy { |name| table.scan("| `{{#{name}}}` |").size == 1 })
  end

  it "escapes pipes so a sample can't end its cell" do
    table = described_class.render("placeholders")
    expect(table).to include("--continue \\|\\| claude")
  end

  it "replaces only the text between markers" do
    text = "before\n<!-- BEGIN GENERATED: placeholders -->\nstale\n<!-- END GENERATED: placeholders -->\nafter\n"
    out = described_class.rewrite(text)
    expect(out).to start_with("before\n<!-- BEGIN GENERATED: placeholders -->\n| Placeholder")
    expect(out).to end_with("<!-- END GENERATED: placeholders -->\nafter\n")
    expect(out).not_to include("stale")
  end

  it "refuses a block name it can't render" do
    expect { described_class.rewrite("<!-- BEGIN GENERATED: nope -->\n<!-- END GENERATED: nope -->\n") }.to raise_error(ArgumentError, /nope/)
  end
  it "returns a document with no markers unchanged" do
    text = "# Title\n\nNo generated blocks here.\n"
    expect(described_class.rewrite(text)).to eq(text)
  end

  it "leaves a BEGIN marker with no END unchanged" do
    text = "<!-- BEGIN GENERATED: placeholders -->\nstale\n"
    expect(described_class.rewrite(text)).to eq(text)
  end

  it "keeps the Kinds and Required cells apart for a row that differs" do
    row = described_class.render("placeholders").lines.grep(/`\{\{PROJECT_ROOT\}\}`/).first
    expect(row).to start_with("| `{{PROJECT_ROOT}}` | project | project | ")
    agent = described_class.render("placeholders").lines.grep(/`\{\{PROJECT_NAME\}\}`/).first
    expect(agent).to start_with("| `{{PROJECT_NAME}}` | project, worktree | project | ")
  end
end
