require "spec_helper"
require "tmpdir"
require "digest"

# TemplateStatus over a real TmuxinatorConfigWriter and a real ProjectConfig (render and agent settings) in a tmpdir.
RSpec.describe Workspace::TemplateStatus do
  around do |example|
    Dir.mktmpdir("template-status") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:global_settings) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_settings, load: {}) }
  let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:config_path_for) { |name| File.join(@dir, "workspace.#{name}.yml") }
      allow(c).to receive(:render_state_dir).and_return(File.join(@dir, ".render"))
    end
  end
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:project_config) do
    Workspace::ProjectConfig.new(config: config, git: instance_double(Workspace::Git), output: StringIO.new, agent_commands: agent_commands, writer: writer)
  end
  let(:library) { instance_double(Workspace::Library) }
  let(:template_path) { File.join(@dir, "project.yml") }
  let(:template_text) { "name: {{WORKSPACE_NAME}}\nwindows:\n  - main:\n      panes:\n        - ascii-banner hi\n        - {{AGENT_COMMAND}}\n        - echo ready\n" }
  let(:selected) { "team" }
  subject(:status) { described_class.new(library: library, project_config: project_config, writer: writer) }

  before do
    File.write(template_path, template_text)
    allow(library).to receive(:tmuxinator_template) { {"name" => selected, "scope" => "global", "source" => "global", "path" => template_path} }
  end

  def config_path(name = "app") = config.config_path_for(name)

  # Writes a config and its record the way a new workspace does.
  def render_workspace(name = "app")
    inputs = {workspace_name: name, agent_kind: "claude"}
    text = project_config.render(:project, inputs, File.read(template_path))
    writer.write(name, text, kind: :project, template: "team", template_sha: Digest::SHA256.hexdigest(File.read(template_path)),
      inputs: inputs.merge(agent_command: project_config.agent_pane_text(text, name)))
  end

  def set_command(name, index, command)
    Workspace::Commands::UpdatePaneCommand.new(config: config, project_config: project_config, writer: writer, template_status: status, output: StringIO.new)
      .call(project: name, command: command, pane_index: index)
  end

  before { allow(project_config).to receive(:exists?).and_return(true) }

  it "calls a config that is what a render writes today current" do
    render_workspace

    expect(status.row("app")).to have_attributes(state: "current", stale: false, reasons: [], kind: "project", template: "team", selected: "team")
  end

  it "calls it stale when the selected tmuxinator template's text changed" do
    render_workspace
    File.write(template_path, "#{template_text}# new\n")

    expect(status.row("app")).to have_attributes(state: "stale", stale: true, reasons: ["template_changed"])
  end

  it "calls it stale when the agent settings would give another pane" do
    render_workspace
    global_settings["agent"] = {"commands" => {"claude" => "claude-dev"}}

    expect(status.row("app")).to have_attributes(state: "stale", reasons: ["agent_changed"])
  end

  context "when another set is selected" do
    let(:selected) { "other" }

    it "calls it stale for the switch alone when the text is identical, so apply rewrites the record" do
      render_workspace

      expect(status.row("app")).to have_attributes(state: "stale", stale: true, template: "team", selected: "other", reasons: ["template_switched"])
    end

    it "adds template_changed when the other set's text differs" do
      render_workspace
      File.write(template_path, "#{template_text}# new\n")

      expect(status.row("app").reasons).to eq(%w[template_switched template_changed])
    end
  end

  it "calls a config that is not what was rendered modified, and still says whether it is stale" do
    render_workspace
    File.write(config_path, "edited\n")
    expect(status.row("app")).to have_attributes(state: "modified", stale: false, reasons: [])

    File.write(template_path, "#{template_text}# new\n")
    expect(status.row("app")).to have_attributes(state: "modified", stale: true, reasons: ["template_changed"])
  end

  it "calls an edit that happens to equal today's render current" do
    render_workspace
    File.write(template_path, "#{template_text}# new\n")
    File.write(config_path, project_config.render(:project, {workspace_name: "app", agent_kind: "claude"}, File.read(template_path)))

    expect(status.row("app")).to have_attributes(state: "current", reasons: [])
  end

  describe "after set-command" do
    before { render_workspace }

    it "reads modified, not current, for an edit of a pane that is not the agent's" do
      set_command("app", 3, "vim .")

      expect(File.read(config_path)).to include("vim .")
      expect(status.row("app")).to have_attributes(state: "modified")
    end

    it "reads modified for an agent command a render today does not write" do
      set_command("app", 2, "claude --model opus")

      expect(File.read(config_path)).to include("claude --model opus")
      expect(status.row("app")).to have_attributes(state: "modified")
    end

    it "reads modified when the agent pane is replaced by a command that is not an agent" do
      set_command("app", 2, "vim .")

      expect(status.row("app")).to have_attributes(state: "modified")
    end

    it "reads current when the agent pane is replaced by another agent command with the setting to match" do
      global_settings["agent"] = {"commands" => {"claude" => "claude-dev"}}
      set_command("app", 2, project_config.agent_pane_value("claude", "app"))

      expect(status.row("app")).to have_attributes(state: "current", reasons: [])
    end
  end

  it "reads current after an agent patch writes today's render and records its pane, as refresh_agent_pane and doctor --fix do" do
    render_workspace
    global_settings["agent"] = {"commands" => {"claude" => "claude-dev"}}
    expect(status.row("app").state).to eq("stale")

    writer.patch("app", inputs: ->(text) { {agent_command: project_config.agent_pane_text(text, "app")} }) do
      project_config.render(:project, {workspace_name: "app", agent_kind: "claude"}, File.read(template_path))
    end

    expect(status.row("app")).to have_attributes(state: "current", stale: false, reasons: [])
  end

  it "keeps a hand-edited config modified through an agent patch, as refresh_agent_pane and doctor --fix make" do
    render_workspace
    File.write(config_path, "#{File.read(config_path)}# by hand\n")
    global_settings["agent"] = {"commands" => {"claude" => "claude-dev"}}

    writer.patch("app", inputs: ->(text) { {agent_command: project_config.agent_pane_text(text, "app")} }) { |text| text.sub("claude", "claude-dev") }

    expect(status.row("app").state).to eq("modified")
  end

  it "calls a config with a corrupt sidecar untracked" do
    render_workspace
    File.write(writer.record_path("app"), "{not json")

    expect(status.row("app")).to have_attributes(state: "untracked", kind: nil, template: nil)
  end

  it "calls a config with no record untracked" do
    File.write(config_path("old"), "name: old\n")

    expect(status.row("old")).to have_attributes(state: "untracked", stale: false)
  end
end
