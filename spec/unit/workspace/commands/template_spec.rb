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
  let(:validator) { instance_double(Workspace::TemplateValidator, call_file: []) }
  let(:differ) { ->(old, new, old_label:, new_label:) { "--- #{old_label}\n+++ #{new_label}\n-#{old}+#{new}" } }
  subject(:command) do
    described_class.new(library: library, project_config: project_config, writer: writer, template_validator: validator, differ: differ,
      output: out, error_output: err)
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
end
