require "spec_helper"
require "tmpdir"
require "digest"

# The cases that need no real render: a double ProjectConfig, writer and library. The round trips over a real
# writer and ProjectConfig are in spec/integration/workspace/template_status_spec.rb.
RSpec.describe Workspace::TemplateStatus do
  around do |example|
    Dir.mktmpdir("template-status") do |dir|
      @dir = dir
      example.run
    end
  end

  def sha(text) = Digest::SHA256.hexdigest(text)

  let(:config_text) { "rendered\n" }
  let(:record) do
    Workspace::TmuxinatorConfigWriter::Record.new(kind: :project, template: "team", template_sha: sha("tpl\n"),
      inputs: {workspace_name: "app", agent_kind: "claude", agent_command: "claude"}, rendered_sha: sha(config_text))
  end
  let(:writer) { instance_double(Workspace::TmuxinatorConfigWriter, record: record) }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, config_path_for: File.join(@dir, "app.yml"), render: "rendered\n", agent_pane_value: "claude").tap do |pc|
      allow(pc).to receive(:agent_pane_value).and_return("claude")
    end
  end
  let(:library) { instance_double(Workspace::Library) }
  subject(:status) { described_class.new(library: library, project_config: project_config, writer: writer) }

  before do
    File.write(File.join(@dir, "app.yml"), config_text)
    File.write(File.join(@dir, "tpl.yml"), "tpl\n")
    allow(library).to receive(:tmuxinator_template).and_return("name" => "team", "scope" => "global", "source" => "global", "path" => File.join(@dir, "tpl.yml"))
  end

  it "is current when a render today is the file" do
    expect(status.row("app")).to have_attributes(state: "current", stale: false, reasons: [], kind: "project", template: "team", selected: "team")
  end

  it "is untracked with no record, keeping the kind and template of none" do
    allow(writer).to receive(:record).and_return(nil)

    expect(status.row("app")).to have_attributes(state: "untracked", kind: nil, template: nil, selected: nil, stale: false, reasons: [])
  end

  it "is untracked when the config is gone, though a record is left" do
    File.delete(File.join(@dir, "app.yml"))

    expect(status.row("app")).to have_attributes(state: "untracked", template: "team")
  end

  it "is stale when the selected set can't be found and the file is as rendered" do
    allow(library).to receive(:tmuxinator_template).and_raise(Workspace::Error.new("gone", code: "unknown_template"))

    expect(status.row("app")).to have_attributes(state: "stale", selected: nil, stale: true, reasons: ["template_unavailable"])
  end

  it "is modified when the set can't be found and the file was edited" do
    allow(library).to receive(:tmuxinator_template).and_raise(Workspace::Error.new("gone", code: "unknown_template"))
    File.write(File.join(@dir, "app.yml"), "edited\n")

    expect(status.row("app")).to have_attributes(state: "modified", stale: true, reasons: ["template_unavailable"])
  end

  it "is stale with render_failed when today's inputs can't fill the template" do
    allow(project_config).to receive(:render).and_raise(Workspace::Error, "no value")

    expect(status.row("app")).to have_attributes(state: "stale", selected: "team", reasons: ["render_failed"])
  end

  it "reports each name in order, and a row as a hash for --json" do
    rows = status.call(%w[b a])

    expect(rows.map(&:workspace)).to eq(%w[b a])
    expect(rows.first.to_h).to eq("workspace" => "b", "state" => "current", "kind" => "project", "template" => "team",
      "selected" => "team", "stale" => false, "reasons" => [])
  end

  describe "#reproduces?" do
    it "is true when a render today writes exactly the text" do
      expect(status.reproduces?("app", "rendered\n")).to be(true)
    end

    it "is false for other text, with no record, and when it can't be rendered" do
      expect(status.reproduces?("app", "edited\n")).to be(false)

      allow(project_config).to receive(:render).and_raise(Workspace::Error, "no value")
      expect(status.reproduces?("app", "rendered\n")).to be(false)

      allow(writer).to receive(:record).and_return(nil)
      expect(status.reproduces?("app", "rendered\n")).to be(false)
    end
  end

  describe ".record_inputs" do
    it "recomputes the agent command from the current settings" do
      allow(project_config).to receive(:agent_pane_value).with("claude", "app").and_return("claude-dev --x")

      inputs = described_class.record_inputs(record, project_config)

      expect(inputs).to eq(workspace_name: "app", agent_kind: "claude", agent_command: Workspace::ProjectConfig.yaml_item("claude-dev --x"))
    end

    it "leaves the agent command out when the renderer would refuse it" do
      allow(project_config).to receive(:agent_pane_value).and_raise(Workspace::Error, "unknown kind")

      expect(described_class.record_inputs(record, project_config)).to eq(workspace_name: "app", agent_kind: "claude")
    end
  end
end
