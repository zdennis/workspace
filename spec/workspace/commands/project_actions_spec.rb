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
      define_method(:sessions) { |strict: false| live.dup }
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

  def counts(**given)
    {"stopped" => 0, "would_stop" => 0, "not_running" => 0, "failed" => 0}.merge(given.transform_keys(&:to_s))
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
        expect(payload["summary"]).to eq(counts(not_running: 3))
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
        expect(payload["summary"]).to eq(counts(stopped: 2, not_running: 1))
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

      it "marks it failed, skips its post_stop and exits 3" do
        result, payload = run_json(name: "app")

        expect(result).to eq({exit_code: 3})
        expect(payload["status"]).to eq("partial")
        expect(outcomes(payload)).to include("app" => "stopped", "app.worktree-login" => "failed")
        failed = payload["results"].find { |r| r["outcome"] == "failed" }
        expect(failed).to include("reason" => "error", "message" => "tmux session 'app-worktree-login' is still running after stop")
        expect(payload["summary"]).to eq(counts(stopped: 1, failed: 1, not_running: 1))
        expect(hook_calls).to eq([[:json, "app", "post_stop"]])
      end

      it "names the failure in the text summary" do
        command.stop(name: "app")

        expect(output.string).to include("Stopped 1 workspace(s)", "Failed to stop app.worktree-login: tmux session 'app-worktree-login' is still running after stop")
      end

      context "and every target failed" do
        let(:stubborn) { %w[app app.worktree-login] }

        it "reports failed and exits 1" do
          result, payload = run_json(name: "app")

          expect(result).to eq({exit_code: 1})
          expect(payload["status"]).to eq("failed")
          expect(payload["summary"]).to eq(counts(failed: 2, not_running: 1))
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

      it "stops its own session quietly so text mode prints one summary line" do
        command.stop(name: "app")

        expect(events.last).to include(stop: ["app"], quiet: true)
        expect(output.string.scan("Stopped").size).to eq(1)
      end

      it "looks up its own session once per call" do
        expect(tmux).to receive(:session_name_for_pane).once.and_call_original
        command.stop(name: "app")
      end

      it "prints only the result JSON, and reports a failing last stop on stderr" do
        allow(stop_command).to receive(:call).and_wrap_original do |original, *args, **kwargs|
          raise Workspace::Error, "late boom" if args.first == ["app"]
          original.call(*args, **kwargs)
        end

        result = command.stop(name: "app", json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("status" => "ok")
        expect(error_output.string).to include("late boom")
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

    context "when the caller's own workspace is active in tmux but absent from state" do
      let(:active) { %w[app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }
      let(:own_session) { "app" }

      it "is not a target and is not stopped" do
        _, payload = run_json(name: "app")

        expect(events.map { |e| e[:stop] }).to eq([["app.worktree-login"]])
        expect(outcomes(payload)["app"]).to eq("not_running")
      end
    end

    context "when a post_stop hook raises mid-run" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }

      it "reports a JSON error and prints a single document" do
        allow(json_hook_runner).to receive(:run).and_raise(Workspace::Error, "hook broke")

        result = command.stop(name: "app", json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "hook broke")
      end
    end

    context "when the tmux re-read errors" do
      let(:active) { %w[app app.worktree-login] }
      let(:live_sessions) { %w[app app-worktree-login] }

      before { allow(tmux).to receive(:sessions).and_raise(Workspace::Error, "protocol mismatch") }

      it "keeps the outcomes Stop reported and warns in JSON and on stderr" do
        result, payload = run_json(name: "app")

        expect(result).to eq({exit_code: 0})
        expect(outcomes(payload)).to include("app" => "stopped", "app.worktree-login" => "stopped")
        expect(payload["warnings"]).to eq(["could not verify sessions stopped: protocol mismatch"])
        expect(error_output.string).to eq("could not verify sessions stopped: protocol mismatch\n")
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
        expect(payload["summary"]).to eq(counts(would_stop: 2, not_running: 1))
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

      it "reports a usage error from the catalog as the JSON error contract" do
        allow(catalog).to receive(:find).and_raise(Workspace::UsageError, "Unexpected argument: b.")

        expect(command.stop(name: "a", json: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "Unexpected argument: b.")
      end

      it "reports an unexpected failure from Stop as a JSON error under --json" do
        active << "app"
        live_sessions << "app"
        stop_error_value = Workspace::Error.new("boom")
        allow(stop_command).to receive(:call).and_raise(stop_error_value)

        expect(command.stop(name: "app", json: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "boom")
      end
    end
  end

  describe "#kill" do
    let(:input) { StringIO.new("") }
    let(:liveness) { FakeLockLiveness.new }
    let(:lock_dir) { File.join(@root, "locks") }
    let(:lock_namespace) do
      dir = -> { lock_dir }
      Class.new do
        define_method(:resolve) { |cwd:| {key: cwd, display: File.basename(cwd), dir: dir.call} }
      end.new
    end

    # Answers per checkout path: unsaved (nil = clean), branch, or :raise / :sleep.
    let(:git_answers) { {} }
    let(:fake_git) do
      answers = git_answers
      Class.new do
        define_method(:unsaved_work) do |path|
          answer = answers.fetch(path, {})
          raise answer[:raise] if answer[:raise]
          sleep answer[:sleep] if answer[:sleep]
          answer[:unsaved]
        end
        define_method(:worktree_branch) { |path| answers.fetch(path, {}).fetch(:branch, File.basename(path)) }
      end.new
    end

    # Records each call with the output written so far. Raises +kill_errors+
    # for a workspace before its block runs (as Kill's re-check would), and
    # +late_errors+ after it (as a failing config removal would).
    let(:kill_calls) { [] }
    let(:kill_errors) { {} }
    let(:late_errors) { {} }
    let(:kill_command) do
      out = output
      log = kill_calls
      errors = kill_errors
      late = late_errors
      Class.new do
        define_method(:call) do |project, force: false, confirm: true, quiet: false, missing_ok: false, warn_inactive: true, &block|
          log << {project: project, force: force, confirm: confirm, quiet: quiet, missing_ok: missing_ok, warn_inactive: warn_inactive,
                  output_so_far: out.string.dup}
          raise errors[project] if errors[project]
          block&.call(project)
          raise late[project] if late[project]
          project
        end
      end.new
    end

    subject(:command) do
      described_class.new(catalog: catalog, stop_command: stop_command, kill_command: kill_command, state: state, tmux: tmux,
        git: fake_git, lock_namespace: lock_namespace, lock_holder: liveness, hook_runner: hook_runner,
        json_hook_runner: json_hook_runner, output: output, error_output: error_output, input: input, own_pane: own_pane)
    end

    let(:main) { File.join(@root, "app") }
    let(:login) { File.join(main, ".worktrees", "login") }
    let(:old) { File.join(main, ".worktrees", "old") }
    let(:wip) { File.join(main, ".worktrees", "wip") }
    let(:unsaved_hash) { {changed_files: 2, unpushed_commits: 1, branch: "wip"} }

    def add_wip
      roots["app.worktree-wip"] = make_linked_worktree(main, wip)
    end

    def drop_old
      roots.delete("app.worktree-old")
    end

    def hold_lock(name, worktree, pid)
      Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
        .acquire(name, identity: {kind: "agent", pid: pid, started: "start-#{pid}", pane: "%#{pid}", worktree: worktree},
          waiter_pid: pid, waiter_started: "start-#{pid}")
    end

    def kill_json(**opts)
      result = command.kill(name: "app", json: true, yes: true, **opts)
      [result, JSON.parse(output.string)]
    end

    def kill_counts(**given)
      {"removed" => 0, "would_remove" => 0, "refused" => 0, "not_attempted" => 0, "failed" => 0, "kept" => 0}
        .merge(given.transform_keys(&:to_s))
    end

    def row(payload, workspace)
      payload["results"].find { |r| r["workspace"] == workspace }
    end

    context "when every worktree is clean" do
      before { drop_old }

      it "kills each worktree through Kill without its prompt, keeps the main checkout and exits 0" do
        result, payload = kill_json

        expect(result).to eq({exit_code: 0})
        expect(kill_calls.map { |c| c.values_at(:project, :force, :confirm, :quiet, :missing_ok) })
          .to eq([["app.worktree-login", false, false, true, false]])
        expect(kill_calls.first[:warn_inactive]).to be(false)
        expect(payload).to include("schema_version" => 1, "action" => "kill", "dry_run" => false, "status" => "ok", "warnings" => [])
        expect(outcomes(payload)).to eq("app" => "kept", "app.worktree-login" => "removed")
        expect(payload["summary"]).to eq(kill_counts(removed: 1, kept: 1))
      end

      it "reports each worktree's checks in its row" do
        _, payload = kill_json

        expect(row(payload, "app")).to eq("workspace" => "app", "path" => main, "kind" => "main", "outcome" => "kept", "reason" => nil)
        expect(row(payload, "app.worktree-login")).to eq(
          "workspace" => "app.worktree-login", "path" => login, "kind" => "worktree", "outcome" => "removed",
          "reason" => nil, "unsaved" => "no", "branch" => "login", "dev_env" => false
        )
      end

      it "runs post_kill from inside Kill, through the stderr-bound runner in JSON mode" do
        kill_json
        command.kill(name: "app", yes: true)

        expect(hook_calls).to eq([[:json, "app.worktree-login", "post_kill"], [:text, "app.worktree-login", "post_kill"]])
      end

      it "prints a text summary" do
        command.kill(name: "app", yes: true)

        expect(output.string).to eq("Removed 1 worktree(s) of project 'app'.\nKept the main checkout app.\n")
        expect(kill_calls.first[:quiet]).to be(false)
      end
    end

    context "with the confirmation prompt" do
      before { drop_old }

      it "prints the plan and kills nothing when the answer is no" do
        input.string = "n\n"

        result = command.kill(name: "app")

        expect(result).to eq({exit_code: 0})
        expect(kill_calls).to be_empty
        expect(output.string).to include(
          "Project 'app' (#{main}):\n",
          "  keep    app                 #{main}  (main checkout)\n",
          "  remove  app.worktree-login  #{login}  (branch login)\n",
          "Remove 1 worktree(s) of 'app' and kill their sessions? [y/N] Cancelled.\n"
        )
      end

      it "treats no answer at all as no" do
        expect(command.kill(name: "app")).to eq({exit_code: 0})
        expect(kill_calls).to be_empty
      end

      it "kills after a yes" do
        input.string = "y\n"

        expect(command.kill(name: "app")).to eq({exit_code: 0})
        expect(kill_calls.map { |c| c[:project] }).to eq(["app.worktree-login"])
        expect(kill_calls.first[:confirm]).to be(false)
      end

      it "is skipped with yes" do
        command.kill(name: "app", yes: true)

        expect(output.string).not_to include("[y/N]")
        expect(kill_calls.size).to eq(1)
      end

      it "still asks under force" do
        command.kill(name: "app", force: true)

        expect(output.string).to include("[y/N]")
        expect(kill_calls).to be_empty
      end
    end

    context "with --json but neither --yes nor --dry-run" do
      it "is a usage error printed as the JSON error contract, and kills nothing" do
        result = command.kill(name: "app", json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "projects kill --json never prompts: pass --yes to remove, or --dry-run to preview.")
        expect(kill_calls).to be_empty
      end
    end

    describe "refusals" do
      it "refuses a missing checkout, kills nothing and exits 1" do
        result, payload = kill_json

        expect(result).to eq({exit_code: 1})
        expect(kill_calls).to be_empty
        expect(payload["status"]).to eq("refused")
        expect(outcomes(payload)).to eq("app" => "kept", "app.worktree-login" => "not_attempted", "app.worktree-old" => "refused")
        expect(row(payload, "app.worktree-old")).to include("reason" => "missing", "unsaved" => "missing",
          "message" => "checkout is gone (#{old})", "blockers" => [{"reason" => "missing", "message" => "checkout is gone (#{old})"}])
        expect(payload["summary"]).to eq(kill_counts(refused: 1, not_attempted: 1, kept: 1))
      end

      it "refuses unsaved work, with its details" do
        drop_old
        git_answers[login] = {unsaved: {changed_files: 2, unpushed_commits: 1, branch: "login"}}

        result, payload = kill_json

        expect(result).to eq({exit_code: 1})
        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "unsaved", "unsaved" => "yes",
          "changed_files" => 2, "unpushed_commits" => 1, "branch" => "login")
        expect(row(payload, "app.worktree-login")["message"]).to eq("has unsaved work: 2 changed file(s) and 1 unpushed commit(s) on login")
      end

      it "refuses a worktree git can't check" do
        drop_old
        git_answers[login] = {unsaved: :unknown}

        _, payload = kill_json

        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "unknown", "unsaved" => "unknown")
      end

      it "treats a git error as unknown" do
        drop_old
        git_answers[login] = {raise: RuntimeError.new("boom")}

        _, payload = kill_json

        expect(row(payload, "app.worktree-login")).to include("reason" => "unknown", "unsaved" => "unknown")
      end

      it "treats a git check that runs out of time as unknown" do
        drop_old
        git_answers[login] = {sleep: 2}

        result = command.kill(name: "app", json: true, yes: true, git_timeout: 0.05)

        expect(result).to eq({exit_code: 1})
        expect(row(JSON.parse(output.string), "app.worktree-login")).to include("reason" => "unknown")
      end

      it "refuses the worktree running the dev env, pointing at 'workspace dev down'" do
        drop_old
        hold_lock("devenv", File.join(login, "lib"), 101)

        _, payload = kill_json

        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "dev_env", "dev_env" => true,
          "message" => "the dev environment is running in it; run 'workspace dev down' first")
      end

      it "ignores a stale dev env holder" do
        drop_old
        hold_lock("devenv", login, 101)
        liveness.kill(101)

        expect(kill_json.first).to eq({exit_code: 0})
      end

      it "does not refuse when the dev env runs in the main checkout" do
        drop_old
        hold_lock("devenv", main, 101)

        expect(kill_json.first).to eq({exit_code: 0})
      end

      it "refuses every worktree when the lock store can't be read" do
        drop_old
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        _, payload = kill_json

        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "lock_store")
        expect(row(payload, "app.worktree-login")["message"]).to start_with("could not read the repo's locks")
          .and include("nothing overrides this", "'workspace kill NAME'")
      end

      it "does not let --force or --discard-unsaved override an unreadable lock store" do
        drop_old
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        result, payload = kill_json(force: true, discard_unsaved: true)

        expect(result).to eq({exit_code: 1})
        expect(row(payload, "app.worktree-login")["reason"]).to eq("lock_store")
        expect(kill_calls).to be_empty
      end

      it "points at --timeout when git couldn't check a worktree" do
        drop_old
        git_answers[login] = {unsaved: :unknown}

        command.kill(name: "app", yes: true)

        expect(output.string).to include("app.worktree-login: git couldn't check it for unsaved work (--force overrides this, or retry with a longer --timeout)")
      end

      it "lists every blocker of every member, and each reason in text" do
        add_wip
        git_answers[wip] = {unsaved: unsaved_hash}
        hold_lock("devenv", wip, 101)

        result = command.kill(name: "app", yes: true)

        expect(result).to eq({exit_code: 1})
        expect(output.string).to eq(<<~TEXT)
          Not killing project 'app'; nothing was removed:
            app.worktree-old: checkout is gone (#{old}) (--force overrides this)
            app.worktree-wip: has unsaved work: 2 changed file(s) and 1 unpushed commit(s) on wip (--discard-unsaved removes it anyway, losing that work)
            app.worktree-wip: the dev environment is running in it; run 'workspace dev down' first
        TEXT
        expect(kill_calls).to be_empty
      end

      it "lists both blockers of one member in JSON, the first as its reason" do
        drop_old
        add_wip
        git_answers[wip] = {unsaved: unsaved_hash}
        hold_lock("devenv", wip, 101)

        _, payload = kill_json

        expect(row(payload, "app.worktree-wip")["reason"]).to eq("unsaved")
        expect(row(payload, "app.worktree-wip")["blockers"].map { |b| b["reason"] }).to eq(%w[unsaved dev_env])
      end

      it "warns about other locks a worktree holds without refusing" do
        drop_old
        hold_lock("deploy", login, 101)

        result, payload = kill_json

        expect(result).to eq({exit_code: 0})
        expect(payload["warnings"]).to eq(["app.worktree-login holds lock 'deploy'; it is released when its session ends"])
        expect(row(payload, "app.worktree-login")["locks"]).to eq(["deploy"])
      end
    end

    describe "--force" do
      it "overrides a missing checkout, killing it with missing_ok but not force" do
        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 0})
        old_call = kill_calls.find { |c| c[:project] == "app.worktree-old" }
        expect(old_call).to include(force: false, missing_ok: true)
        expect(kill_calls.find { |c| c[:project] == "app.worktree-login" }).to include(force: false, missing_ok: false)
        expect(row(payload, "app.worktree-old")).to include("outcome" => "removed", "forced" => true, "overridden_reason" => "missing")
        expect(row(payload, "app.worktree-login")).not_to include("forced")
      end

      it "overrides unknown, keeping Kill's re-check" do
        drop_old
        git_answers[login] = {unsaved: :unknown}

        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 0})
        expect(kill_calls.first).to include(force: false, missing_ok: false)
        expect(row(payload, "app.worktree-login")).to include("forced" => true, "overridden_reason" => "unknown")
      end

      it "reports an unknown member that git still can't check at removal as failed" do
        drop_old
        git_answers[login] = {unsaved: :unknown}
        kill_errors["app.worktree-login"] = Workspace::UnsavedWorkError.new("Could not check 'app.worktree-login'.\nmore", unsaved: :unknown)

        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 1})
        expect(payload["status"]).to eq("failed")
        expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "unknown", "message" => "Could not check 'app.worktree-login'.")
      end

      it "does not override unsaved work" do
        drop_old
        git_answers[login] = {unsaved: unsaved_hash}

        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 1})
        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "unsaved")
        expect(kill_calls).to be_empty
      end

      it "does not override a running dev env" do
        drop_old
        hold_lock("devenv", login, 101)

        result, payload = kill_json(force: true, discard_unsaved: true)

        expect(result).to eq({exit_code: 1})
        expect(row(payload, "app.worktree-login")).to include("outcome" => "refused", "reason" => "dev_env")
        expect(kill_calls).to be_empty
      end

      it "still refuses a missing member that runs the dev env" do
        hold_lock("devenv", old, 101)

        _, payload = kill_json(force: true)

        expect(row(payload, "app.worktree-old")["blockers"].map { |b| b["reason"] }).to eq(["dev_env"])
        expect(row(payload, "app.worktree-old")).not_to include("forced", "overridden_reason")
      end

      it "leaves forced off not_attempted rows when another member refuses" do
        add_wip
        git_answers[wip] = {unsaved: unsaved_hash}

        _, payload = kill_json(force: true)

        expect(row(payload, "app.worktree-old")["outcome"]).to eq("not_attempted")
        expect(row(payload, "app.worktree-old")).not_to include("forced", "overridden_reason")
      end
    end

    describe "--discard-unsaved" do
      before do
        add_wip
        git_answers[wip] = {unsaved: unsaved_hash}
      end

      it "passes force only for the members it covers" do
        result, payload = kill_json(force: true, discard_unsaved: true)

        expect(result).to eq({exit_code: 0})
        forced = kill_calls.to_h { |c| [c[:project], c[:force]] }
        expect(forced).to eq("app.worktree-login" => false, "app.worktree-old" => false, "app.worktree-wip" => true)
        expect(row(payload, "app.worktree-wip")).to include("outcome" => "removed", "forced" => true, "overridden_reason" => "unsaved")
      end

      it "does not override missing or unknown on its own" do
        _, payload = kill_json(discard_unsaved: true)

        expect(payload["status"]).to eq("refused")
        expect(outcomes(payload)).to include("app.worktree-old" => "refused", "app.worktree-wip" => "not_attempted")
      end

      it "shows the work it will discard in the plan" do
        drop_old
        input.string = "n\n"

        command.kill(name: "app", discard_unsaved: true)

        expect(output.string).to include("  remove  app.worktree-wip    #{wip}  (DISCARDING unsaved work: 2 changed file(s) and 1 unpushed commit(s) on wip)\n")
      end
    end

    context "when Kill's re-check finds new work during the run" do
      before do
        drop_old
        add_wip
        kill_errors["app.worktree-login"] = Workspace::UnsavedWorkError.new("'app.worktree-login' has unsaved work at x: 1 changed file(s).\nCommit/push", unsaved: {changed_files: 1, unpushed_commits: 0, branch: "login"})
      end

      it "marks that member failed, carries on with the rest and exits 3" do
        result, payload = kill_json

        expect(result).to eq({exit_code: 3})
        expect(kill_calls.map { |c| c[:project] }).to eq(%w[app.worktree-login app.worktree-wip])
        expect(payload["status"]).to eq("partial")
        expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "unsaved",
          "message" => "'app.worktree-login' has unsaved work at x: 1 changed file(s).")
        expect(row(payload, "app.worktree-wip")["outcome"]).to eq("removed")
        expect(payload["summary"]).to eq(kill_counts(removed: 1, failed: 1, kept: 1))
        expect(hook_calls).to eq([[:json, "app.worktree-wip", "post_kill"]])
      end

      it "names the failure in text" do
        command.kill(name: "app", yes: true)

        expect(output.string).to include("Removed 1 worktree(s)", "Failed to remove app.worktree-login: 'app.worktree-login' has unsaved work")
      end

      it "reports any other error as reason error" do
        kill_errors["app.worktree-login"] = Workspace::Error.new("Error removing worktree: locked")

        _, payload = kill_json

        expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "error", "message" => "Error removing worktree: locked")
        expect(row(payload, "app.worktree-login")).not_to include("worktree_removed")
      end

      [Errno::EACCES.new("/tmp/x"), IOError.new("closed stream")].each do |error|
        it "reports #{error.class} as failed for that member only and carries on" do
          kill_errors["app.worktree-login"] = error

          result, payload = kill_json

          expect(result).to eq({exit_code: 3})
          expect(payload["status"]).to eq("partial")
          expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "error", "message" => error.message)
          expect(row(payload, "app.worktree-wip")["outcome"]).to eq("removed")
        end
      end

      it "says when a failure came after the worktree was removed" do
        kill_errors.clear
        late_errors["app.worktree-login"] = Errno::EACCES.new("config")

        result, payload = kill_json

        expect(result).to eq({exit_code: 3})
        expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "error", "worktree_removed" => true,
          "message" => "Permission denied - config (its worktree is already removed)")
      end
    end

    context "with --dry-run" do
      it "reports the refusal and exits 1 without prompting or killing" do
        result, payload = kill_json(dry_run: true, yes: false)

        expect(result).to eq({exit_code: 1})
        expect(payload).to include("dry_run" => true, "status" => "refused")
        expect(kill_calls).to be_empty
      end

      it "reports would_remove and exits 0 when the run would proceed" do
        result, payload = kill_json(dry_run: true, yes: false, force: true)

        expect(result).to eq({exit_code: 0})
        expect(payload).to include("dry_run" => true, "status" => "dry_run")
        expect(outcomes(payload)).to eq("app" => "kept", "app.worktree-login" => "would_remove", "app.worktree-old" => "would_remove")
        expect(row(payload, "app.worktree-old")).to include("forced" => true, "overridden_reason" => "missing")
        expect(payload["summary"]).to eq(kill_counts(would_remove: 2, kept: 1))
        expect(kill_calls).to be_empty
        expect(hook_calls).to be_empty
      end

      it "prints the plan in text, without a prompt" do
        result = command.kill(name: "app", dry_run: true, force: true)

        expect(result).to eq({exit_code: 0})
        expect(output.string).to eq(<<~TEXT)
          Would remove 2 worktree(s) of project 'app':
            keep    app                 #{main}  (main checkout)
            remove  app.worktree-login  #{login}  (branch login)
            remove  app.worktree-old    #{old}  (checkout gone; removing its config and state)
        TEXT
      end

      it "says so in text when it would be refused" do
        expect(command.kill(name: "app", dry_run: true)).to eq({exit_code: 1})
        expect(output.string).to start_with("Would refuse to kill project 'app' (dry run):\n")
      end
    end

    context "when the project has no worktrees" do
      before do
        roots.delete("app.worktree-login")
        drop_old
      end

      it "says so and exits 0" do
        expect(command.kill(name: "app", yes: true)).to eq({exit_code: 0})
        expect(output.string).to eq("No worktrees in project 'app'.\n")
        expect(kill_calls).to be_empty
      end
    end

    context "when the caller runs inside one of the worktrees" do
      let(:own_session) { "app-worktree-login" }

      before { add_wip }

      it "kills its own worktree last, quietly, with the JSON written from inside its Kill block" do
        written_in_block = nil
        allow(json_hook_runner).to receive(:run).and_wrap_original do |original, project, event, **kw|
          original.call(project, event, **kw)
        end
        allow(kill_command).to receive(:call).and_wrap_original do |original, project, **kw, &block|
          original.call(project, **kw) do |p|
            block.call(p)
            written_in_block = output.string.dup if project == "app.worktree-login"
          end
        end

        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 0})
        expect(kill_calls.map { |c| c[:project] }).to eq(%w[app.worktree-old app.worktree-wip app.worktree-login])
        expect(kill_calls.last[:quiet]).to be(true)
        expect(kill_calls.last[:output_so_far]).to eq("")
        expect(JSON.parse(written_in_block)).to eq(payload)
        expect(payload["results"].last).to include("workspace" => "app.worktree-login", "outcome" => "removed")
        expect(output.string.lines.size).to eq(1)
      end

      it "writes the text summary from inside its Kill block, after the others ran" do
        written_in_block = nil
        allow(kill_command).to receive(:call).and_wrap_original do |original, project, **kw, &block|
          original.call(project, **kw) do |p|
            block.call(p)
            written_in_block = output.string.dup if project == "app.worktree-login"
          end
        end

        command.kill(name: "app", yes: true, force: true)

        expect(written_in_block).to eq("Removed 3 worktree(s) of project 'app'.\nKept the main checkout app.\n")
        expect(kill_calls.last[:quiet]).to be(true)
      end

      it "writes the result after its own kill when that fails before the block" do
        kill_errors["app.worktree-login"] = Workspace::Error.new("Error removing worktree: busy")

        result, payload = kill_json(force: true)

        expect(result).to eq({exit_code: 3})
        expect(row(payload, "app.worktree-login")).to include("outcome" => "failed", "reason" => "error")
      end

      it "keeps a single JSON document when its kill fails after the result was written" do
        late_errors["app.worktree-login"] = Workspace::Error.new("could not remove config")

        result = command.kill(name: "app", json: true, yes: true, force: true)

        expect(result).to eq({exit_code: 0})
        expect(JSON.parse(output.string)["status"]).to eq("ok")
        expect(error_output.string).to include("error after the result was written: could not remove config")
      end
    end

    context "when the main checkout is the caller's own session" do
      let(:own_session) { "app" }

      it "never kills it" do
        drop_old

        _, payload = kill_json

        expect(kill_calls.map { |c| c[:project] }).to eq(["app.worktree-login"])
        expect(row(payload, "app")["outcome"]).to eq("kept")
      end
    end

    context "with a bare repository" do
      it "treats every configured member as a worktree" do
        bare = File.join(@root, "bare.git")
        FileUtils.mkdir_p(bare)
        roots.clear
        %w[a b].each do |n|
          wt_gitdir = File.join(bare, "worktrees", n)
          FileUtils.mkdir_p(wt_gitdir)
          File.write(File.join(wt_gitdir, "commondir"), "../..\n")
          path = FileUtils.mkdir_p(File.join(@root, "wt-#{n}")).first
          File.write(File.join(path, ".git"), "gitdir: #{wt_gitdir}\n")
          roots["bare.worktree-#{n}"] = path
        end

        result = command.kill(name: "bare.worktree-a", json: true, yes: true)

        expect(result).to eq({exit_code: 0})
        expect(kill_calls.map { |c| c[:project] }).to eq(%w[bare.worktree-a bare.worktree-b])
        expect(JSON.parse(output.string)["summary"]).to include("removed" => 2, "kept" => 0)
      end
    end

    context "with a name that doesn't resolve" do
      it "prints the JSON error contract and kills nothing" do
        expect(command.kill(name: "nope", json: true, yes: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /nope/)
        expect(kill_calls).to be_empty
      end

      it "raises in text mode" do
        expect { command.kill(name: "nope", yes: true) }.to raise_error(Workspace::Error, /nope/)
      end
    end

    context "when a post_kill hook raises mid-run" do
      it "reports that member as failed in a single JSON document" do
        drop_old
        allow(json_hook_runner).to receive(:run).and_raise(Workspace::Error, "hook broke")

        result = command.kill(name: "app", json: true, yes: true)

        expect(result).to eq({exit_code: 1})
        expect(output.string.lines.size).to eq(1)
        expect(row(JSON.parse(output.string), "app.worktree-login")).to include("outcome" => "failed", "worktree_removed" => true,
          "message" => "hook broke (its worktree is already removed)")
      end
    end

    context "when the kill collaborators aren't wired" do
      subject(:command) do
        described_class.new(catalog: catalog, stop_command: stop_command, state: state, tmux: tmux, hook_runner: hook_runner,
          output: output, error_output: error_output, own_pane: own_pane)
      end

      it "raises a clear error naming them" do
        expect { command.kill(name: "app", yes: true) }
          .to raise_error(Workspace::Error, "projects kill is not available: no kill_command, git, lock_namespace, lock_holder was wired")
      end

      it "prints it as the JSON error contract under json" do
        expect(command.kill(name: "app", yes: true, json: true)).to eq({exit_code: 1})
        expect(JSON.parse(output.string)["error"]).to start_with("projects kill is not available")
      end
    end
  end

  describe "list-projects" do
    it "is not touched: ProjectActions only adds the stop and kill leaves" do
      expect(described_class.instance_methods(false)).to contain_exactly(:stop, :kill)
    end
  end
end
