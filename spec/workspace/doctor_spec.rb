require "stringio"

RSpec.describe Workspace::Doctor do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:hook_installer) { double("hook_installer") }
  let(:project_detector) { double("project_detector", detect: nil) }

  def build_doctor(**overrides)
    unless overrides.key?(:hook_installer)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)
      allow(hook_installer).to receive(:local_statusline_command).and_return(nil)
      allow(hook_installer).to receive(:settings_path_for).and_return("/codex-home/hooks.json")
      allow(hook_installer).to receive(:install).and_return(false)
    end

    described_class.new(
      config: config,
      state: state,
      hook_installer: hook_installer,
      project_detector: project_detector,
      output: output,
      project_settings: CLITestHelpers::FakeProjectSettings.new,
      launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new,
        platform: "arm64-darwin", env: {}, which: ->(_exe) { true }),
      **overrides
    )
  end

  it "runs without crashing and produces output" do
    doctor = build_doctor
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing in test environment
    end
    expect(output.string).to include("workspace doctor")
    expect(output.string.length).to be > 0
  end

  it "checks for required commands and templates" do
    doctor = build_doctor
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing
    end
    expect(output.string).to include("ruby")
    expect(output.string).to include("tmux")
    expect(output.string).to include("git")
  end

  describe "duplicate window ID detection" do
    it "reports no issues when window IDs are unique" do
      state["proj-a"] = {"iterm_window_id" => 100}
      state["proj-b"] = {"iterm_window_id" => 200}

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on missing dependencies
      end
      expect(output.string).to include("no duplicate window IDs")
    end

    it "detects duplicate window IDs" do
      state["growth-engine"] = {"iterm_window_id" => 318}
      state["growth-engine-migrations"] = {"iterm_window_id" => 318}

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # Expected
      end
      expect(output.string).to include("duplicate window IDs detected")
      expect(output.string).to include("window 318 claimed by: growth-engine, growth-engine-migrations")
    end
  end

  describe "session monitoring check" do
    it "skips when not inside a workspace project" do
      allow(project_detector).to receive(:detect).and_return(nil)

      doctor = build_doctor
      begin
        doctor.run
      rescue Workspace::Error
        # Expected if other dependencies are missing
      end
      expect(output.string).to include("session monitoring (not inside a workspace project, skipped)")
    end

    it "reports missing hooks and a stopped agent for a detected project" do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")

      doctor = build_doctor(which: ->(_exe) { false })
      expect { doctor.run }.to raise_error(Workspace::Error)
      expect(output.string).to include("no hook-capable agent detected")
      expect(output.string).to include("session monitor agent not running for myapp")
    end

    it "reports installed hooks and a running agent" do
      require "socket"
      tmpdir = Dir.mktmpdir
      socket_path = File.join(tmpdir, "workspace-myapp.sock")
      server = UNIXServer.new(socket_path)

      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return(socket_path)
      allow(hook_installer).to receive(:installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" })
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on missing dependencies unrelated to session monitoring
      end
      expect(output.string).to include("session monitoring hooks installed for myapp")
      expect(output.string).to include("session monitor agent running for myapp")
    ensure
      server&.close
      FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir)
    end
  end

  describe "statusLine check" do
    before do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
    end

    it "reports statusLine routed through workspace" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)
      allow(hook_installer).to receive(:local_statusline_command).and_return(nil)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer)
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on unrelated checks (e.g. agent not running)
      end
      expect(output.string).to include("✓  statusLine routed through workspace")
    end

    it "warns, without failing doctor, when statusLine isn't routed through workspace" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(hook_installer).to receive(:statusline_installed?).and_return(false)
      allow(hook_installer).to receive(:local_statusline_command).and_return(nil)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer)
      begin
        doctor.run
      rescue Workspace::Error
        # Unrelated failures (e.g. agent not running) still raise; the
        # statusLine warning itself must not be why.
      end
      expect(output.string).to include("statusLine not routed through workspace")
      expect(output.string).to include("workspace doctor --fix")
    end

    it "skips the check when no hook-capable agent is detected" do
      doctor = build_doctor(which: ->(_exe) { false })
      begin
        doctor.run
      rescue Workspace::Error
        # Expected
      end
      expect(output.string).not_to include("statusLine")
    end

    it "warns that settings.local.json shadows the statusLine instead of reporting it routed" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)
      allow(hook_installer).to receive(:local_statusline_command).and_return("bash ~/.claude/local-statusline.sh")
      allow(hook_installer).to receive(:local_settings_path_for).and_return("/tmp/.claude/settings.local.json")

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer)
      begin
        doctor.run
      rescue Workspace::Error
        # Unrelated failures fine; the expectation below is what's under test
      end
      expect(output.string).to include("statusLine shadowed by /tmp/.claude/settings.local.json")
      expect(output.string).to include("routes through \"bash ~/.claude/local-statusline.sh\" there")
      expect(output.string).not_to include("✓  statusLine routed through workspace")
    end
  end

  describe "Codex's user-level hooks" do
    before do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_running?).with("myapp").and_return(true)
    end

    def codex_row(result)
      result[:rows].find { |r| r[:id] == "hooks-codex" }
    end

    it "reports them installed, with how to trust them, and no project hooks row when only Codex is on PATH" do
      allow(hook_installer).to receive(:installed?).and_return(true)

      result = build_doctor(which: ->(exe) { exe == "codex" }).report(headless: true)

      expect(codex_row(result)).to include(status: "ok", message: "Codex hooks installed in /codex-home/hooks.json")
      expect(codex_row(result)[:hints].first).to include("/hooks")
      expect(result[:rows].map { |r| r[:id] }).not_to include("hooks")
    end

    it "reports them as turned off by config, not as a failure, when codex.hooks.install is false" do
      hooks_config = instance_double(Workspace::HooksConfig, install_user_hooks?: false)
      allow(hook_installer).to receive(:installed?).and_return(false)

      result = build_doctor(which: ->(exe) { exe == "codex" }, hooks_config: hooks_config).report(headless: true)

      expect(codex_row(result)).to include(status: "ok")
      expect(codex_row(result)[:message]).to include("turned off by config")
      expect(codex_row(result)[:message]).not_to include("earlier install")
      expect(codex_row(result)[:fix_command]).to be_nil
    end

    it "says so when hooks from an earlier install are still there, and names hooks uninstall" do
      hooks_config = instance_double(Workspace::HooksConfig, install_user_hooks?: false)
      allow(hook_installer).to receive(:installed?).and_return(true)

      result = build_doctor(which: ->(exe) { exe == "codex" }, hooks_config: hooks_config).report(headless: true)

      expect(codex_row(result)).to include(status: "ok")
      expect(codex_row(result)[:message]).to include("earlier install are still there")
      expect(codex_row(result)[:hints]).to include("workspace hooks uninstall --agent codex")
    end

    it "warns, without failing doctor, when they are missing, and names doctor --fix" do
      allow(hook_installer).to receive(:installed?).and_return(false)

      result = build_doctor(which: ->(exe) { exe == "codex" }).report(headless: true)

      expect(codex_row(result)).to include(status: "warn", fix_command: "workspace doctor --fix")
    end

    it "keeps the project hooks row about Claude Code alone when both are on PATH" do
      codex = Workspace::AgentProvider.find("codex")
      allow(hook_installer).to receive(:installed?) { |provider, *| provider != codex }

      result = build_doctor(which: ->(exe) { %w[claude codex].include?(exe) }).report(headless: true)

      expect(result[:rows].find { |r| r[:id] == "hooks" }).to include(status: "ok")
      expect(codex_row(result)).to include(status: "warn")
    end

    it "installs them on --fix, and says nothing about having nothing to fix" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      doctor = build_doctor(which: ->(exe) { exe == "codex" })
      expect(hook_installer).to receive(:install)
        .with(Workspace::AgentProvider.find("codex"), anything, "workspace session-event").and_return(true)

      doctor.report(headless: true, fix: true)

      expect(output.string).not_to include("nothing to fix")
    end

    it "reports a hook file it can't read as a failed --fix, and a warning row" do
      allow(hook_installer).to receive(:installed?).and_raise(Workspace::Error, "bad json")
      doctor = build_doctor(which: ->(exe) { exe == "codex" })
      allow(hook_installer).to receive(:install).and_raise(Workspace::Error, "bad json")

      result = doctor.report(headless: true, fix: true)

      expect(result[:rows].find { |r| r[:id] == "fix" }).to include(status: "fail", message: "--fix: Codex hooks not installed: bad json")
      expect(codex_row(result)).to include(status: "warn", message: "Codex hooks can't be checked: bad json")
    end
  end

  describe "agents read by scraping their own panes (Codex)" do
    before do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
      allow(hook_installer).to receive(:installed?).and_return(true)
    end

    it "reports Codex context as read from its own pane when only Codex is on PATH, without the Claude routing warning" do
      allow(config).to receive(:agent_running?).with("myapp").and_return(false)

      doctor = build_doctor(which: ->(exe) { exe == "codex" })
      begin
        doctor.run
      rescue Workspace::Error
        # The unrelated agent-not-running check fails here
      end

      expect(output.string).to include("✓  Codex context usage read from its own pane (no statusLine to route)")
      expect(output.string).not_to include("statusLine not routed")
    end

    it "counts no --fix failure when only Codex is on PATH, because Codex needs no routing" do
      allow(config).to receive(:agent_running?).with("myapp").and_return(true)

      messages = [false, true].map do |fix|
        build_doctor(which: ->(exe) { exe == "codex" }).run(fix: fix)
        nil
      rescue Workspace::Error => e
        e.message
      end

      expect(messages.first).to eq(messages.last)
      expect(output.string).to include("--fix: nothing to fix: Codex read context usage from their own panes (no statusLine to route)")
      expect(output.string).not_to include("--fix: no statusLine-capable agent")
    end

    describe "the pane diagnosis from the session monitor" do
      let(:snapshot_client) { double("snapshot_client") }

      before do
        allow(config).to receive(:agent_running?).with("myapp").and_return(true)
      end

      def pane(overrides = {})
        {"pane_id" => "%3", "index" => 2, "kind" => "codex"}.merge(overrides)
      end

      it "reports each Codex pane whose context was read" do
        allow(snapshot_client).to receive(:fetch).with("myapp")
          .and_return({"panes" => [pane("context_pct" => 37, "context_error" => nil)]})

        doctor = build_doctor(which: ->(exe) { exe == "codex" }, snapshot_client: snapshot_client)
        begin
          doctor.run
        rescue Workspace::Error
          # Unrelated checks may fail on this machine
        end

        expect(output.string).to include("✓  Codex context usage read from pane 2 (37% used)")
      end

      it "warns, without failing doctor, when a Codex pane's context can't be read, with the Codex fix hint" do
        readings = [
          {"context_pct" => 37, "context_error" => nil},
          {"context_pct" => nil, "context_error" => Workspace::ContextReasons::PATTERN_NO_MATCH}
        ]
        messages = readings.map do |reading|
          allow(snapshot_client).to receive(:fetch).with("myapp").and_return({"panes" => [pane.merge(reading)]})
          begin
            build_doctor(which: ->(exe) { exe == "codex" }, snapshot_client: snapshot_client).run
            nil
          rescue Workspace::Error => e
            e.message
          end
        end

        expect(messages.first).to eq(messages.last)
        expect(output.string).to include("⚠  Codex context usage unreadable on pane 2 (#{Workspace::ContextReasons::PATTERN_NO_MATCH})")
        expect(output.string).to include("context.patterns")
        expect(output.string).not_to include("route Claude's status line")
      end

      it "says nothing when the daemon can't be asked, and ignores panes of kinds it doesn't scrape" do
        allow(snapshot_client).to receive(:fetch).with("myapp")
          .and_raise(Workspace::AgentSnapshotClient::Unavailable.new("down", reason: "no daemon"))
        doctor = build_doctor(which: ->(exe) { exe == "codex" }, snapshot_client: snapshot_client)
        begin
          doctor.run
        rescue Workspace::Error
          # Expected
        end
        expect(output.string).not_to include("context usage read from pane")
        expect(output.string).not_to include("context usage unreadable")

        allow(snapshot_client).to receive(:fetch).with("myapp").and_return({"panes" => [
          pane("pane_id" => "%4", "index" => 3, "kind" => "claude", "context_pct" => nil,
            "context_error" => Workspace::ContextReasons::NO_READING),
          pane("pane_id" => "%5", "index" => 4, "kind" => "shell")
        ]})
        output.truncate(output.string.length)
        doctor = build_doctor(which: ->(exe) { exe == "codex" }, snapshot_client: snapshot_client)
        begin
          doctor.run
        rescue Workspace::Error
          # Expected
        end
        expect(output.string).not_to include("context usage read from pane")
        expect(output.string).not_to include("context usage unreadable")
      end

      it "is skipped without a snapshot client" do
        allow(config).to receive(:agent_running?).with("myapp").and_return(true)

        doctor = build_doctor(which: ->(exe) { exe == "codex" })
        begin
          doctor.run
        rescue Workspace::Error
          # Expected
        end

        expect(output.string).not_to include("Codex context usage read from pane")
      end
    end
  end

  describe "--fix" do
    it "installs the statusLine entry via HookInstaller before running checks" do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
      allow(hook_installer).to receive(:installed?).and_return(true)
      project_settings = CLITestHelpers::FakeProjectSettings.new

      expect(hook_installer).to receive(:install_statusline)
        .with(instance_of(Workspace::AgentProvider), Dir.pwd, command: "workspace statusline", project_settings: project_settings)
      allow(hook_installer).to receive(:statusline_installed?).and_return(true)
      allow(hook_installer).to receive(:local_statusline_command).and_return(nil)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, hook_installer: hook_installer, project_settings: project_settings)
      begin
        doctor.run(fix: true)
      rescue Workspace::Error
        # Unrelated failures fine; the expectation above is what's under test
      end
    end

    it "does nothing when not inside a workspace project" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect(hook_installer).not_to receive(:install_statusline)

      doctor = build_doctor
      begin
        doctor.run(fix: true)
      rescue Workspace::Error
        # Expected
      end
    end
  end

  describe "plan check" do
    let(:plan) { double("plan") }
    let(:plan_path) { "/notes/myapp/IMPLEMENTATION_PLAN.md" }

    def row(overrides = {})
      {"workspace" => "myapp", "project" => "myapp", "path" => plan_path, "exists" => true, "status" => "active", "state" => "working",
       "owner_pane" => "%19", "pane_state" => "working", "counts" => {"in_progress" => 0}}.merge(overrides)
    end

    def run_doctor(rows)
      allow(plan).to receive(:rows).with(all: true).and_return(rows)
      begin
        build_doctor(plan: plan, which: ->(_exe) { false }).run
      rescue Workspace::Error
        # Other checks fail here; only the plan lines matter
      end
    end

    before do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
    end

    it "warns on a paused plan whose owner pane is working" do
      run_doctor([row("status" => "paused", "state" => "paused")])

      expect(output.string).to include("⚠  plan for myapp is paused, but its owner pane %19 is working", "fix: tell that agent to stop, or run 'workspace plan start --name myapp'")
    end

    it "warns on an in-progress task in a workspace with no session" do
      run_doctor([row("state" => "stopped", "pane_state" => nil, "counts" => {"in_progress" => 1})])

      expect(output.string).to include("⚠  plan for myapp has a task in progress ([~]) but the workspace has no session",
        "fix: run 'workspace plan start --name myapp' to resume the plan", plan_path)
    end

    it "says nothing about a healthy plan, a paused one that is idle, or a stopped one with nothing in progress" do
      run_doctor([row, row("status" => "paused", "state" => "paused", "pane_state" => "idle"),
        row("state" => "stopped", "pane_state" => nil), row("exists" => false, "state" => "empty", "status" => "paused")])

      expect(output.string).not_to include("plan for")
    end

    it "does not count a plan warning as an issue" do
      allow(hook_installer).to receive(:installed?).and_return(true)
      allow(config).to receive(:agent_running?).and_return(true)
      messages = [[row("status" => "paused", "state" => "paused")], []].map do |rows|
        allow(plan).to receive(:rows).and_return(rows)
        begin
          build_doctor(plan: plan).run
          nil
        rescue Workspace::Error => e
          e.message
        end
      end

      expect(messages.first).to eq(messages.last)
    end

    it "only looks at the detected project's workspaces" do
      run_doctor([row("project" => "other", "workspace" => "other", "status" => "paused", "state" => "paused")])

      expect(output.string).not_to include("plan for")
    end

    it "skips the check when the plans can't be read, and when no project is detected" do
      allow(plan).to receive(:rows).and_raise(JSON::ParserError, "bad daemon reply")
      begin
        build_doctor(plan: plan, which: ->(_exe) { false }).run
      rescue Workspace::Error
        # expected
      end
      expect(output.string).not_to include("plan for")

      allow(project_detector).to receive(:detect).and_return(nil)
      begin
        build_doctor(plan: plan).run
      rescue Workspace::Error
        # expected
      end
      expect(plan).to have_received(:rows).once
    end

    it "skips the check when reading a plan raises a system error" do
      allow(plan).to receive(:rows).and_raise(Errno::EACCES)
      begin
        build_doctor(plan: plan, which: ->(_exe) { false }).run
      rescue Workspace::Error
        # expected
      end

      expect(output.string).not_to include("plan for")
    end
  end

  describe "pipeline config check" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:project_yml) { File.join(tmpdir, "myapp.yml") }

    before do
      FileUtils.touch(project_yml)
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
      allow(config).to receive(:project_config_path).with("myapp").and_return(project_yml)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reports an invalid pipeline config for the detected project" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp")
        .and_raise(Workspace::Error, "Invalid pipeline.panes[0].timeout in #{project_yml}: must be greater than 0")

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)

      expect { doctor.run }.to raise_error(Workspace::Error)
      expect(output.string).to include("pipeline config invalid for myapp")
      expect(output.string).to include("must be greater than 0")
    end

    it "says pipeline is deprecated for a project that configures one, without counting it as an issue" do
      pipeline_config = double("pipeline_config", literal_sentinel_warnings: [])
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return([{role: "researcher", pane_index: 0, timeout: nil}])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("⚠  pipeline is deprecated and will be removed in a later release; use `workspace workflow`")
      expect(output.string).not_to include("pipeline config invalid")
    end

    it "says nothing about pipeline for a project that configures none" do
      pipeline_config = double("pipeline_config", stages_for: nil, declared_but_empty?: false, literal_sentinel_warnings: [])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).not_to include("pipeline")
    end

    it "is silent when the pipeline config is valid" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return([{role: "researcher", pane_index: 0, timeout: nil}])
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp").and_return([])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config valid for myapp")
    end

    it "warns when the pipeline block has no panes" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return(nil)
      allow(pipeline_config).to receive(:declared_but_empty?).with("myapp").and_return(true)
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp").and_return([])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config for myapp has no panes")
    end

    it "warns about a stage that names the bare completion sentinel, without failing the check" do
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for).with("myapp").and_return([{role: "implementer", pane_index: 0, timeout: nil}])
      allow(pipeline_config).to receive(:literal_sentinel_warnings).with("myapp")
        .and_return(["myapp's pipeline stage implementer (pane 0) names the bare WORKSPACE_DONE: marker"])

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(output.string).to include("pipeline config valid for myapp")
      expect(output.string).to include("names the bare WORKSPACE_DONE: marker")
    end

    it "skips the check when the project has no pipeline config file" do
      FileUtils.rm_f(project_yml)
      pipeline_config = double("pipeline_config")
      allow(pipeline_config).to receive(:stages_for)

      doctor = build_doctor(which: ->(_exe) { false }, pipeline_config: pipeline_config)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected from the unrelated hooks/agent checks in this scenario
      end

      expect(pipeline_config).not_to have_received(:stages_for)
    end
  end

  describe "worktree lock hook check" do
    let(:git) { double("git") }
    let(:tmpdir) { Dir.mktmpdir }
    let(:worktree_path) { File.join(tmpdir, "worktree-a") }

    before do
      FileUtils.mkdir_p(worktree_path)
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "is skipped without a git dependency" do
      doctor = build_doctor(which: ->(exe) { exe == "claude" })
      allow(hook_installer).to receive(:installed?).and_return(true)

      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).not_to include("edit lock hooks")
    end

    it "reports every worktree with hooks installed" do
      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path])
      allow(hook_installer).to receive(:installed?).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("edit lock hooks installed in every worktree")
    end

    it "warns, without failing doctor, about a worktree missing hooks" do
      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path])
      allow(hook_installer).to receive(:installed?).with(anything, worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, Dir.pwd, anything).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error => e
        # The worktree warning alone must never be why this raises.
        expect(e.message).not_to match(/edit lock hooks/)
      end

      expect(output.string).to include("edit lock hooks missing in 1 worktree(s): worktree-a")
      expect(output.string).to include("fix: run 'workspace init' from each worktree listed above")
    end

    it "falls back to full paths when worktree basenames collide" do
      other_worktree_path = File.join(tmpdir, "nested", "worktree-a")
      FileUtils.mkdir_p(other_worktree_path)

      allow(git).to receive(:list_worktrees).with(repo: Dir.pwd).and_return([worktree_path, other_worktree_path])
      allow(hook_installer).to receive(:installed?).with(anything, worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, other_worktree_path, anything).and_return(false)
      allow(hook_installer).to receive(:installed?).with(anything, Dir.pwd, anything).and_return(true)

      doctor = build_doctor(which: ->(exe) { exe == "claude" }, git: git)
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("edit lock hooks missing in 2 worktree(s): #{worktree_path}, #{other_worktree_path}")
    end
  end

  describe "headless" do
    it "skips the iTerm2 and window-tool checks and says why" do
      doctor = build_doctor
      begin
        doctor.run(headless: true)
      rescue Workspace::Error
        # other dependencies may be missing on this machine
      end

      expect(output.string).to include("mode: headless (--headless)")
      expect(output.string).to include("⊘  iTerm2 (not needed headless, skipped)")
      expect(output.string).to include("⊘  window-tool (not needed headless, skipped)")
    end

    it "follows the launch mode when no flag is given" do
      doctor = build_doctor(launch_mode: CLITestHelpers.launch_mode(headless: true))
      begin
        doctor.run
      rescue Workspace::Error
      end

      expect(output.string).to include("mode: headless (not macOS)")
    end

    it "checks iTerm2 when not headless" do
      doctor = build_doctor
      begin
        doctor.run(headless: false)
      rescue Workspace::Error
      end

      expect(output.string).to include("mode: iTerm2 (--no-headless)")
      expect(output.string).not_to include("not needed headless")
    end
  end

  describe "#report and .document" do
    it "returns rows with stable ids and prints nothing" do
      state["proj-a"] = {"iterm_window_id" => 100}
      state["proj-b"] = {"iterm_window_id" => 100}

      result = build_doctor.report(headless: true)

      row = result[:rows].find { |r| r[:id] == "state-window-ids" }
      expect(row).to include(status: "fail", fix: "run 'workspace stop' then 'workspace launch' for affected projects")
      expect(result[:rows].map { |r| r[:id] }).to include("ruby", "git", "templates")
      expect(result[:rows].find { |r| r[:id] == "iterm2" }[:status]).to eq("skipped")
      expect(result[:issues]).to eq(result[:rows].count { |r| r[:status] == "fail" })
      expect(output.string).to eq("")
    end

    it "builds the JSON document, marking only fail rows not ok" do
      result = {mode: {"headless" => false, "reason" => "iTerm2"}, issues: 1, rows: [
        {id: "a", status: "warn", message: "m", fix: "do", fix_command: nil, project: "p"},
        {id: "b", status: "fail", message: "n", fix: nil, fix_command: nil, project: nil}
      ]}

      doc = described_class.document(result)

      expect(doc).to include("schema_version" => 1, "ok" => true, "healthy" => false)
      expect(doc["checks"].map { |c| c["ok"] }).to eq([true, false])
      expect(doc["checks"].first).to eq("id" => "a", "ok" => true, "status" => "warn", "message" => "m", "fix" => "do", "fix_command" => nil, "project" => "p")
      expect(doc["summary"]).to eq("ok" => 0, "warn" => 1, "fail" => 1, "skipped" => 0, "issues" => 1)
    end

    it "gives per-project rows their project and a fix command for hooks" do
      allow(project_detector).to receive(:detect).and_return("myapp")
      allow(hook_installer).to receive(:installed?).and_return(false)
      allow(config).to receive(:agent_socket_path).with("myapp").and_return("/tmp/does-not-exist-workspace-myapp.sock")

      result = build_doctor(which: ->(_exe) { true }).report(headless: true)

      hooks = result[:rows].find { |r| r[:id] == "hooks" }
      expect(hooks).to include(status: "fail", project: "myapp", fix_command: "workspace init")
    end

    it "reports a failed --fix as a fail row" do
      allow(project_detector).to receive(:detect).and_return(nil)

      result = build_doctor.report(headless: true, fix: true)

      expect(result[:rows].find { |r| r[:id] == "fix" }).to include(status: "fail")
      expect(result[:issues]).to eq(result[:rows].count { |r| r[:status] == "fail" })
    end
  end

  describe "mixed-case workspaces" do
    let(:name_migration) { double("name_migration") }

    def row(result) = result[:rows].find { |r| r[:id] == "mixed-case-workspaces" }

    it "adds an ok row when every name is lowercase" do
      allow(name_migration).to receive(:pending).and_return([])

      expect(row(build_doctor(name_migration: name_migration).report(headless: true))).to include(status: "ok")
    end

    it "warns, without failing, and says the next agentd start fixes it" do
      allow(name_migration).to receive(:pending).and_return([{"name" => "Notes", "workspace" => "notes", "remaining" => %w[tmuxinator_config state]}])

      result = build_doctor(name_migration: name_migration).report(headless: true)

      expect(row(result)).to include(status: "warn")
      expect(row(result)[:message]).to include("Notes (tmuxinator_config, state)")
      expect(row(result)[:fix]).to include("agentd start")
      expect(Workspace::Doctor.document(result)["checks"].map { |c| c["id"] }).to include("mixed-case-workspaces")
    end

    it "skips the check, not a false ok, when the names can't be read" do
      allow(name_migration).to receive(:pending).and_raise(Errno::EACCES, "state")

      expect(row(build_doctor(name_migration: name_migration).report(headless: true))).to include(status: "skipped")
    end

    it "adds no row without a name migration" do
      expect(row(build_doctor.report(headless: true))).to be_nil
    end
  end
end
