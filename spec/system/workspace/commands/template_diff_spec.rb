require "spec_helper"

RSpec.describe Workspace::TextDiff do
  it "gives a unified diff with the labels, and nothing for the same text" do
    diff = described_class.new.call("a\nb\n", "a\nc\n", old_label: "current", new_label: "rendered")

    expect(diff).to start_with("--- current\n+++ rendered\n")
    expect(diff).to include("-b\n", "+c\n")
    expect(described_class.new.call("a\n", "a\n", old_label: "x", new_label: "y")).to eq("")
  end

  it "backs template render --diff with a real diff" do
    Dir.mktmpdir("template-diff") do |dir|
      config = Workspace::Config.new(workspace_dir: dir)
      project_config = Workspace::ProjectConfig.new(config: config, git: Workspace::Git.new, output: StringIO.new)
      out = StringIO.new
      library = instance_double(Workspace::Library, tmuxinator_template: {"name" => "default", "scope" => "builtin", "source" => "default",
                                                                          "path" => File.join(PROJECT_ROOT, "lib/library/template/default/project.yml")})
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      inputs = {project_name: "app", workspace_name: "app", project_root: "/src/app", display_name: "app", config_path: config.config_path_for("app"), agent_kind: "claude"}
      FileUtils.mkdir_p(File.dirname(config.config_path_for("app")))
      text = File.read(File.join(PROJECT_ROOT, "lib/library/template/default/project.yml"))
      writer.write("app", project_config.render(:project, inputs, text).sub("/src/app", "/elsewhere"), kind: :project, template: "default",
        template_sha: "x", inputs: inputs.merge(agent_command: "claude"))

      Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
        template_validator: Workspace::TemplateValidator.new(project_config: project_config), differ: described_class.new,
        output: out, error_output: StringIO.new).render(workspace: "app", diff: true)

      expect(out.string).to include("-root: /elsewhere", "+root: /src/app", "--- #{config.config_path_for("app")}", "+++ rendered")
    end
  end
  it "backs template diff with a real diff of two sets" do
    Dir.mktmpdir("template-diff") do |dir|
      %w[default team].each do |name|
        FileUtils.mkdir_p(File.join(dir, name))
        %w[project worktree].each { |kind| File.write(File.join(dir, name, "#{kind}.yml"), "#{kind}: 1\nname: #{name}\n") }
      end
      library = instance_double(Workspace::Library)
      allow(library).to receive(:tmuxinator_set) { |name, **| {"name" => name, "path" => File.join(dir, name)} }
      out = StringIO.new
      err = StringIO.new

      Workspace::Commands::Template.new(library: library, project_config: nil, writer: nil, template_validator: nil, differ: described_class.new,
        output: out, error_output: err).diff(set: "team", kind: "project")
      Workspace::Commands::Template.new(library: library, project_config: nil, writer: nil, template_validator: nil, differ: described_class.new,
        output: out, error_output: err).diff(set: "default", kind: "worktree")

      expect(out.string).to include("--- #{dir}/default/project.yml\n+++ #{dir}/team/project.yml\n", "-name: default\n+name: team\n")
      expect(err.string).to eq("No differences from default.\n")
    end
  end
end
