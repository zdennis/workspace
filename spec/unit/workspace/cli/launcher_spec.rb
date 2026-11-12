require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Launcher do
  let(:err) { StringIO.new }
  let(:project_config) { CLITestHelpers::FakeProjectConfig.new("app" => "/src/app", "web" => "/src/web") }
  let(:launch_command) { RecordingLaunchCommand.new }
  let(:settings) { RecordingLaunchSettings.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_runner) { CLITestHelpers::FakeHookRunner.new }
  let(:library) { RecordingLaunchLibrary.new }
  let(:composer) { nil }
  let(:name_migration) { nil }

  def launcher
    described_class.new(project_config: project_config, launch_command: launch_command,
      launch_mode: Workspace::LaunchMode.new(project_settings: settings, which: ->(_) { "/usr/bin/osascript" }, platform: "arm64-darwin", env: {}),
      state: state, project_settings: settings, hook_runner: hook_runner, common: Workspace::CLI::Common.new,
      working_dir: "/src/here", library: library, instruction_composer: composer, name_migration: name_migration)
  end

  def invocation
    Workspace::CLI::Invocation.new(output: StringIO.new, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def config_pack(ref)
    {"ref" => "pack/#{ref}", "source" => "config"}
  end

  describe "#launch" do
    it "hands the projects to the launch command, then makes each one's settings file and runs its post_launch hook" do
      launched = launcher.launch(invocation, ["app", "web"])

      expect(launch_command.calls).to eq([[["app", "web"], {reattach: false, prompts: {}}]])
      expect(settings.ensured).to eq(["app", "web"])
      expect(hook_runner.runs.map { |run| [run[:project], run[:event]] }).to eq([["app", "post_launch"], ["web", "post_launch"]])
      expect(launched).to include(exit_code: 0, projects: ["app", "web"], plays: {}, packs: {}, skipped_packs: {}, prompts: {})
    end

    it "makes a config for a path argument before launching it" do
      project_config.resolutions["~/src/new"] = ["new", "/src/new"]

      launcher.launch(invocation, ["~/src/new"])

      expect(project_config.created).to eq([["new", "/src/new"]])
      expect(launch_command.calls.first.first).to eq(["new"])
    end

    it "passes the prompt, timeout, headless and arrange choices through" do
      launcher.launch(invocation, ["app"], reattach: true, headless: true, prompt: "Go", prompt_timeout: 30, arrange: true)

      expect(launch_command.calls.first.last).to eq(reattach: true, prompts: {"app" => "Go"}, report_panes: true, prompt_timeout: 30, headless: true, arrange: true)
    end

    it "takes headless from launch.headless when no flag is given" do
      settings = RecordingLaunchSettings.new(global: {"launch" => {"headless" => true}})
      launcher = described_class.new(project_config: project_config, launch_command: launch_command,
        launch_mode: Workspace::LaunchMode.new(project_settings: settings, which: ->(_) { "/usr/bin/osascript" }, platform: "arm64-darwin", env: {}),
        state: state, project_settings: settings, hook_runner: hook_runner, common: Workspace::CLI::Common.new, working_dir: "/src/here")

      launcher.launch(invocation, ["app"])

      expect(launch_command.calls.first.last).to include(headless: true)
    end

    context "with a mixed-case workspace" do
      let(:name_migration) { RecordingNameMigration.new("App" => ["app", ["kept the old notes"]], "Web" => [nil, ["daemon running"]]) }

      it "launches it under its lowercase name and prints the migration's warnings on the run's error output" do
        launched = launcher.launch(invocation, ["App", "Web"])

        expect(launched[:projects]).to eq(["app", "Web"])
        expect(err.string).to eq("Warning: kept the old notes\nWarning: daemon running\n")
      end
    end

    context "with plays" do
      it "looks each play up from the project's root and sends one prompt and binding naming them" do
        launched = launcher.launch(invocation, ["app"], plays: ["kickoff", "review"], prompt: "Go")

        expect(library.calls).to eq([[:play, "kickoff", "/src/app"], [:play, "review", "/src/app"]])
        expect(launched[:prompts]).to eq("app" => "play:play/kickoff | play:play/review | Go")
        opts = launch_command.calls.first.last
        expect(opts[:bindings]).to eq("app" => {"kind" => "play", "id" => "play/kickoff", "packs" => []})
        expect(opts[:report_panes]).to be(true)
        expect(launched[:plays]["app"].map { |play| play["ref"] }).to eq(["play/kickoff", "play/review"])
      end

      it "refuses more plays than a launch takes before anything launches" do
        plays = Array.new(Workspace::Library::MAX_PLAYS + 1) { |i| "play#{i}" }

        expect { launcher.launch(invocation, ["app"], plays: plays) }.to raise_error(Workspace::UsageError, /at most/)
        expect(launch_command.calls).to be_empty
      end

      it "refuses a play when no library was wired" do
        library = nil
        launcher = described_class.new(project_config: project_config, launch_command: launch_command, launch_mode: Workspace::LaunchMode.new(project_settings: settings, which: ->(_) {}, platform: "linux", env: {}),
          state: state, project_settings: settings, hook_runner: hook_runner, common: Workspace::CLI::Common.new, working_dir: "/src/here", library: library)

        expect { launcher.launch(invocation, ["app"], plays: ["kickoff"]) }.to raise_error(Workspace::Error, "--play is not available: no library was wired.")
        expect(launch_command.calls).to be_empty
      end
    end

    context "with packs" do
      let(:composer) do
        RecordingStartComposer.new("/src/app" => {"packs" => [config_pack("notes")], "text" => "NOTES", "skipped" => [{"name" => "dev", "message" => "dev pack skipped"}]})
      end

      it "composes packs only when asked, from each project's root" do
        launcher.launch(invocation, ["app"])
        expect(composer.calls).to be_empty

        launcher.launch(invocation, ["app"], with_packs: true, packs: ["extra"], no_packs: false, handoff: false)
        expect(composer.calls).to eq([{cwd: "/src/app", packs: ["extra"], none: false, handoff: false}])
      end

      it "warns of each skipped pack, sends the pack text, and marks a config-only composition as optional" do
        launched = launcher.launch(invocation, ["app"], with_packs: true)

        expect(err.string).to eq("Warning: dev pack skipped\n")
        expect(launched[:skipped_packs]).to eq("app" => [{"name" => "dev", "message" => "dev pack skipped"}])
        expect(launched[:prompts]).to eq("app" => "NOTES")
        opts = launch_command.calls.first.last
        expect(opts[:bindings]).to eq("app" => {"kind" => "play", "id" => "play/notes", "packs" => ["notes"]})
        expect(opts[:optional]).to eq("app" => ["notes"])
      end

      it "composes a project with no root from the working directory when a pack is named" do
        launcher.launch(invocation, ["loose"], with_packs: true, packs: ["extra"])

        expect(composer.calls.map { |call| call[:cwd] }).to eq(["/src/here"])
      end
    end

    it "refuses --pack and --handoff when no composer was wired, and sends nothing otherwise" do
      expect { launcher.launch(invocation, ["app"], with_packs: true, packs: ["extra"]) }.to raise_error(Workspace::Error, "--pack is not available: no library was wired.")
      expect { launcher.launch(invocation, ["app"], with_packs: true, handoff: true) }.to raise_error(Workspace::Error, "--handoff is not available: no library was wired.")

      launched = launcher.launch(invocation, ["app"], with_packs: true)
      expect(launched[:packs]).to eq({})
    end
  end

  describe "#rows" do
    before do
      state["app"] = {"iterm_window_id" => 7}
      state["web"] = {"headless" => true}
    end

    it "gives a launched row from the state Launch wrote, and reused for a session it reused" do
      rows = launcher.rows(["app", "web"], {exit_code: 0, reused: ["web"], positions: {"app" => 1}})

      expect(rows).to eq([
        {"workspace" => "app", "outcome" => "launched", "reason" => nil, "message" => nil, "iterm_window_id" => 7, "headless" => false, "position" => 1, "prompt_sent" => nil, "pane" => nil},
        {"workspace" => "web", "outcome" => "reused", "reason" => nil, "message" => nil, "iterm_window_id" => nil, "headless" => true, "position" => nil, "prompt_sent" => nil, "pane" => nil}
      ])
    end

    it "names the outcome a caller gives for a project that launched" do
      expect(launcher.rows(["app"], {exit_code: 0}, ok_outcome: "relaunched").first["outcome"]).to eq("relaunched")
    end

    it "fails a project whose session did not start, that left no state, or whose prompt was not sent" do
      rows = launcher.rows(["app", "gone", "web"], {exit_code: 1, start_failures: {"app" => "no tmux"}, prompt_failures: {"web" => "not ready"}}, prompts: {"web" => "Go"})

      expect(rows.map { |row| row.values_at("outcome", "reason", "message") }).to eq([
        ["failed", "session_not_started", "no tmux"],
        ["failed", "not_launched", "No state was recorded for 'gone'."],
        ["failed", "prompt_not_sent", "not ready"]
      ])
      expect(rows.last["prompt_sent"]).to be(false)
    end

    it "adds the plays and packs delivered, with the pane they went to" do
      plays = {"app" => [{"ref" => "play/kickoff"}]}
      packs = {"app" => {"packs" => [config_pack("notes")]}}
      result = {exit_code: 0, bound_panes: {"app" => "%3"}, delivered_panes: {"app" => "%3"}}

      row = launcher.rows(["app"], result, plays: plays, packs: packs, prompts: {"app" => "Go"}).first

      expect(row).to include("prompt_sent" => true, "pane" => "%3", "play" => {"ref" => "play/kickoff", "delivered" => true, "pane" => "%3"})
      expect(row["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%3"}])
    end

    it "leaves packs out of a row when none were given" do
      expect(launcher.rows(["app"], {exit_code: 0}).first).not_to have_key("packs")
    end
  end
end
