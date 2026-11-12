require "spec_helper"
require "tmpdir"
require "digest"
require "stringio"

# Doctor's `templates` and `template-current` rows over a real TemplateStatus, TemplateApply, writer, backup
# store and startup lock in a temporary directory; the render, the template lookup and tmux are doubles.
RSpec.describe Workspace::Doctor, "templates" do
  around do |example|
    Dir.mktmpdir("doctor-templates") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:config) do
    instance_double(Workspace::Config, render_state_dir: File.join(@dir, "state", ".render"), tmuxinator_backups_dir: File.join(@dir, "state", "backups", "tmuxinator"),
      tmuxinator_dir: File.join(@dir, "tmuxinator"), lock_dir: File.join(@dir, "locks")).tap do |c|
      allow(c).to receive(:config_path_for) { |name| File.join(@dir, "tmuxinator", "workspace.#{name}.yml") }
      allow(c).to receive(:agent_lock_path) { |name| File.join(@dir, "locks", "#{name}.lock") }
    end
  end
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:backups) { Workspace::TmuxinatorBackupStore.new(config: config, writer: writer) }
  let(:locks) { Workspace::NameMigration.new(config: config, project_config: nil, tmux: nil, state: nil, event_log: nil, project_catalog_factory: nil, writer: writer) }
  let(:template_path) { File.join(@dir, "team", "project.yml") }
  let(:pick) { {"name" => "team", "path" => template_path} }
  let(:library) { instance_double(Workspace::Library, tmuxinator_template: pick) }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, agent_pane_value: "claude", agent_pane_text: "claude").tap do |pc|
      allow(pc).to receive(:config_path_for) { |name| config.config_path_for(name) }
      allow(pc).to receive(:exists?) { |name| File.exist?(config.config_path_for(name)) }
      allow(pc).to receive(:render) { |_kind, inputs, _text| "#{inputs[:workspace_name]} v2\n" }
      allow(pc).to receive(:available_projects) { Dir.glob(File.join(@dir, "tmuxinator", "workspace.*.yml")).map { |f| File.basename(f, ".yml").delete_prefix("workspace.") }.sort }
    end
  end
  let(:status) { Workspace::TemplateStatus.new(library: library, project_config: project_config, writer: writer) }
  let(:tmux) { instance_double(Workspace::Tmux, session_exists?: false).tap { |t| allow(t).to receive(:session_name_for) { |name| name } } }
  let(:retention) { instance_double(Workspace::TmuxinatorBackupConfig, keep: 20, max_age: nil) }
  let(:differ) { ->(old, new, old_label:, new_label:) { "" } }
  let(:apply) do
    Workspace::TemplateApply.new(status: status, writer: writer, backups: backups, locks: locks, project_config: project_config, tmux: tmux, differ: differ, retention: retention)
  end
  let(:project_detector) { double("project_detector", detect: nil) }
  let(:validator) { instance_double(Workspace::TemplateValidator, call_file: []) }
  let(:doctor) do
    described_class.new(config: config, state: CLITestHelpers::FakeState.new, hook_installer: double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false, installed?: true),
      project_detector: project_detector, output: output, project_settings: CLITestHelpers::FakeProjectSettings.new,
      command_probe: ->(_name, flag) { flag ? "99.0" : "" }, app_probe: ->(_id) { true }, which: ->(_exe) { true },
      launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }),
      project_config: project_config, library: library, template_validator: validator, template_status: status, template_apply: apply)
  end

  before do
    FileUtils.mkdir_p([File.dirname(template_path), File.join(@dir, "locks"), File.join(@dir, "tmuxinator")])
    File.write(template_path, "tpl v2\n")
  end

  def sha(text) = Digest::SHA256.hexdigest(text)

  def path(name) = config.config_path_for(name)

  def rendered(name, text: "#{name} v1\n", template_sha: sha("tpl v1\n"))
    writer.write(name, text, kind: :project, template: "team", template_sha: template_sha,
      inputs: {workspace_name: name, agent_kind: "claude", agent_command: "claude"})
  end

  def rows(id, fix: false) = doctor.report(headless: true, fix: fix)[:rows].select { |row| row[:id] == id }

  describe "templates" do
    it "names the set both kinds resolve to" do
      expect(rows("templates")).to contain_exactly(include(status: "ok", message: "tmuxinator template set: team (global)"))
    end

    it "resolves the set for the detected workspace and says so" do
      allow(project_detector).to receive(:detect).and_return("app")
      allow(config).to receive_messages(agent_running?: false, agent_socket_path: File.join(@dir, "none.sock"), project_config_path: File.join(@dir, "none.yml"))

      expect(rows("templates")).to contain_exactly(include(status: "ok", message: "tmuxinator template set: team (this workspace)"))
      expect(library).to have_received(:tmuxinator_template).with(:project, workspace: "app")
    end

    it "fails on a set that can't be resolved" do
      allow(library).to receive(:tmuxinator_template).and_raise(Workspace::Error.new("No tmuxinator template 'x'", code: "unknown_template"))

      expect(rows("templates")).to contain_exactly(include(status: "fail", message: include("No tmuxinator template 'x'")))
    end

    it "fails on a validation error and warns on a validation warning" do
      problem = ->(severity) { Workspace::TemplateValidator::Problem.new(severity: severity, code: "c", kind: :project, message: "bad") }
      allow(validator).to receive(:call_file).and_return([problem.call("error")])
      expect(rows("templates")).to contain_exactly(include(status: "fail", message: include("project.yml: bad")))

      allow(validator).to receive(:call_file).and_return([problem.call("warning")])
      expect(rows("templates")).to contain_exactly(include(status: "warn"))
    end

    it "points at template import while the edited copy init installed is what renders" do
      allow(library).to receive(:tmuxinator_template).and_return({"name" => "legacy", "path" => template_path})

      expect(rows("templates")).to contain_exactly(include(status: "warn", message: include("new tmuxinator configs still use your edited copy from `workspace init`"), fix_command: "workspace template import"))
    end

    it "adds no row without a library" do
      bare = described_class.new(config: config, state: CLITestHelpers::FakeState.new, hook_installer: double("h", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false, installed?: true),
        project_detector: double("d", detect: nil), output: output, project_settings: CLITestHelpers::FakeProjectSettings.new, command_probe: ->(_n, f) { f ? "99.0" : "" }, app_probe: ->(_i) { true })

      expect(bare.report(headless: true)[:rows].map { |r| r[:id] }).not_to include("templates", "template-current")
    end
  end

  describe "template-current" do
    it "counts current configs in one ok row" do
      rendered("app", text: "app v2\n", template_sha: sha("tpl v2\n"))

      expect(rows("template-current")).to contain_exactly(include(status: "ok", message: "1 tmuxinator config(s) match their template"))
    end

    it "carries the config's state and approx in the JSON rows, so edited-and-left-alone is not healthy" do
      rendered("app")
      rendered("edited")
      File.write(path("edited"), "edited\n")
      File.write(path("old"), "x\n")

      checks = Workspace::Doctor.document(doctor.report(headless: true))["checks"].select { |c| c["id"] == "template-current" }

      expect(checks.to_h { |c| [c["project"], [c["status"], c["state"], c["approx"]]] }).to include("app" => ["warn", "stale", false], "edited" => ["ok", "modified", false])
      expect(checks.map { |c| c["state"] }).to include("untracked")
      other = Workspace::Doctor.document(doctor.report(headless: true))["checks"].find { |c| c["id"] == "templates" }
      expect(other).not_to have_key("state")
    end

    it "warns for a stale config, naming why and the fix" do
      rendered("app")

      expect(rows("template-current")).to contain_exactly(include(status: "warn", project: "app", message: include("behind its template (its template changed)"), fix_command: "workspace doctor --fix"))
    end

    it "reports a hand-edited config as ok and leaves it alone under --fix" do
      rendered("app")
      File.write(path("app"), "edited\n")

      expect(rows("template-current")).to contain_exactly(include(status: "ok", message: include("edited by hand")))
      expect(rows("template-current", fix: true)).to contain_exactly(include(status: "ok", message: include("edited by hand")))
      expect(File.read(path("app"))).to eq("edited\n")
    end

    it "sums up configs with no render record and points at template adopt" do
      File.write(path("old"), "x\n")

      expect(rows("template-current")).to contain_exactly(include(status: "warn", fix_command: "workspace template adopt --all", message: include("(old)")))
    end

    it "never counts any of it as an issue" do
      rendered("app")
      File.write(path("old"), "x\n")

      expect(doctor.report(headless: true)[:rows].select { |r| r[:id].start_with?("template") }.map { |r| r[:status] }).not_to include("fail")
    end

    describe "--fix" do
      it "re-renders a stale config once, in one backup batch, and reports the fixed state" do
        rendered("app")
        rendered("other", text: "other v2\n", template_sha: sha("tpl v2\n"))
        before = File.mtime(path("other"))

        result = rows("template-current", fix: true)

        expect(File.read(path("app"))).to eq("app v2\n")
        expect(File.mtime(path("other"))).to eq(before)
        expect(result).to include(include(status: "ok", project: "app", message: include("re-rendered")))
        expect(result).not_to include(include(status: "warn"))
        expect(output.string).to include("--fix: app: tmuxinator config re-rendered")
        expect(Dir.glob(File.join(@dir, "state", "backups", "tmuxinator", "*"))).not_to be_empty
        expect(rows("template-current")).to contain_exactly(include(status: "ok", message: include("2 tmuxinator config(s)")))
      end

      it "writes a config with a stale template and a stale agent pane once, with no pane rewrite on top" do
        rendered("app")
        main_agent = double("main_agent", kind: "claude")
        allow(project_config).to receive(:stale_agent_pane) do |name, _kind|
          File.read(path(name)).include?("v1") ? {path: path(name), running: "claude", wanted: "claude-dev"} : nil
        end
        allow(project_config).to receive(:rewrite_agent_pane)
        with_pane = described_class.new(config: config, state: CLITestHelpers::FakeState.new, hook_installer: double("h", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false, installed?: true),
          project_detector: project_detector, output: output, project_settings: CLITestHelpers::FakeProjectSettings.new, command_probe: ->(_n, f) { f ? "99.0" : "" }, app_probe: ->(_i) { true }, which: ->(_exe) { true },
          launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }),
          project_config: project_config, main_agent: main_agent, library: library, template_validator: validator, template_status: status, template_apply: apply)

        result = with_pane.report(headless: true, fix: true)

        expect(File.read(path("app"))).to eq("app v2\n")
        expect(project_config).not_to have_received(:rewrite_agent_pane)
        expect(result[:rows].map { |r| r[:id] }).not_to include("agent-pane-command")
        expect(Dir.glob(File.join(@dir, "state", "backups", "tmuxinator", "*")).size).to eq(1)
      end

      it "writes a second --fix nothing" do
        rendered("app")
        doctor.report(headless: true, fix: true)
        mtime = File.mtime(path("app"))
        batches = Dir.glob(File.join(@dir, "state", "backups", "tmuxinator", "*")).size

        doctor.report(headless: true, fix: true)

        expect(File.mtime(path("app"))).to eq(mtime)
        expect(Dir.glob(File.join(@dir, "state", "backups", "tmuxinator", "*")).size).to eq(batches)
      end

      it "leaves a config with no render record alone" do
        File.write(path("old"), "x\n")

        rows("template-current", fix: true)

        expect(File.read(path("old"))).to eq("x\n")
      end
    end
  end
end
