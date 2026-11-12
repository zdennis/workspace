require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Template, "render and variables over a real ProjectConfig" do
  around do |example|
    Dir.mktmpdir("template-render") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:config) { Workspace::Config.new(workspace_dir: @dir) }
  let(:builtin) { File.join(PROJECT_ROOT, "lib/library/template/default") }
  let(:project_config) { Workspace::ProjectConfig.new(config: config, git: Workspace::Git.new, output: StringIO.new) }
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:library) { instance_double(Workspace::Library) }
  let(:differ) { ->(old, new, old_label:, new_label:) { (old == new) ? "" : "differs #{old_label}\n" } }
  subject(:command) do
    described_class.new(library: library, project_config: project_config, writer: writer,
      template_validator: Workspace::TemplateValidator.new(project_config: project_config), differ: differ, output: out, error_output: err)
  end

  def tree = Dir.glob("**/*", base: @dir).sort.map { |f| [f, File.directory?(File.join(@dir, f)) ? nil : File.read(File.join(@dir, f))] }

  before do
    allow(library).to receive(:tmuxinator_template) do |kind, **|
      {"name" => "default", "scope" => "builtin", "source" => "default", "path" => File.join(builtin, "#{kind}.yml")}
    end
  end

  it "fills the built-in project template with sample values and writes nothing" do
    before = tree

    expect(command.render(sample: true, kind: "project")).to be(true)

    parsed = YAML.safe_load(out.string)
    expect(parsed).to include("name" => "myapp", "root" => "/Users/me/src/myapp")
    expect(out.string).not_to include("{{")
    expect(err.string).to eq("")
    expect(tree).to eq(before)
  end

  it "fills a worktree sample, dropping nothing it was given" do
    command.render(sample: true, kind: "worktree")

    expect(out.string).to include("WORKSPACE_TASK=t_sample", "myapp-wt-proj-123")
  end

  it "fills an unsaved --file and reports its problems, exit false, still showing the text" do
    path = File.join(@dir, "draft.yml")
    File.write(path, "name: {{WORKSPACE_NAME}}\nroot: /tmp\nwindows:\n  - main: ls\n")

    expect(command.render(file: path, kind: "project", sample: true)).to be(false)

    expect(err.string).to include("{{PROJECT_ROOT}} is required")
    expect(out.string).to start_with("name: myapp.worktree-proj-123")
  end

  it "fills a workspace from its record with the current agent settings and diffs against its config" do
    inputs = {project_name: "app", workspace_name: "app", project_root: "/src/app", display_name: "app", config_path: config.config_path_for("app"),
              agent_kind: "claude"}
    template_text = File.read(File.join(builtin, "project.yml"))
    FileUtils.mkdir_p(File.dirname(config.config_path_for("app")))
    writer.write("app", project_config.render(:project, inputs, template_text), kind: :project, template: "default",
      template_sha: Digest::SHA256.hexdigest(template_text), inputs: inputs.merge(agent_command: "claude"))
    tree

    command.render(workspace: "app", diff: true)
    expect(err.string).to include("No differences")

    File.write(config.config_path_for("app"), File.read(config.config_path_for("app")).sub("root:", "root: # edited\nold:"))
    before = tree
    command.render(workspace: "app", diff: true)

    expect(out.string).to start_with("differs ")
    expect(tree).to eq(before)
  end
end
