require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::Template do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:env) { {} }
  let(:template_command) { instance_double(Workspace::Commands::Template, list: nil, show: nil, path: nil, variables: nil, render: true, validate: true, diff: nil, status: nil, apply: {results: [], exit_code: 0}, new: {}, export: {}, import: {}, edit: {"outcome" => "edited"}, use: {}) }

  let(:relauncher) do
    Workspace::CLI::Relauncher.new(stop_command: nil, hook_runner: nil, launcher: nil, state: nil, sleeper: nil, tmux: FakeTmux.new).tap do |double|
      allow(double).to receive(:call).and_return({exit_code: 0, results: [], warnings: []})
      allow(double).to receive(:running?).and_return(true)
      allow(double).to receive(:active_name) { |name| name }
      allow(double).to receive(:pane_in_session?).and_return(nil)
      allow(double).to receive(:client_session).and_return(nil)
      allow(double).to receive(:session_of?).and_return(false)
    end
  end
  let(:backups_command) { instance_double(Workspace::Commands::TemplateBackups, restore: {results: [], status: "ok", exit_code: 0, warnings: [], extra: {}}) }

  def family(command = template_command)
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: detector,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(template_command: command, backups_command: backups_command, relauncher: relauncher, common: Workspace::CLI::Common.new, names: names, working_dir: "/src/app")
  end

  def invocation(help_asked: false)
    Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: help_asked, quiet: false, env: env)
  end

  def run(*args, command: template_command)
    family(command).call("template", args, invocation)
  end

  it "lists for the workspace of the working directory, with the scope and the directory" do
    run("list", "--scope", "global", "--json")

    expect(template_command).to have_received(:list).with(workspace: "app", scope: "global", cwd: "/src/app", json: true)
  end

  it "takes --name over the detected workspace" do
    run("show", "--name", "api.worktree-x")

    expect(template_command).to have_received(:show).with(set: nil, kind: nil, workspace: "api.worktree-x", json: false)
  end

  it "hands a named set and a kind to show and path, flags in any order" do
    run("show", "team", "--kind", "worktree", "--json")
    run("--kind", "project", "path", "team")

    expect(template_command).to have_received(:show).with(set: "team", kind: "worktree", workspace: "app", json: true)
    expect(template_command).to have_received(:path).with(set: "team", kind: "project", workspace: "app", json: false)
  end

  it "reads the global settings when no workspace is detected" do
    family_here = described_class.new(template_command: template_command, relauncher: relauncher, common: Workspace::CLI::Common.new,
      names: Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: RecordingProjectDetector.new({}),
        lineage: CLITestHelpers::FakeLineage.new, working_dir: "/elsewhere"), working_dir: "/elsewhere")

    family_here.call("template", ["path"], invocation)

    expect(template_command).to have_received(:path).with(set: nil, kind: nil, workspace: nil, json: false)
  end

  it "shows the overview for a bare template, and refuses an unknown subcommand" do
    run
    expect(out.string).to include("Usage: workspace template list", "Subcommands:")
    expect { run("bogus") }.to raise_error(Workspace::UsageError, /Unknown tmuxinator template subcommand: bogus/)
  end

  it "hands variables its kind, and the workspace only when --name names one" do
    run("variables", "--kind", "worktree", "--json")
    run("variables", "--name", "api")

    expect(template_command).to have_received(:variables).with(kind: "worktree", workspace: nil, json: true)
    expect(template_command).to have_received(:variables).with(kind: nil, workspace: "api", json: false)
  end

  it "renders for the detected workspace, with the set and the workspace that picks it" do
    run("render", "team", "--kind", "project", "--diff", "--json")

    expect(template_command).to have_received(:render).with(set: "team", file: nil, kind: "project", workspace: "app", context: "app",
      sample: false, diff: true, json: true)
  end

  it "renders a sample with no workspace but the one that chooses the set, and a file as given" do
    run("render", "--sample", "--file", "./w.yml", "--kind", "worktree")

    expect(template_command).to have_received(:render).with(set: nil, file: "./w.yml", kind: "worktree", workspace: nil, context: "app",
      sample: true, diff: false, json: false)
  end

  it "exits 1 when render says the file had an error" do
    allow(template_command).to receive(:render).and_return(false)

    expect { run("render", "--sample") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "validates the named set or file for the detected workspace, and exits 1 when a file has an error" do
    run("validate", "team", "--kind", "worktree", "--json")
    run("validate", "--file", "./w.yml")

    expect(template_command).to have_received(:validate).with(set: "team", file: nil, kind: "worktree", workspace: "app", json: true)
    expect(template_command).to have_received(:validate).with(set: nil, file: "./w.yml", kind: nil, workspace: "app", json: false)
    allow(template_command).to receive(:validate).and_return(false)
    expect { run("validate") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "diffs the named set against --against, with no exit status of its own" do
    run("diff", "team", "--against", "old", "--kind", "project", "--json")

    expect(template_command).to have_received(:diff).with(set: "team", against: "old", kind: "project", workspace: "app", json: true)
  end

  it "refuses --against outside diff and --file on diff" do
    expect { run("validate", "--against", "x") }.to raise_error(Workspace::UsageError, /--against does not apply to 'template validate'/)
    expect { run("diff", "--file", "x") }.to raise_error(Workspace::UsageError, /--file does not apply to 'template diff'/)
  end

  it "refuses render flags on the other verbs, and a stray argument to variables" do
    expect { run("show", "--sample") }.to raise_error(Workspace::UsageError, /--sample does not apply to 'template show'/)
    expect { run("variables", "--file", "x") }.to raise_error(Workspace::UsageError, /--file does not apply/)
    expect { run("variables", "team") }.to raise_error(Workspace::UsageError, /Unexpected argument: team/)
  end

  it "refuses a flag the verb does not take" do
    expect { run("list", "--kind", "project") }.to raise_error(Workspace::UsageError, /--kind does not apply to 'template list'/)
    expect { run("show", "--scope", "global") }.to raise_error(Workspace::UsageError, /--scope does not apply to 'template show'/)
  end

  it "refuses a stray argument" do
    expect { run("list", "team") }.to raise_error(Workspace::UsageError, /Unexpected argument: team/)
    expect { run("show", "a", "b") }.to raise_error(Workspace::UsageError, /Unexpected argument: b/)
  end

  it "parses before it asks for a command, so a bad flag is a usage error even unwired" do
    expect { run("list", "--bogus", command: nil) }.to raise_error(OptionParser::InvalidOption)
    expect { run("list", command: nil) }.to raise_error(Workspace::Error, /template is not available/)
  end

  it "prints the verb's page for --help and the overview for a bare --help, calling nothing" do
    run("show", "--help")
    expect(out.string).to start_with("Usage: workspace template show")

    out.truncate(0)
    run("--help")
    expect(out.string).to include("Usage: workspace template list", "Subcommands:")
    expect(template_command).not_to have_received(:show)
  end
  describe "status" do
    it "hands the names, the flags and the working directory to the command, not the detected workspace" do
      run("status", "app", "api", "--json")
      run("status", "--all")
      run("status", "--project")
      run("status", "--project", "api")
      run("status")

      expect(template_command).to have_received(:status).with(names: %w[app api], all: false, project: nil, cwd: "/src/app", json: true)
      expect(template_command).to have_received(:status).with(names: [], all: true, project: nil, cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: true, cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: "api", cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: nil, cwd: "/src/app", json: false).once
    end

    it "refuses a flag it has no use for" do
      expect { run("status", "--name", "app") }.to raise_error(Workspace::UsageError, /--name does not apply to 'template status'/)
      expect { run("list", "--all") }.to raise_error(Workspace::UsageError, /--all does not apply to 'template list'/)
    end

    it "still takes no names for list" do
      expect { run("list", "app") }.to raise_error(Workspace::UsageError, /Unexpected argument: app/)
    end
  end

  describe "apply" do
    it "hands the names and every flag to the command" do
      run("apply", "app", "api", "--dry-run", "--diff", "--force", "--rollback-all-on-error")
      run("apply", "--all")

      expect(template_command).to have_received(:apply).with(names: %w[app api], all: false, project: nil, cwd: "/src/app",
        dry_run: true, diff: true, force: true, rollback: true, json: false)
      expect(template_command).to have_received(:apply).with(names: [], all: true, project: nil, cwd: "/src/app",
        dry_run: false, diff: false, force: false, rollback: false, json: false)
    end

    it "prints the command's outcome as an action document under --json, exiting through its status" do
      allow(template_command).to receive(:apply).and_return(results: [{"workspace" => "app", "outcome" => "failed"}, {"workspace" => "api", "outcome" => "applied"}],
        status: "partial", exit_code: 3, warnings: [], extra: {"backup" => "id-1", "rolled_back" => false})

      expect { run("apply", "--all", "--json") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
      expect(JSON.parse(out.string)).to include("action" => "template apply", "status" => "partial", "backup" => "id-1", "rolled_back" => false)
    end

    it "exits with the command's code in text mode" do
      allow(template_command).to receive(:apply).and_return(results: [], status: "failed", exit_code: 1)

      expect { run("apply", "app") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "refuses the flags only apply takes on other verbs, and apply's unused ones" do
      expect { run("status", "--force") }.to raise_error(Workspace::UsageError, /--force does not apply to 'template status'/)
      expect { run("apply", "--name", "app") }.to raise_error(Workspace::UsageError, /--name does not apply to 'template apply'/)
    end
  end

  describe "--relaunch" do
    let(:detector) { RecordingProjectDetector.new({}) }

    def applied(name, running: true, record_only: false, outcome: "applied")
      {"workspace" => name, "outcome" => outcome, "running" => running, "record_only" => record_only}
    end

    def apply_outcome(rows, status: "ok", extra: {})
      {results: rows, status: status, exit_code: Workspace::JsonEnvelope::ACTION_EXIT_CODES.fetch(status), warnings: [],
       extra: {"backup" => "id-1", "rolled_back" => false}.merge(extra)}
    end

    def relaunched(*names) = {exit_code: 0, results: names.map { |n| {"workspace" => n, "outcome" => "relaunched"} }, warnings: []}

    def document
      JSON.parse(out.string)
    end

    def exit_status
      yield
      nil
    rescue FakeSystemExit => e
      e.status
    end

    def relaunch_of(doc = document) = doc["results"].map { |r| [r["workspace"], r["relaunch"], r["relaunch_code"]] }

    it "leaves the document as it is without the flag, and relaunches nothing" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api")]))

      run("apply", "--all", "--json")

      expect(document["results"]).to eq([applied("api")])
      expect(document).not_to have_key("relaunched")
      expect(relauncher).not_to have_received(:active_name)
      expect(relauncher).not_to have_received(:call)
    end

    it "relaunches only applied rows that were running, rewrote the config and are active, marking each row" do
      rows = [applied("api"), applied("web", running: false), applied("doc", record_only: true, running: false), applied("old"),
        {"workspace" => "bad", "outcome" => "failed", "running" => true}, {"workspace" => "same", "outcome" => "unchanged", "running" => true}]
      allow(template_command).to receive(:apply).and_return(apply_outcome(rows, status: "partial"))
      allow(relauncher).to receive(:active_name) { |name| (name == "api") ? "api" : nil }
      allow(relauncher).to receive(:call).and_return(relaunched("api"))

      expect(exit_status { run("apply", "--all", "--relaunch", "--json") }).to eq(3)

      expect(relauncher).to have_received(:call).with(anything, %w[api], only_stopped: true)
      expect(relaunch_of).to eq([["api", "relaunched", nil], ["web", "not_running", nil], ["doc", nil, nil],
        ["old", "not_active", nil], ["bad", nil, nil], ["same", nil, nil]])
      expect(document).to include("status" => "partial", "relaunched" => %w[api])
    end

    it "relaunches under the state's spelling of a name and says not_active with a warning for an untracked session" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api"), applied("web")]))
      allow(relauncher).to receive(:active_name) { |name| {"api" => "API"}[name] }
      allow(relauncher).to receive(:call).and_return(relaunched("API"))

      run("apply", "--all", "--relaunch", "--json")

      expect(relauncher).to have_received(:call).with(anything, %w[API], only_stopped: true)
      expect(relaunch_of).to eq([["api", "relaunched", nil], ["web", "not_active", nil]])
      expect(document["status"]).to eq("ok")
      expect(document["warnings"]).to eq([{"code" => "relaunch_not_active", "workspace" => "web",
                                           "message" => "web's tmux session is up but not tracked as active, so it was not relaunched; run `workspace stop web` and `workspace launch web` by hand."}])
    end

    it "says would_relaunch under --dry-run, stops nothing, and always lists would_relaunch" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api", outcome: "would_apply"), applied("web", outcome: "would_apply", running: false)], status: "dry_run"))

      run("apply", "--all", "--dry-run", "--relaunch", "--json")

      expect(relauncher).not_to have_received(:call)
      expect(document["results"].map { |r| r["relaunch"] }).to eq(%w[would_relaunch not_running])
      expect(document).to include("status" => "dry_run", "would_relaunch" => %w[api])

      out.truncate(0)
      out.rewind
      allow(template_command).to receive(:apply).and_return(apply_outcome([], status: "dry_run"))
      run("apply", "--all", "--dry-run", "--relaunch", "--json")
      expect(document).to include("would_relaunch" => [])
    end

    it "lists relaunched as empty when nothing qualified" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("web", running: false)]))

      run("apply", "--all", "--relaunch", "--json")

      expect(relauncher).not_to have_received(:call)
      expect(document).to include("status" => "ok", "relaunched" => [])
    end

    it "relaunches nothing after a roll back: rows that would have qualified are skipped, with one warning" do
      rows = [applied("api", outcome: "rolled_back"), applied("kept"), applied("idle", outcome: "rolled_back", running: false), {"workspace" => "web", "outcome" => "failed"}]
      allow(template_command).to receive(:apply).and_return(apply_outcome(rows, status: "failed", extra: {"rolled_back" => true}))

      expect(exit_status { run("apply", "--all", "--rollback-all-on-error", "--relaunch", "--json") }).to eq(1)

      expect(relauncher).not_to have_received(:call)
      expect(relaunch_of).to eq([["api", "skipped", "relaunch_skipped"], ["kept", "skipped", "relaunch_skipped"], ["idle", nil, nil], ["web", nil, nil]])
      expect(document["warnings"].map { |w| w["code"] }).to eq(%w[relaunch_skipped])
      expect(document).to include("status" => "failed", "relaunched" => [])
    end

    it "prints a Warning: line for the rolled-back skip in text mode" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api", outcome: "rolled_back")], status: "failed", extra: {"rolled_back" => true}))

      expect(exit_status { run("apply", "--all", "--rollback-all-on-error", "--relaunch") }).to eq(1)

      expect(err.string).to include("Warning: Nothing was relaunched: the batch was rolled back.\n")
    end

    it "makes an ok run partial when a relaunch fails, with a closed relaunch_code, the reason in the warning and the stop's warnings" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api"), applied("web"), applied("bot")]))
      allow(relauncher).to receive(:call).and_return(exit_code: 1, warnings: ["iTerm did not answer"], results: [
        {"workspace" => "api", "outcome" => "relaunched"},
        {"workspace" => "bot", "outcome" => "failed", "reason" => "session_not_started", "message" => "tmuxinator exited 1"},
        {"workspace" => "web", "outcome" => "failed", "reason" => "relaunch_stop_failed"}
      ])

      expect(exit_status { run("apply", "--all", "--relaunch", "--json") }).to eq(3)

      expect(relaunch_of).to eq([["api", "relaunched", nil], ["web", "failed", "relaunch_stop_failed"], ["bot", "failed", "relaunch_launch_failed"]])
      expect(document).to include("status" => "partial", "relaunched" => %w[api])
      expect(document["warnings"]).to eq([
        {"code" => "relaunch_stop_warning", "message" => "iTerm did not answer"},
        {"code" => "relaunch_failed", "workspace" => "web", "message" => "web was not relaunched (relaunch_stop_failed)."},
        {"code" => "relaunch_failed", "workspace" => "bot", "message" => "bot was not relaunched (session_not_started: tmuxinator exited 1)."}
      ])
    end

    it "marks a workspace the relauncher gave no row for, or raised on, relaunch_launch_failed" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api")]))
      allow(relauncher).to receive(:call).and_return(exit_code: 1, results: [], warnings: [])

      expect(exit_status { run("apply", "--all", "--relaunch", "--json") }).to eq(3)
      expect(relaunch_of).to eq([["api", "failed", "relaunch_launch_failed"]])

      out.truncate(0)
      out.rewind
      allow(relauncher).to receive(:call).and_raise(Workspace::Error, "no tmuxinator")
      expect(exit_status { run("apply", "--all", "--relaunch", "--json") }).to eq(3)
      expect(relaunch_of).to eq([["api", "failed", "relaunch_launch_failed"]])
      expect(document["warnings"].last["message"]).to eq("api was not relaunched (relaunch_launch_failed: no tmuxinator).")
    end

    it "skips the workspace whose session holds TMUX_PANE even when the working directory is outside every workspace" do
      env["TMUX_PANE"] = "%5"
      allow(relauncher).to receive(:pane_in_session?) { |pane, name| pane == "%5" && name == "x" }
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("x"), applied("y")]))
      allow(relauncher).to receive(:call).and_return(relaunched("y"))

      run("apply", "--all", "--relaunch", "--json")

      expect(relauncher).to have_received(:call).with(anything, %w[y], only_stopped: true)
      expect(relaunch_of).to eq([["x", "skipped", "relaunch_own_workspace"], ["y", "relaunched", nil]])
      expect(document["warnings"].map { |w| w["code"] }).to eq(%w[relaunch_own_workspace])
    end

    it "skips a worktree whose session holds TMUX_PANE and relaunches the main checkout, from outside both" do
      env["TMUX_PANE"] = "%7"
      allow(relauncher).to receive(:pane_in_session?) { |_pane, name| name == "app.worktree-login" }
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app"), applied("app.worktree-login")]))
      allow(relauncher).to receive(:call).and_return(relaunched("app"))

      run("apply", "--all", "--relaunch", "--json")

      expect(relaunch_of).to eq([["app", "relaunched", nil], ["app.worktree-login", "skipped", "relaunch_own_workspace"]])
    end

    describe "with $TMUX set and no $TMUX_PANE" do
      before { env["TMUX"] = "/tmp/tmux-501/default,123,4" }

      it "skips the workspace whose session is the current client's, reading the session once" do
        allow(relauncher).to receive(:client_session).with("/tmp/tmux-501/default,123,4").and_return("foo_js")
        allow(relauncher).to receive(:session_of?) { |session, name| session == "foo_js" && name == "foo.js" }
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("foo.js"), applied("api"), applied("web")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api", "web"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relauncher).to have_received(:client_session).once
        expect(relauncher).not_to have_received(:pane_in_session?)
        expect(relaunch_of).to eq([["foo.js", "skipped", "relaunch_own_workspace"], ["api", "relaunched", nil], ["web", "relaunched", nil]])
        expect(document["warnings"].map { |w| w["code"] }).to eq(%w[relaunch_own_workspace])
      end

      it "warns relaunch_own_workspace_unknown when tmux can't name the client's session, relaunching by the cwd test alone" do
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relaunch_of).to eq([["api", "relaunched", nil]])
        expect(document["warnings"]).to eq([{"code" => "relaunch_own_workspace_unknown", "pane" => nil,
                                             "message" => "tmux could not say which session this command's tmux client is in, so the workspace this command runs in was told by the working directory alone."}])
      end
    end

    describe "with $TMUX_PANE that tmux can't place, and $TMUX set" do
      before do
        env["TMUX_PANE"] = "%9"
        env["TMUX"] = "/tmp/tmux-501/default,123,4"
      end

      it "falls back to the client's session, warning nothing when that answered" do
        allow(relauncher).to receive(:client_session).and_return("ws-x")
        allow(relauncher).to receive(:session_of?) { |session, name| session == "ws-x" && name == "x" }
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("x"), applied("y")]))
        allow(relauncher).to receive(:call).and_return(relaunched("y"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relauncher).to have_received(:client_session).once
        expect(relaunch_of).to eq([["x", "skipped", "relaunch_own_workspace"], ["y", "relaunched", nil]])
        expect(document["warnings"].map { |w| w["code"] }).to eq(%w[relaunch_own_workspace])
      end

      it "warns once when neither check answered" do
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("x")]))
        allow(relauncher).to receive(:call).and_return(relaunched("x"))

        run("apply", "--all", "--relaunch", "--json")

        expect(document["warnings"]).to eq([{"code" => "relaunch_own_workspace_unknown", "pane" => "%9",
                                             "message" => "tmux could not say which session pane %9 is in (nor which session this command's tmux client is in), so the workspace this command runs in was told by the working directory alone."}])
      end

      it "asks the client only for a workspace the pane could not be placed for" do
        allow(relauncher).to receive(:pane_in_session?).and_return(false)
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("x")]))
        allow(relauncher).to receive(:call).and_return(relaunched("x"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relauncher).not_to have_received(:client_session)
        expect(relaunch_of).to eq([["x", "relaunched", nil]])
      end
    end

    it "asks tmux nothing with neither $TMUX nor $TMUX_PANE set" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api")]))
      allow(relauncher).to receive(:call).and_return(relaunched("api"))

      run("apply", "--all", "--relaunch", "--json")

      expect(relauncher).not_to have_received(:client_session)
      expect(relauncher).not_to have_received(:pane_in_session?)
      expect(document["warnings"]).to eq([])
    end

    it "warns once when tmux placed the pane for none of the workspaces asked" do
      env["TMUX_PANE"] = "%9"
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("x"), applied("y")]))
      allow(relauncher).to receive(:call).and_return(relaunched("x", "y"))

      run("apply", "--all", "--relaunch", "--json")

      expect(document["warnings"]).to eq([{"code" => "relaunch_own_workspace_unknown", "pane" => "%9",
                                           "message" => "tmux could not say which session pane %9 is in, so the workspace this command runs in was told by the working directory alone."}])

      out.truncate(0)
      out.rewind
      allow(relauncher).to receive(:pane_in_session?) { |_pane, name| (name == "y") ? false : nil }
      run("apply", "--all", "--relaunch", "--json")
      expect(document["warnings"]).to eq([])
    end

    context "from inside one of the workspaces" do
      let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }

      it "never relaunches the caller's own workspace, says so in a warning, and leaves the status alone" do
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("App"), applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        expect(exit_status { run("apply", "--all", "--relaunch", "--json") }).to be_nil

        expect(relauncher).to have_received(:call).once.with(anything, %w[api], only_stopped: true)
        expect(relaunch_of).to eq([["App", "skipped", "relaunch_own_workspace"], ["api", "relaunched", nil]])
        expect(document).to include("status" => "ok", "relaunched" => %w[api])
        expect(document["warnings"]).to eq([{"code" => "relaunch_own_workspace", "workspace" => "App",
                                             "message" => "App is the workspace this command runs in, so it was not relaunched; run `workspace relaunch App` from outside it."}])
      end

      it "tells it by the working directory when TMUX_PANE is unset, asking tmux nothing" do
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app"), applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relauncher).not_to have_received(:pane_in_session?)
        expect(relaunch_of.first).to eq(["app", "skipped", "relaunch_own_workspace"])
      end

      it "skips both the working directory's workspace and the one whose session holds TMUX_PANE" do
        env["TMUX_PANE"] = "%7"
        allow(relauncher).to receive(:pane_in_session?) { |_pane, name| name == "app.worktree-login" }
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app"), applied("app.worktree-login"), applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relauncher).to have_received(:call).with(anything, %w[api], only_stopped: true)
        expect(relaunch_of).to eq([["app", "skipped", "relaunch_own_workspace"], ["app.worktree-login", "skipped", "relaunch_own_workspace"], ["api", "relaunched", nil]])
      end

      it "still skips the working directory's workspace when a stale TMUX_PANE places the pane elsewhere" do
        env["TMUX_PANE"] = "%7"
        allow(relauncher).to receive(:pane_in_session?).and_return(false)
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app"), applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relaunch_of).to eq([["app", "skipped", "relaunch_own_workspace"], ["api", "relaunched", nil]])
        expect(document["warnings"].map { |w| w["code"] }).to eq(%w[relaunch_own_workspace])
      end

      it "falls back to the working directory, with a warning, when tmux can't name the pane's session" do
        env["TMUX_PANE"] = "%7"
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app"), applied("api")]))
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("apply", "--all", "--relaunch", "--json")

        expect(relaunch_of).to eq([["app", "skipped", "relaunch_own_workspace"], ["api", "relaunched", nil]])
        expect(document["warnings"].first).to include("code" => "relaunch_own_workspace_unknown", "pane" => "%7")
      end

      it "skips it under --dry-run too" do
        allow(template_command).to receive(:apply).and_return(apply_outcome([applied("app", outcome: "would_apply")], status: "dry_run"))

        run("apply", "--all", "--dry-run", "--relaunch", "--json")

        expect(relaunch_of).to eq([["app", "skipped", "relaunch_own_workspace"]])
        expect(document).to include("would_relaunch" => [])
      end
    end

    it "prints a line per relaunched or failed workspace in text mode, a Warning: for an untracked one, and exits 3 on a failure" do
      allow(template_command).to receive(:apply).and_return(apply_outcome([applied("api"), applied("web"), applied("doc", running: false), applied("odd")]))
      allow(relauncher).to receive(:active_name) { |name| (name == "odd") ? nil : name }
      allow(relauncher).to receive(:call).and_return(exit_code: 1, warnings: [], results: [
        {"workspace" => "api", "outcome" => "relaunched"}, {"workspace" => "web", "outcome" => "failed", "reason" => "relaunch_stop_failed"}
      ])

      expect(exit_status { run("apply", "--all", "--relaunch") }).to eq(3)

      expect(out.string).to include("api: relaunched\n", "web: relaunch failed: relaunch_stop_failed\n")
      expect(out.string).not_to include("doc:")
      expect(err.string).to include("Warning: odd's tmux session is up but not tracked as active")
    end

    describe "restore" do
      def restored(name, config_rewritten: true) = {"workspace" => name, "outcome" => "restored", "files" => %w[config record], "config_rewritten" => config_rewritten}

      it "relaunches restored workspaces whose config changed and whose session is up, never a template set's row" do
        allow(backups_command).to receive(:restore).and_return(results: [
          restored("api"), restored("web"), restored("rec", config_rewritten: false),
          {"workspace" => "doc", "outcome" => "unchanged"}, {"workspace" => nil, "template" => "team", "outcome" => "restored"}
        ], status: "ok", exit_code: 0, warnings: [], extra: {"backup" => "id-2", "restored_from" => "id-1"})
        allow(relauncher).to receive(:running?) { |name| name == "api" }
        allow(relauncher).to receive(:call).and_return(relaunched("api"))

        run("restore", "id-1", "--relaunch", "--json")

        expect(backups_command).to have_received(:restore).with(id: "id-1", names: [], force: false, json: true)
        expect(relauncher).to have_received(:call).with(anything, %w[api], only_stopped: true)
        expect(relauncher).not_to have_received(:running?).with("rec")
        expect(document["results"].map { |r| r["relaunch"] }).to eq(["relaunched", "not_running", nil, nil, nil])
        expect(document).to include("status" => "ok", "relaunched" => %w[api], "restored_from" => "id-1")
      end
    end

    it "refuses --relaunch on a verb that rewrites nothing" do
      expect { run("status", "--relaunch") }.to raise_error(Workspace::UsageError, /--relaunch does not apply to 'template status'/)
      expect { run("backup", "--relaunch") }.to raise_error(Workspace::UsageError, /--relaunch does not apply to 'template backup'/)
    end
  end

  describe "export and import" do
    it "hands the directory, scope and --force to export" do
      run("export", "~/out", "--scope", "project", "--force")

      expect(template_command).to have_received(:export).with(dir: "~/out", scope: "project", force: true, workspace: "app", cwd: "/src/app")
    end

    it "hands import no path when none is given" do
      run("import")

      expect(template_command).to have_received(:import).with(path: nil, scope: nil, force: false, workspace: "app", cwd: "/src/app")
    end

    it "hands the path to import, force false by default" do
      run("import", "~/in")

      expect(template_command).to have_received(:import).with(path: "~/in", scope: nil, force: false, workspace: "app", cwd: "/src/app")
    end

    it "needs a DIR or PATH, and refuses flags they do not take" do
      expect { run("export") }.to raise_error(Workspace::UsageError, /'template export' needs a DIR/)
      expect { run("import", "x", "--kind", "project") }.to raise_error(Workspace::UsageError, /--kind does not apply to 'template import'/)
    end

    it "prints the action document under --json" do
      allow(template_command).to receive(:import).and_return({"workspace" => nil, "outcome" => "imported"})

      run("import", "x", "--json")

      expect(JSON.parse(out.string)).to include("ok" => true, "action" => "template import")
    end
  end

  describe "new, edit and use" do
    it "makes a copy for the detected workspace, from --from, in --scope" do
      run("new", "team", "--from", "base", "--scope", "project")

      expect(template_command).to have_received(:new).with(name: "team", from: "base", scope: "project", workspace: "app", cwd: "/src/app")
    end

    it "selects a set for a kind and scope" do
      run("use", "team", "--kind", "worktree", "--scope", "global")

      expect(template_command).to have_received(:use).with(name: "team", scope: "global", kind: "worktree", workspace: "app", cwd: "/src/app")
    end

    it "needs a NAME for new and use, and refuses a second one" do
      expect { run("new") }.to raise_error(Workspace::UsageError, /'template new' needs a tmuxinator template NAME/)
      expect { run("use") }.to raise_error(Workspace::UsageError, /'template use' needs/)
      expect { run("use", "a", "b") }.to raise_error(Workspace::UsageError, /Unexpected argument: b/)
    end

    it "refuses the flags the verb does not take" do
      expect { run("new", "team", "--kind", "project") }.to raise_error(Workspace::UsageError, /--kind does not apply to 'template new'/)
      expect { run("edit", "team", "--scope", "global") }.to raise_error(Workspace::UsageError, /--scope does not apply to 'template edit'/)
      expect { run("use", "team", "--from", "x") }.to raise_error(Workspace::UsageError, /--from does not apply to 'template use'/)
    end

    it "prints the action document under --json" do
      allow(template_command).to receive(:use).and_return({"workspace" => nil, "outcome" => "selected", "template" => "team"})

      run("use", "team", "--json")

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => true, "action" => "template use", "status" => "ok")
      expect(doc["results"]).to eq([{"workspace" => nil, "outcome" => "selected", "template" => "team"}])
    end

    it "gives edit an opener unless --json, and exits 1 when a file has an error" do
      allow(template_command).to receive(:edit).and_return({"outcome" => "failed"})

      expect { run("edit", "team") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(template_command).to have_received(:edit).with(set: "team", kind: nil, workspace: "app", opener: an_instance_of(Proc))

      allow(template_command).to receive(:edit).and_return({"outcome" => "edited"})
      run("edit", "--kind", "project", "--json")
      expect(template_command).to have_received(:edit).with(set: nil, kind: "project", workspace: "app", opener: nil)
    end
  end
end
