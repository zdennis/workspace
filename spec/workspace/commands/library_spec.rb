require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Library do
  around do |example|
    Dir.mktmpdir("library-cmd") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library"), builtin_library_dir: File.join(@dir, "builtin")) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:cwd) { File.join(@dir, "app") }
  subject(:command) { described_class.new(library: library, output: output, input: input) }

  before do
    FileUtils.mkdir_p(cwd)
    allow(project_config).to receive(:exists?) { |name| name == "app" }
    allow(lineage).to receive(:resolve).with(cwd: cwd).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
  end

  def source(name, body)
    File.join(@dir, name).tap { |path| File.write(path, body) }
  end

  describe "#add" do
    it "copies a file into the global store, named after the file in kebab case" do
      path = source("Agent Orchestration Playbook.md", "# Playbook\n")

      result = command.add(kind: "play", path: path, cwd: cwd)

      expect(result.to_h).to include(outcome: "added", workspace: nil, message: "Added play/agent-orchestration-playbook in the global library.")
      expect(result.entry).to include("ref" => "play/agent-orchestration-playbook", "scope" => "global", "link" => nil, "description" => "Playbook")
      expect(File.read(File.join(@dir, "library/global/play/agent-orchestration-playbook.md"))).to eq("# Playbook\n")
      expect(output.string).to eq("Added play/agent-orchestration-playbook in the global library.\n")
    end

    it "stores under the project of cwd with the project scope" do
      path = source("kickoff.md", "go")

      result = command.add(kind: "prompt", path: path, scope: "project", cwd: cwd)

      expect(result.workspace).to eq("app")
      expect(result.entry["path"]).to eq(File.join(@dir, "library/projects/app/prompt/kickoff.md"))
      expect(output.string).to include("in project app.")
    end

    it "links instead of copying with --link, resolving the path from cwd" do
      File.write(File.join(cwd, "Play.md"), "# Linked\n")

      result = command.add(kind: "play", path: "Play.md", link: true, cwd: cwd)

      expect(result.entry).to include("link" => File.join(cwd, "Play.md"), "readable" => true)
      expect(File.symlink?(result.entry["path"])).to be true
    end

    it "reads the body from stdin with --as" do
      result = command.add(kind: "prompt", body: "typed\n", name: "typed", cwd: cwd)

      expect(result.outcome).to eq("added")
      expect(File.read(result.entry["path"])).to eq("typed\n")
    end

    it "needs a name for stdin and a file for --link" do
      expect { command.add(kind: "prompt", body: "x", cwd: cwd) }.to raise_error(Workspace::UsageError, /--as NAME/)
      expect { command.add(kind: "prompt", body: "x", name: "x", link: true, cwd: cwd) }.to raise_error(Workspace::UsageError, /--link needs a file path/)
    end

    it "rejects a bad kind or name as usage before touching the store" do
      path = source("x.md", "x")
      expect { command.add(kind: "tool", path: path, cwd: cwd) }.to raise_error(Workspace::UsageError, /Unknown kind 'tool'/)
      expect { command.add(kind: "play", path: path, name: "Bad_Name", cwd: cwd) }.to raise_error(Workspace::UsageError, /not a valid library name/)
      expect(Dir.exist?(File.join(@dir, "library"))).to be false
    end

    it "fails with library_source_missing for a file that isn't there, for a copy and a link" do
      expect { command.add(kind: "play", path: "nope.md", cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "play/nope", "path" => File.join(cwd, "nope.md"))
      }
      expect { command.add(kind: "play", path: "nope.md", link: true, cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
      }
      expect(Dir.glob(File.join(@dir, "library/**/*"))).to all(satisfy { |p| File.directory?(p) })
    end

    it "is unchanged for identical content and refuses different content without --force" do
      path = source("x.md", "same")
      command.add(kind: "play", path: path, cwd: cwd)

      expect(command.add(kind: "play", path: path, cwd: cwd).outcome).to eq("unchanged")
      File.write(path, "different")
      expect { command.add(kind: "play", path: path, cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_entry_exists")
        expect(e.details).to eq("ref" => "play/x", "scope" => "global")
        expect(e.retry).to eq("flags" => ["--force"], "destructive" => true)
      }
      expect(File.read(File.join(@dir, "library/global/play/x.md"))).to eq("same")
    end

    it "replaces different content with --force, a copy over a link too" do
      path = source("x.md", "one")
      command.add(kind: "play", path: path, link: true, cwd: cwd)

      expect(command.add(kind: "play", path: path, link: true, cwd: cwd).outcome).to eq("unchanged")
      expect { command.add(kind: "play", path: path, cwd: cwd) }.to raise_error(Workspace::Error, /--force/)
      result = command.add(kind: "play", path: path, force: true, cwd: cwd)

      expect(result.outcome).to eq("replaced")
      expect(File.symlink?(result.entry["path"])).to be false
      expect(File.read(result.entry["path"])).to eq("one")
    end

    it "writes nothing with --dry-run and reports the outcome it would have had" do
      path = source("x.md", "one")

      result = command.add(kind: "play", path: path, dry_run: true, cwd: cwd)

      expect(result.outcome).to eq("added")
      expect(result.entry).to eq("kind" => "play", "name" => "x", "ref" => "play/x", "scope" => "global", "project" => nil,
        "path" => File.join(@dir, "library/global/play/x.md"), "link" => nil, "readable" => nil, "description" => nil, "updated_at" => nil)
      expect(File.exist?(result.entry["path"])).to be false
      expect(output.string).to eq("Would add play/x in the global library.\n")
      expect { command.add(kind: "play", path: source("x.md", "two"), dry_run: true, cwd: cwd) }.not_to raise_error
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)
      expect { command.add(kind: "play", path: source("x.md", "two"), dry_run: true, cwd: cwd) }.to raise_error(Workspace::Error, /--force/)
    end
  end

  describe "agents and skills" do
    def skill_dir(name, body = "# Skill\n", extra: {})
      File.join(@dir, name).tap do |dir|
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), body)
        extra.each do |rel, text|
          FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
          File.write(File.join(dir, rel), text)
        end
      end
    end
    let(:skill_path) { File.join(@dir, "library/global/skill/write-tests") }

    it "adds an agent file like a play" do
      result = command.add(kind: "agent", path: source("Code Reviewer.md", "You review.\n"), cwd: cwd)

      expect(result.entry).to include("ref" => "agent/code-reviewer", "path" => File.join(@dir, "library/global/agent/code-reviewer.md"))
    end

    it "copies a skill directory, named after the directory, with every file in it" do
      source_dir = skill_dir("Write Tests", "# Write tests\n", extra: {"scripts/run.sh" => "echo\n"})

      result = command.add(kind: "skill", path: source_dir, cwd: cwd)

      expect(result.outcome).to eq("added")
      expect(result.entry).to include("ref" => "skill/write-tests", "path" => skill_path, "link" => nil, "description" => "Write tests")
      expect(File.read(File.join(skill_path, "scripts/run.sh"))).to eq("echo\n")
    end

    it "is unchanged for the same tree, and refuses a changed one without --force" do
      source_dir = skill_dir("write-tests", extra: {"a.txt" => "one"})
      command.add(kind: "skill", path: source_dir, cwd: cwd)

      expect(command.add(kind: "skill", path: source_dir, cwd: cwd).outcome).to eq("unchanged")
      File.write(File.join(source_dir, "a.txt"), "two")
      expect { command.add(kind: "skill", path: source_dir, cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_entry_exists")
      }
      expect(command.add(kind: "skill", path: source_dir, force: true, cwd: cwd).outcome).to eq("replaced")
      expect(File.read(File.join(skill_path, "a.txt"))).to eq("two")
    end

    it "links a skill directory with --link" do
      source_dir = skill_dir("write-tests")

      result = command.add(kind: "skill", path: source_dir, link: true, cwd: cwd)

      expect(result.entry).to include("link" => source_dir, "readable" => true)
      expect(File.symlink?(skill_path)).to be true
    end

    it "stores a skill from stdin as a directory holding SKILL.md" do
      command.add(kind: "skill", body: "# From stdin\n", name: "write-tests", cwd: cwd)

      expect(File.read(File.join(skill_path, "SKILL.md"))).to eq("# From stdin\n")
    end

    it "refuses a file as a skill and a directory without SKILL.md" do
      expect { command.add(kind: "skill", path: source("x.md", "x"), cwd: cwd) }
        .to raise_error(Workspace::UsageError, /a skill is a directory holding SKILL.md/)
      FileUtils.mkdir_p(File.join(@dir, "empty"))
      expect { command.add(kind: "skill", path: File.join(@dir, "empty"), cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
      }
      expect { command.add(kind: "skill", path: File.join(@dir, "empty"), link: true, cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
      }
    end

    it "shows a skill's SKILL.md, updates it from a directory, and removes the directory" do
      command.add(kind: "skill", path: skill_dir("write-tests", "# One\n"), cwd: cwd)

      command.show("skill/write-tests", cwd: cwd)
      expect(output.string).to end_with("# One\n")
      expect(command.update("write-tests", path: skill_dir("v2", "# Two\n"), cwd: cwd).outcome).to eq("updated")
      expect(File.read(File.join(skill_path, "SKILL.md"))).to eq("# Two\n")
      expect(command.remove("skill/write-tests", yes: true, cwd: cwd).outcome).to eq("removed")
      expect(File.exist?(skill_path)).to be false
    end
  end

  describe "#update" do
    it "replaces the content of an existing entry and is unchanged for the same content" do
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)

      expect(command.update("play/x", path: source("y.md", "two"), cwd: cwd).outcome).to eq("updated")
      expect(File.read(File.join(@dir, "library/global/play/x.md"))).to eq("two")
      expect(command.update("x", body: "two", cwd: cwd).outcome).to eq("unchanged")
      expect(output.string.lines.last).to eq("Unchanged play/x in the global library.\n")
    end

    it "repoints a link and only looks in the write scope" do
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)
      target = source("other.md", "other")

      result = command.update("play/x", path: target, link: true, cwd: cwd)

      expect(result.outcome).to eq("updated")
      expect(result.entry["link"]).to eq(target)
      expect { command.update("play/x", path: target, scope: "project", cwd: cwd) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "play/x", "scopes" => ["project:app"])
      }
    end

    it "writes nothing with --dry-run" do
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)

      expect(command.update("play/x", body: "two", dry_run: true, cwd: cwd).outcome).to eq("updated")
      expect(File.read(File.join(@dir, "library/global/play/x.md"))).to eq("one")
      expect(output.string.lines.last).to eq("Would update play/x in the global library.\n")
    end
  end

  describe "#remove" do
    before { command.add(kind: "play", path: source("x.md", "one"), cwd: cwd) }

    it "deletes the entry with --yes" do
      result = command.remove("play/x", yes: true, cwd: cwd)

      expect(result.to_h).to include(outcome: "removed", workspace: nil, message: "Removed play/x from the global library.")
      expect(result.entry["ref"]).to eq("play/x")
      expect(File.exist?(File.join(@dir, "library/global/play/x.md"))).to be false
    end

    it "asks first and keeps the entry on anything but y" do
      input.string = "n\n"

      expect(command.remove("play/x", cwd: cwd)).to be_nil
      expect(output.string).to include("Remove play/x from the global library? [y/N] ").and include("Cancelled.")
      expect(File.exist?(File.join(@dir, "library/global/play/x.md"))).to be true
    end

    it "removes on y" do
      input.string = "Y\n"

      expect(command.remove("play/x", cwd: cwd).outcome).to eq("removed")
    end

    it "refuses to ask when input is off" do
      no_input = Workspace::PromptInput.new(StringIO.new, no_input: true)
      command = described_class.new(library: library, output: output, input: no_input)

      expect { command.remove("play/x", cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
    end

    it "writes nothing with --dry-run and fails for an unknown entry" do
      expect(command.remove("play/x", dry_run: true, cwd: cwd).outcome).to eq("removed")
      expect(File.exist?(File.join(@dir, "library/global/play/x.md"))).to be true
      expect(output.string.lines.last).to eq("Would remove play/x from the global library.\n")
      expect { command.remove("play/nope", yes: true, cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
    end
  end

  describe "#list, #show and #info" do
    before do
      command.add(kind: "play", path: source("kickoff.md", "---\ndescription: Global kickoff\n---\n# K\n"), cwd: cwd)
      command.add(kind: "play", path: source("kickoff.md", "# Project kickoff\n"), scope: "project", cwd: cwd)
      command.add(kind: "prompt", path: source("fix.md", "fix it\n"), cwd: cwd)
      output.truncate(0)
      output.rewind
      output.rewind
    end

    it "lists every visible entry as a table, hidden ones marked" do
      command.list(cwd: cwd)

      expect(output.string).to eq(<<~TEXT)
        play    kickoff  project:app      Project kickoff
        play    kickoff  global (hidden)  Global kickoff
        prompt  fix      global
      TEXT
    end

    it "lists as JSON with effective flags, filtered by kind and scope" do
      command.list(kind: "play", scope: "global", json: true, cwd: cwd)

      doc = JSON.parse(output.string)
      expect(doc).to include("schema_version" => 1, "ok" => true)
      expect(doc["entries"].map { |e| e.slice("ref", "scope", "project", "effective", "readable", "link") }).to eq([
        {"ref" => "play/kickoff", "scope" => "global", "project" => nil, "effective" => true, "readable" => true, "link" => nil}
      ])
      expect(doc["entries"].first.keys).to eq(%w[kind name ref scope project path link readable description updated_at effective])
    end

    it "says how to add when nothing is there" do
      command.list(scope: "project", kind: "prompt", cwd: cwd)
      allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "nowhere"))
      command.list(kind: "play", cwd: File.join(@dir, "nowhere"))

      expect(output.string.lines).to eq([
        "No library entries. Add one with: workspace library add PATH --kind play\n",
        "play  kickoff  global  Global kickoff\n"
      ])
    end

    it "lists, shows and describes the built-in plays, last and hidden by a global play of the same name" do
      library.builtin_store.write("play", "orchestrator", "---\ndescription: Delegate to sub-agents\n---\nDelegate.\n")
      library.builtin_store.write("play", "kickoff", "Built-in kickoff.\n")

      command.list(kind: "play", cwd: cwd)
      expect(output.string).to eq(<<~TEXT)
        play  kickoff       project:app       Project kickoff
        play  kickoff       global (hidden)   Global kickoff
        play  kickoff       builtin (hidden)
        play  orchestrator  builtin           Delegate to sub-agents
      TEXT

      output.truncate(0)
      output.rewind
      output.rewind
      command.list(scope: "builtin", json: true, cwd: cwd)
      expect(JSON.parse(output.string)["entries"].map { |e| e.slice("ref", "scope", "project", "effective") }).to eq([
        {"ref" => "play/kickoff", "scope" => "builtin", "project" => nil, "effective" => true},
        {"ref" => "play/orchestrator", "scope" => "builtin", "project" => nil, "effective" => true}
      ])

      output.truncate(0)
      output.rewind
      output.rewind
      command.show("kickoff", scope: "builtin", cwd: cwd)
      command.show("play/orchestrator", cwd: cwd)
      expect(output.string).to eq("Built-in kickoff.\n---\ndescription: Delegate to sub-agents\n---\nDelegate.\n")

      output.truncate(0)
      output.rewind
      output.rewind
      command.info("orchestrator", json: true, cwd: cwd)
      expect(JSON.parse(output.string)["entry"]).to include("scope" => "builtin", "path" => library.builtin_store.path_for("play", "orchestrator"))
    end

    it "never writes to the built-in store: update and remove look in the global or project store only" do
      library.builtin_store.write("play", "orchestrator", "Delegate.\n")

      expect { command.update("play/orchestrator", body: "mine\n", cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
      expect { command.remove("play/orchestrator", yes: true, cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
      command.add(kind: "play", body: "mine\n", name: "orchestrator", cwd: cwd)

      expect(library.builtin_store.read("play", "orchestrator")).to eq("Delegate.\n")
      expect(library.global_store.read("play", "orchestrator")).to eq("mine\n")
    end

    it "rejects a bad kind filter" do
      expect { command.list(kind: "tool", cwd: cwd) }.to raise_error(Workspace::UsageError, /Unknown kind 'tool'/)
    end

    it "shows the effective body as is, and the global one with --global" do
      command.show("kickoff", cwd: cwd)
      expect(output.string).to eq("# Project kickoff\n")

      output.truncate(0)
      output.rewind
      output.rewind
      command.show("play/kickoff", scope: "global", json: true, cwd: cwd)
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "body" => "---\ndescription: Global kickoff\n---\n# K\n")
      expect(doc["entry"]).to include("scope" => "global", "effective" => true)
    end

    it "fails show for a broken link with library_source_missing" do
      command.add(kind: "prompt", path: source("gone.md", "x"), link: true, cwd: cwd)
      File.unlink(File.join(@dir, "gone.md"))

      expect { command.show("prompt/gone", cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
    end

    it "prints an entry's metadata with info" do
      command.info("prompt/fix", cwd: cwd)

      expect(output.string).to include("kind        prompt\n", "name        fix\n", "scope       global\n", "project     -\n", "effective   true\n", "link        -\n")
      expect(output.string).to match(/^path        .*\/library\/global\/prompt\/fix\.md$/)
    end
  end

  describe ".name_from_path" do
    it "drops the extension and makes kebab case" do
      expect(described_class.name_from_path("/x/Agent Orchestration Playbook.md")).to eq("agent-orchestration-playbook")
      expect(described_class.name_from_path("My_Prompt.v2.txt")).to eq("my-prompt-v2")
      expect(described_class.name_from_path("-")).to eq("")
    end
  end

  describe "library_changed events" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    subject(:command) { described_class.new(library: library, output: output, input: input, event_log: event_log) }

    def changed(ref, scope, action, project = "")
      {"type" => "library_changed", "project" => project, "data" => {"ref" => ref, "scope" => scope, "action" => action}}
    end

    it "records add, update (also add --force) and remove" do
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)
      command.update("play/x", body: "two", cwd: cwd)
      command.add(kind: "play", path: source("x.md", "three"), force: true, cwd: cwd)
      command.remove("play/x", yes: true, cwd: cwd)

      expect(event_log.events).to eq([
        changed("play/x", "global", "add"), changed("play/x", "global", "update"),
        changed("play/x", "global", "update"), changed("play/x", "global", "remove")
      ])
    end

    it "names the project for a project store" do
      command.add(kind: "prompt", path: source("p.md", "hi"), scope: "project", cwd: cwd)

      expect(event_log.events).to eq([changed("prompt/p", "project", "add", "app")])
    end

    it "writes nothing for unchanged, dry-run, declined or failed writes" do
      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)
      event_log.events.clear

      command.add(kind: "play", path: source("x.md", "one"), cwd: cwd)
      command.update("play/x", body: "one", cwd: cwd)
      command.add(kind: "play", path: source("x.md", "two"), force: true, dry_run: true, cwd: cwd)
      command.update("play/x", body: "two", dry_run: true, cwd: cwd)
      command.remove("play/x", dry_run: true, cwd: cwd)
      input.string = "n\n"
      command.remove("play/x", cwd: cwd)
      expect { command.add(kind: "play", path: source("x.md", "two"), cwd: cwd) }.to raise_error(Workspace::Error)
      expect { command.remove("play/missing", yes: true, cwd: cwd) }.to raise_error(Workspace::Error)

      expect(event_log.events).to be_empty
    end
  end

  describe "spine templates" do
    def template_dir(name = "team-template", files: {"10-research.md" => "r\n", "README.md" => "---\ndescription: Team\n---\n"})
      File.join(@dir, name).tap do |dir|
        files.each do |rel, text|
          FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
          File.write(File.join(dir, rel), text)
        end
      end
    end
    let(:store_path) { File.join(@dir, "library/global/spine/team") }

    it "copies a folder of stage files, named with --as, and lists it with description and files" do
      result = command.add(kind: "spine", path: template_dir, name: "team", cwd: cwd)

      expect(result.outcome).to eq("added")
      expect(File.read(File.join(store_path, "10-research.md"))).to eq("r\n")

      output.truncate(0)
      output.rewind
      command.list(kind: "spine", cwd: cwd, json: true)
      entry = JSON.parse(output.string)["entries"].first
      expect(entry).to include("ref" => "spine/team", "scope" => "global", "description" => "Team", "files" => %w[10-research.md README.md])
    end

    it "links a folder and reads files through the link" do
      source = template_dir
      command.add(kind: "spine", path: source, name: "team", link: true, cwd: cwd)

      expect(File.symlink?(store_path)).to be(true)
      expect(File.readlink(store_path)).to eq(source)
    end

    it "stores into a project with --project" do
      command.add(kind: "spine", path: template_dir, name: "team", scope: "project", project: "app", cwd: cwd)

      expect(File.directory?(File.join(@dir, "library/projects/app/spine/team"))).to be(true)
    end

    it "is unchanged when added again with the same files, and needs --force for different ones" do
      command.add(kind: "spine", path: template_dir, name: "team", cwd: cwd)
      expect(command.add(kind: "spine", path: template_dir, name: "team", cwd: cwd).outcome).to eq("unchanged")

      other = template_dir("other", files: {"10-x.md" => "x\n"})
      expect { command.add(kind: "spine", path: other, name: "team", cwd: cwd) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_entry_exists") }
      expect(command.add(kind: "spine", path: other, name: "team", force: true, cwd: cwd).outcome).to eq("replaced")
    end

    it "refuses a file, a folder with no markdown, a missing path and stdin" do
      file = source("one.md", "x")
      expect { command.add(kind: "spine", path: file, name: "a", cwd: cwd) }.to raise_error(Workspace::UsageError, /folder of stage files/)
      expect { command.add(kind: "spine", path: template_dir("empty", files: {"notes.txt" => "n"}), name: "b", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
      expect { command.add(kind: "spine", path: File.join(@dir, "none"), name: "c", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
      expect { command.add(kind: "spine", body: "x", name: "d", cwd: cwd) }.to raise_error(Workspace::UsageError, /folder of stage files/)
      expect(Dir.exist?(File.join(@dir, "library/global/spine"))).to be(false)
    end

    it "shows the README.md of a template" do
      command.add(kind: "spine", path: template_dir, name: "team", cwd: cwd)
      output.truncate(0)
      output.rewind

      command.show("spine/team", cwd: cwd)

      expect(output.string).to eq("---\ndescription: Team\n---\n")
    end
  end

  describe "#install and #uninstall" do
    let(:installer) { instance_double(Workspace::LibraryInstaller) }
    let(:checkout) { instance_double(Workspace::WorkspaceCheckout) }
    let(:target) { {"workspace" => "app", "path" => cwd, "branch" => "main"} }
    subject(:command) { described_class.new(library: library, output: output, input: input, installer: installer, checkout: checkout) }

    before do
      allow(checkout).to receive(:resolve).with("app", working_dir: anything, allow_detached: true).and_return(target)
      allow(installer).to receive(:relative_path) { |kind, name, **| File.join(".claude", "#{kind}s", (kind == "agent") ? "#{name}.md" : name) }
      command.add(kind: "skill", path: skill_dir("global body"), name: "tests", cwd: cwd)
      command.add(kind: "skill", path: skill_dir("project body"), name: "tests", scope: "project", cwd: cwd)
      command.add(kind: "play", body: "p", name: "kickoff", cwd: cwd)
      output.truncate(0)
      output.rewind
    end

    def skill_dir(body)
      File.join(@dir, "skill-#{body.tr(" ", "-")}").tap do |dir|
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), body)
      end
    end

    it "installs the entry from the target workspace's project store, reporting the document" do
      expect(installer).to receive(:install) do |entry, worktree:, project:, force:, dry_run:|
        expect(entry).to include("ref" => "skill/tests", "scope" => "project")
        expect([worktree, project, force, dry_run]).to eq([cwd, "app", true, false])
        {"result" => "installed", "path" => "#{cwd}/.claude/skills/tests"}
      end

      result = command.install("tests", name: "app", force: true, cwd: "/elsewhere")

      expect(result.to_h).to eq("schema_version" => 1, "ok" => true, "ref" => "skill/tests", "workspace" => "app",
        "result" => "installed", "path" => "#{cwd}/.claude/skills/tests", "dry_run" => false, "user" => false)
      expect(output.string).to eq("Installed skill/tests at #{cwd}/.claude/skills/tests (workspace app).\n")
    end

    it "refuses a play with library_kind_not_copyable and an unknown ref with unknown_library_entry" do
      expect { command.install("play/kickoff", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_kind_not_copyable") }
      expect { command.install("kickoff", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_kind_not_copyable") }
      expect { command.install("skill/nope", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
    end

    it "passes unknown_workspace through from the checkout" do
      allow(checkout).to receive(:resolve).with("nope", working_dir: cwd, allow_detached: true)
        .and_raise(Workspace::Error.new("Unknown workspace 'nope'", code: "unknown_workspace"))

      expect { command.install("skill/tests", name: "nope", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    end

    it "uninstalls by a library ref, or by what is installed once the entry is gone, without touching the library" do
      expect(installer).to receive(:uninstall).with("skill", "tests", worktree: cwd, project: "app", dry_run: true, entry: a_hash_including("ref" => "skill/tests"), force: false)
        .and_return({"result" => "would_remove", "path" => "#{cwd}/.claude/skills/tests"})
      expect(installer).to receive(:uninstall).with("agent", "gone", worktree: cwd, project: "app", dry_run: false, entry: nil, force: false)
        .and_return({"result" => "absent", "path" => "#{cwd}/.claude/agents/gone.md"})

      expect(command.uninstall("tests", name: "app", dry_run: true, cwd: cwd).result).to eq("would_remove")
      expect(output.string).to start_with("Would remove skill/tests from")
      FileUtils.mkdir_p(File.join(cwd, ".claude", "agents"))
      File.write(File.join(cwd, ".claude", "agents", "gone.md"), "x")
      expect(command.uninstall("gone", name: "app", cwd: cwd).result).to eq("absent")
      expect(library.entries(library.stores(cwd: cwd)).map { |e| e["ref"] }).to include("skill/tests")
    end

    it "passes --force through to uninstall without reading the library entry" do
      expect(installer).to receive(:uninstall).with("skill", "tests", worktree: cwd, project: "app", dry_run: false, entry: nil, force: true)
        .and_return({"result" => "removed", "path" => "#{cwd}/.claude/skills/tests"})

      expect(command.uninstall("skill/tests", name: "app", force: true, cwd: cwd).result).to eq("removed")
    end

    it "installs at user level with no workspace, from the working directory's library" do
      expect(checkout).not_to receive(:resolve)
      expect(installer).to receive(:install_user) do |entry, force:, dry_run:|
        expect(entry).to include("ref" => "skill/tests", "scope" => "project")
        expect([force, dry_run]).to eq([false, false])
        {"result" => "installed", "path" => "/home/me/.agents/skills/tests"}
      end

      result = command.install("skill/tests", user: true, cwd: cwd)

      expect(result.to_h).to include("workspace" => nil, "result" => "installed", "path" => "/home/me/.agents/skills/tests", "user" => true)
      expect(output.string).to eq("Installed skill/tests at /home/me/.agents/skills/tests (user level).\n")
    end

    it "reports a dry-run install as would_install" do
      allow(installer).to receive(:install).and_return({"result" => "would_install", "path" => "#{cwd}/.claude/skills/tests"})

      expect(command.install("skill/tests", name: "app", dry_run: true, cwd: cwd).result).to eq("would_install")
      expect(output.string).to start_with("Would install skill/tests at")
    end

    it "refuses an ambiguous bare name with ambiguous_library_entry" do
      command.add(kind: "agent", body: "x", name: "tests", cwd: cwd)

      expect { command.install("tests", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ambiguous_library_entry") }
      expect { command.uninstall("tests", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ambiguous_library_entry") }
    end

    it "refuses an uninstall of a play or an unknown name" do
      expect { command.uninstall("play/kickoff", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_kind_not_copyable") }
      expect { command.uninstall("nothing", name: "app", cwd: cwd) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
    end
  end
end
