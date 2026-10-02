require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::ConfigReport do
  let(:dir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config, workspace_config_dir: dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  let(:available) { %w[api api.worktree-fix api.worktree-search other] }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: available) }
  subject(:report) { described_class.new(project_settings: settings, project_config: project_config) }

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

  describe "#show" do
    it "describes every schema key, in schema order, under the documented envelope" do
      doc = report.show("api")

      expect(doc.keys.first(4)).to eq(%w[schema_version ok workspace parent])
      expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "parent" => nil)
      expect(doc["keys"].map { |row| [row["key"], row["scope"]] }).to eq(Workspace::ConfigSchema.all.map { |key| [key.name, key.scope.to_s] })
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

    it "reads a worktree's dev keys from the parent project's file, as the readers do" do
      write("api", "dev:\n  ready_timeout: 90s\n")
      write("api.worktree-fix", "dev:\n  ready_timeout: 5s\n")
      doc = report.show("api.worktree-fix")

      expect(key_row(doc, "dev.ready_timeout")).to include("effective" => 90, "source" => "project", "resolve" => "parent")
      expect(doc["files"].first["layer"]).to eq("worktree")
      note = key_row(doc, "dev.ready_timeout")["problems"].find { |p| p["code"] == "not_read" }
      expect(note["message"]).to include("parent project's file (api)")
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

      expect(key_row(doc, "dev.up")["affects"]).to eq(%w[api api.worktree-fix api.worktree-search])
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
        ["project", "mystery", "warning", "unknown_key"], ["global", "dev", "warning", "unknown_key"]
      ])
      expect(problems.first["message"]).to include("It is a global setting.")
      expect(problems.last["message"]).to include("It is a project setting.")
    end

    it "doesn't call a valid worktree key unknown, and doesn't descend into free-form sections" do
      write("api", "hooks:\n  post_launch: x\n  anything: y\nlayouts:\n  my-layout: even-vertical\nworktree_hooks:\n  post_launch: z\npipeline:\n  panes: []\n")

      expect(report.validate("api")["problems"]).to eq([])
    end

    it "notes global hooks, which nothing reads, and parent keys set in a worktree's file" do
      write("api.worktree-fix", "dev:\n  up: x\nhooks: {}\n")
      write("api", "")
      write(:global, "hooks:\n  post_launch: x\n")
      problems = report.validate("api.worktree-fix")["problems"]

      expect(problems.map { |p| [p["layer"], p["key"], p["severity"], p["code"]] }).to eq([
        ["worktree", "dev.up", "info", "not_read"], ["global", "hooks", "info", "not_read"]
      ])
      expect(report.validate("api.worktree-fix")["valid"]).to be true
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
