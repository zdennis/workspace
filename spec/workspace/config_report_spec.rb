require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::ConfigReport do
  let(:dir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config, workspace_config_dir: dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  let(:available) { %w[api api.worktree-fix api.worktree-search other] }
  let(:roots) { {"api" => "/src/api", "api.worktree-fix" => "/src/api/.worktrees/fix", "api.worktree-search" => "/src/api/.worktrees/search"} }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: available) }
  let(:git) { Workspace::Git.new }
  let(:notes_dir) { Workspace::NotesDir.new(git: git, home: "/home/me") }
  subject(:report) { described_class.new(project_settings: settings, project_config: project_config, notes_dir: notes_dir) }

  before do
    allow(project_config).to receive(:project_root_for) { |name| roots[name] }
    allow(git).to receive(:worktree_branch) { |path| "feature/#{File.basename(path)}" }
  end

  after { FileUtils.rm_rf(dir) }

  def write(name, text)
    path = (name == :global) ? settings.global_config_path : settings.project_config_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def key_row(doc, name, scope: nil)
    doc["keys"].find { |row| row["key"] == name && (scope.nil? || row["scope"] == scope) }
  end

  describe "non-finite numbers" do
    it "reports .inf, -.inf and .nan as invalid_value problems and keeps every document JSON-safe" do
      path = write("api", "dev:\n  ready_timeout: .inf\n  kill_grace: -.inf\n  stop_timeout: .nan\n")

      show = report.show("api")
      validate = report.validate("api")

      expect { JSON.generate(show) }.not_to raise_error
      expect { JSON.generate(validate) }.not_to raise_error
      rows = %w[dev.ready_timeout dev.kill_grace dev.stop_timeout].map { |name| key_row(show, name) }
      expect(rows.map { |r| r["value"] }).to eq(%w[Infinity -Infinity NaN])
      expect(rows.map { |r| r["problems"].map { |p| p["code"] } }).to eq([["invalid_value"]] * 3)
      expect(rows.first).to include("effective" => 120, "line" => 2, "column" => 3)
      expect(validate["valid"]).to be(false)
      expect(validate["problems"].map { |p| [p["key"], p["code"], p["file"], p["line"]] }).to eq(
        [["dev.ready_timeout", "invalid_value", path, 2], ["dev.kill_grace", "invalid_value", path, 3], ["dev.stop_timeout", "invalid_value", path, 4]]
      )
    end

    it "never prints a sensitive key's value, finite or not" do
      write("api", "dev:\n  up: .inf\n")

      show = report.show("api")
      row = key_row(show, "dev.up")

      expect(row).to include("value" => nil, "masked" => true, "effective" => nil)
      expect(row["problems"].map { |p| p["code"] }).to eq(["invalid_value"])
      expect(JSON.generate(show)).not_to match(/Infinity/)
    end
  end

  describe "dev.configured" do
    it "is a read-only derived row: true when the project's dev.up is set, with no value or masking" do
      write("api", "dev:\n  up: ./start-dev\n")
      row = key_row(report.show("api"), "dev.configured")

      expect(row).to include("scope" => "project", "type" => "boolean", "value" => nil, "masked" => false, "default" => false,
        "effective" => true, "source" => "default", "settable" => false, "sensitive" => false, "affects" => [], "problems" => [])
    end

    it "is false with no dev.up or a blank one, and true in a worktree whose parent sets it" do
      expect(key_row(report.show("api"), "dev.configured")["effective"]).to be(false)
      write("api", "dev:\n  up: \"  \"\n")
      expect(key_row(report.show("api"), "dev.configured")["effective"]).to be(false)
      write("api", "dev:\n  up: ./start-dev\n")
      expect(key_row(report.show("api.worktree-fix"), "dev.configured")["effective"]).to be(true)
    end

    it "follows dev.up's winning layer: true for a worktree whose own file sets dev.up while the project sets none" do
      write("api", "dev: {}\n")
      write("api.worktree-fix", "dev:\n  up: ./worktree-start\n")

      expect(key_row(report.show("api.worktree-fix"), "dev.configured")["effective"]).to be(true)
      expect(key_row(report.show("api.worktree-search"), "dev.configured")["effective"]).to be(false)
      expect(key_row(report.show("api"), "dev.configured")["effective"]).to be(false)
    end

    it "is false in a worktree whose own dev.up is blank over a project that sets one, and null when the worktree file is unreadable" do
      write("api", "dev:\n  up: ./start-dev\n")
      write("api.worktree-fix", "dev:\n  up: \"  \"\n")
      expect(key_row(report.show("api.worktree-fix"), "dev.configured")["effective"]).to be(false)

      write("api.worktree-fix", "dev: [\n")
      expect(key_row(report.show("api.worktree-fix"), "dev.configured")["effective"]).to be_nil
    end

    it "is null when the project's file can't be read" do
      write("api", "dev: [\n")

      expect(key_row(report.show("api"), "dev.configured")).to include("effective" => nil, "source" => "unreadable")
    end

    it "warns that a dev.configured written in a file is not read" do
      write("api", "dev:\n  configured: true\n  up: ./x\n")
      problems = report.validate("api")["problems"].select { |p| p["key"] == "dev.configured" }

      expect(problems.map { |p| [p["severity"], p["code"]] }).to eq([%w[info not_read]])
      expect(key_row(report.show("api"), "dev.configured")["effective"]).to be(true)
    end
  end

  describe "#show" do
    it "describes every schema key, in schema order, under the documented envelope" do
      doc = report.show("api")

      expect(doc.keys.first(4)).to eq(%w[schema_version ok workspace parent])
      expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "parent" => nil)
      expect(doc["keys"].map { |row| [row["key"], row["scope"]] }).to eq(Workspace::ConfigSchema.all.map { |key| [key.name, key.scope.to_s] })
    end

    it "describes just the one key asked for, with the same envelope and layering" do
      path = write("api", "dev:\n  stop_timeout: 90s\n")
      write("api.worktree-fix", "dev:\n  stop_timeout: 5s\n")
      doc = report.show("api.worktree-fix", key: "dev.stop_timeout")

      expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "api.worktree-fix", "parent" => "api")
      expect(doc["keys"].map { |row| row["key"] }).to eq(["dev.stop_timeout"])
      expect(doc["keys"].first).to include("effective" => 90, "source" => "project", "source_file" => path, "resolve" => "parent")
    end

    describe "layers" do
      it "lists every layer that holds a value, lowest to highest precedence, with exactly the winner active" do
        global = write(:global, "handoff:\n  threshold: 20\n")
        project = write("api", "handoff:\n  threshold: 30\n")
        worktree = write("api.worktree-fix", "\n\nhandoff:\n  threshold: 40\n")
        row = key_row(report.show("api.worktree-fix"), "handoff.threshold")

        expect(row["layers"]).to eq([
          {"layer" => "global", "value" => 20, "masked" => false, "file" => global, "line" => 2, "column" => 3, "active" => false},
          {"layer" => "project", "value" => 30, "masked" => false, "file" => project, "line" => 2, "column" => 3, "active" => false},
          {"layer" => "worktree", "value" => 40, "masked" => false, "file" => worktree, "line" => 4, "column" => 3, "active" => true}
        ])
        expect(row).to include("value" => 40, "source" => "worktree", "overridable_in" => %w[global project worktree])
      end

      it "lists a main checkout's layers without the worktree, and none for an unset key" do
        write("api", "handoff:\n  threshold: 30\n")
        write("api.worktree-fix", "handoff:\n  threshold: 40\n")
        doc = report.show("api")

        expect(key_row(doc, "handoff.threshold")["layers"].map { |l| [l["layer"], l["active"]] }).to eq([["project", true]])
        expect(key_row(doc, "handoff.auto")["layers"]).to eq([])
      end

      it "masks a sensitive key's value in every layer and never quotes it in a problem message" do
        write(:global, "alerts:\n  notify: ' '\n")
        write("api", "alerts:\n  notify: sekrit-project\ncommands:\n  test: sekrit-test\n")
        write("api.worktree-fix", "alerts:\n  notify: sekrit-worktree\n")
        doc = report.show("api.worktree-fix")
        row = key_row(doc, "alerts.notify")

        expect(row["layers"].map { |l| [l["layer"], l["value"], l["masked"]] }).to eq([["global", nil, true], ["project", nil, true], ["worktree", nil, true]])
        expect(row["layers"].map { |l| l["active"] }).to eq([false, false, true])
        expect(JSON.generate(doc)).not_to include("sekrit")
        expect(report.validate("api.worktree-fix")["problems"].map { |p| p["message"] }.join).not_to include("sekrit")
      end

      it "reports one entry for a key edited in its own file, none for the derived row" do
        write("api", "hooks:\n  post_launch: echo\n")
        doc = report.show("api")

        expect(key_row(doc, "hooks", scope: "project")["layers"].map { |l| [l["layer"], l["active"]] }).to eq([["project", true]])
        expect(key_row(doc, "dev.configured")["layers"]).to eq([])
      end

      it "describes each key: its layers, doc, choices and limits, only where set" do
        doc = report.show("api")

        expect(key_row(doc, "handoff.threshold")).to include("min" => 1, "max" => 100, "doc" => start_with("Context-usage percent"))
        expect(key_row(doc, "handoff.threshold")).not_to include("choices", "unit")
        expect(key_row(doc, "dev.ready_timeout")).to include("unit" => "seconds", "overridable_in" => %w[project worktree])
        expect(key_row(doc, "dev.ready_timeout")).not_to include("choices", "min", "max")
        expect(key_row(doc, "dev.kill_grace")).to include("max" => 60, "unit" => "seconds")
        expect(key_row(doc, "handoff.auto")).to include("choices" => %w[true false])
        expect(key_row(doc, "context.source")).to include("choices" => %w[statusline scrape], "overridable_in" => ["global"])
        expect(key_row(doc, "locks.ps_timeout")).to include("min" => 1, "max" => 60)
        expect(key_row(doc, "dev.up")).not_to include("choices", "min", "max", "unit")
        expect(doc["keys"]).to all(include("doc" => a_kind_of(String), "overridable_in" => a_kind_of(Array), "layers" => a_kind_of(Array)))
      end
    end

    describe "which layer a value may sit in" do
      it "notes a project-only key in a worktree file, and names the allowed layers for a key allowed elsewhere" do
        write("api", "")
        write("api.worktree-fix", "locks:\n  idle_grace: 1m\nnotes:\n  default_dir: tmp/n\n")
        problems = report.validate("api.worktree-fix")["problems"]

        expect(problems.map { |p| [p["key"], p["code"], p["severity"]] }).to eq([["locks.idle_grace", "not_read", "info"], ["notes.default_dir", "not_read", "info"]])
        expect(problems[0]["message"]).to include("parent project's file (api)")
        expect(problems[1]["message"]).to eq("notes.default_dir in the worktree config isn't read. It is read from the global, project config.")
        expect(key_row(report.show("api.worktree-fix"), "locks.idle_grace")["problems"].map { |p| p["code"] }).to eq(["not_read"])
      end

      it "reads a value in a newly allowed layer without a warning, and still flags a key allowed in neither layer" do
        write("api", "")
        write(:global, "handoff:\n  auto: true\ndev:\n  stop_timeout: 5s\nworkflows:\n  defaults:\n    include: binding\n")
        write("api.worktree-fix", "workflows:\n  defaults:\n    include: commits\ncontext:\n  source: scrape\n")
        problems = report.validate("api.worktree-fix")["problems"]

        expect(problems.map { |p| [p["layer"], p["key"], p["code"]] }).to eq([["worktree", "context", "unknown_key"], ["global", "dev.stop_timeout", "unknown_key"]])
        expect(problems.first["message"]).to include("It is a global setting.")
        expect(problems.last["message"]).to include("It is a project setting.")
      end

      it "checks a widened key's value in the layer it newly sits in" do
        write("api", "")
        write(:global, "handoff:\n  threshold: 500\n")

        expect(report.validate("api")["problems"].map { |p| [p["layer"], p["key"], p["code"]] }).to eq([["global", "handoff.threshold", "invalid_value"]])
      end
    end

    it "raises for a key no schema defines" do
      expect { report.show("api", key: "dev.bogus") }.to raise_error(Workspace::Error, /Unknown config key 'dev.bogus'/)
    end

    it "lists the layers the workspace reads: worktree, its parent project and the global file" do
      write("api", "dev: {}\n")
      doc = report.show("api.worktree-fix")

      expect(doc["parent"]).to eq("api")
      expect(doc["files"].map { |f| [f["layer"], f["exists"]] }).to eq([["worktree", false], ["project", true], ["global", false]])
      expect(doc["files"][1]).to include("path" => settings.project_config_path("api"), "etag" => start_with("sha256:"), "parse_error" => nil)
    end

    it "reports a stored value with its source, file, line and column, and the default when unset" do
      path = write("api", "dev:\n  ready_timeout: 90s\n")
      doc = report.show("api")

      row = key_row(doc, "dev.ready_timeout")
      expect(row).to include("value" => "90s", "effective" => 90, "default" => 120, "source" => "project", "source_file" => path,
        "line" => 2, "column" => 3, "type" => "duration", "problems" => [])
      unset = key_row(doc, "dev.stop_timeout")
      expect(unset).to include("value" => nil, "effective" => 20, "source" => "default", "source_file" => nil, "line" => nil)
    end

    it "reads a worktree's project-only dev keys from the parent project's file, as the readers do" do
      write("api", "dev:\n  stop_timeout: 90s\n")
      write("api.worktree-fix", "dev:\n  stop_timeout: 5s\n")
      doc = report.show("api.worktree-fix")

      expect(key_row(doc, "dev.stop_timeout")).to include("effective" => 90, "source" => "project", "resolve" => "parent", "overridable_in" => ["project"])
      expect(doc["files"].first["layer"]).to eq("worktree")
      note = key_row(doc, "dev.stop_timeout")["problems"].find { |p| p["code"] == "not_read" }
      expect(note["message"]).to include("parent project's file (api)")
    end

    it "reads a widened key from the worktree's own file over the project's, with resolve layered" do
      path = write("api.worktree-fix", "dev:\n  ready_timeout: 5s\n")
      write("api", "dev:\n  ready_timeout: 90s\n")
      doc = report.show("api.worktree-fix")

      expect(key_row(doc, "dev.ready_timeout")).to include("effective" => 5, "source" => "worktree", "source_file" => path, "resolve" => "layered",
        "overridable_in" => %w[project worktree], "target_layer" => "worktree", "problems" => [])
      expect(key_row(report.show("api"), "dev.ready_timeout")).to include("effective" => 90, "source" => "project", "target_layer" => "project")
    end

    it "reads a widened key from the global file when neither the project nor the worktree sets it" do
      write("api", "")
      write(:global, "handoff:\n  auto: true\n")

      expect(key_row(report.show("api.worktree-fix"), "handoff.auto")).to include("effective" => "true", "source" => "global", "resolve" => "layered")
      expect(report.validate("api.worktree-fix")["problems"]).to eq([])
    end

    it "reports the layer config set writes as target_layer, the same one a write with no scope lands in" do
      command = Workspace::Commands::Config.new(project_settings: settings, file_backup: instance_double(Workspace::FileBackup, backup: nil),
        lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api", is_worktree: false)))
      expected = {
        ["api", "dev.ready_timeout"] => "api", ["api.worktree-fix", "dev.ready_timeout"] => "api.worktree-fix",
        ["api", "locks.idle_grace"] => "api", ["api.worktree-fix", "locks.idle_grace"] => "api",
        ["api", "notes.dir"] => "api", ["api.worktree-fix", "notes.dir"] => "api.worktree-fix",
        ["api", "handoff.auto"] => "api", ["api.worktree-fix", "handoff.auto"] => "api.worktree-fix"
      }
      layers = {"api" => "project", "api.worktree-fix" => "worktree"}
      expected.each do |(workspace, name), file_name|
        write("api", "")
        write("api.worktree-fix", "")
        value = {"notes.dir" => "/n", "handoff.auto" => "true"}.fetch(name, "90s")
        target = key_row(report.show(workspace), name)["target_layer"]
        command.set(name, value, project: workspace)

        written = %w[api api.worktree-fix].select { |w| settings.load(w).dig(*name.split(".")) }
        expect(written).to eq([file_name]), "#{name} on #{workspace}"
        expect(target).to eq((file_name == workspace) ? layers.fetch(workspace) : "project"), "#{name} on #{workspace}"
      end
    end

    it "doesn't let an invalid value in a worktree's file, where the reader never looks, change the effective value or fail validation" do
      write("api", "dev:\n  stop_timeout: 90s\n")
      write("api.worktree-fix", "dev:\n  stop_timeout: soon\n")

      expect(key_row(report.show("api.worktree-fix"), "dev.stop_timeout")).to include("effective" => 90, "source" => "project")
      validation = report.validate("api.worktree-fix")
      expect(validation["valid"]).to be true
      expect(validation["problems"].map { |p| [p["code"], p["severity"]] }).to eq([["not_read", "info"]])
    end

    it "reads hooks from the workspace's own file and layouts from the project layer of that file" do
      write("api", "hooks:\n  post_launch: echo parent\n")
      write("api.worktree-fix", "hooks:\n  post_launch: echo wt\n")
      doc = report.show("api.worktree-fix")

      expect(key_row(doc, "hooks", scope: "project")).to include("source" => "worktree", "resolve" => "own", "applies" => "next_event", "affects" => ["api.worktree-fix"])
    end

    it "reads notes.dir from a worktree's own file and never falls back to the project's value" do
      write("api", "notes:\n  dir: /shared/notes\n")
      write("api.worktree-fix", "notes:\n  dir: /wt/notes\n")

      own = key_row(report.show("api.worktree-fix"), "notes.dir")
      expect(own).to include("resolve" => "own_then_parent", "source" => "worktree", "effective" => "/wt/notes", "target_layer" => "worktree", "affects" => ["api.worktree-fix"])
      expect(own["source_file"]).to eq(settings.project_config_path("api.worktree-fix"))

      bare = key_row(report.show("api.worktree-search"), "notes.dir")
      expect(bare).to include("source" => "default", "value" => nil, "effective" => nil, "target_layer" => "worktree", "source_file" => nil)
    end

    it "reads notes.dir from the project's file for a main checkout" do
      write("api", "notes:\n  dir: /shared/notes\n")
      write("api.worktree-fix", "notes:\n  dir: /wt/notes\n")

      row = key_row(report.show("api"), "notes.dir")
      expect(row).to include("source" => "project", "effective" => "/shared/notes", "target_layer" => "project", "affects" => ["api"])
    end

    it "gives notes.dir and notes.default_dir an effective_path computed for the workspace asked about" do
      write("api", "notes:\n  default_dir: \"~/notes/{workspace}/{branch}\"\n")
      write("api.worktree-fix", "notes:\n  dir: /wt/notes\n")

      fix = report.show("api.worktree-fix")
      expect(key_row(fix, "notes.dir")["effective_path"]).to eq("/wt/notes")
      expect(key_row(fix, "notes.default_dir")).to include("effective_path" => "/home/me/notes/api.worktree-fix/feature-fix", "source" => "project", "resolve" => "layered", "type" => "path")

      search = report.show("api.worktree-search")
      expect(key_row(search, "notes.dir")).to include("source" => "default", "effective" => nil, "effective_path" => "/home/me/notes/api.worktree-search/feature-search")
      expect(key_row(search, "dev.up")).not_to have_key("effective_path")
    end

    it "falls back to tmp/workspace-notes when no default_dir is set and to the project's notes.dir for a main checkout" do
      expect(key_row(report.show("api.worktree-fix"), "notes.dir")["effective_path"]).to eq("/src/api/.worktrees/fix/tmp/workspace-notes")
      expect(key_row(report.show("api.worktree-fix"), "notes.default_dir")["effective_path"]).to eq("/src/api/.worktrees/fix/tmp/workspace-notes")

      write("api", "notes:\n  dir: /shared/notes\n")
      expect(key_row(report.show("api"), "notes.dir")["effective_path"]).to eq("/shared/notes")
    end

    it "uses the computed default when the stored notes.dir is invalid" do
      write("api.worktree-fix", "notes:\n  dir: relative/notes\n")

      expect(key_row(report.show("api.worktree-fix"), "notes.dir")["effective_path"]).to eq("/src/api/.worktrees/fix/tmp/workspace-notes")
    end

    it "gives a null effective_path when the checkout is unknown, the file is unreadable, or the stored value is invalid" do
      expect(key_row(report.show("other"), "notes.dir")["effective_path"]).to be_nil

      write("api", "notes:\n  default_dir: ../up\n")
      expect(key_row(report.show("api"), "notes.dir")["effective_path"]).to eq("/src/api/tmp/workspace-notes")
      expect(key_row(report.show("api"), "notes.default_dir")["effective_path"]).to eq("/src/api/tmp/workspace-notes")

      write("api", "notes: [\n")
      expect(key_row(report.show("api"), "notes.dir")["effective_path"]).to be_nil
      expect(key_row(report.show("api"), "notes.default_dir")["effective_path"]).to be_nil
    end

    it "reports global keys from the global file" do
      write(:global, "context:\n  source: scrape\nlaunch:\n  headless: true\n")
      doc = report.show("api")

      expect(key_row(doc, "context.source")).to include("value" => "scrape", "effective" => "scrape", "source" => "global", "target_layer" => "global")
      expect(key_row(doc, "launch.headless")).to include("value" => true, "source" => "global")
    end

    it "never prints a sensitive key's value, parsed form or a problem that quotes it" do
      write("api", "dev:\n  up: super-secret-command --token abc123\nalerts:\n  notify: curl https://x/?k=sekrit\nhooks:\n  post_launch: echo sekrit-hook\n")
      write(:global, "statusline:\n  command: ~/bin/sekrit-line\nhooks:\n  post_launch: echo sekrit-global\n")
      doc = report.show("api")

      expect(JSON.generate(doc)).not_to match(/super-secret|abc123|sekrit/)
      expect(key_row(doc, "dev.up")).to include("value" => nil, "masked" => true, "effective" => nil, "sensitive" => true, "source" => "project", "line" => 2)
      expect(key_row(doc, "statusline.command")).to include("masked" => true, "value" => nil)
      expect(key_row(doc, "hooks", scope: "global")).to include("masked" => true, "value" => nil)
    end

    it "reports a problem for a sensitive key without its value" do
      write("api", "alerts:\n  notify: '   '\n")
      row = key_row(report.show("api"), "alerts.notify")

      expect(row).to include("value" => nil, "masked" => true, "effective" => nil)
      expect(row["problems"].map { |p| [p["code"], p["message"]] }).to eq([["invalid_value", "alerts.notify: must not be blank"]])
    end

    it "doesn't mask a sensitive key that has no value" do
      doc = report.show("api")

      expect(key_row(doc, "dev.up")).to include("masked" => false, "value" => nil, "source" => "default")
    end

    it "lists the workspaces a change reaches: the parent and its worktrees for a parent key, itself for its own" do
      doc = report.show("api.worktree-fix")

      expect(key_row(doc, "dev.stop_timeout")["affects"]).to eq(%w[api api.worktree-fix api.worktree-search])
      expect(key_row(doc, "dev.up")["affects"]).to eq(["api.worktree-fix"])
      expect(key_row(report.show("api"), "dev.up")["affects"]).to eq(%w[api api.worktree-fix api.worktree-search])
      expect(key_row(doc, "notes.dir")["affects"]).to eq(["api.worktree-fix"])
      expect(key_row(doc, "hooks", scope: "project")["affects"]).to eq(["api.worktree-fix"])
      expect(key_row(doc, "context.source")["affects"]).to eq(available | ["api.worktree-fix"])
      expect(key_row(doc, "hooks", scope: "global")["affects"]).to eq([])
    end

    it "gives a worktree-less workspace its own name even when no tmuxinator file lists it" do
      write("solo", "dev: {}\n")

      expect(key_row(report.show("solo"), "dev.up")["affects"]).to eq(["solo"])
    end

    it "says when a key applies and whether config set writes it" do
      doc = report.show("api")

      expect(key_row(doc, "alerts.notify")).to include("applies" => "daemon_restart", "settable" => true, "target_layer" => "project")
      expect(key_row(doc, "layouts", scope: "project")).to include("settable" => false, "target_layer" => nil, "resolve" => "merge")
    end

    it "reports a bad file as data: parse_error in files, its keys unreadable, other layers still read" do
      write("api", "a: 1\nb: [\n")
      write(:global, "context:\n  source: scrape\n")
      doc = report.show("api")

      expect(doc["ok"]).to be true
      expect(doc["files"].first["parse_error"]).to include("line" => 3, "column" => 1)
      expect(key_row(doc, "dev.up")).to include("source" => "unreadable", "effective" => nil)
      expect(key_row(doc, "context.source")).to include("source" => "global")
    end

    it "uses the default and shows the problem for a stored value the reader would reject" do
      write("api", "handoff:\n  threshold: 500\n")
      row = key_row(report.show("api"), "handoff.threshold")

      expect(row).to include("value" => 500, "effective" => 11, "source" => "project")
      expect(row["problems"].first).to include("severity" => "error", "code" => "invalid_value", "line" => 2, "column" => 3)
    end

    it "reports the built-in text of a handoff prompt as its default and effective value" do
      row = key_row(report.show("api"), "handoff.resume_prompt")

      expect(row).to include("value" => nil, "source" => "default")
      expect(row["default"]).to eq(Workspace::ConfigSchema.default("handoff.resume_prompt"))
      expect(row["default"]).to start_with("Read %{doc}")
      expect(row["effective"]).to eq(row["default"])
    end

    it "lists unknown keys with layer and position" do
      write("api", "dev:\n  up: x\n  bogus: 1\ndeploy_url: z\n")
      write(:global, "statusline_color: red\n")
      doc = report.show("api")

      expect(doc["unknown_keys"]).to eq([
        {"key" => "dev.bogus", "layer" => "project", "line" => 3, "column" => 3},
        {"key" => "deploy_url", "layer" => "project", "line" => 4, "column" => 1},
        {"key" => "statusline_color", "layer" => "global", "line" => 1, "column" => 1}
      ])
    end

    it "raises unknown_workspace for a name nothing knows" do
      expect { report.show("nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "nope")
      }
    end

    it "knows a workspace by its config file alone" do
      write("fresh", "dev: {}\n")

      expect(report.show("fresh")["workspace"]).to eq("fresh")
    end

    it "emits a document that round-trips through JSON" do
      write("api", "dev:\n  ready_timeout: 90s\nlayouts:\n  a: even-vertical\n")

      expect(JSON.parse(JSON.generate(report.show("api")))["keys"].size).to eq(Workspace::ConfigSchema.all.size)
    end
  end

  describe "#validate" do
    it "is valid with no problems when the files are fine or missing" do
      write("api", "dev:\n  ready_timeout: 90s\nhooks:\n  post_launch: echo\n")

      expect(report.validate("api")).to eq("schema_version" => 1, "ok" => true, "valid" => true, "workspace" => "api", "problems" => [])
    end

    it "reports a syntax error with line and column and does not raise" do
      path = write("api", "a: 1\nb: [\n")
      doc = report.validate("api")

      expect(doc).to include("ok" => true, "valid" => false)
      expect(doc["problems"]).to eq([{"severity" => "error", "code" => "yaml_syntax", "layer" => "project", "file" => path, "line" => 3, "column" => 1,
                                      "key" => nil, "message" => "did not find expected node content while parsing a flow node"}])
    end

    it "reports a non-mapping file as yaml_syntax at 1:1" do
      write("api", "- a\n")

      expect(report.validate("api")["problems"].first).to include("code" => "yaml_syntax", "line" => 1, "column" => 1)
    end

    it "reports invalid values as errors at the key" do
      write("api", "dev:\n  ready_timeout: soon\n  kill_grace: 90s\nlocks:\n  ps_timeout: 0\nhandoff:\n  threshold: x\n  check_prompt: ' '\n")
      problems = report.validate("api")["problems"]

      expect(problems.map { |p| [p["key"], p["line"], p["severity"], p["code"]] }).to eq([
        ["dev.ready_timeout", 2, "error", "invalid_value"], ["dev.kill_grace", 3, "error", "invalid_value"],
        ["locks.ps_timeout", 5, "error", "invalid_value"], ["handoff.threshold", 7, "error", "invalid_value"],
        ["handoff.check_prompt", 8, "error", "invalid_value"]
      ])
      expect(problems.map { |p| p["message"] }).to all(match(/\A[a-z_.]+: /))
    end

    it "reports a section that isn't a mapping once, and a mapping key that isn't a mapping" do
      write("api", "dev: yes\nhooks: nope\n")

      expect(report.validate("api")["problems"].map { |p| [p["key"], p["message"]] }).to eq([["dev", "dev must be a mapping"], ["hooks", "hooks must be a mapping"]])
    end

    it "warns about unknown keys and says when a key belongs to the other scope" do
      write("api", "statusline:\n  command: x\ndev:\n  upp: x\nmystery: 1\n")
      write(:global, "dev:\n  up: x\n")
      problems = report.validate("api")["problems"]

      expect(problems.map { |p| [p["layer"], p["key"], p["severity"], p["code"]] }).to eq([
        ["project", "statusline", "warning", "unknown_key"], ["project", "dev.upp", "warning", "unknown_key"],
        ["project", "mystery", "warning", "unknown_key"], ["global", "dev.up", "warning", "unknown_key"]
      ])
      expect(problems.first["message"]).to include("It is a global setting.")
      expect(problems.last["message"]).to include("It is a project setting.")
    end

    it "doesn't call a valid worktree key unknown, and doesn't descend into free-form sections" do
      write("api", "hooks:\n  post_launch: x\n  anything: y\nlayouts:\n  my-layout: even-vertical\nworktree_hooks:\n  post_launch: z\npipeline:\n  panes: []\n")

      expect(report.validate("api")["problems"]).to eq([])
    end

    it "notes global hooks, which nothing reads, and parent keys set in a worktree's file" do
      write("api.worktree-fix", "dev:\n  stop_timeout: 5s\nhooks: {}\n")
      write("api", "")
      write(:global, "hooks:\n  post_launch: x\n")
      problems = report.validate("api.worktree-fix")["problems"]

      expect(problems.map { |p| [p["layer"], p["key"], p["severity"], p["code"]] }).to eq([
        ["worktree", "dev.stop_timeout", "info", "not_read"], ["global", "hooks", "info", "not_read"]
      ])
      expect(report.validate("api.worktree-fix")["valid"]).to be true
    end

    it "checks notes.dir in a worktree's own file and does not call it unread" do
      write("api", "")
      write("api.worktree-fix", "notes:\n  dir: relative/notes\n")

      problems = report.validate("api.worktree-fix")["problems"]
      expect(problems.map { |p| [p["layer"], p["key"], p["code"]] }).to eq([["worktree", "notes.dir", "invalid_value"]])
    end

    it "warns about a notes.dir with a backslash before a space or a tilde" do
      write("api", "notes:\n  dir: \"/Users/me/My\\\\ Notes\"\n")
      write("api.worktree-fix", "notes:\n  dir: \"/x/\\\\~notes\"\n")

      problems = report.validate("api.worktree-fix")["problems"]
      expect(problems.map { |p| [p["layer"], p["key"], p["severity"], p["code"]] }).to eq([
        ["worktree", "notes.dir", "warning", "escaped_path"], ["project", "notes.dir", "warning", "escaped_path"]
      ])
      expect(problems.first).to include("line" => 2)
      expect(problems.first["message"]).to include("backslash")
      expect(report.validate("api.worktree-fix")["valid"]).to be true
    end

    it "warns about escapes in notes.default_dir too" do
      write("api", "notes:\n  default_dir: \"/Users/me/My\\\\ Notes/{workspace}\"\n")

      expect(report.validate("api")["problems"].map { |p| [p["key"], p["code"]] }).to eq([["notes.default_dir", "escaped_path"]])
    end

    it "warns shared_notes_dir when a project with worktrees has an absolute default_dir with no placeholder" do
      path = write("api", "notes:\n  default_dir: /shared/notes\n")

      problems = report.validate("api")["problems"]
      expect(problems.map { |p| [p["severity"], p["code"], p["key"], p["layer"], p["file"], p["line"]] }).to eq([["warning", "shared_notes_dir", "notes.default_dir", "project", path, 2]])
      expect(problems.first["message"]).to include("{workspace}")
      expect(report.validate("api")["valid"]).to be true
      expect(report.validate("api.worktree-fix")["problems"].map { |p| p["code"] }).to eq(["shared_notes_dir"])

      write("api", "notes:\n  default_dir: \"~/notes\"\n")
      expect(report.validate("api")["problems"].map { |p| p["code"] }).to eq(["shared_notes_dir"])
    end

    it "does not warn shared_notes_dir for a placeholder, a relative path, or a project without worktrees" do
      write("api", "notes:\n  default_dir: /shared/{workspace}\n")
      expect(report.validate("api")["problems"]).to eq([])
      write("api", "notes:\n  default_dir: tmp/n\n")
      expect(report.validate("api")["problems"]).to eq([])
      write("other", "notes:\n  default_dir: /shared/notes\n")
      expect(report.validate("other")["problems"]).to eq([])
    end

    it "rejects a relative default_dir with .. as an invalid_value" do
      write("api", "notes:\n  default_dir: ../up\n")

      expect(report.validate("api")["problems"].map { |p| [p["key"], p["code"], p["severity"]] }).to eq([["notes.default_dir", "invalid_value", "error"]])
    end

    it "does not warn about a plain notes.dir with spaces" do
      write("api", "notes:\n  dir: /Users/me/My Notes\n")

      expect(report.validate("api")["problems"]).to eq([])
    end

    it "orders problems by layer (worktree, project, global) then line" do
      write("api.worktree-fix", "zzz: 1\n")
      write("api", "aaa: 1\n")
      write(:global, "bbb: 1\n")

      expect(report.validate("api.worktree-fix")["problems"].map { |p| p["layer"] }).to eq(%w[worktree project global])
    end

    it "is invalid only for errors, not warnings or notes" do
      write("api", "mystery: 1\n")

      expect(report.validate("api")).to include("valid" => true)
    end

    it "raises unknown_workspace for a name nothing knows" do
      expect { report.validate("nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    end
  end
end
