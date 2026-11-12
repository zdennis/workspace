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
  let(:library) { instance_double(Workspace::Library) }
  subject(:command) { described_class.new(library: library, output: out) }

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

  def selects(kind, name, scope: "builtin", source: "default")
    allow(library).to receive(:tmuxinator_template).with(kind, workspace: "app").and_return(
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
end
