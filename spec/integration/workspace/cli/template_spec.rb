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
  let(:validator) { Workspace::TemplateValidator.new(project_config: project_config) }
  let(:built) do
    build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
      template_validator: validator, differ: ->(*, **) { "" }, output: output, error_output: error_output),
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

  describe "template status" do
    let(:global_settings) { {} }
    let(:status_scope) { instance_double(Workspace::StatusScope) }
    let(:catalog) { instance_double(Workspace::ProjectCatalog) }
    let(:built) do
      selection = Workspace::TemplateSelection.new(status_scope: status_scope, catalog: catalog, project_config: project_config)
      build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
        template_validator: validator, differ: ->(*, **) { "" }, selection: selection,
        status: Workspace::TemplateStatus.new(library: library, project_config: project_config, writer: writer),
        output: output, error_output: error_output),
        project_detector: detector, output: output, error_output: error_output, working_dir: File.join(@dir, "src"))
    end

    before do
      allow(project_config).to receive(:exists?) { |name| name == "app" }
      allow(project_config).to receive(:config_path_for) { |name| File.join(@dir, "workspace.#{name}.yml") }
      File.write(File.join(@dir, "workspace.app.yml"), "name: app\n")
    end

    it "reports a config with no render record as untracked, by name" do
      cli.run(["template", "status", "app"])

      expect(output.string.lines.map(&:rstrip)).to eq(["WORKSPACE  STATE      TEMPLATE  NOTE", "app        untracked  -         no render record"])
    end

    it "gives the document with counts under --json, for the current workspace when none is named" do
      allow(status_scope).to receive(:resolve).and_return(Workspace::StatusScope::Scope.new(kind: :workspace, workspace: "app"))

      cli.run(["template", "status", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "counts" => {"current" => 0, "stale" => 0, "modified" => 0, "untracked" => 1})
      expect(doc["workspaces"]).to eq([{"workspace" => "app", "state" => "untracked", "kind" => nil, "template" => nil, "selected" => nil, "stale" => false, "reasons" => [], "approx" => false}])
    end

    it "answers an unknown name with unknown_workspace, exit 1, as a document under --json" do
      expect(exit_status { cli.run(["template", "status", "nope", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "refuses names beside --all as a usage error" do
      expect(exit_status { cli.run(["template", "status", "app", "--all", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "writes nothing" do
      before = Dir.glob("**/*", base: @dir).sort

      cli.run(["template", "status", "app"])

      expect(Dir.glob("**/*", base: @dir).sort).to eq(before)
    end
  end

  describe "template apply" do
    let(:status_scope) { instance_double(Workspace::StatusScope) }
    let(:catalog) { instance_double(Workspace::ProjectCatalog) }
    let(:applier) { instance_double(Workspace::TemplateApply) }
    let(:built) do
      selection = Workspace::TemplateSelection.new(status_scope: status_scope, catalog: catalog, project_config: project_config)
      build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
        template_validator: validator, differ: ->(*, **) { "" }, selection: selection, apply: applier, output: output, error_output: error_output),
        project_detector: detector, output: output, error_output: error_output, working_dir: File.join(@dir, "src"))
    end

    def answer(*outcomes, rolled_back: false)
      rows = outcomes.each_with_index.map { |outcome, i| {"workspace" => "w#{i}", "outcome" => outcome, "reason" => nil, "message" => nil} }
      Workspace::TemplateApply::Result.new(rows: rows, backup: "20261112T100000000000Z-aaaaaa", rolled_back: rolled_back, warnings: [])
    end

    before { allow(project_config).to receive(:exists?) { |name| %w[app api].include?(name) } }

    it "prints the action document with the batch id, exit 0 when every row is fine" do
      allow(applier).to receive(:call).and_return(answer("applied", "skipped"))

      cli.run(["template", "apply", "app", "api", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("action" => "template apply", "status" => "ok", "backup" => "20261112T100000000000Z-aaaaaa", "rolled_back" => false,
        "summary" => {"applied" => 1, "skipped" => 1})
      expect(applier).to have_received(:call).with(%w[app api], dry_run: false, diff: false, force: false, rollback: false)
    end

    it "exits 3 with status partial when some rows failed, and 1 when all did or the batch was rolled back" do
      allow(applier).to receive(:call).and_return(answer("failed", "applied"))
      expect(exit_status { cli.run(["template", "apply", "app", "api", "--json"]) }).to eq(3)
      expect(JSON.parse(output.string)).to include("status" => "partial")

      output.truncate(0)
      output.rewind
      allow(applier).to receive(:call).and_return(answer("rolled_back", "failed", rolled_back: true))
      expect(exit_status { cli.run(["template", "apply", "app", "api", "--rollback-all-on-error", "--json"]) }).to eq(1)
      expect(JSON.parse(output.string)).to include("status" => "failed", "rolled_back" => true)

      allow(applier).to receive(:call).and_return(answer("failed"))
      expect(exit_status { cli.run(["template", "apply", "app"]) }).to eq(1)
    end

    it "is a dry_run document under --dry-run" do
      allow(applier).to receive(:call).and_return(answer("applied"))

      cli.run(["template", "apply", "app", "--dry-run", "--json"])

      expect(JSON.parse(output.string)).to include("status" => "dry_run")
    end

    it "answers an unknown name with unknown_workspace before anything is applied" do
      expect(exit_status { cli.run(["template", "apply", "nope", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "shows its help page" do
      cli.run(["template", "apply", "--help"])

      expect(output.string).to include("Usage: workspace template apply [WORKSPACE...]", "--rollback-all-on-error")
    end
  end

  describe "template adopt" do
    let(:status_scope) { instance_double(Workspace::StatusScope) }
    let(:catalog) { instance_double(Workspace::ProjectCatalog) }
    let(:adopter) { instance_double(Workspace::TemplateAdopt) }
    let(:built) do
      selection = Workspace::TemplateSelection.new(status_scope: status_scope, catalog: catalog, project_config: project_config)
      build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
        template_validator: validator, differ: ->(*, **) { "" }, selection: selection, adopt: adopter, output: output, error_output: error_output),
        project_detector: detector, output: output, error_output: error_output, working_dir: File.join(@dir, "src"))
    end

    def answer(*outcomes)
      outcomes.each_with_index.map { |outcome, i| {"workspace" => "w#{i}", "outcome" => outcome, "reason" => nil, "message" => nil, "match" => (outcome == "adopted") ? "exact" : nil} }
    end

    before { allow(project_config).to receive(:exists?) { |name| %w[app api].include?(name) } }

    it "prints the action document with the adopted count" do
      allow(adopter).to receive(:call).and_return(answer("adopted", "skipped"))

      cli.run(["template", "adopt", "app", "api", "--json"])

      expect(JSON.parse(output.string)).to include("action" => "template adopt", "status" => "ok", "adopted" => {"exact" => 1}, "summary" => {"adopted" => 1, "skipped" => 1})
      expect(adopter).to have_received(:call).with(%w[app api], dry_run: false)
    end

    it "is a dry_run document under --dry-run, and exits 3 when some rows failed" do
      allow(adopter).to receive(:call).and_return(answer("would_adopt"))
      cli.run(["template", "adopt", "app", "--dry-run", "--json"])
      expect(JSON.parse(output.string)).to include("status" => "dry_run")

      output.truncate(0)
      output.rewind
      allow(adopter).to receive(:call).and_return(answer("failed", "adopted"))
      expect(exit_status { cli.run(["template", "adopt", "app", "api", "--json"]) }).to eq(3)
    end

    it "refuses a flag it does not take, and shows its help page" do
      expect(exit_status { cli.run(["template", "adopt", "app", "--force", "--json"]) }).to eq(1)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")

      output.truncate(0)
      output.rewind
      cli.run(["template", "adopt", "--help"])
      expect(output.string).to include("Usage: workspace template adopt [WORKSPACE...]", "--dry-run")
    end
  end

  describe "template validate and diff" do
    before { allow(project_config).to receive(:agent_pane_in_template?).and_return(false) }

    it "lists a set's errors and exits 1, as a document with ok false under --json" do
      expect(exit_status { cli.run(["template", "validate", "team"]) }).to eq(1)
      expect(output.string).to include("team: #{@dir}/library/global/template/team/project.yml: ", "Error: {{PROJECT_NAME}}")

      output.truncate(0)
      output.rewind
      expect(exit_status { cli.run(["template", "validate", "team", "--kind", "worktree", "--json"]) }).to eq(1)
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => false)
      expect(doc["files"].map { |f| f["kind"] }).to eq(["worktree"])
    end

    it "reports a file that can't be read as an unreadable error" do
      expect(exit_status { cli.run(["template", "validate", "--file", File.join(@dir, "none.yml")]) }).to eq(1)
      expect(output.string).to include("Error: can't read")
    end

    it "reports a missing --file path as ok false in the document" do
      expect(exit_status { cli.run(["template", "validate", "--file", File.join(@dir, "none.yml"), "--json"]) }).to eq(1)
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => false, "errors" => 1)
      expect(doc["files"].first["problems"].first).to include("code" => "unreadable")
    end

    it "diffs a set against the default through the injected differ, writing nothing" do
      before = Dir.glob("**/*", base: @dir).sort

      cli.run(["template", "diff", "team", "--json"])

      expect(JSON.parse(output.string)).to include("ok" => true, "against" => "default", "changed" => false)
      expect(Dir.glob("**/*", base: @dir).sort).to eq(before)
    end

    it "answers an unknown --against with unknown_template, exit 1" do
      expect(exit_status { cli.run(["template", "diff", "team", "--against", "nope", "--json"]) }).to eq(1)
      expect(JSON.parse(output.string)).to include("code" => "unknown_template")
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
  describe "template new, edit and use" do
    let(:validator) { instance_double(Workspace::TemplateValidator, call_set: Workspace::TemplateValidator::Result.new(errors: [], warnings: []), call_file: []) }
    let(:editor_runs) { [] }
    let(:config_command) { instance_double(Workspace::Commands::Config) }
    let(:editor_env) { {"EDITOR" => "vi"} }
    let(:gate) { Workspace::OutputGate.new(output) }
    let(:built) do
      build_test_cli(template_command: Workspace::Commands::Template.new(library: library, project_config: project_config, writer: writer,
        template_validator: validator, differ: ->(*, **) { "" }, config_command: config_command, output: gate, error_output: error_output),
        project_detector: detector, env: editor_env, editor_launcher: ->(argv) { editor_runs << argv },
        output: gate, error_output: error_output, working_dir: File.join(@dir, "src"))
    end

    it "copies the built-in default into the global library, ready to edit and select" do
      cli.run(["template", "new", "mine"])

      path = File.join(@dir, "library/global/template/mine")
      expect(File.read(File.join(path, "project.yml"))).to eq("default project\n")
      expect(output.string).to eq("Created the tmuxinator template 'mine' from 'default' at #{path}. Edit it with: workspace template edit mine\n")
      expect(Dir.glob("*", base: File.join(@dir, "builtin/template/default")).sort).to eq(%w[README.md project.yml worktree.yml])
    end

    it "refuses an existing name with template_exists, as a document under --json, leaving the set as it was" do
      expect(exit_status { cli.run(["template", "new", "team", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "template_exists", "details" => hash_including("template" => "team", "scope" => "global"))
      expect(File.read(File.join(@dir, "library/global/template/team/project.yml"))).to eq("team project\n")
    end

    it "prints the created row as an action document" do
      cli.run(["template", "new", "mine", "--from", "team", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "action" => "template new", "status" => "ok")
      expect(doc["results"].first).to include("outcome" => "created", "template" => "mine", "scope" => "global", "from" => "team")
    end

    it "opens both files of the template in $EDITOR, then reports them valid" do
      cli.run(["template", "edit", "team"])

      expect(editor_runs).to eq([["vi", *%w[project worktree].map { |kind| "#{@dir}/library/global/template/team/#{kind}.yml" }]])
      expect(output.string).to include("team: #{@dir}/library/global/template/team/project.yml: valid")
    end

    it "prints the paths and says nothing was opened when no editor is set" do
      editor_env.clear

      cli.run(["template", "edit", "team", "--kind", "worktree"])

      expect(editor_runs).to eq([])
      expect(error_output.string).to include("Nothing was opened: set $VISUAL or $EDITOR")
      expect(output.string).to start_with("#{@dir}/library/global/template/team/worktree.yml\n")
    end

    it "exits 1 with the problems when the edited file has an error" do
      allow(validator).to receive(:call_file).with(:project, anything).and_return(
        [Workspace::TemplateValidator::Problem.new(severity: "error", code: "missing_placeholder", kind: :project, message: "{{PROJECT_NAME}} is required and does not appear.")]
      )

      expect(exit_status { cli.run(["template", "edit", "team", "--kind", "project"]) }).to eq(1)
      expect(output.string).to include("Error: {{PROJECT_NAME}} is required")
    end

    it "refuses a built-in template and opens nothing" do
      expect(exit_status { cli.run(["template", "edit", "default", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "template_builtin_readonly")
      expect(editor_runs).to eq([])
    end

    it "checks the files under --json without opening an editor" do
      cli.run(["template", "edit", "team", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("action" => "template edit", "status" => "ok")
      expect(doc["results"].first).to include("outcome" => "edited", "template" => "team")
      expect(editor_runs).to eq([])
    end

    it "selects a set through config set after checking its name" do
      result = Workspace::Commands::Config::Result.new(key: "tmuxinator.template", workspace: "app", layer: "project", path: "/cfg/app.yml")
      allow(config_command).to receive(:set).and_return(result)

      cli.run(["template", "use", "team", "--scope", "project", "--json"])

      expect(config_command).to have_received(:set).with("tmuxinator.template", "team", project: "app", scope: "project", cwd: File.join(@dir, "src"))
      expect(JSON.parse(output.string)["results"].first).to include("outcome" => "selected", "key" => "tmuxinator.template", "layer" => "project")
    end

    it "does not set the key for a name no template has" do
      allow(config_command).to receive(:set)

      expect(exit_status { cli.run(["template", "use", "nope", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("code" => "unknown_template")
      expect(config_command).not_to have_received(:set)
    end
  end
end
