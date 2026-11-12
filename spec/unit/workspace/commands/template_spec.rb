require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Template do
  around do |example|
    Dir.mktmpdir("template-command") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:library) { instance_double(Workspace::Library) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, render: "rendered\n", config_path_for: File.join(@dir, "app.yml")) }
  let(:writer) { instance_double(Workspace::TmuxinatorConfigWriter, record: nil) }
  let(:validator) { instance_double(Workspace::TemplateValidator, call_file: [], call_set: Workspace::TemplateValidator::Result.new(errors: [], warnings: [])) }
  let(:config_command) { instance_double(Workspace::Commands::Config) }
  let(:differ) { ->(old, new, old_label:, new_label:) { "--- #{old_label}\n+++ #{new_label}\n-#{old}+#{new}" } }
  subject(:command) do
    described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
      config_command: config_command, output: out, error_output: err)
  end

  def set_dir(name)
    File.join(@dir, name).tap do |dir|
      FileUtils.mkdir_p(dir)
      %w[project worktree].each { |kind| File.write(File.join(dir, "#{kind}.yml"), "#{name} #{kind}\n") }
    end
  end

  def entry(name, scope: "builtin", effective: true, project: nil)
    {"kind" => "template", "name" => name, "ref" => "template/#{name}", "scope" => scope, "project" => project,
     "path" => set_dir(name), "description" => "the #{name} set", "files" => %w[project.yml worktree.yml], "effective" => effective,
     "readable" => true, "link" => nil, "updated_at" => "2026-11-12T00:00:00Z"}
  end

  def selects(kind, name, scope: "builtin", source: "default", workspace: "app")
    allow(library).to receive(:tmuxinator_template).with(kind, workspace: workspace).and_return(
      "ref" => "template/#{name}", "name" => name, "scope" => scope, "source" => source, "path" => File.join(@dir, name, "#{kind}.yml")
    )
  end

  describe "#list" do
    before do
      allow(library).to receive(:stores).and_return([:stores])
      allow(library).to receive(:entries).with([:stores], kind: "template").and_return([entry("default"), entry("team", scope: "global")])
      selects(:project, "team", scope: "global", source: "global")
      selects(:worktree, "default")
    end

    it "marks the kinds each template is selected for, by name and scope" do
      command.list(workspace: "app", json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "app", "warnings" => [])
      expect(doc["selected"]).to eq("project" => {"name" => "team", "scope" => "global", "source" => "global"},
        "worktree" => {"name" => "default", "scope" => "builtin", "source" => "default"})
      expect(doc["templates"].to_h { |t| [t["name"], t["selected_for"]] }).to eq("default" => ["worktree"], "team" => ["project"])
    end

    it "never marks a hidden entry that a higher scope shadows" do
      allow(library).to receive(:entries).and_return([entry("team", scope: "global"), entry("team", effective: false)])

      command.list(workspace: "app", json: true)

      expect(JSON.parse(out.string)["templates"].map { |t| [t["scope"], t["selected_for"]] }).to eq([["global", ["project"]], ["builtin", []]])
    end

    it "prints a table with a header and a dash for an unselected template" do
      allow(library).to receive(:entries).and_return([entry("default"), entry("spare", scope: "global")])
      selects(:project, "default")

      command.list(workspace: "app")

      expect(out.string.lines.map(&:rstrip)).to eq([
        "Tmuxinator template sets (a new config of each kind is rendered from the one selected):",
        "NAME     SCOPE    SELECTED FOR       DESCRIPTION",
        "default  builtin  project, worktree  the default set",
        "spare    global   -                  the spare set"
      ])
    end

    it "passes the scope and working directory to the library's stores" do
      command.list(workspace: "app", scope: "global", cwd: "/src/app")

      expect(library).to have_received(:stores).with(scope: "global", cwd: "/src/app")
    end

    it "refuses a scope it does not know before reading anything" do
      expect { command.list(scope: "everywhere") }.to raise_error(Workspace::UsageError, /Unknown scope: everywhere/)
      expect(library).not_to have_received(:entries)
    end

    it "reports a selection that can't be found as a warning and still lists the sets" do
      allow(library).to receive(:tmuxinator_template).with(:project, workspace: "app").and_raise(
        Workspace::Error.new("No tmuxinator template 'gone'.", code: "unknown_template", details: {})
      )

      command.list(workspace: "app", json: true)

      doc = JSON.parse(out.string)
      expect(doc["selected"]["project"]).to be_nil
      expect(doc["warnings"]).to eq([{"code" => "unknown_template", "kind" => "project", "message" => "No tmuxinator template 'gone'."}])
      expect(doc["templates"].size).to eq(2)
    end

    it "lists an edited installed copy as legacy when a kind renders from it" do
      selects(:project, Workspace::Library::LEGACY_TEMPLATE, scope: "legacy", source: "legacy")

      command.list(workspace: "app", json: true)

      legacy = JSON.parse(out.string)["templates"].find { |t| t["name"] == "legacy" }
      expect(legacy).to include("scope" => "legacy", "selected_for" => ["project"])
    end

    it "leaves the legacy row out when listing one scope" do
      selects(:project, Workspace::Library::LEGACY_TEMPLATE, scope: "legacy", source: "legacy")

      command.list(workspace: "app", scope: "global", json: true)

      expect(JSON.parse(out.string)["templates"].map { |t| t["name"] }).not_to include("legacy")
    end

    it "says when a scope holds no tmuxinator template" do
      allow(library).to receive(:entries).and_return([])
      selects(:project, "default")

      command.list(workspace: "app", scope: "global")

      expect(out.string).to end_with("No tmuxinator templates in that scope.\n")
    end
  end

  describe "#show and #path" do
    before do
      selects(:project, "team", scope: "global", source: "global")
      selects(:worktree, "default")
      set_dir("team")
      set_dir("default")
    end

    it "prints the one file a kind selects, as it is" do
      command.show(kind: "worktree", workspace: "app")

      expect(out.string).to eq("default worktree\n")
    end

    it "prints each kind's selected file under a path line when no kind is given" do
      command.show(workspace: "app")

      expect(out.string).to eq("==> #{@dir}/team/project.yml <==\nteam project\n\n==> #{@dir}/default/worktree.yml <==\ndefault worktree\n")
    end

    it "reads the files of a named set instead of the selection" do
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "scope" => "global", "path" => File.join(@dir, "team"))

      command.show(set: "team", kind: "worktree", workspace: "app")

      expect(out.string).to eq("team worktree\n")
      expect(library).not_to have_received(:tmuxinator_template).with(:worktree, workspace: "app")

      out.truncate(0)
      out.rewind
      command.path(set: "team", kind: "worktree", workspace: "app", json: true)
      expect(JSON.parse(out.string)["templates"].first).to include("template" => "team", "source" => "argument")
    end

    it "gives each file's text and sha256 in the document" do
      command.show(kind: "project", workspace: "app", json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("schema_version" => 1, "ok" => true, "warnings" => [])
      expect(doc["templates"]).to eq([{"kind" => "project", "template" => "team", "scope" => "global", "source" => "global",
                                       "path" => "#{@dir}/team/project.yml", "content" => "team project\n", "sha256" => Digest::SHA256.hexdigest("team project\n")}])
    end

    it "prints one path per line, project first" do
      command.path(workspace: "app")

      expect(out.string).to eq("#{@dir}/team/project.yml\n#{@dir}/default/worktree.yml\n")
    end

    it "prints the path of one kind of a named set" do
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "scope" => "global", "path" => File.join(@dir, "team"))

      command.path(set: "team", kind: "project", workspace: "app")

      expect(out.string).to eq("#{@dir}/team/project.yml\n")
    end

    it "gives the paths as a document without file text" do
      command.path(kind: "worktree", workspace: "app", json: true)

      expect(JSON.parse(out.string)["templates"]).to eq([{"kind" => "worktree", "template" => "default", "scope" => "builtin", "source" => "default",
                                                          "path" => "#{@dir}/default/worktree.yml"}])
    end

    it "refuses a kind it does not know" do
      expect { command.show(kind: "window", workspace: "app") }.to raise_error(Workspace::UsageError, /Unknown kind: window/)
    end

    it "raises library_source_missing for a file the set lacks" do
      File.delete(File.join(@dir, "team", "project.yml"))

      expect { command.path(kind: "project", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "template/team/project.yml", "path" => "#{@dir}/team/project.yml")
      }
    end

    it "lets an unknown set's error through" do
      allow(library).to receive(:tmuxinator_set).and_raise(Workspace::Error.new("No tmuxinator template 'nope'.", code: "unknown_template"))

      expect { command.show(set: "nope", workspace: "app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_template") }
    end

    it "writes nothing" do
      before = Dir.glob("**/*", base: @dir).sort

      command.show(workspace: "app")
      command.path(workspace: "app", json: true)

      expect(Dir.glob("**/*", base: @dir).sort).to eq(before)
    end
  end

  describe "#variables" do
    def record(inputs, kind: :worktree)
      Workspace::TmuxinatorConfigWriter::Record.new(kind: kind, template: "default", template_sha: "x", inputs: inputs, rendered_sha: "y")
    end

    it "prints the table, and with --kind only that kind's rows" do
      command.variables(kind: "project")

      lines = out.string.lines.map(&:rstrip)
      expect(lines.first.split).to eq(%w[NAME KINDS REQUIRED DESCRIPTION])
      expect(lines.map { |l| l.split.first }).to include("PROJECT_ROOT", "AGENT_COMMAND")
      expect(lines.map { |l| l.split.first }).not_to include("WORKTREE_BRANCH", "PRE_WINDOW")
      expect(out.string).not_to include("VALUE")
    end

    it "adds the recorded values with --name, the agent command from its own key" do
      allow(writer).to receive(:record).with("app.worktree-x").and_return(record({workspace_name: "app.worktree-x", agent_kind: "codex", agent_command: "recorded", task_id: nil}))
      allow(project_config).to receive(:agent_pane_value).with("codex", "app.worktree-x").and_return("codex --fast")

      command.variables(kind: "worktree", workspace: "app.worktree-x", json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => true, "workspace" => "app.worktree-x", "value_state" => "recorded")
      values = doc["variables"].to_h { |v| [v["name"], v["value"]] }
      expect(values).to include("WORKSPACE_NAME" => "app.worktree-x", "AGENT_COMMAND" => "codex --fast", "PRE_WINDOW" => "(dropped)")
    end

    it "says (no record) for every row of a workspace with none" do
      command.variables(workspace: "app")

      rows = out.string.lines.drop(1)
      expect(rows).to all(include("(no record)"))
      command.variables(workspace: "app", json: true)
      expect(JSON.parse(out.string.lines.last)).to include("value_state" => "no_record")
      out.truncate(0)
      out.rewind
      command.variables(json: true)
      expect(JSON.parse(out.string)).to include("value_state" => nil)
    end

    it "shows the values adopt would recover for a workspace with no record, marked (recovered)" do
      adopter = instance_double(Workspace::TemplateAdopt)
      allow(adopter).to receive(:recover).with("app").and_return(Workspace::TemplateAdopt::Recovered.new(kind: :project, inputs: {workspace_name: "app", project_name: "app", agent_kind: "claude"}))
      allow(project_config).to receive(:agent_pane_value).with("claude", "app").and_return("claude --current")
      adopting = described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ, adopt: adopter, output: out, error_output: err)

      adopting.variables(kind: "project", workspace: "app")

      expect(out.string.lines.grep(/\AWORKSPACE_NAME/).first).to include("app (recovered)")
      expect(out.string.lines.grep(/\AAGENT_COMMAND/).first).to include("claude --current (recovered)")
      out.truncate(0)
      out.rewind
      adopting.variables(workspace: "app", json: true)
      expect(JSON.parse(out.string)).to include("value_state" => "recovered")
    end

    it "refuses an unknown kind, and writes nothing" do
      before = Dir.glob("**/*", base: @dir).sort

      expect { command.variables(kind: "window") }.to raise_error(Workspace::UsageError, /Unknown kind: window/)
      command.variables(json: true)

      expect(Dir.glob("**/*", base: @dir).sort).to eq(before)
    end
  end

  describe "#render" do
    let(:problem) { Workspace::TemplateValidator::Problem.new(severity: "error", code: "missing_placeholder", kind: :project, message: "{{WORKSPACE_NAME}} is required and does not appear.") }
    let(:warning) { Workspace::TemplateValidator::Problem.new(severity: "warning", code: "literal_agent_pane", kind: :project, message: "literal pane") }

    before do
      set_dir("team")
      selects(:project, "team", scope: "global", source: "global")
      allow(writer).to receive(:record).with("app").and_return(
        Workspace::TmuxinatorConfigWriter::Record.new(kind: :project, template: "team", template_sha: "x", rendered_sha: "y",
          inputs: {workspace_name: "app", project_name: "app", agent_kind: "claude", agent_command: "old pane"})
      )
      allow(project_config).to receive(:agent_pane_value).with("claude", "app").and_return("claude --current")
    end

    it "fills from the record minus its recorded agent command, so current agent settings apply, and prints the text raw" do
      expect(command.render(workspace: "app")).to be(true)

      expect(project_config).to have_received(:render).with(:project, {workspace_name: "app", project_name: "app", agent_kind: "claude", agent_command: "claude --current"}, "team project\n")
      expect(out.string).to eq("rendered\n")
      expect(err.string).to eq("")
    end

    it "fills --sample with each placeholder's sample, the agent command quoted for a list item" do
      selects(:project, "team", scope: "global", source: "global", workspace: nil)

      command.render(sample: true, context: nil)

      expect(project_config).to have_received(:render) do |kind, inputs, _text|
        expect(kind).to eq(:project)
        expect(inputs).to include(project_name: "myapp", workspace_name: "myapp.worktree-proj-123", agent_kind: "claude")
        expect(inputs[:agent_command]).to start_with("claude --dangerously-skip-permissions")
      end
    end

    it "fills a --file that is not saved as a set, kind from the option" do
      path = File.join(@dir, "draft.yml")
      File.write(path, "draft {{WORKSPACE_NAME}}\n")

      command.render(file: path, kind: "worktree", sample: true, json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => true, "template" => nil, "source" => "file", "path" => path, "kind" => "worktree", "workspace" => nil)
      expect(validator).to have_received(:call_file).with(:worktree, path)
      expect(project_config).to have_received(:render).with(:worktree, anything, "draft {{WORKSPACE_NAME}}\n")
    end

    it "takes a named set's file of the recorded kind" do
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "scope" => "global", "path" => File.join(@dir, "team"))

      command.render(set: "team", workspace: "app", json: true)

      expect(JSON.parse(out.string)).to include("template" => "team", "source" => "argument", "kind" => "project")
    end

    it "prints a diff against the workspace's current config, nothing else, and reads the file only" do
      File.write(File.join(@dir, "app.yml"), "old\n")
      before = Dir.glob("**/*", base: @dir).sort_by(&:to_s)

      command.render(workspace: "app", diff: true)

      expect(out.string).to eq("--- #{@dir}/app.yml\n+++ rendered\n-old\n+rendered\n")
      expect(Dir.glob("**/*", base: @dir).sort_by(&:to_s)).to eq(before)
    end

    it "says under --json --diff whether the config would change" do
      File.write(File.join(@dir, "app.yml"), "old\n")
      command.render(workspace: "app", diff: true, json: true)
      expect(JSON.parse(out.string)).to include("changed" => true)

      out.truncate(0)
      out.rewind
      File.write(File.join(@dir, "app.yml"), "rendered\n")
      same = described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: ->(*, **) { "" }, output: out, error_output: err)
      same.render(workspace: "app", diff: true, json: true)
      expect(JSON.parse(out.string)).to include("changed" => false)

      out.truncate(0)
      out.rewind
      command.render(workspace: "app", json: true)
      expect(JSON.parse(out.string)).not_to have_key("changed")
    end

    it "says on stderr when the diff is empty" do
      differ_same = ->(*, **) { "" }
      quiet = described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ_same, output: out, error_output: err)

      quiet.render(workspace: "app", diff: true)

      expect(out.string).to eq("")
      expect(err.string).to include("No differences")
    end

    it "reports problems on stderr, still prints the text and returns false for an error" do
      allow(validator).to receive(:call_file).and_return([problem, warning])

      expect(command.render(workspace: "app")).to be(false)

      expect(err.string).to eq("Error: {{WORKSPACE_NAME}} is required and does not appear.\nWarning: literal pane\n")
      expect(out.string).to eq("rendered\n")
    end

    it "puts the problems in the document's warnings, ok false" do
      allow(validator).to receive(:call_file).and_return([problem])

      expect(command.render(workspace: "app", json: true)).to be(false)

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => false, "content" => "rendered\n", "diff" => nil)
      expect(doc["warnings"]).to eq([problem.to_h])
      expect(doc["inputs"]).to eq("workspace_name" => "app", "project_name" => "app", "agent_kind" => "claude", "agent_command" => "claude --current")
    end

    it "adds render_failed when the renderer refuses, and shows no text" do
      allow(project_config).to receive(:render).and_raise(Workspace::Error, "no value for PROJECT_ROOT")

      expect(command.render(workspace: "app", json: true)).to be(false)

      doc = JSON.parse(out.string)
      expect(doc["content"]).to be_nil
      expect(doc["warnings"]).to include(hash_including("code" => "render_failed", "message" => "no value for PROJECT_ROOT"))
    end

    it "escapes the text on a terminal, as it is to a pipe" do
      tty = StringIO.new
      allow(tty).to receive(:tty?).and_return(true)
      allow(project_config).to receive(:render).and_return("a\e[31m\n")
      terminal = described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ, output: tty, error_output: err)

      terminal.render(workspace: "app")

      expect(tty.string).to eq('a\e[31m' + "\n")
    end

    it "answers no_render_record for a workspace without one" do
      expect { command.render(workspace: "other") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("no_render_record")
        expect(e.details).to eq("name" => "other")
      }
    end

    it "refuses combinations that have no meaning" do
      expect { command.render(set: "a", file: "b", sample: true) }.to raise_error(Workspace::UsageError, /not both/)
      expect { command.render(sample: true, workspace: "app") }.to raise_error(Workspace::UsageError, /--name or --sample/)
      expect { command.render }.to raise_error(Workspace::Error, /Not in a workspace: pass --name WORKSPACE .* or --sample/) { |e| expect(e.code).to eq("not_in_workspace") }
      expect { command.render(sample: true, diff: true) }.to raise_error(Workspace::UsageError, /--diff/)
      expect { command.render(workspace: "app", kind: "window") }.to raise_error(Workspace::UsageError, /Unknown kind/)
    end
  end
  describe "#validate" do
    let(:error) { Workspace::TemplateValidator::Problem.new(severity: "error", code: "missing_placeholder", kind: :project, message: "{{WORKSPACE_NAME}} is required.") }
    let(:warning) { Workspace::TemplateValidator::Problem.new(severity: "warning", code: "literal_agent_pane", kind: :worktree, message: "literal pane") }

    before do
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "path" => set_dir("team"))
    end

    it "checks both files of a named set, and is true for no problems" do
      expect(command.validate(set: "team", workspace: "app")).to be(true)

      expect(validator).to have_received(:call_file).with(:project, File.join(@dir, "team", "project.yml"))
      expect(validator).to have_received(:call_file).with(:worktree, File.join(@dir, "team", "worktree.yml"))
      expect(out.string.lines.map { |l| l.sub(@dir, "DIR") }).to eq(["team: DIR/team/project.yml: valid\n", "team: DIR/team/worktree.yml: valid\n"])
    end

    it "lists problems and is false when one is an error, true for warnings alone" do
      allow(validator).to receive(:call_file).with(:project, anything).and_return([error])
      allow(validator).to receive(:call_file).with(:worktree, anything).and_return([warning])

      expect(command.validate(set: "team", workspace: "app")).to be(false)
      expect(out.string).to include("1 error, 0 warnings", "  Error: {{WORKSPACE_NAME}} is required.", "0 errors, 1 warning", "  Warning: literal pane")

      allow(validator).to receive(:call_file).with(:project, anything).and_return([])
      expect(command.validate(set: "team", workspace: "app")).to be(true)
    end

    it "checks the file each kind selects when no set is named, only the kind asked for" do
      selects(:worktree, "default")

      command.validate(kind: "worktree", workspace: "app")

      expect(validator).to have_received(:call_file).with(:worktree, File.join(@dir, "default", "worktree.yml"))
      expect(validator).not_to have_received(:call_file).with(:project, anything)
    end

    it "checks a file as it is given, its kind from its name unless --kind says" do
      command.validate(file: "w/worktree.yml")
      command.validate(file: "w/x.yml")
      command.validate(file: "w/x.yml", kind: "worktree")

      expect(validator).to have_received(:call_file).with(:worktree, File.expand_path("w/worktree.yml"))
      expect(validator).to have_received(:call_file).with(:project, File.expand_path("w/x.yml"))
      expect(validator).to have_received(:call_file).with(:worktree, File.expand_path("w/x.yml"))
    end

    it "gives the document for --json, ok false on an error" do
      allow(validator).to receive(:call_file).with(:project, anything).and_return([error])
      allow(validator).to receive(:call_file).with(:worktree, anything).and_return([warning])

      command.validate(set: "team", workspace: "app", json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("schema_version" => 1, "ok" => false, "errors" => 1, "warnings" => 1)
      expect(doc["files"].map { |f| [f["kind"], f["template"], f["problems"].map { |p| p["code"] }] }).to eq(
        [["project", "team", ["missing_placeholder"]], ["worktree", "team", ["literal_agent_pane"]]]
      )
    end

    it "refuses a set with --file, and a kind that is not one" do
      expect { command.validate(set: "team", file: "x.yml") }.to raise_error(Workspace::UsageError, /not both/)
      expect { command.validate(set: "team", kind: "nope") }.to raise_error(Workspace::UsageError, /Unknown kind/)
    end
  end

  describe "#diff" do
    before do
      allow(library).to receive(:tmuxinator_set).with("default", workspace: "app").and_return("name" => "default", "path" => set_dir("default"))
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "path" => set_dir("team"))
    end

    it "diffs each file of the set against the same file of default, labelled by path" do
      command.diff(set: "team", workspace: "app")

      expect(out.string).to include("--- #{@dir}/default/project.yml\n+++ #{@dir}/team/project.yml\n-default project\n+team project\n",
        "--- #{@dir}/default/worktree.yml\n+++ #{@dir}/team/worktree.yml")
      expect(err.string).to eq("")
    end

    it "compares with --against, one kind, and the set each kind selects when none is named" do
      allow(library).to receive(:tmuxinator_set).with("old", workspace: "app").and_return("name" => "old", "path" => set_dir("old"))
      selects(:worktree, "team", scope: "global", source: "global")

      command.diff(against: "old", kind: "worktree", workspace: "app")

      expect(out.string).to eq("--- #{@dir}/old/worktree.yml\n+++ #{@dir}/team/worktree.yml\n-old worktree\n+team worktree\n")
    end

    it "says on stderr when nothing differs" do
      allow(differ).to receive(:call).and_return("")

      command.diff(set: "default", workspace: "app")

      expect(out.string).to eq("")
      expect(err.string).to eq("No differences from default.\n")
    end

    it "gives the document for --json with each diff and whether any changed" do
      command.diff(set: "team", against: "default", kind: "project", workspace: "app", json: true)

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => true, "against" => "default", "changed" => true)
      expect(doc["files"].first).to include("kind" => "project", "template" => "team", "changed" => true, "path" => File.join(@dir, "team", "project.yml"),
        "against_path" => File.join(@dir, "default", "project.yml"))
    end
  end
  describe "#new" do
    let(:store) { Workspace::LibraryStore.new(dir: File.join(@dir, "global"), scope: "global") }

    before do
      allow(library).to receive(:write_store).and_return(store)
      allow(library).to receive(:stores).and_return([store])
      allow(library).to receive(:tmuxinator_set).with("default", workspace: "app").and_return("name" => "default", "ref" => "template/default", "scope" => "builtin", "path" => set_dir("default"))
    end

    it "copies the default set into the library scope and says where it is" do
      row = command.new(name: "team", workspace: "app")

      path = File.join(@dir, "global", "template", "team")
      expect(File.read(File.join(path, "project.yml"))).to eq("default project\n")
      expect(File.read(File.join(path, "worktree.yml"))).to eq("default worktree\n")
      expect(row).to include("outcome" => "created", "template" => "team", "scope" => "global", "path" => path, "from" => "default", "warnings" => [])
      expect(out.string).to include("Created the tmuxinator template 'team' from 'default' at #{path}")
    end

    it "copies --from another set, and writes to the scope and project asked for" do
      allow(library).to receive(:tmuxinator_set).with("base", workspace: "api.worktree-x").and_return("name" => "base", "ref" => "template/base", "path" => set_dir("base"))

      command.new(name: "mine", from: "base", scope: "project", workspace: "api.worktree-x", cwd: "/src/api")

      expect(library).to have_received(:write_store).with(scope: "project", project: "api", cwd: "/src/api")
      expect(File.read(File.join(@dir, "global", "template", "mine", "project.yml"))).to eq("base project\n")
    end

    it "warns, on stderr and in the row, when the new set hides one of the same name in a lower scope" do
      builtin = Workspace::LibraryStore.new(dir: File.join(@dir, "builtin"), scope: "builtin")
      builtin.copy_tree("template", "team", set_dir("shipped"))
      allow(library).to receive(:stores).and_return([store, builtin])

      row = command.new(name: "team", workspace: "app")

      expect(row["warnings"]).to include(hash_including("code" => "shadows_template", "scope" => "builtin"))
      expect(err.string).to include("Warning: The new tmuxinator template 'team' hides the builtin one of the same name")
    end

    it "does not warn when only a different name exists below" do
      builtin = Workspace::LibraryStore.new(dir: File.join(@dir, "builtin"), scope: "builtin")
      builtin.copy_tree("template", "other", set_dir("shipped"))
      allow(library).to receive(:stores).and_return([store, builtin])

      expect(command.new(name: "team", workspace: "app")["warnings"]).to eq([])
      expect(err.string).to eq("")
    end

    it "refuses a name already in that scope, leaving it as it is" do
      store.copy_tree("template", "team", set_dir("old"))

      expect { command.new(name: "team", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("template_exists")
        expect(e.details).to include("template" => "team", "scope" => "global")
      }
      expect(File.read(File.join(@dir, "global", "template", "team", "project.yml"))).to eq("old project\n")
    end

    it "writes nothing when the source has an error" do
      error = Workspace::TemplateValidator::Problem.new(severity: "error", code: "x", kind: :project, message: "broken")
      allow(validator).to receive(:call_set).and_return(Workspace::TemplateValidator::Result.new(errors: [error], warnings: []))

      expect { command.new(name: "team", workspace: "app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_template") }
      expect(File.exist?(File.join(@dir, "global", "template", "team"))).to be(false)
    end

    it "refuses a bad name, the reserved name and an unknown scope" do
      expect { command.new(name: "Team") }.to raise_error(Workspace::UsageError, /not a valid tmuxinator template name/)
      expect { command.new(name: "legacy") }.to raise_error(Workspace::UsageError, /reserved/)
      expect { command.new(name: "team", scope: "builtin") }.to raise_error(Workspace::UsageError, /One of global, project/)
    end
  end

  describe "#edit" do
    def selected(name, scope)
      %i[project worktree].each do |kind|
        allow(library).to receive(:tmuxinator_template).with(kind, workspace: "app").and_return(
          "name" => name, "scope" => scope, "source" => "global", "path" => File.join(set_dir(name), "#{kind}.yml")
        )
      end
    end

    it "opens both files of the selected set, then checks them" do
      selected("team", "global")
      opened = []

      row = command.edit(workspace: "app", opener: ->(paths) { opened << paths })

      expect(opened).to eq([[File.join(@dir, "team", "project.yml"), File.join(@dir, "team", "worktree.yml")]])
      expect(row).to include("outcome" => "edited", "reason" => nil, "template" => "team")
      expect(row["files"].map { |f| f.values_at("kind", "problems") }).to eq([["project", []], ["worktree", []]])
      expect(out.string).to include("project.yml: valid", "worktree.yml: valid")
    end

    it "opens one file of a named set with --kind" do
      allow(library).to receive(:tmuxinator_set).with("team", workspace: "app").and_return("name" => "team", "scope" => "global", "path" => set_dir("team"))
      opened = []

      command.edit(set: "team", kind: "worktree", workspace: "app", opener: ->(paths) { opened << paths })

      expect(opened).to eq([[File.join(@dir, "team", "worktree.yml")]])
    end

    it "is failed, with the problems, when a file has an error after the edit" do
      selected("team", "global")
      allow(validator).to receive(:call_file).with(:worktree, anything).and_return([Workspace::TemplateValidator::Problem.new(severity: "error", code: "x", kind: :worktree, message: "broken")])

      row = command.edit(workspace: "app")

      expect(row).to include("outcome" => "failed", "reason" => "invalid_template")
      expect(out.string).to include("Error: broken")
    end

    it "refuses a built-in set before opening anything" do
      selected("default", "builtin")
      opened = []

      expect { command.edit(workspace: "app", opener: ->(paths) { opened << paths }) }.to raise_error(Workspace::Error, /template new NAME --from default/) { |e|
        expect(e.code).to eq("template_builtin_readonly")
      }
      expect(opened).to eq([])
    end
  end

  describe "#status notes" do
    let(:selection) { instance_double(Workspace::TemplateSelection, call: %w[old hand]) }
    let(:statuses) { instance_double(Workspace::TemplateStatus) }
    let(:reporting) do
      described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
        selection: selection, status: statuses, output: out, error_output: err)
    end

    def row(name, approx)
      Workspace::TemplateStatus::Row.new(workspace: name, state: "modified", kind: "project", template: "default", selected: "default", stale: false, reasons: [], approx: approx)
    end

    it "says an adopted record may hold edits, apart from one edited since it was rendered" do
      allow(statuses).to receive(:call).and_return([row("old", true), row("hand", false)])

      reporting.status

      lines = out.string.lines.map(&:rstrip)
      expect(lines[1]).to include("adopted without an exact render; may hold edits (apply --force re-renders it)")
      expect(lines[2]).to end_with("edited since it was rendered")
    end

    it "puts approx on each --json row" do
      allow(statuses).to receive(:call).and_return([row("old", true)])

      reporting.status(json: true)

      expect(JSON.parse(out.string)["workspaces"].first).to include("approx" => true)
    end
  end

  describe "#adopt" do
    let(:selection) { instance_double(Workspace::TemplateSelection, call: %w[app api]) }
    let(:adopter) { instance_double(Workspace::TemplateAdopt) }
    let(:adopting) do
      described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
        selection: selection, adopt: adopter, output: out, error_output: err)
    end

    def row(name, outcome, reason = nil, match = nil)
      {"workspace" => name, "outcome" => outcome, "reason" => reason, "message" => nil, "match" => match}
    end

    it "hands the selection and --dry-run to TemplateAdopt" do
      allow(adopter).to receive(:call).and_return([])

      adopting.adopt(names: ["app"], cwd: "/src", dry_run: true, json: true)

      expect(selection).to have_received(:call).with(names: ["app"], all: false, project: nil, working_dir: "/src")
      expect(adopter).to have_received(:call).with(%w[app api], dry_run: true)
    end

    it "is ok, partial or failed by the failed rows and dry_run under --dry-run, counting adopted rows by match" do
      cases = {
        [[row("app", "adopted", nil, "exact"), row("api", "adopted", nil, "approx"), row("x", "skipped", "tracked")], false] => ["ok", 0],
        [[row("app", "failed", "adopt_unrecoverable"), row("api", "adopted", nil, "exact")], false] => ["partial", 3],
        [[row("app", "failed", "adopt_unrecoverable")], false] => ["failed", 1],
        [[row("app", "would_adopt", nil, "exact")], true] => ["dry_run", 0]
      }
      cases.each do |(rows, dry_run), (status, code)|
        allow(adopter).to receive(:call).and_return(rows)
        outcome = adopting.adopt(dry_run: dry_run, json: true)
        expect([outcome[:status], outcome[:exit_code]]).to eq([status, code])
      end
      allow(adopter).to receive(:call).and_return([row("app", "adopted", nil, "exact"), row("api", "adopted", nil, "approx"), row("b", "adopted", nil, "exact")])
      expect(adopting.adopt(json: true)[:extra]).to eq("adopted" => {"exact" => 2, "approx" => 1})
    end

    it "prints a line per row in text mode, and nothing under --json" do
      allow(adopter).to receive(:call).and_return([row("app", "adopted", nil, "exact"), row("api", "skipped", "tracked")])

      adopting.adopt(dry_run: true)

      expect(out.string).to eq("app: adopted exact\napi: skipped: tracked\nDry run: nothing was written.\n")
      out.truncate(0)
      out.rewind
      adopting.adopt(json: true)
      expect(out.string).to be_empty
    end

    it "is not available without the adopt part" do
      expect { command.adopt }.to raise_error(Workspace::Error, /template adopt is not available/)
    end
  end

  describe "#apply" do
    let(:selection) { instance_double(Workspace::TemplateSelection, call: %w[app api]) }
    let(:applier) { instance_double(Workspace::TemplateApply) }
    let(:applying) do
      described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
        selection: selection, apply: applier, output: out, error_output: err)
    end

    def result(*rows, backup: nil, rolled_back: false, warnings: [])
      Workspace::TemplateApply::Result.new(rows: rows, backup: backup, rolled_back: rolled_back, warnings: warnings)
    end

    def row(name, outcome, reason = nil, message = nil, diff: nil)
      {"workspace" => name, "outcome" => outcome, "reason" => reason, "message" => message}.tap { |r| r["diff"] = diff if diff }
    end

    it "hands the selection and the flags to TemplateApply" do
      allow(applier).to receive(:call).and_return(result)

      applying.apply(names: ["app"], all: false, project: nil, cwd: "/src", dry_run: true, diff: true, force: true, rollback: true, json: true)

      expect(selection).to have_received(:call).with(names: ["app"], all: false, project: nil, working_dir: "/src")
      expect(applier).to have_received(:call).with(%w[app api], dry_run: true, diff: true, force: true, rollback: true)
    end

    it "is ok, partial or failed by the failed rows, dry_run under --dry-run, and failed after a roll back" do
      cases = {
        [result(row("app", "applied"), row("api", "skipped", "modified")), false] => ["ok", 0],
        [result(row("app", "failed", "workspace_locked"), row("api", "applied")), false] => ["partial", 3],
        [result(row("app", "failed", "error"), row("api", "failed", "error")), false] => ["failed", 1],
        [result(row("app", "applied")), true] => ["dry_run", 0],
        [result(row("app", "rolled_back"), row("api", "failed", "error"), rolled_back: true), false] => ["failed", 1]
      }
      cases.each do |(answer, dry_run), (status, code)|
        allow(applier).to receive(:call).and_return(answer)
        outcome = applying.apply(dry_run: dry_run, json: true)
        expect([outcome[:status], outcome[:exit_code]]).to eq([status, code])
      end
    end

    it "puts the batch id and the roll back in the document's extra keys, with the warnings" do
      allow(applier).to receive(:call).and_return(result(row("app", "applied"), backup: "id-1", warnings: [{"code" => "prune_failed", "message" => "w"}]))

      expect(applying.apply(json: true)).to include(results: [row("app", "applied")], warnings: [{"code" => "prune_failed", "message" => "w"}],
        extra: {"backup" => "id-1", "rolled_back" => false, "skipped" => {}})
      expect(out.string).to be_empty
    end

    it "prints a line per row, its diff, the warnings and the batch in text mode" do
      allow(applier).to receive(:call).and_return(result(row("app", "applied", nil, "running: relaunch to take effect", diff: "-a\n+b\n"),
        row("api", "skipped", "modified", "edited"), row("new", "unchanged"), backup: "id-1", warnings: [{"code" => "rollback_failed", "message" => "x: could not be put back"}]))

      applying.apply

      expect(out.string).to eq("app: applied (running: relaunch to take effect)\n-a\n+b\napi: skipped: modified (edited)\nnew: unchanged\nBackup: id-1\n")
      expect(err.string).to eq("Warning: x: could not be put back\n")
    end

    it "prints would apply for a dry run's row, and counts the skipped rows by reason" do
      allow(applier).to receive(:call).and_return(result(row("app", "would_apply"), row("api", "skipped", "modified"), row("x", "skipped", "untracked"), row("y", "skipped", "modified")))

      outcome = applying.apply(dry_run: true)

      expect(out.string.lines.first).to eq("app: would apply\n")
      expect(outcome).to include(status: "dry_run", exit_code: 0)
      expect(outcome[:extra]["skipped"]).to eq("modified" => 2, "untracked" => 1)
    end

    it "says a dry run wrote nothing, and when there was nothing to apply to" do
      allow(applier).to receive(:call).and_return(result)

      applying.apply(dry_run: true)

      expect(out.string).to eq("No workspaces to apply to.\nDry run: nothing was written.\n")
    end

    it "is refused when no TemplateApply was wired" do
      expect { command.apply }.to raise_error(Workspace::Error, /template apply is not available/)
    end
  end

  describe "#use" do
    let(:result) { Workspace::Commands::Config::Result.new(key: "tmuxinator.template", workspace: "app", layer: "project", path: "/cfg/app.yml") }

    before do
      allow(library).to receive(:tmuxinator_set).and_return("name" => "team")
      allow(config_command).to receive(:set).and_return(result)
    end

    it "checks the name, then sets tmuxinator.template through config set" do
      row = command.use(name: "team", scope: "project", workspace: "app", cwd: "/src/app")

      expect(library).to have_received(:tmuxinator_set).with("team", workspace: "app")
      expect(config_command).to have_received(:set).with("tmuxinator.template", "team", project: "app", scope: "project", cwd: "/src/app")
      expect(row).to include("outcome" => "selected", "template" => "team", "key" => "tmuxinator.template", "layer" => "project", "file" => "/cfg/app.yml")
      expect(out.string).to eq("New tmuxinator configs now render from 'team'; existing configs are unchanged until `workspace template apply`.\n")
    end

    it "sets tmuxinator.worktree_template for --kind worktree" do
      command.use(name: "team", kind: "worktree", scope: "global", workspace: "app")

      expect(config_command).to have_received(:set).with("tmuxinator.worktree_template", "team", hash_including(scope: "global"))
    end

    it "writes the global file outside a workspace" do
      command.use(name: "team")

      expect(config_command).to have_received(:set).with("tmuxinator.template", "team", hash_including(project: nil, scope: "global"))
    end

    it "sets nothing for an unknown set" do
      allow(library).to receive(:tmuxinator_set).and_raise(Workspace::Error.new("No tmuxinator template 'nope'.", code: "unknown_template"))

      expect { command.use(name: "nope", workspace: "app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_template") }
      expect(config_command).not_to have_received(:set)
    end

    it "refuses an unknown kind" do
      expect { command.use(name: "team", kind: "both") }.to raise_error(Workspace::UsageError, /Unknown kind/)
    end
  end

  describe "#export and #import" do
    let(:store) { Workspace::LibraryStore.new(dir: File.join(@dir, "global"), scope: "global") }
    let(:backups) { Workspace::TmuxinatorBackupStore.new(config: instance_double(Workspace::Config, tmuxinator_backups_dir: File.join(@dir, "backups")), writer: writer) }
    let(:in_use) { instance_double(Workspace::TemplateInUse, check!: nil, check_default!: nil) }
    subject(:command) do
      described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
        backups: backups, template_in_use: in_use, output: out, error_output: err)
    end

    before do
      allow(library).to receive(:write_store).and_return(store)
      allow(library).to receive(:stores).and_return([store])
      allow(library).to receive(:root).and_return(File.join(@dir, "libroot"))
    end

    def seed(name, text)
      src = set_dir("seed-#{name}")
      File.write(File.join(src, "project.yml"), text)
      store.copy_tree("template", name, src)
    end

    describe "#export" do
      it "writes each user set and templates.json with its shas and the version" do
        seed("team", "p1\n")
        dest = File.join(@dir, "out")

        row = command.export(dir: dest)

        expect(File.read(File.join(dest, "team", "project.yml"))).to eq("p1\n")
        doc = JSON.parse(File.read(File.join(dest, "templates.json")))
        expect(doc).to include("schema" => 1, "workspace_version" => Workspace::VERSION)
        expect(doc["templates"]["team"]["files"]["project.yml"]).to eq(Digest::SHA256.hexdigest("p1\n"))
        expect(row).to include("outcome" => "exported", "dir" => dest, "warnings" => [])
      end

      it "leaves dotfiles out" do
        seed("team", "p1\n")
        File.write(File.join(store.path_for("template", "team"), ".DS_Store"), "x")

        command.export(dir: File.join(@dir, "out"))

        expect(Dir.children(File.join(@dir, "out", "team")).sort).to eq(%w[project.yml worktree.yml])
      end

      it "refuses a set folder already there unless --force, and then lists only the folders in DIR" do
        seed("team", "p1\n")
        dest = File.join(@dir, "out")
        command.export(dir: dest)
        seed("other", "o\n")

        expect { command.export(dir: dest) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("template_exists") }
        File.write(File.join(dest, "team", "project.yml"), "local\n")
        command.export(dir: dest, force: true)
        FileUtils.rm_rf(File.join(dest, "other"))
        command.export(dir: dest, force: true)

        expect(File.read(File.join(dest, "team", "project.yml"))).to eq("p1\n")
        expect(JSON.parse(File.read(File.join(dest, "templates.json")))["templates"].keys).to eq(%w[other team])
        FileUtils.rm_rf(File.join(dest, "other"))
        store.delete("template", "other")
        command.export(dir: dest, force: true)
        expect(JSON.parse(File.read(File.join(dest, "templates.json")))["templates"].keys).to eq(%w[team])
      end

      it "skips the legacy set with a warning, so the folder always imports back" do
        seed("team", "p1\n")
        seed("legacy", "l\n")

        row = command.export(dir: File.join(@dir, "out"))

        expect(Dir.children(File.join(@dir, "out")).sort).to eq(%w[team templates.json])
        expect(row["templates"].map { |t| t["template"] }).to eq(%w[team])
        expect(row["warnings"].map { |w| w["code"] }).to eq(%w[legacy_not_exported])
        expect(err.string).to include("Warning:").and include("template import after selecting it")
        expect { command.import(path: File.join(@dir, "out")) }.not_to raise_error
      end

      it "refuses a DIR that is the library store or inside it, even through a link" do
        seed("team", "p1\n")
        FileUtils.ln_s(File.join(@dir, "global"), File.join(@dir, "alias"))

        [File.join(@dir, "global"), File.join(@dir, "global", "template", "x"), File.join(@dir, "alias", "sub")].each do |dir|
          expect { command.export(dir: dir) }.to raise_error(Workspace::UsageError, /inside it|is the library/)
        end
        expect(Dir.exist?(File.join(@dir, "global", "template", "x"))).to be(false)
      end

      it "refuses the library root, which holds every store, and anything inside it" do
        seed("team", "p1\n")
        FileUtils.mkdir_p(File.join(@dir, "projects"))
        allow(library).to receive(:root).and_return(File.join(@dir))

        [@dir, File.join(@dir, "projects", "api"), File.join(@dir, "elsewhere")].each do |dir|
          expect { command.export(dir: dir) }.to raise_error(Workspace::UsageError, /inside it|is the library/)
        end
        expect(Dir.exist?(File.join(@dir, "elsewhere"))).to be(false)
      end

      it "says so and writes nothing when there are no user sets" do
        row = command.export(dir: File.join(@dir, "out"))

        expect(row["outcome"]).to eq("nothing_to_export")
        expect(Dir.exist?(File.join(@dir, "out"))).to be(false)
      end
    end

    describe "#import" do
      it "adds the sets of an exported folder, and reports unchanged on a second run" do
        seed("team", "p1\n")
        command.export(dir: File.join(@dir, "out"))
        FileUtils.rm_rf(File.join(@dir, "global"))

        row = command.import(path: File.join(@dir, "out"))
        again = command.import(path: File.join(@dir, "out"))

        expect(row).to include("outcome" => "imported")
        expect(row["backup"]).to match(/\A\d{8}T/)
        expect(row["templates"].map { |t| [t["template"], t["outcome"]] }).to eq([["team", "added"]])
        expect(File.read(File.join(@dir, "global/template/team/project.yml"))).to eq("p1\n")
        expect(again["outcome"]).to eq("unchanged")
      end

      it "takes one set folder and names it after the folder" do
        command.import(path: set_dir("mine"))

        expect(File.read(File.join(@dir, "global/template/mine/project.yml"))).to eq("mine project\n")
      end

      it "ignores dotfiles, so they neither get copied nor make a set differ" do
        src = set_dir("mine")
        File.write(File.join(src, ".DS_Store"), "x")
        FileUtils.mkdir_p(File.join(src, ".git"))
        File.write(File.join(src, ".git", "HEAD"), "x")

        command.import(path: src)
        File.write(File.join(@dir, "global/template/mine/.DS_Store"), "y")

        expect(Dir.children(File.join(@dir, "global/template/mine")).sort).to eq(%w[.DS_Store project.yml worktree.yml])
        expect(command.import(path: src)["outcome"]).to eq("unchanged")
      end

      it "refuses a set holding a symbolic link, writing nothing" do
        src = set_dir("mine")
        File.write(File.join(@dir, "secret"), "s")
        FileUtils.ln_s(File.join(@dir, "secret"), File.join(src, "notes.txt"))

        expect { command.import(path: src) }.to raise_error(Workspace::Error) { |e|
          expect([e.code, e.details["ref"], e.details["problems"].first["code"]]).to eq(["invalid_template", "template/mine", "symlink"])
        }
        expect(Dir.exist?(File.join(@dir, "global/template"))).to be(false)
      end

      it "refuses a set folder that is itself a link" do
        real = set_dir("real")
        FileUtils.mkdir_p(File.join(@dir, "bundle"))
        FileUtils.ln_s(real, File.join(@dir, "bundle", "linked"))

        expect { command.import(path: File.join(@dir, "bundle")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_template") }
      end

      it "backs up a set it replaces into a batch of reason import, with the set's files and shas" do
        seed("team", "old\n")

        row = command.import(path: set_dir("team"))

        expect(File.read(File.join(@dir, "global/template/team/project.yml"))).to eq("team project\n")
        manifest = JSON.parse(File.read(File.join(@dir, "backups", row["backup"], "manifest.json")))
        expect(manifest["reason"]).to eq("import")
        expect(manifest["sets"]).to match([include("name" => "team", "scope" => "global", "project" => nil,
          "sha_before" => String, "sha_after" => Workspace::LibraryStore.tree_sha(File.join(@dir, "global/template/team")))])
        expect(File.read(File.join(@dir, "backups", row["backup"], "templates/global/team/project.yml"))).to eq("old\n")
      end

      it "asks the in-use guard before replacing, and --force skips it" do
        seed("team", "old\n")
        guard = Workspace::Error.new("in use", code: "template_in_use")
        allow(in_use).to receive(:check!).and_raise(guard)

        expect { command.import(path: set_dir("team")) }.to raise_error(guard)
        expect(File.read(File.join(@dir, "global/template/team/project.yml"))).to eq("old\n")
        expect(command.import(path: set_dir("team"), force: true)["outcome"]).to eq("imported")
      end

      it "asks about a default set hiding the built-in one, and --force skips it" do
        guard = Workspace::Error.new("hides", code: "template_in_use")
        allow(in_use).to receive(:check_default!).and_raise(guard)

        expect { command.import(path: set_dir("default")) }.to raise_error(guard)
        expect(Dir.exist?(File.join(@dir, "global/template"))).to be(false)
        expect(command.import(path: set_dir("default"), force: true)["outcome"]).to eq("imported")
      end

      it "does not ask the guard for an unchanged set" do
        command.import(path: set_dir("fresh"))
        command.import(path: set_dir("fresh"))

        expect(in_use).not_to have_received(:check!)
        expect(in_use).to have_received(:check_default!).once
      end

      it "warns, on stderr and in the row, when a new set hides a lower scope's" do
        builtin = Workspace::LibraryStore.new(dir: File.join(@dir, "builtin"), scope: "builtin")
        builtin.copy_tree("template", "mine", set_dir("shipped"))
        allow(library).to receive(:stores).and_return([store, builtin])

        row = command.import(path: set_dir("mine"))

        expect(row["templates"].first["warnings"].map { |w| w["code"] }).to eq(%w[shadows_template])
        expect(err.string).to include("hides the builtin one")
      end

      it "writes nothing when one set is invalid" do
        root = File.join(@dir, "bundle")
        FileUtils.mkdir_p(root)
        FileUtils.cp_r(set_dir("a-good"), root)
        FileUtils.cp_r(set_dir("b-bad"), root)
        bad = Workspace::TemplateValidator::Problem.new(severity: "error", code: "x", kind: :project, message: "broken")
        allow(validator).to receive(:call_set) { |dir| Workspace::TemplateValidator::Result.new(errors: dir.end_with?("b-bad") ? [bad] : [], warnings: []) }

        expect { command.import(path: root) }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details["ref"]]).to eq(["invalid_template", "template/b-bad"]) }
        expect(Dir.exist?(File.join(@dir, "global/template"))).to be(false)
      end

      it "refuses a missing path, a file, an empty folder and the reserved name" do
        expect { command.import(path: File.join(@dir, "none")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
        File.write(File.join(@dir, "f"), "x")
        expect { command.import(path: File.join(@dir, "f")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
        FileUtils.mkdir_p(File.join(@dir, "empty"))
        expect { command.import(path: File.join(@dir, "empty")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
        expect { command.import(path: set_dir("legacy")) }.to raise_error(Workspace::UsageError, /reserved/)
      end

      it "refuses an unknown scope" do
        expect { command.import(path: set_dir("x"), scope: "builtin") }.to raise_error(Workspace::UsageError, /Unknown scope/)
      end
    end
  end
end
