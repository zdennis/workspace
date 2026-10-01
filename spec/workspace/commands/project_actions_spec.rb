require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::ProjectActions do
  include FakeCheckouts

  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:roots) { {} }
  let(:events) { [] }
  let(:active) { [] }
  let(:live_sessions) { [] }
  let(:stubborn) { [] }
  let(:own_session) { nil }
  let(:own_pane) { own_session && "%7" }
  let(:stop_error) { nil }

  let(:fake_config) do
    roots_hash = roots
    Class.new do
      define_method(:available_projects) { roots_hash.keys.sort }
      define_method(:project_root_for) { |name| roots_hash[name] }
    end.new
  end

  let(:catalog) do
    Workspace::ProjectCatalog.new(project_config: fake_config, git: Workspace::Git.new(output: StringIO.new, input: StringIO.new))
  end

  let(:state) do
    list = active
    Class.new do
      define_method(:load) { self }
      define_method(:[]) { |name| list.include?(name) ? {"unique_id" => "x"} : nil }
    end.new
  end

  # Session names differ from workspace names (dots become dashes), as with tmuxinator.
  let(:tmux) do
    live = live_sessions
    own = own_session
    Class.new do
      define_method(:sessions) { live.dup }
      define_method(:session_name_for) { |workspace| workspace.tr(".", "-") }
      define_method(:session_name_for_pane) { |_pane| own }
    end.new
  end

  # Records each call with a snapshot of the output at that moment. Like the
  # real Stop it returns the workspaces that were active, and kills their
  # sessions unless they're +stubborn+.
  let(:stop_command) do
    out = output
    log = events
    live = live_sessions
    hard = stubborn
    error = stop_error
    Class.new do
      define_method(:call) do |projects = [], quiet: false|
        raise error if error
        log << {stop: projects, quiet: quiet, output_so_far: out.string.dup}
        projects.each do |p|
          session = p.tr(".", "-")
          live.delete(session) unless hard.include?(p)
        end
        projects
      end
    end.new
  end

  let(:hook_calls) { [] }
  let(:hook_runner) { fake_hook_runner(:text) }
  let(:json_hook_runner) { fake_hook_runner(:json) }

  def fake_hook_runner(label)
    calls = hook_calls
    Class.new do
      define_method(:run) { |project, event, env: {}| calls << [label, project, event] }
    end.new
  end

  subject(:command) do
    described_class.new(catalog: catalog, stop_command: stop_command, state: state, tmux: tmux, hook_runner: hook_runner,
      json_hook_runner: json_hook_runner, output: output, error_output: error_output, own_pane: own_pane)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  # app (main), app.worktree-login (exists), app.worktree-old (checkout gone)
  def build_app
    main = make_main_checkout(File.join(@root, "app"))
    roots["app"] = main
    roots["app.worktree-login"] = make_linked_worktree(main, File.join(main, ".worktrees", "login"))
    roots["app.worktree-old"] = File.join(main, ".worktrees", "old")
    main
  end

  def run_json(**opts)
    result = command.stop(json: true, **opts)
    [result, JSON.parse(output.string)]
  end

  def outcomes(payload)
    payload["results"].to_h { |r| [r["workspace"], r["outcome"]] }
  end

  before { build_app }

  describe "#stop" do
    context "when nothing is running" do
      it "says so, stops nothing and exits 0" do
        result = command.stop(name: "app")

        expect(output.string).to eq("Nothing running in project 'app'.\n")
        expect(events).to be_empty
        expect(result).to eq({exit_code: 0})
      end

      it "reports every member as not_running in JSON" do
        result, payload = run_json(name: "app")

        expect(result).to eq({exit_code: 0})
        expect(payload).to include("schema_version" => 1, "action" => "stop", "dry_run" => false, "status" => "ok", "warnings" => [])
        expect(outcomes(payload).values.uniq).to eq(["not_running"])
        expect(payload["summary"]).to eq("not_running" => 3)
      end
    end

    context "when some workspaces are running" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login other] }

      it "calls Stop once for all targets, main first, quietly in JSON mode only" do
        command.stop(name: "app")
        json_events = events.dup
        events.clear
        command.stop(name: "app", json: true)

        expect(json_events.map { |e| e.values_at(:stop, :quiet) }).to eq([[%w[app app.worktree-login], false]])
        expect(events.map { |e| e.values_at(:stop, :quiet) }).to eq([[%w[app app.worktree-login], true]])
      end

      it "prints a summary and exits 0" do
        result = command.stop(name: "app")

        expect(output.string).to eq("Stopped 2 workspace(s) of project 'app'.\n")
        expect(result).to eq({exit_code: 0})
      end

      it "reports stopped and not_running outcomes with paths and kinds in JSON" do
        result, payload = run_json(name: "app")

        expect(result).to eq({exit_code: 0})
        expect(payload["status"]).to eq("ok")
        expect(payload["project"]).to eq("name" => "app", "id" => File.join(@root, "app", ".git"), "path" => File.join(@root, "app"))
        expect(payload["results"].first).to eq("workspace" => "app", "path" => File.join(@root, "app"), "kind" => "main", "outcome" => "stopped", "reason" => nil)
        expect(outcomes(payload)).to eq("app" => "stopped", "app.worktree-login" => "stopped", "app.worktree-old" => "not_running")
        expect(payload["summary"]).to eq("stopped" => 2, "not_running" => 1)
      end

      it "runs post_stop for each stopped workspace, through the stderr-bound runner in JSON mode" do
        command.stop(name: "app")
        command.stop(name: "app", json: true)

        expect(hook_calls).to eq([
          [:text, "app", "post_stop"], [:text, "app.worktree-login", "post_stop"],
          [:json, "app", "post_stop"], [:json, "app.worktree-login", "post_stop"]
        ])
      end

      it "leaves other sessions alone" do
        command.stop(name: "app")

        expect(live_sessions).to eq(["other"])
      end

      it "resolves NAME from a member workspace name or a path" do
        command.stop(name: "app.worktree-login")
        command.stop(name: File.join(@root, "app"))

        expect(events.size).to eq(2)
      end

      it "defaults NAME to the project containing cwd" do
        command.stop(cwd: File.join(@root, "app"))

        expect(events.first[:stop]).to eq(%w[app app.worktree-login])
      end
    end

    context "when a running workspace's checkout is gone" do
      let(:active) { %w[app.worktree-old] }
      let(:live_sessions) { %w[app-worktree-old] }

      it "stops it like any other" do
        _, payload = run_json(name: "app")

        expect(events.first[:stop]).to eq(["app.worktree-old"])
        expect(outcomes(payload)["app.worktree-old"]).to eq("stopped")
      end
    end

    context "when a session survives the stop" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }
      let(:stubborn) { ["app.worktree-login"] }

      it "marks it failed, still runs post_stop (Stop already removed it from state) and exits 3" do
        result, payload = run_json(name: "app")

        expect(result).to eq({exit_code: 3})
        expect(payload["status"]).to eq("partial")
        expect(outcomes(payload)).to include("app" => "stopped", "app.worktree-login" => "failed")
        failed = payload["results"].find { |r| r["outcome"] == "failed" }
        expect(failed).to include("reason" => "error", "message" => "tmux session 'app-worktree-login' is still running after stop")
        expect(payload["summary"]).to eq("stopped" => 1, "failed" => 1, "not_running" => 1)
      end

      it "names the failure in the text summary" do
        command.stop(name: "app")

        expect(output.string).to include("Stopped 1 workspace(s)", "Failed to stop app.worktree-login: tmux session 'app-worktree-login' is still running after stop")
      end

      context "and every target failed" do
        let(:stubborn) { %w[app app.worktree-login] }

        it "reports refused and exits 1" do
          result, payload = run_json(name: "app")

          expect(result).to eq({exit_code: 1})
          expect(payload["status"]).to eq("refused")
          expect(payload["summary"]).to eq("failed" => 2, "not_running" => 1)
        end
      end
    end

    context "when the caller is inside one of the project's sessions" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }
      let(:own_session) { "app" }

      it "stops everyone else in one call, then its own session last, after the output is written" do
        result = command.stop(name: "app")

        expect(events.map { |e| e[:stop] }).to eq([["app.worktree-login"], ["app"]])
        expect(events[0][:output_so_far]).to eq("")
        expect(events[1][:output_so_far]).to eq("Stopped 2 workspace(s) of project 'app'.\n")
        expect(result).to eq({exit_code: 0})
      end

      it "has written the whole JSON result before the last stop, with own listed last as stopped" do
        events_before = nil
        allow(stop_command).to receive(:call).and_wrap_original do |original, *args, **kwargs|
          events_before = JSON.parse(output.string) if args.first == ["app"] && !output.string.empty?
          original.call(*args, **kwargs)
        end

        run_json(name: "app")

        expect(events_before["results"].map { |r| r["workspace"] }).to eq(%w[app.worktree-login app.worktree-old app])
        expect(events_before["results"].last).to include("workspace" => "app", "outcome" => "stopped")
      end

      it "does not run post_stop for the caller's own workspace" do
        command.stop(name: "app")

        expect(hook_calls).to eq([[:text, "app.worktree-login", "post_stop"]])
      end

      it "stops its own session even when another target failed, exiting 3" do
        stubborn << "app.worktree-login"

        result = command.stop(name: "app")

        expect(events.map { |e| e[:stop] }).to eq([["app.worktree-login"], ["app"]])
        expect(result).to eq({exit_code: 3})
      end

      it "flushes the output before stopping its own session" do
        flushed = []
        allow(output).to receive(:flush) { flushed << output.string.dup }
        allow(stop_command).to receive(:call).and_wrap_original do |original, *args, **kwargs|
          expect(flushed.last).to include("Stopped") if args.first == ["app"]
          original.call(*args, **kwargs)
        end

        command.stop(name: "app")
      end
    end

    context "when the caller is the only running workspace" do
      let(:active) { %w[app] }
      let(:live_sessions) { %w[app] }
      let(:own_session) { "app" }

      it "makes a single Stop call after writing output, with no re-read of sessions needed" do
        command.stop(name: "app")

        expect(events.map { |e| e[:stop] }).to eq([["app"]])
        expect(events[0][:output_so_far]).to include("Stopped 1 workspace(s)")
      end
    end

    context "when the caller's session is not a member of the project" do
      let(:active) { %w[app] }
      let(:live_sessions) { %w[app] }
      let(:own_session) { "elsewhere" }

      it "treats every target as an ordinary one" do
        command.stop(name: "app")

        expect(events.map { |e| e[:stop] }).to eq([["app"]])
        expect(events[0][:output_so_far]).to eq("")
      end
    end

    context "with --dry-run" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }

      it "lists the targets, stops nothing, runs no hooks and exits 0" do
        result = command.stop(name: "app", dry_run: true)

        expect(output.string).to eq("Would stop 2 workspace(s) of project 'app':\n  app\n  app.worktree-login\n")
        expect(events).to be_empty
        expect(hook_calls).to be_empty
        expect(live_sessions).to eq(%w[app app-worktree-login])
        expect(result).to eq({exit_code: 0})
      end

      it "reports would_stop and status dry_run in JSON" do
        result, payload = run_json(name: "app", dry_run: true)

        expect(result).to eq({exit_code: 0})
        expect(payload).to include("dry_run" => true, "status" => "dry_run")
        expect(outcomes(payload)).to eq("app" => "would_stop", "app.worktree-login" => "would_stop", "app.worktree-old" => "not_running")
        expect(payload["summary"]).to eq("would_stop" => 2, "not_running" => 1)
      end

      it "says nothing is running when nothing would be stopped" do
        active.clear

        expect(command.stop(name: "app", dry_run: true)).to eq({exit_code: 0})
        expect(output.string).to eq("Nothing running in project 'app'.\n")
      end

      it "lists the caller's own workspace last" do
        own_command = described_class.new(catalog: catalog, stop_command: stop_command, state: state,
          tmux: Class.new(tmux.class) { def session_name_for_pane(_) = "app" }.new, hook_runner: hook_runner, output: output, own_pane: "%1")
        own_command.stop(name: "app", dry_run: true)

        expect(output.string.lines.last).to eq("  app\n")
      end
    end

    context "with a name that doesn't resolve" do
      it "raises for an unknown NAME in text mode" do
        expect { command.stop(name: "nope") }.to raise_error(Workspace::Error, /nope/)
        expect(events).to be_empty
      end

      it "prints the JSON error contract and exits 1 in JSON mode" do
        result = command.stop(name: "nope", json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /nope/)
      end

      it "raises a UsageError for an ambiguous NAME, and prints the error as JSON under --json" do
        a = make_main_checkout(File.join(@root, "a", "dup"))
        b = make_main_checkout(File.join(@root, "b", "dup"))
        roots["wt-a"] = make_linked_worktree(a, File.join(@root, "wa"))
        roots["wt-b"] = make_linked_worktree(b, File.join(@root, "wb"))

        expect { command.stop(name: "dup") }.to raise_error(Workspace::UsageError)
        expect(events).to be_empty
        expect(command.stop(name: "dup", json: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /dup/)
      end

      it "reports an unexpected failure from Stop as a JSON error under --json" do
        active << "app"
        live_sessions << "app"
        stop_error_value = Workspace::Error.new("boom")
        allow(stop_command).to receive(:call).and_raise(stop_error_value)

        expect(command.stop(name: "app", json: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "error" => "boom")
      end
    end
  end

  describe "list-projects" do
    it "is not touched: ProjectActions only adds the stop leaf" do
      expect(described_class.instance_methods(false)).to eq([:stop])
    end
  end
end
