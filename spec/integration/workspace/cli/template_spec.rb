require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

# The template family through CLI#run: its rescue funnel (the `--json` error envelopes and exit
# codes), its help, and a real Commands::Template over a real Library, TmuxinatorTemplateConfig and
# ConfigResolver reading template sets from a temporary directory.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::TemplateFamilyCli

  around do |example|
    Dir.mktmpdir("template-cli") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:global_settings) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global_settings, load: {}) }
  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library"), builtin_library_dir: File.join(@dir, "builtin"), tmuxinator_dir: File.join(@dir, "tmuxinator")) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, exists?: false) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "src")) }
  let(:library) do
    Workspace::Library.new(config: config, lineage: lineage, project_config: project_config,
      template_config: Workspace::TmuxinatorTemplateConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)))
  end
  let(:writer) { instance_double(Workspace::TmuxinatorConfigWriter, record: nil) }
  let(:detector) { instance_double(Workspace::ProjectDetector, detect: "app") }
  let(:built) do
    build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
      template_validator: Workspace::TemplateValidator.new(project_config: project_config), differ: ->(*, **) { "" }, output: output, error_output: error_output),
      project_detector: detector,
      output: output, error_output: error_output, working_dir: File.join(@dir, "src"))
  end
  let(:cli) { built[0] }

  def make_set(store, name, description: "the #{name} set")
    dir = File.join(@dir, store, "template", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "README.md"), "---\ndescription: #{description}\n---\n# #{name}\n")
    %w[project worktree].each { |kind| File.write(File.join(dir, "#{kind}.yml"), "#{name} #{kind}\n") }
  end

  def exit_status
    yield
    nil
  rescue FakeSystemExit => e
    e.status
  end

  before do
    make_set("builtin", "default")
    make_set("library/global", "team")
  end

  describe "template list" do
    it "marks the tmuxinator template the layered keys select" do
      global_settings["tmuxinator"] = {"template" => "team"}

      cli.run(["template", "list"])

      expect(output.string.lines.map(&:rstrip)).to eq([
        "Tmuxinator template sets (a new config of each kind is rendered from the one selected):",
        "NAME     SCOPE    SELECTED FOR       DESCRIPTION",
        "default  builtin  -                  the default set",
        "team     global   project, worktree  the team set"
      ])
    end

    it "gives the document for --json, selecting the built-in default when nothing is set" do
      cli.run(["template", "list", "--json"])

      doc = JSON.parse(output.string)
      expect(doc["workspace"]).to eq("app")
      expect(doc["templates"].map { |t| [t["name"], t["selected_for"]] }).to eq([["default", %w[project worktree]], ["team", []]])
    end

    it "narrows to a scope" do
      cli.run(["template", "list", "--scope", "global", "--json"])

      expect(JSON.parse(output.string)["templates"].map { |t| t["name"] }).to eq(["team"])
    end

    it "reports an unknown scope as a usage error, and as a document under --json, exit 1" do
      expect(exit_status { cli.run(["template", "list", "--scope", "nowhere", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end
  end

  describe "template show and path" do
    it "prints a named set's file raw, and its paths" do
      cli.run(["template", "show", "team", "--kind", "project"])
      cli.run(["template", "path", "team"])

      expect(output.string).to eq("team project\n#{@dir}/library/global/template/team/project.yml\n#{@dir}/library/global/template/team/worktree.yml\n")
    end

    it "answers an unknown set with unknown_template, exit 1, in text and in a document" do
      expect(exit_status { cli.run(["template", "show", "nope"]) }).to eq(1)
      expect(error_output.string).to include("No tmuxinator template 'nope'", "workspace template list")

      output.truncate(0)
      output.rewind
      expect(exit_status { cli.run(["template", "path", "nope", "--json"]) }).to eq(1)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_template", "details" => hash_including("kind" => "tmuxinator", "template" => "nope"))
    end

    it "answers a missing file with library_source_missing" do
      File.delete(File.join(@dir, "library/global/template/team/worktree.yml"))

      expect(exit_status { cli.run(["template", "path", "team", "--json"]) }).to eq(1)
      expect(JSON.parse(output.string)).to include("code" => "library_source_missing")
    end

    it "writes nothing under the library or tmuxinator directories" do
      before = Dir.glob("**/*", base: @dir).sort

      cli.run(["template", "list"])
      cli.run(["template", "show"])
      cli.run(["template", "path", "--json"])

      expect(Dir.glob("**/*", base: @dir).sort).to eq(before)
    end
  end

  describe "template variables and render" do
    it "prints the placeholders as a document" do
      cli.run(["template", "variables", "--kind", "worktree", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "workspace" => nil)
      expect(doc["variables"].map { |v| v["name"] }).to include("WORKTREE_BRANCH", "PRE_WINDOW")
      expect(doc["variables"].map { |v| v["name"] }).not_to include("PROJECT_ROOT")
    end

    it "answers render for a workspace with no record with no_render_record, exit 1" do
      expect(exit_status { cli.run(["template", "render", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "no_render_record", "details" => {"name" => "app"})
    end

    it "refuses --sample with --name as a usage error" do
      expect(exit_status { cli.run(["template", "render", "--sample", "--name", "app"]) }).to eq(1)
      expect(error_output.string).to include("--name or --sample")
    end
  end

  describe "help" do
    it "prints the overview for a bare template --help and each verb's page" do
      cli.run(["template", "--help"])
      expect(output.string).to include("Usage: workspace template list", "workspace template show", "workspace template path")

      output.truncate(0)
      output.rewind
      cli.run(["template", "path", "--help"])
      expect(output.string).to start_with("Usage: workspace template path [NAME]")
    end

    it "uses the words tmuxinator template, never bare template, in each page's summary" do
      Workspace::HelpPages::TEMPLATE.each_value do |page|
        expect(page[:summary]).to include("tmuxinator template")
      end
    end

    it "shows the overview for a bare template and exits 0" do
      expect(exit_status { cli.run(["template"]) }).to be_nil

      expect(output.string).to include("Usage: workspace template list", "Subcommands:", "Examples:")
    end
  end
end
