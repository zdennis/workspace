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
  let(:hook_check_class) do
    Class.new do
      attr_reader :calls

      def initialize(order = [])
        @calls = []
        @order = order
      end

      def check(root, io:, only: nil)
        @order << :check
        @calls << {root: root, io: io, only: only}
      end
    end
  end
  let(:hook_setup) { nil }
  let(:order) { [] }
  let(:hook_setup_class) do
    Class.new do
      attr_reader :installs

      def initialize(result, order)
        @result = result
        @order = order
        @installs = []
      end

      def install(root, name, quiet:)
        @order << :install
        @installs << {root: root, name: name, quiet: quiet}
        @result
      end
    end
  end
  let(:ordered_launch_command) { RecordingLaunchCommand.new { |*, **| (order << :launch) && {exit_code: 0} } }
  let(:hook_check) { nil }

  def launcher
    described_class.new(project_config: project_config, launch_command: launch_command,
      launch_mode: Workspace::LaunchMode.new(project_settings: settings, which: ->(_) { "/usr/bin/osascript" }, platform: "arm64-darwin", env: {}),
      state: state, project_settings: settings, hook_runner: hook_runner, common: Workspace::CLI::Common.new,
      working_dir: "/src/here", library: library, instruction_composer: composer, name_migration: name_migration, hook_check: hook_check, hook_setup: hook_setup)
  end

  def invocation
    Workspace::CLI::Invocation.new(output: StringIO.new, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def config_pack(ref)
    {"ref" => "pack/#{ref}", "source" => "config"}
  end

  describe "#launch_missing" do
    it "launches windowed workspaces and headless ones as two batches, and answers none failed" do
      state["app"] = {"unique_id" => "u1"}
      state["web"] = {"headless" => true, "unique_id" => "u2"}

      expect(launcher.launch_missing(invocation, ["app", "web"])).to eq({})

      expect(launch_command.calls.map { |names, options| [names, options[:headless]] }).to eq([[["app"], nil], [["web"], true]])
    end

    it "answers why a batch could not be launched when the launch raises" do
      allow(launch_command).to receive(:call).and_raise(Workspace::Error, "no tmux")

      expect(launcher.launch_missing(invocation, ["app"])).to eq({"app" => "no tmux"})
    end
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

    context "with a hook check wired and no hook setup" do
      let(:hook_check) { hook_check_class.new(order) }
      let(:launch_command) { ordered_launch_command }

      it "checks each launched checkout on the error output, by the root it resolved, before the launch" do
        project_config.resolutions["~/src/new"] = ["new", "/src/new"]

        launcher.launch(invocation, ["app", "~/src/new"])

        expect(hook_check.calls.map { |call| call[:root] }).to eq(["/src/app", "/src/new"])
        expect(hook_check.calls.map { |call| call[:io] }).to all(eq(err))
        expect(order).to eq([:check, :check, :launch])
      end

      it "falls back to the project's root from the config when the launch resolved no root for it" do
        allow(project_config).to receive(:project_root_for).with("loose").and_return("/src/loose")

        launcher.launch(invocation, ["loose"])

        expect(hook_check.calls.map { |call| call[:root] }).to eq(["/src/loose"])
      end

      it "skips a workspace whose checkout root cannot be resolved" do
        launcher.launch(invocation, ["loose"])

        expect(hook_check.calls).to be_empty
      end
    end

    context "with a hook setup wired" do
      let(:hook_check) { hook_check_class.new(order) }
      let(:launch_command) { ordered_launch_command }
      let(:notes) { [] }
      let(:leftovers) { [] }
      let(:out) { StringIO.new }
      let(:hook_setup) { hook_setup_class.new(Workspace::AgentHookSetup::Result.new(notes: notes, leftovers: leftovers), order) }
      let(:installs) { hook_setup.installs }

      def note(text, kind) = Workspace::AgentHookSetup::Note.new(nil, text, kind)

      def run_launch(args)
        inv = Workspace::CLI::Invocation.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
        launcher.launch(inv, args)
      end

      it "installs quietly into each checkout before the launch command runs" do
        run_launch(["app", "web"])

        expect(installs).to eq([{root: "/src/app", name: "app", quiet: true}, {root: "/src/web", name: "web", quiet: true}])
        expect(order).to eq([:install, :install, :launch])
      end

      it "prints info notes to the error output, drops refused ones and writes nothing to the output" do
        notes.push(note("Note: installed", :info), note("Note: refused", :refused))

        run_launch(["app"])

        expect(err.string).to include("Note: installed")
        expect(err.string).not_to include("refused")
        expect(out.string).to eq("")
      end

      it "runs no check when nothing is left over" do
        run_launch(["app"])

        expect(hook_check.calls).to be_empty
      end

      it "checks only the leftover providers on the error output" do
        leftovers << Workspace::AgentProvider.all.first

        run_launch(["app"])

        expect(hook_check.calls).to eq([{root: "/src/app", io: err, only: leftovers}])
      end

      it "installs nothing for a workspace whose root cannot be resolved" do
        run_launch(["loose"])

        expect(installs).to be_empty
      end
    end

    it "launches with no hook check wired and prints nothing for it" do
      expect { launcher.launch(invocation, ["app"]) }.not_to raise_error
      expect(err.string).not_to include("hooks")
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
