require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Library, "#installed" do
  around do |example|
    Dir.mktmpdir("library-installed") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:app) { File.join(@dir, "app") }
  let(:home) { File.join(@dir, "home") }
  let(:common) { File.join(@dir, "app/.git") }
  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library"), builtin_library_dir: File.join(@dir, "builtin")) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:git) { instance_double(Workspace::Git, tracked?: false, common_dir_from_files: common) }
  let(:dirs) { Workspace::LibraryInstallDirs.new(home: home) }
  let(:installer) { Workspace::LibraryInstaller.new(git: git, dirs: dirs) }
  let(:checkout) { instance_double(Workspace::WorkspaceCheckout) }
  let(:output) { StringIO.new }
  subject(:command) { described_class.new(library: library, output: output, installer: installer, checkout: checkout) }

  before do
    FileUtils.mkdir_p([File.join(common, "info"), home])
    allow(project_config).to receive(:exists?) { |name| name == "app" }
    allow(lineage).to receive(:resolve) { |cwd:| Workspace::WorkspaceLineage::Lineage.new(name: (cwd == app) ? "app" : "other") }
    allow(checkout).to receive(:resolve) do |name, **|
      raise Workspace::Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name}) if name && name != "app"
      {"workspace" => "app", "path" => app, "branch" => "main"}
    end
  end

  def skill(root, name, body = "# S\n")
    FileUtils.mkdir_p(File.join(root, name))
    File.write(File.join(root, name, "SKILL.md"), body)
    File.join(root, name)
  end

  def add_entry(kind, name, body = "# S\n", scope: nil)
    store = library.write_store(scope: scope, cwd: app)
    if kind == "skill"
      store.copy_tree(kind, name, skill(File.join(@dir, "src"), name, body))
    else
      store.write(kind, name, body)
    end
  end

  def exclude(*lines)
    File.write(File.join(common, "info", "exclude"), lines.map { |l| "#{l}\n" }.join)
  end

  def json
    JSON.parse(output.string)
  end

  it "lists a copy that matches its entry, a modified one and one whose entry is gone" do
    add_entry("skill", "pdf-tools")
    add_entry("agent", "reviewer", "Review.\n", scope: "project")
    skill(File.join(app, ".claude/skills"), "pdf-tools")
    FileUtils.mkdir_p(File.join(app, ".claude/agents"))
    File.write(File.join(app, ".claude/agents/reviewer.md"), "Edited.\n")
    skill(File.join(app, ".claude/skills"), "old-one")
    exclude("/.claude/skills/old-one/")

    command.installed(cwd: app, json: true)

    expect(json).to include("schema_version" => 1, "ok" => true, "workspace" => "app", "user" => false)
    expect(json["copies"]).to eq([
      {"kind" => "agent", "name" => "reviewer", "ref" => "agent/reviewer", "path" => File.join(app, ".claude/agents/reviewer.md"), "entry" => "project", "modified" => true},
      {"kind" => "skill", "name" => "old-one", "ref" => "skill/old-one", "path" => File.join(app, ".claude/skills/old-one"), "entry" => nil, "modified" => false},
      {"kind" => "skill", "name" => "pdf-tools", "ref" => "skill/pdf-tools", "path" => File.join(app, ".claude/skills/pdf-tools"), "entry" => "global", "modified" => false}
    ])
  end

  describe "a copy of a shadowed entry" do
    before do
      add_entry("skill", "pdf-tools", "# Global\n")
      add_entry("skill", "pdf-tools", "# Project\n", scope: "project")
    end

    it "reads as matching the store whose entry it equals, not modified" do
      skill(File.join(app, ".claude/skills"), "pdf-tools", "# Global\n")

      command.installed(cwd: app, json: true)

      expect(json["copies"].first).to include("entry" => "global", "modified" => false)
    end

    it "reports the first-found scope, modified, when it matches neither" do
      skill(File.join(app, ".claude/skills"), "pdf-tools", "# Edited\n")

      command.installed(cwd: app, json: true)

      expect(json["copies"].first).to include("entry" => "project", "modified" => true)
    end

    it "uninstalls it without --force in a workspace and at user level, but refuses one matching neither" do
      skill(File.join(app, ".claude/skills"), "pdf-tools", "# Global\n")
      expect(command.uninstall("skill/pdf-tools", name: "app", cwd: app).result).to eq("removed")

      skill(File.join(home, ".claude/skills"), "pdf-tools", "# Global\n")
      expect(command.uninstall("skill/pdf-tools", user: true, cwd: app).result).to eq("removed")

      skill(File.join(app, ".claude/skills"), "pdf-tools", "# Edited\n")
      expect { command.uninstall("skill/pdf-tools", name: "app", cwd: app) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_uninstall_modified") }
      skill(File.join(home, ".claude/skills"), "pdf-tools", "# Edited\n")
      expect { command.uninstall("skill/pdf-tools", user: true, cwd: app) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_uninstall_modified") }
    end
  end

  it "leaves out hand-made items that no entry and no exclude line names" do
    skill(File.join(app, ".claude/skills"), "mine")
    FileUtils.mkdir_p(File.join(app, ".claude/agents"))
    File.write(File.join(app, ".claude/agents/notes.md"), "x")
    File.write(File.join(app, ".claude/agents/readme.txt"), "x")

    command.installed(cwd: app, json: true)

    expect(json["copies"]).to eq([])
  end

  it "reads an exclude line with trailing whitespace and CRLF" do
    skill(File.join(app, ".claude/skills"), "old-one")
    File.write(File.join(common, "info", "exclude"), "/.claude/skills/old-one/ \r\n")

    command.installed(cwd: app, json: true)

    expect(json["copies"].map { |c| c["name"] }).to eq(["old-one"])
  end

  it "reports a copy of an unreadable entry as modified" do
    add_entry("skill", "pdf-tools")
    skill(File.join(app, ".claude/skills"), "pdf-tools")
    allow(library).to receive(:entries).and_wrap_original do |m, *args, **kw|
      m.call(*args, **kw).map { |e| e.merge("readable" => false) }
    end

    command.installed(cwd: app, json: true)

    expect(json["copies"].first).to include("entry" => "global", "modified" => true)
  end

  it "reports a symlinked copy as modified" do
    add_entry("skill", "pdf-tools")
    FileUtils.mkdir_p(File.join(app, ".claude/skills"))
    File.symlink(skill(File.join(@dir, "elsewhere"), "pdf-tools"), File.join(app, ".claude/skills/pdf-tools"))

    command.installed(cwd: app, json: true)

    expect(json["copies"].first).to include("name" => "pdf-tools", "modified" => true)
  end

  it "filters by kind" do
    add_entry("skill", "pdf-tools")
    add_entry("agent", "reviewer", "Review.\n")
    skill(File.join(app, ".claude/skills"), "pdf-tools")
    FileUtils.mkdir_p(File.join(app, ".claude/agents"))
    File.write(File.join(app, ".claude/agents/reviewer.md"), "Review.\n")

    command.installed(cwd: app, kind: "agent", json: true)

    expect(json["copies"].map { |c| c["ref"] }).to eq(["agent/reviewer"])
  end

  it "lists user-level copies with workspace null, by library entry name only" do
    add_entry("skill", "pdf-tools")
    skill(File.join(home, ".claude/skills"), "pdf-tools", "# Changed\n")
    skill(File.join(home, ".claude/skills"), "hand-made")
    exclude("/.claude/skills/hand-made/")

    command.installed(cwd: app, user: true, json: true)

    expect(json).to include("workspace" => nil, "user" => true)
    expect(json["copies"]).to eq([
      {"kind" => "skill", "name" => "pdf-tools", "ref" => "skill/pdf-tools", "path" => File.join(home, ".claude/skills/pdf-tools"), "entry" => "global", "modified" => true}
    ])
  end

  it "follows the configured install directory" do
    resolver = instance_double(Workspace::ConfigResolver)
    view = double(resolve: double(winner: double(value: ".agents/skills")))
    allow(resolver).to receive(:view).and_return(view)
    configured = Workspace::LibraryInstaller.new(git: git, dirs: Workspace::LibraryInstallDirs.new(config_resolver: resolver, home: home))
    add_entry("skill", "pdf-tools")
    skill(File.join(app, ".agents/skills"), "pdf-tools")
    skill(File.join(app, ".claude/skills"), "pdf-tools")
    cmd = described_class.new(library: library, output: output, installer: configured, checkout: checkout)

    cmd.installed(cwd: app, kind: "skill", json: true)

    expect(json["copies"].map { |c| c["path"] }).to eq([File.join(app, ".agents/skills/pdf-tools")])
  end

  it "lists nothing through a symlinked install directory" do
    add_entry("skill", "pdf-tools")
    skill(File.join(@dir, "real"), "pdf-tools")
    FileUtils.mkdir_p(File.join(app, ".claude"))
    File.symlink(File.join(@dir, "real"), File.join(app, ".claude/skills"))

    command.installed(cwd: app, json: true)

    expect(json["copies"]).to eq([])
  end

  it "prints a line per copy, or says there are none" do
    command.installed(cwd: app)
    expect(output.string).to eq("No installed copies in workspace app.\n")

    add_entry("skill", "pdf-tools")
    skill(File.join(app, ".claude/skills"), "pdf-tools")
    output.truncate(0)
    output.rewind
    command.installed(cwd: app)
    expect(output.string).to eq("skill/pdf-tools  matches global    #{File.join(app, ".claude/skills/pdf-tools")}\n")
  end

  it "refuses --user with a workspace, a kind that is not copied, and an unknown workspace" do
    expect { command.installed(name: "app", user: true, cwd: app) }.to raise_error(Workspace::UsageError, /takes no --name/)
    expect { command.installed(kind: "play", cwd: app) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_kind_not_copyable") }
    expect { command.installed(kind: "nope", cwd: app) }.to raise_error(Workspace::UsageError)
    expect { command.installed(name: "ghost", cwd: app) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
  end

  it "raises invalid_library_install_dir for a bad stored value" do
    resolver = instance_double(Workspace::ConfigResolver)
    view = double(resolve: double(winner: double(value: "/abs")))
    allow(resolver).to receive(:view).and_return(view)
    bad = Workspace::LibraryInstaller.new(git: git, dirs: Workspace::LibraryInstallDirs.new(config_resolver: resolver, home: home))
    cmd = described_class.new(library: library, output: output, installer: bad, checkout: checkout)

    expect { cmd.installed(cwd: app) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_library_install_dir") }
  end
end
