require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Projects do
  include FakeCheckouts

  let(:output) { StringIO.new }
  let(:roots) { {} }
  let(:sessions) { [] }
  let(:tmux_error) { nil }

  let(:fake_config) do
    Class.new do
      def initialize(roots)
        @roots = roots
      end

      def available_projects = @roots.keys.sort

      def project_root_for(name) = @roots[name]
    end.new(roots)
  end

  # Session names differ from workspace names (dots become dashes), as with tmuxinator.
  let(:tmux) do
    error = tmux_error
    names = sessions
    Class.new do
      define_method(:sessions) { error ? raise(error) : names }
      define_method(:session_name_for) { |workspace| workspace.tr(".", "-") }
    end.new
  end

  let(:catalog) do
    Workspace::ProjectCatalog.new(project_config: fake_config, git: Workspace::Git.new(output: StringIO.new, input: StringIO.new))
  end

  let(:error_output) { StringIO.new }
  let(:headless_workspaces) { [] }
  let(:liveness) { FakeLockLiveness.new }
  let(:dev_payload) { {"schema_version" => 1, "running" => false, "holder" => nil, "ready" => nil, "queue" => []} }
  let(:dev_error) { nil }
  let(:dev_calls) { [] }
  let(:agent_facts) { {} }
  let(:agent_calls) { [] }

  # Answers per workspace from +agent_facts+; a workspace with no entry has no daemon.
  let(:agents) do
    facts = agent_facts
    calls = agent_calls
    Class.new do
      define_method(:facts) do |workspace, timeout: nil|
        calls << {workspace: workspace, timeout: timeout}
        facts.fetch(workspace) { {"available" => false, "reason" => "no_daemon"} }
      end
    end.new
  end

  let(:state) do
    names = headless_workspaces
    Class.new do
      define_method(:load) { self }
      define_method(:[]) { |name| names.include?(name) ? {"headless" => true} : {"unique_id" => "x"} }
    end.new
  end

  # Ask and pipeline state files live under <root>/state/<workspace>/.
  let(:state_config) do
    root = -> { @root }
    Class.new do
      define_method(:ask_state_path) { |name| File.join(root.call, "state", name, "asks.json") }
      define_method(:pipeline_state_path) { |name| File.join(root.call, "state", name, "pipeline.json") }
    end.new
  end

  let(:lock_namespace) do
    root = -> { @root }
    Class.new do
      define_method(:resolve) { |cwd:| {key: cwd, display: File.basename(cwd), dir: File.join(root.call, "locks")} }
    end.new
  end

  let(:dev) do
    payload = dev_payload
    error = dev_error
    calls = dev_calls
    Class.new do
      define_method(:status_payload) do |working_dir:|
        calls << working_dir
        raise error if error
        payload
      end
    end.new
  end

  # Answers per checkout path from +git_answers+ (unsaved_work, branch, upstream, ahead);
  # a path with no entry is clean on "main" with no upstream. A :raise entry blows up.
  let(:git_answers) { {} }
  let(:git_calls) { [] }
  let(:fake_git) do
    answers = git_answers
    calls = git_calls
    Class.new do
      define_method(:unsaved_work) do |path|
        calls << path
        answer = answers.fetch(path, {})
        raise answer[:raise] if answer[:raise]
        sleep answer[:sleep] if answer[:sleep]
        answer.fetch(:unsaved, nil)
      end
      define_method(:worktree_branch) { |path| answers.fetch(path, {}).fetch(:branch, "main") }
      define_method(:upstream_branch) { |path| answers.fetch(path, {}).fetch(:upstream, nil) }
      define_method(:commits_ahead_of_upstream) { |path| answers.fetch(path, {}).fetch(:ahead, 0) }
    end.new
  end

  let(:facts) do
    Workspace::ProjectFacts.new(tmux: tmux, state: state, config: state_config, lock_namespace: lock_namespace,
      lock_holder: liveness, dev: dev, agents: agents, git: fake_git, catalog: catalog, error_output: error_output)
  end

  subject(:command) do
    described_class.new(catalog: catalog, tmux: tmux, facts: facts, output: output, error_output: error_output, home: @root)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def build_app_with_worktrees
    main = make_main_checkout(File.join(@root, "app"))
    roots["app"] = main
    roots["app.worktree-login"] = make_linked_worktree(main, File.join(main, ".worktrees", "login"))
    roots["app.worktree-old"] = File.join(main, ".worktrees", "old")
    main
  end

  describe "#list" do
    it "says so when there are no projects" do
      command.list

      expect(output.string).to eq("No projects. Run 'workspace add' to create one.\n")
    end

    it "prints one row per project with workspace and running counts, abbreviating the home directory" do
      build_app_with_worktrees
      roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first
      sessions.replace(%w[app app-worktree-login])

      result = command.list

      expect(result).to eq(exit_code: 0)
      lines = output.string.lines.map(&:chomp)
      expect(lines[0]).to match(/\APROJECT\s+WORKSPACES\s+RUNNING\s+PATH\s+NOTE\z/)
      expect(lines[1]).to match(%r{\Aapp\s+3\s+2\s+~/app\z})
      expect(lines[2]).to match(%r{\Anotes\s+1\s+0\s+~/notes\s+\(no git\)\z})
    end

    it "counts a running session only for a workspace whose checkout exists" do
      build_app_with_worktrees
      sessions.replace(%w[app-worktree-old])

      command.list(json: true)

      expect(JSON.parse(output.string)["projects"].first["running"]).to eq(0)
    end

    it "marks projects whose checkout is gone" do
      roots["lost"] = File.join(@root, "lost")

      command.list

      expect(output.string).to match(/lost\s+1\s+0\s+~\/lost\s+\(checkout missing\)/)
    end

    it "marks projects that share a name, showing each path" do
      a = make_main_checkout(File.join(@root, "a", "app"))
      b = make_main_checkout(File.join(@root, "b", "app"))
      roots["wt-a"] = make_linked_worktree(a, File.join(@root, "wa"))
      roots["wt-b"] = make_linked_worktree(b, File.join(@root, "wb"))

      command.list

      lines = output.string.lines.map(&:chomp)
      expect(lines[1]).to match(%r{\Aapp\s+1\s+0\s+~/a/app\s+\(same name\)\z})
      expect(lines[2]).to match(%r{\Aapp\s+1\s+0\s+~/b/app\s+\(same name\)\z})
    end

    it "flags a broken checkout in the NOTE column" do
      broken = File.join(@root, "stale")
      FileUtils.mkdir_p(broken)
      File.write(File.join(broken, ".git"), "gitdir: #{File.join(@root, "gone", ".git", "worktrees", "stale")}\n")
      roots["stale"] = broken

      command.list

      expect(output.string.lines.last).to match(%r{\Astale\s+1\s+0\s+~/stale\s+\(broken checkout\)$})
    end

    it "prints a JSON error instead of raising when something unexpected fails under --json" do
      allow(catalog).to receive(:all).and_raise(NoMethodError, "boom")

      expect(command.list(json: true)).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "boom")
    end

    it "lets an unexpected failure raise without --json" do
      allow(catalog).to receive(:all).and_raise(NoMethodError, "boom")

      expect { command.list }.to raise_error(NoMethodError)
    end

    it "shows a full path when it is outside the home directory" do
      other_home = File.join(@root, "elsewhere")
      roots["app"] = make_main_checkout(File.join(@root, "app"))
      described_class.new(catalog: catalog, tmux: tmux, facts: facts, output: output, home: other_home).list

      expect(output.string).to include(File.join(@root, "app"))
    end

    context "with --running" do
      it "keeps only projects with a running workspace" do
        build_app_with_worktrees
        roots["quiet"] = make_main_checkout(File.join(@root, "quiet"))
        sessions.replace(%w[quiet])

        command.list(running_only: true)

        expect(output.string).to include("quiet")
        expect(output.string).not_to match(/^app\s/)
      end

      it "prints a plain message when nothing is running" do
        build_app_with_worktrees

        command.list(running_only: true)

        expect(output.string).to eq("No projects with a running workspace.\n")
      end

      it "prints an empty list in JSON" do
        build_app_with_worktrees

        command.list(running_only: true, json: true)

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "projects" => [])
      end
    end

    context "when tmux has no server or doesn't answer" do
      let(:tmux_error) { Workspace::Error.new("tmux did not answer") }

      it "reports nothing running instead of failing" do
        build_app_with_worktrees

        command.list

        expect(output.string).to match(/^app\s+3\s+0\s/)
      end
    end

    context "with --json" do
      it "prints the schema-versioned payload with full paths and the stable id" do
        main = build_app_with_worktrees
        sessions.replace(%w[app])

        command.list(json: true)

        expect(JSON.parse(output.string)).to eq(
          "schema_version" => 1, "ok" => true,
          "projects" => [{
            "name" => "app",
            "id" => File.join(main, ".git"),
            "path" => main,
            "vcs" => "git",
            "workspaces" => 3,
            "running" => 1
          }]
        )
      end

      it "prints an empty projects array with no projects" do
        command.list(json: true)

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "projects" => [])
      end

      it "reports vcs none for a non-git workspace and unknown for a missing checkout" do
        roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first
        roots["lost"] = File.join(@root, "lost")

        command.list(json: true)

        expect(JSON.parse(output.string)["projects"].to_h { |p| [p["name"], p["vcs"]] }).to eq("notes" => "none", "lost" => "unknown")
      end

      it "prints the error payload and returns exit code 1 when listing fails" do
        allow(catalog).to receive(:all).and_raise(Workspace::Error, "boom\nsecond line")

        result = command.list(json: true)

        expect(result).to eq(exit_code: 1)
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "boom")
      end
    end

    it "raises a failure as an error when not in JSON mode" do
      allow(catalog).to receive(:all).and_raise(Workspace::Error, "boom")

      expect { command.list }.to raise_error(Workspace::Error, "boom")
      expect(output.string).to eq("")
    end
  end

  describe "#members" do
    def lines = output.string.lines.map(&:chomp)

    def payload = JSON.parse(output.string)

    context "with a main checkout, a worktree and a worktree whose checkout is gone" do
      let!(:main) { build_app_with_worktrees }
      let(:login) { File.join(main, ".worktrees", "login") }
      let(:old) { File.join(main, ".worktrees", "old") }

      it "prints one workspace name per line, main first, including a missing checkout" do
        result = command.members(name: "app")

        expect(result).to eq(exit_code: 0)
        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
      end

      it "prints checkout paths with path: true" do
        command.members(name: "app", path: true)

        expect(lines).to eq([main, login, old])
      end

      it "prints the schema-versioned member list as JSON" do
        command.members(name: "app", json: true)

        expect(payload).to eq(
          "schema_version" => 1, "ok" => true,
          "project" => {"name" => "app", "id" => File.join(main, ".git"), "path" => main, "vcs" => "git"},
          "members" => [
            {"workspace" => "app", "path" => main, "kind" => "main", "configured" => true, "exists" => true},
            {"workspace" => "app.worktree-login", "path" => login, "kind" => "worktree", "configured" => true, "exists" => true},
            {"workspace" => "app.worktree-old", "path" => old, "kind" => "worktree", "configured" => true, "exists" => false}
          ]
        )
      end

      it "prints paths in JSON even with path: true" do
        command.members(name: "app", json: true, path: true)

        expect(payload["members"].map { |m| m["path"] }).to eq([main, login, old])
      end

      it "makes no git subprocess and no fact reads without all" do
        expect(Open3).not_to receive(:popen3)
        expect(Open3).not_to receive(:capture3)
        expect(Open3).not_to receive(:capture2e)
        expect(Open3).not_to receive(:capture2)

        command.members(name: "app")
        command.members(name: "app", json: true)

        expect(git_calls).to be_empty
      end

      it "does not ask tmux, state, locks or agents" do
        expect(tmux).not_to receive(:sessions)
        expect(agents).not_to receive(:facts)
        expect(dev).not_to receive(:status_payload)

        command.members(name: "app", json: true)
      end

      it "does not list worktrees without all" do
        expect_any_instance_of(Workspace::Git).not_to receive(:list_worktrees)

        command.members(name: "app")
      end

      it "adds nothing with --all when every worktree git lists has a config" do
        allow_any_instance_of(Workspace::Git).to receive(:list_worktrees).and_return([main, login])

        command.members(name: "app", all: true)

        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
      end
    end

    describe "resolving the project" do
      let!(:main) { build_app_with_worktrees }

      it "accepts a member workspace name" do
        command.members(name: "app.worktree-login")

        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
      end

      it "accepts a path to the project or to a member checkout" do
        command.members(name: main)
        expect(lines.first).to eq("app")

        output.truncate(0)
        output.rewind
        command.members(name: File.join(main, ".worktrees", "login"))
        expect(lines.first).to eq("app")
      end

      it "defaults to the project containing the working directory" do
        FileUtils.mkdir_p(File.join(main, "lib"))

        command.members(cwd: File.join(main, "lib"))

        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
      end

      it "prints nothing for a repository with no workspaces" do
        repo = make_main_checkout(File.join(@root, "fresh"))

        expect(command.members(cwd: repo)).to eq(exit_code: 0)
        expect(output.string).to eq("")
        expect(error_output.string).to eq("no workspaces in project fresh\n")
      end

      it "prints an empty member list as JSON for a repository with no workspaces" do
        repo = make_main_checkout(File.join(@root, "fresh"))

        command.members(cwd: repo, json: true)

        expect(payload["project"]["name"]).to eq("fresh")
        expect(payload["members"]).to eq([])
      end

      context "with two clones sharing a name" do
        let!(:a) { make_main_checkout(File.join(@root, "a", "shared")).tap { |p| roots["wt-a"] = make_linked_worktree(p, File.join(@root, "wa")) } }
        let!(:b) { make_main_checkout(File.join(@root, "b", "shared")).tap { |p| roots["wt-b"] = make_linked_worktree(p, File.join(@root, "wb")) } }

        it "raises a usage error listing the candidate paths" do
          expect { command.members(name: "shared") }.to raise_error(Workspace::UsageError) { |e|
            expect(e.message).to include(a, b)
          }
          expect(output.string).to eq("")
        end

        it "prints the same error as JSON with exit code 1" do
          expect(command.members(name: "shared", json: true)).to eq(exit_code: 1)
          expect(payload["error"]).to include("Ambiguous project 'shared'", a, b)
        end

        it "accepts a path to choose one" do
          command.members(name: b, path: true)

          expect(lines).to eq([File.join(@root, "wb")])
        end
      end

      it "raises for an unknown project" do
        expect { command.members(name: "nope") }.to raise_error(Workspace::Error, "Unknown project 'nope'")
        expect(output.string).to eq("")
      end

      it "prints an unknown project as a JSON error with exit code 1" do
        expect(command.members(name: "nope", json: true)).to eq(exit_code: 1)
        expect(payload).to eq("schema_version" => 1, "ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"}, "error" => "Unknown project 'nope'")
      end

      it "reports a directory in no project as an error" do
        FileUtils.mkdir_p(File.join(@root, "stray"))

        expect { command.members(cwd: File.join(@root, "stray")) }.to raise_error(Workspace::Error, /No project found/)
        expect(command.members(cwd: File.join(@root, "stray"), json: true)).to eq(exit_code: 1)
      end

      it "lets an unexpected failure raise without json and print a JSON error with it" do
        allow(catalog).to receive(:for_cwd).and_raise(NoMethodError, "boom")

        expect { command.members }.to raise_error(NoMethodError)
        expect(command.members(json: true)).to eq(exit_code: 1)
        expect(payload).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "boom")
      end
    end

    context "with a project whose checkouts are all gone" do
      before do
        roots["lost"] = File.join(@root, "lost")
        roots["lost.worktree-x"] = File.join(@root, "lost", ".worktrees", "x")
      end

      it "still lists the workspaces, marked as not existing" do
        command.members(name: "lost", json: true)

        expect(payload["members"].map { |m| [m["workspace"], m["exists"]] }).to eq([["lost", false], ["lost.worktree-x", false]])
      end

      it "makes no git subprocess for --all when the project is not a git repository on disk" do
        expect_any_instance_of(Workspace::Git).not_to receive(:list_worktrees)

        command.members(name: "lost", all: true)

        expect(lines).to eq(%w[lost lost.worktree-x])
      end
    end

    context "with a project that is not a git repository" do
      it "lists its one workspace" do
        roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first

        command.members(name: "notes", all: true)

        expect(lines).to eq(%w[notes])
      end
    end

    context "with --all and a worktree that has no workspace config" do
      let!(:main) { build_app_with_worktrees }
      let(:spike) { File.join(@root, "spike") }
      let(:gone) { File.join(@root, "gone") }

      before do
        allow_any_instance_of(Workspace::Git).to receive(:list_worktrees)
          .and_return([main, File.join(main, ".worktrees", "login"), File.join(main, ".worktrees", "old"), spike, gone])
        FileUtils.mkdir_p(spike)
      end

      it "omits them in name mode, with one stderr note counting them" do
        command.members(name: "app", all: true)

        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
        expect(error_output.string).to eq("2 unconfigured worktree(s) omitted; use --path or --json to include them\n")
      end

      it "prints no omission note with path: true or json" do
        command.members(name: "app", all: true, path: true)
        command.members(name: "app", all: true, json: true)

        expect(error_output.string).to eq("")
      end

      it "lists them by path with path: true" do
        command.members(name: "app", all: true, path: true)

        expect(lines.last(2)).to eq([gone, spike])
      end

      it "reports them in JSON as unconfigured, with a null workspace" do
        command.members(name: "app", all: true, json: true)

        expect(payload["members"].last(2)).to eq([
          {"workspace" => nil, "path" => gone, "kind" => "worktree", "configured" => false, "exists" => false},
          {"workspace" => nil, "path" => spike, "kind" => "worktree", "configured" => false, "exists" => true}
        ])
      end

      it "leaves them out without all" do
        command.members(name: "app")

        expect(lines).to eq(%w[app app.worktree-login app.worktree-old])
      end

      it "bounds the listing by timeout:" do
        allow_any_instance_of(Workspace::Git).to receive(:list_worktrees) { sleep 5 }

        expect { command.members(name: "app", all: true, timeout: 0.1) }.to raise_error(Workspace::Error, /Timed out listing/)
      end

      it "fails with a clear error when the listing times out" do
        stub_const("Workspace::ProjectFacts::DEFAULT_GIT_TIMEOUT", 0.1)
        allow_any_instance_of(Workspace::Git).to receive(:list_worktrees) { sleep 5 }

        expect { command.members(name: "app", all: true) }.to raise_error(Workspace::Error, /Timed out listing the worktrees of project 'app'/)
        expect(command.members(name: "app", all: true, json: true)).to eq(exit_code: 1)
        expect(payload["error"]).to include("Timed out listing")
      end
    end

    context "with a bare repository common dir and all: true" do
      let(:bare) { File.join(@root, "svc.git") }
      let(:wt) { File.join(@root, "svc-a") }

      def sh(*cmd, chdir:)
        out, status = Open3.capture2e(*cmd, chdir: chdir)
        raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      end

      before do
        seed = File.join(@root, "seed")
        FileUtils.mkdir_p(seed)
        sh("git", "init", "-q", "-b", "main", chdir: seed)
        sh("git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "i", chdir: seed)
        sh("git", "clone", "-q", "--bare", seed, bare, chdir: @root)
        sh("git", "worktree", "add", "-q", wt, "main", chdir: bare)
        roots["svc-a"] = wt
      end

      it "leaves the bare entry out of the members" do
        command.members(name: "svc-a", all: true, json: true)

        expect(payload["members"].map { |m| m["path"] }).to eq([wt])
        expect(payload["members"].map { |m| m["path"] }).not_to include(bare)
      end
    end

    context "with real git repositories" do
      let(:main) { File.join(@root, "real") }
      let(:spike) { File.join(main, ".worktrees", "spike") }

      def sh(*cmd, chdir:)
        out, status = Open3.capture2e(*cmd, chdir: chdir)
        raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      end

      before do
        FileUtils.mkdir_p(main)
        sh("git", "init", "-q", "-b", "main", chdir: main)
        sh("git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "initial", chdir: main)
        sh("git", "worktree", "add", "-q", "-b", "spike", spike, chdir: main)
        roots["real"] = main
      end

      it "lists the main checkout without --all and the unconfigured worktree with it" do
        command.members(name: "real", path: true)
        expect(lines).to eq([main])

        output.truncate(0)
        output.rewind
        command.members(name: "real", path: true, all: true)
        expect(lines).to eq([main, spike])
      end
    end
  end

  describe "#show" do
    let(:lock_dir) { File.join(@root, "locks") }

    def payload = JSON.parse(output.string)

    def member(workspace) = payload["members"].find { |m| m["workspace"] == workspace }

    def add_ask(workspace, question = "which?")
      Workspace::AskStore.new(path: state_config.ask_state_path(workspace)).add(question: question, default: "a")
    end

    def write_pipeline(workspace, content)
      path = state_config.pipeline_state_path(workspace)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def lock_store = Workspace::LockStore.new(dir: lock_dir, liveness: liveness)

    def hold_lock(name, worktree, pid, wait: false)
      lock_store.acquire(name, identity: {kind: "agent", pid: pid, started: "start-#{pid}", pane: "%#{pid}", worktree: worktree},
        waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
    end

    context "with a project of a main checkout and two worktrees, one missing" do
      before { build_app_with_worktrees }

      it "reports each workspace's local facts and a summary as JSON" do
        sessions.replace(%w[app app-worktree-login])
        headless_workspaces << "app.worktree-login"
        add_ask("app.worktree-login")
        add_ask("app.worktree-login", "other?")
        write_pipeline("app", JSON.generate("item-1" => {}, "item-2" => {}))

        expect(command.show(name: "app", json: true, git: false)).to eq(exit_code: 0)

        expect(payload["schema_version"]).to eq(1)
        expect(payload["project"]).to eq("name" => "app", "id" => File.join(@root, "app", ".git"), "path" => File.join(@root, "app"), "vcs" => "git")
        expect(payload["members"].map { |m| m["workspace"] }).to eq(%w[app app.worktree-login app.worktree-old])
        expect(member("app")).to include("kind" => "main", "configured" => true, "exists" => true, "running" => true,
          "headless" => false, "open_asks" => 0, "pipeline" => {"entries" => 2})
        expect(member("app.worktree-login")).to include("kind" => "worktree", "running" => true, "headless" => true,
          "open_asks" => 2, "pipeline" => {"entries" => 0})
        expect(payload["summary"]).to eq("workspaces" => 3, "running" => 2, "open_asks" => 2, "pipeline_entries" => 2, "unsaved_members" => nil, "waiting_agents" => 0, "agents_unavailable" => 2)
      end

      it "counts only open asks" do
        add_ask("app")
        store = Workspace::AskStore.new(path: state_config.ask_state_path("app"))
        store.answer(store.list.first["id"], answer: "yes")
        add_ask("app", "second")

        command.show(name: "app", json: true)

        expect(member("app")["open_asks"]).to eq(1)
      end

      it "shows a missing checkout without running, asks or pipeline facts" do
        sessions.replace(%w[app-worktree-old])
        add_ask("app.worktree-old")
        write_pipeline("app.worktree-old", JSON.generate("x" => {}))

        command.show(name: "app", json: true)

        expect(member("app.worktree-old")).to include("exists" => false, "running" => false, "open_asks" => nil, "pipeline" => nil)
        expect(payload["summary"]).to include("running" => 0, "open_asks" => 0, "pipeline_entries" => 0)
      end

      it "prints a table with the project line, run state, counts and a MISSING note" do
        sessions.replace(%w[app app-worktree-login])
        headless_workspaces << "app.worktree-login"
        add_ask("app")

        command.show(name: "app", agents: false, git: false)

        lines = output.string.lines.map(&:chomp)
        expect(lines[0]).to eq("Project  app   ~/app   (git)")
        expect(lines[2]).to match(/\AWORKSPACE\s+KIND\s+RUN\s+ASKS\s+PIPE\s+NOTE\z/)
        expect(lines[3]).to match(/\Aapp\s+main\s+yes\s+1\s+0\z/)
        expect(lines[4]).to match(/\Aapp.worktree-login\s+worktree\s+yes \(headless\)\s+0\s+0\z/)
        expect(lines[5]).to match(/\Aapp.worktree-old\s+worktree\s+-\s+-\s+-\s+MISSING \(checkout gone\)\z/)
        expect(output.string).to include("Locks (repo-wide)\n  none\n")
        expect(output.string).to include("Dev env   not running\n")
      end

      it "treats a running session as not running when its checkout is missing" do
        sessions.replace(%w[app-worktree-old])

        command.show(name: "app", json: true)

        expect(member("app.worktree-old")["running"]).to be(false)
      end

      it "reports no running tmux server as nothing running" do
        tmux_error_class = Workspace::Error
        allow(tmux).to receive(:sessions).and_raise(tmux_error_class, "no server")

        command.show(name: "app", json: true)

        expect(payload["summary"]["running"]).to eq(0)
      end

      it "reads a pipeline file that is not valid JSON as unknown and warns" do
        write_pipeline("app", "{nope")

        command.show(name: "app", json: true)

        expect(member("app")["pipeline"]).to be_nil
        expect(error_output.string).to include("could not read app's pipeline state")
      end

      it "reads a pipeline file that is not an object as empty" do
        write_pipeline("app", "[1,2]")

        command.show(name: "app", json: true)

        expect(member("app")["pipeline"]).to eq("entries" => 0)
      end
    end

    describe "resolving the project" do
      it "accepts a member workspace name" do
        build_app_with_worktrees

        command.show(name: "app.worktree-login", json: true)

        expect(payload["project"]["name"]).to eq("app")
      end

      it "defaults to the project containing the working directory" do
        main = build_app_with_worktrees
        FileUtils.mkdir_p(File.join(main, "lib"))

        command.show(json: true, cwd: File.join(main, "lib"))

        expect(payload["project"]["name"]).to eq("app")
      end

      it "shows an empty project for a repository with no workspaces" do
        repo = make_main_checkout(File.join(@root, "fresh"))

        command.show(cwd: repo)

        expect(output.string).to include("Project  fresh   ~/fresh   (git)")
        expect(output.string).to include("No workspaces are configured for this project.")
      end

      context "with two clones sharing a name" do
        let!(:a) { make_main_checkout(File.join(@root, "a", "app")).tap { |p| roots["wt-a"] = make_linked_worktree(p, File.join(@root, "wa")) } }
        let!(:b) { make_main_checkout(File.join(@root, "b", "app")).tap { |p| roots["wt-b"] = make_linked_worktree(p, File.join(@root, "wb")) } }

        it "raises a usage error listing the candidate paths" do
          expect { command.show(name: "app") }.to raise_error(Workspace::UsageError) { |e|
            expect(e.message).to include(a, b)
          }
        end

        it "prints the same error as JSON with exit code 1" do
          expect(command.show(name: "app", json: true)).to eq(exit_code: 1)
          expect(payload["schema_version"]).to eq(1)
          expect(payload["error"]).to include("Ambiguous project 'app'", a, b)
        end

        it "accepts a path to choose one" do
          command.show(name: b, json: true)

          expect(payload["project"]["path"]).to eq(b)
        end
      end

      it "raises for an unknown project" do
        expect { command.show(name: "nope") }.to raise_error(Workspace::Error, "Unknown project 'nope'")
        expect(output.string).to eq("")
      end

      it "prints an unknown project as a JSON error with exit code 1" do
        expect(command.show(name: "nope", json: true)).to eq(exit_code: 1)
        expect(payload).to eq("schema_version" => 1, "ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"}, "error" => "Unknown project 'nope'")
      end

      it "prints a JSON error when the working directory is in no project" do
        FileUtils.mkdir_p(File.join(@root, "stray"))

        expect(command.show(json: true, cwd: File.join(@root, "stray"))).to eq(exit_code: 1)
        expect(payload["error"]).to start_with("No project found for")
      end
    end

    context "with a project that is not a git repository" do
      it "looks up locks and the dev environment from the project directory" do
        notes = FileUtils.mkdir_p(File.join(@root, "notes")).first
        roots["notes"] = notes
        resolved = []
        allow(lock_namespace).to receive(:resolve) { |cwd:| resolved << cwd and {dir: lock_dir} }

        expect(command.show(name: "notes", json: true)).to eq(exit_code: 0)

        expect(payload["project"]).to include("name" => "notes", "path" => notes, "vcs" => "none")
        expect(resolved).to eq([notes])
        expect(dev_calls).to eq([notes])
        expect(payload["locks"]).to eq({})
        expect(payload["dev"]).to eq("running" => false, "ready" => nil, "holder_workspace" => nil)
        expect(payload["errors"]).to be_nil
      end
    end

    describe "locks" do
      let!(:main) { build_app_with_worktrees }
      let(:login) { File.join(main, ".worktrees", "login") }

      it "maps each holder and waiter to the member whose checkout contains its worktree" do
        hold_lock("devenv", login, 101)
        hold_lock("devenv", main, 102, wait: true)

        command.show(name: "app", json: true)

        expect(payload["locks"]["devenv"]).to eq(
          "holder" => {"workspace" => "app.worktree-login", "path" => login, "pid" => 101, "stale" => false},
          "queue" => [{"workspace" => "app", "path" => main, "pid" => 102, "stale" => false}]
        )
      end

      it "maps a holder in a subdirectory to its worktree and an outside path to nil" do
        FileUtils.mkdir_p(File.join(login, "lib"))
        hold_lock("devenv", File.join(login, "lib"), 101)
        hold_lock("deploy", File.join(@root, "elsewhere"), 102)

        command.show(name: "app", json: true)

        expect(payload["locks"]["devenv"]["holder"]["workspace"]).to eq("app.worktree-login")
        expect(payload["locks"]["deploy"]["holder"]["workspace"]).to be_nil
      end

      it "flags a stale holder" do
        hold_lock("deploy", main, 999)
        liveness.kill(999)

        command.show(name: "app", json: true)

        expect(payload["locks"]["deploy"]["holder"]).to include("pid" => 999, "stale" => true)
      end

      it "prints held, queued and stale locks in the text view" do
        hold_lock("devenv", login, 101)
        hold_lock("devenv", main, 102, wait: true)
        hold_lock("deploy", main, 999)
        liveness.kill(999)

        command.show(name: "app")

        expect(output.string).to include("Locks (repo-wide)\n")
        expect(output.string).to include("  devenv   held by app.worktree-login (pid 101)   queue: 1\n")
        expect(output.string).to include("  deploy   STALE holder app (pid 999)\n")
      end

      it "reads the lock store of the project's main checkout without writing to it" do
        resolved = []
        allow(lock_namespace).to receive(:resolve) { |cwd:| resolved << cwd and {dir: lock_dir} }

        command.show(name: "app", json: true)

        expect(resolved).to eq([main])
        expect(payload["locks"]).to eq({})
        expect(File.exist?(File.join(lock_dir, "locks.json"))).to be(false)
      end

      it "reports a corrupt lock store as an error entry, not a failure" do
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        expect(command.show(name: "app", json: true, git: false)).to eq(exit_code: 0)

        expect(payload["locks"]).to be_nil
        expect(payload["errors"]["locks"]).to include("corrupt")
        expect(payload["members"].size).to eq(3)
      end

      it "says the locks are unavailable in the text view when the store is corrupt" do
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        command.show(name: "app")

        expect(output.string).to match(/Locks \(repo-wide\)\n  unavailable \(.*corrupt/)
      end
    end

    describe "dev environment" do
      let!(:main) { build_app_with_worktrees }
      let(:login) { File.join(main, ".worktrees", "login") }

      it "reuses Dev#status_payload for the main checkout and reports it" do
        command.show(name: "app", json: true)

        expect(dev_calls).to eq([main])
        expect(payload["dev"]).to eq("running" => false, "ready" => nil, "holder_workspace" => nil)
      end

      context "while held" do
        let(:dev_payload) do
          {"schema_version" => 1, "running" => true, "ready" => true, "queue" => [],
           "holder" => {"worktree" => File.join(@root, "app", ".worktrees", "login"), "pid" => 5, "stale" => false}}
        end

        it "names the holding workspace and readiness" do
          command.show(name: "app", json: true)

          expect(payload["dev"]).to eq("running" => true, "ready" => true, "holder_workspace" => "app.worktree-login")
        end

        it "prints the holder and readiness in the text view" do
          command.show(name: "app")

          expect(output.string).to include("Dev env   running in app.worktree-login, ready\n")
        end
      end

      context "while held but not ready" do
        let(:dev_payload) do
          {"schema_version" => 1, "running" => true, "ready" => false, "queue" => [],
           "holder" => {"worktree" => File.join(@root, "app"), "pid" => 5, "stale" => false}}
        end

        it "says not ready" do
          command.show(name: "app")

          expect(output.string).to include("Dev env   running in app, not ready\n")
        end
      end

      context "with a stale holder" do
        let(:dev_payload) do
          {"schema_version" => 1, "running" => false, "ready" => nil, "queue" => [],
           "holder" => {"worktree" => File.join(@root, "app"), "pid" => 5, "stale" => true}}
        end

        it "is not running and names no holder" do
          command.show(name: "app", json: true)

          expect(payload["dev"]).to eq("running" => false, "ready" => nil, "holder_workspace" => nil)
        end
      end

      context "when the lock store can't be read" do
        let(:dev_error) { Workspace::Error.new("locks.json is corrupt") }

        it "reports an error entry instead of failing" do
          expect(command.show(name: "app", json: true, git: false)).to eq(exit_code: 0)

          expect(payload["dev"]).to be_nil
          expect(payload["errors"]).to eq("dev" => "locks.json is corrupt")
        end

        it "says the dev env is unavailable in the text view" do
          command.show(name: "app")

          expect(output.string).to include("Dev env   unavailable (locks.json is corrupt)\n")
        end
      end
    end

    describe "a project whose checkouts are all gone" do
      before { roots["lost"] = File.join(@root, "lost") }

      it "skips the lock store and the dev status" do
        command.show(name: "lost", json: true)

        expect(dev_calls).to eq([])
        expect(payload["locks"]).to eq({})
        expect(payload["dev"]).to be_nil
        expect(payload["project"]["vcs"]).to eq("unknown")
        expect(member("lost")).to include("exists" => false, "running" => false)
      end

      it "says the dev env is not available in the text view" do
        command.show(name: "lost")

        expect(output.string).to include("Dev env   not available\n")
        expect(output.string).to include("MISSING (checkout gone)")
      end
    end

    it "shows a non-git project as (no git)" do
      roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first

      command.show(name: "notes")

      expect(output.string.lines.first).to eq("Project  notes   ~/notes   (no git)\n")
    end

    it "prints no extra keys beyond the documented ones when nothing failed" do
      build_app_with_worktrees

      command.show(name: "app", json: true)

      expect(payload.keys).to eq(%w[schema_version ok project members locks dev summary])
    end

    describe "agents" do
      def pane(state, id: "%1") = {"pane_id" => id, "kind" => "claude", "state" => state, "idle_seconds" => 3, "agents" => []}

      def available(*states)
        panes = states.each_with_index.map { |state, i| pane(state, id: "%#{i}") }
        counts = %w[working idle waiting].to_h { |state| [state, states.count(state)] }
        {"available" => true, "panes" => panes, "counts" => counts}
      end

      before { build_app_with_worktrees }

      it "asks each running workspace's daemon, with the default 1 second timeout, and nobody else" do
        sessions.replace(%w[app app-worktree-login app-worktree-old])

        command.show(name: "app", json: true)

        expect(agent_calls).to eq([{workspace: "app", timeout: 1.0}, {workspace: "app.worktree-login", timeout: 1.0}])
      end

      it "passes --timeout through" do
        sessions.replace(%w[app])

        command.show(name: "app", json: true, timeout: 0.25)

        expect(agent_calls).to eq([{workspace: "app", timeout: 0.25}])
      end

      it "reports each running workspace's agent facts and sums waiting agents" do
        sessions.replace(%w[app app-worktree-login])
        agent_facts["app"] = available("idle")
        agent_facts["app.worktree-login"] = available("waiting", "waiting", "working")

        command.show(name: "app", json: true)

        expect(member("app")["agents"]).to eq(agent_facts["app"])
        expect(member("app.worktree-login")["agents"]["counts"]).to eq("working" => 1, "idle" => 0, "waiting" => 2)
        expect(payload["summary"]["waiting_agents"]).to eq(2)
        expect(payload["summary"]["agents_unavailable"]).to eq(0)
        expect(payload["errors"]).to be_nil
      end

      it "reports a workspace that isn't running as not running, without asking its daemon" do
        command.show(name: "app", json: true)

        expect(member("app")["agents"]).to eq("available" => false, "reason" => "not_running")
        expect(agent_calls).to be_empty
      end

      it "degrades to unavailable, with exit 0 and no errors entry, when a daemon is down or too slow" do
        sessions.replace(%w[app app-worktree-login])
        agent_facts["app.worktree-login"] = {"available" => false, "reason" => "timeout"}

        result = command.show(name: "app", json: true)

        expect(result).to eq(exit_code: 0)
        expect(member("app")["agents"]).to eq("available" => false, "reason" => "no_daemon")
        expect(member("app.worktree-login")["agents"]).to eq("available" => false, "reason" => "timeout")
        expect(payload["summary"]["agents_unavailable"]).to eq(2)
        expect(payload).not_to have_key("errors")
      end

      it "skips every daemon and nulls the facts with agents: false" do
        sessions.replace(%w[app])

        command.show(name: "app", json: true, agents: false)

        expect(agent_calls).to be_empty
        expect(member("app")["agents"]).to be_nil
        expect(payload["summary"]).to include("waiting_agents" => nil, "agents_unavailable" => nil)
      end

      context "in the text view" do
        it "adds an AGENTS column with waiting first and a note for unavailable daemons" do
          sessions.replace(%w[app app-worktree-login])
          agent_facts["app"] = available("idle", "working", "waiting")

          command.show(name: "app", git: false)

          lines = output.string.lines.map(&:chomp)
          expect(lines.find { |l| l.start_with?("WORKSPACE") }).to match(/\AWORKSPACE\s+KIND\s+RUN\s+AGENTS\s+ASKS\s+PIPE/)
          expect(lines.find { |l| l.start_with?("app ") }).to include("1 waiting, 1 working, 1 idle")
          expect(lines.find { |l| l.start_with?("app.worktree-login") }).to include("no daemon")
          expect(lines.find { |l| l.start_with?("app.worktree-old") }).to match(/\s-\s+-\s+-\s+MISSING/)
        end

        it "says none for a daemon with no panes and a dash for a stopped workspace" do
          sessions.replace(%w[app])
          agent_facts["app"] = available

          command.show(name: "app", git: false)

          expect(output.string.lines.find { |l| l.start_with?("app ") }).to include("none")
          expect(output.string.lines.find { |l| l.start_with?("app.worktree-login") }).to match(/worktree\s+-\s+-\s+0\s+0/)
        end

        it "drops the AGENTS column with agents: false" do
          command.show(name: "app", agents: false, git: false)

          expect(output.string).not_to include("AGENTS")
        end
      end
    end

    context "git facts, with fake git answers" do
      before { build_app_with_worktrees }

      let(:main) { File.join(@root, "app") }
      let(:login) { File.join(main, ".worktrees", "login") }
      let(:old) { File.join(main, ".worktrees", "old") }
      let(:clean_git) do
        {"available" => true, "branch" => "main", "changed_files" => 0, "ahead" => nil, "upstream" => nil, "unpushed_commits" => 0, "unsaved" => "no"}
      end

      it "reports a clean checkout" do
        command.show(name: "app", json: true)

        expect(member("app")["git"]).to eq(clean_git)
      end

      it "reports branch, changed files, upstream, ahead and unpushed commits for a dirty checkout" do
        git_answers[login] = {unsaved: {changed_files: 3, unpushed_commits: 2, branch: "projects"}, branch: "projects", upstream: "origin/projects", ahead: 2}

        command.show(name: "app", json: true)

        expect(member("app.worktree-login")["git"]).to eq("available" => true, "branch" => "projects", "changed_files" => 3, "ahead" => 2,
          "upstream" => "origin/projects", "unpushed_commits" => 2, "unsaved" => "yes")
      end

      it "reports a detached HEAD as a nil branch" do
        git_answers[main] = {branch: nil}

        command.show(name: "app", json: true)

        expect(member("app")["git"]).to include("branch" => nil, "unsaved" => "no")
      end

      it "reports git not being able to answer as unknown, never clean" do
        git_answers[login] = {unsaved: :unknown}

        command.show(name: "app", json: true)

        expect(member("app.worktree-login")["git"]).to include("available" => false, "reason" => "error", "unsaved" => "unknown", "changed_files" => nil)
      end

      it "reports a failing member as unknown with the error, leaving the other members alone" do
        git_answers[login] = {raise: Workspace::Error.new("boom")}

        command.show(name: "app", json: true)

        expect(member("app.worktree-login")["git"]).to include("available" => false, "reason" => "error", "detail" => "boom", "unsaved" => "unknown")
        expect(member("app")["git"]).to eq(clean_git)
      end

      it "reports a member that outlasts the timeout as unknown, without waiting for it" do
        git_answers[login] = {sleep: 5}
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        command.show(name: "app", json: true, timeout: 0.2)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(member("app.worktree-login")["git"]).to include("available" => false, "reason" => "timeout", "unsaved" => "unknown")
        expect(member("app")["git"]).to eq(clean_git)
      end

      it "reports a checkout that is gone as missing, never clean, without asking git about it" do
        command.show(name: "app", json: true)

        expect(member("app.worktree-old")["git"]).to include("available" => true, "branch" => nil, "unsaved" => "missing")
        expect(git_calls).not_to include(old)
      end

      it "reports a checkout that vanished after the catalog was built as missing" do
        catalog.all
        FileUtils.rm_rf(login)

        command.show(name: "app", json: true)

        expect(member("app.worktree-login")["git"]).to include("unsaved" => "missing")
      end

      it "counts yes and unknown, not missing, in the summary" do
        git_answers[main] = {unsaved: {changed_files: 1, unpushed_commits: 0, branch: "main"}}
        git_answers[login] = {unsaved: :unknown}

        command.show(name: "app", json: true)

        expect(payload["summary"]["unsaved_members"]).to eq(2)
      end

      it "leaves git nil, runs no git and nulls the summary count with --no-git" do
        command.show(name: "app", json: true, git: false)

        expect(payload["members"].map { |m| m["git"] }).to all(be_nil)
        expect(payload["summary"]["unsaved_members"]).to be_nil
        expect(git_calls).to be_empty
      end

      it "has a nil git key (not an absent one) for every member with --no-git" do
        command.show(name: "app", json: true, git: false)

        expect(payload["members"]).to all(have_key("git"))
      end

      it "stops a git read that outlasts the timeout, and reports the listing of worktrees timing out" do
        allow(catalog).to receive(:members).and_wrap_original do |original, *args, **kwargs|
          sleep 5 if kwargs[:include_unconfigured]
          original.call(*args, **kwargs)
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        command.show(name: "app", json: true, timeout: 0.2)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(payload["errors"]).to include("worktrees" => /timed out/)
        expect(payload["members"].map { |m| m["workspace"] }).to eq(%w[app app.worktree-login app.worktree-old])
      end

      it "gives a project whose checkout is gone no git facts" do
        roots["lost"] = File.join(@root, "lost")

        command.show(name: "lost", json: true)

        expect(payload["members"].first["git"]).to be_nil
        expect(payload["summary"]["unsaved_members"]).to be_nil
      end

      it "leaves git nil for a project that is not a git repository" do
        roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first

        command.show(name: "notes", json: true)

        expect(payload["members"].first["git"]).to be_nil
        expect(payload["summary"]["unsaved_members"]).to be_nil
        expect(git_calls).to be_empty
      end

      it "adds BRANCH and GIT columns to the text view" do
        git_answers[main] = {branch: "trunk"}
        git_answers[login] = {unsaved: {changed_files: 3, unpushed_commits: 2, branch: "x"}, branch: "login"}

        command.show(name: "app")

        lines = output.string.lines.map(&:chomp)
        expect(lines[2]).to match(/\AWORKSPACE\s+KIND\s+BRANCH\s+RUN\s+AGENTS\s+ASKS\s+PIPE\s+GIT\s+NOTE\z/)
        expect(lines[3]).to match(/\Aapp\s+main\s+trunk\s.*\sclean\z/)
        expect(lines[4]).to match(/\Aapp.worktree-login\s+worktree\s+login\s.*\s3 changed, 2 unpushed\z/)
        expect(lines[5]).to match(/\Aapp.worktree-old\s+worktree\s+-\s.*\s-\s+MISSING \(checkout gone\)\z/)
      end

      it "says unknown and timed out are treated as unsaved in the text view" do
        git_answers[main] = {unsaved: :unknown}
        git_answers[login] = {sleep: 5}

        command.show(name: "app", timeout: 0.2)

        expect(output.string).to match(/^app\s.*unknown \(treated as unsaved\)$/)
        expect(output.string).to match(/^app.worktree-login\s.*timed out \(treated as unsaved\)$/)
      end

      it "omits the git columns with --no-git" do
        command.show(name: "app", git: false)

        expect(output.string).not_to include("BRANCH")
        expect(output.string).not_to include("GIT")
      end

      it "prints a JSON error when listing the worktrees fails under --json" do
        allow(catalog).to receive(:members).and_raise(Workspace::Error, "no")

        expect(command.show(name: "app", json: true)).to eq(exit_code: 1)
        expect(JSON.parse(output.string)).to include("error" => "no")
      end
    end

    context "list --git, with fake git answers" do
      before { build_app_with_worktrees }

      let(:main) { File.join(@root, "app") }
      let(:login) { File.join(main, ".worktrees", "login") }

      def listed = JSON.parse(output.string)["projects"]

      it "adds an UNSAVED column counting checkouts with unsaved work" do
        git_answers[login] = {unsaved: {changed_files: 1, unpushed_commits: 0, branch: "login"}}
        roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first

        command.list(git: true)

        lines = output.string.lines.map(&:chomp)
        expect(lines[0]).to match(/\APROJECT\s+WORKSPACES\s+RUNNING\s+UNSAVED\s+PATH\s+NOTE\z/)
        expect(lines[1]).to match(%r{\Aapp\s+3\s+0\s+1 of 2 \(1 missing\)\s+~/app\z})
        expect(lines[2]).to match(%r{\Anotes\s+1\s+0\s+-\s+~/notes\s+\(no git\)\z})
      end

      it "shares one deadline across every project instead of one per project" do
        other = make_main_checkout(File.join(@root, "other"))
        roots["other"] = other
        git_answers[main] = {sleep: 5}
        git_answers[other] = {sleep: 5}
        git_answers[login] = {sleep: 5}
        allow(facts).to receive(:git_deadline).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        command.list(git: true)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
        expect(output.string).to match(/^app\s+3\s+0\s+unknown\s/)
        expect(output.string).to match(/^other\s+1\s+0\s+1 of 1 \(worktrees not listed, 1 unknown\)\s/)
      end

      it "leaves a gone checkout out of the total and names it" do
        git_answers[main] = {unsaved: {changed_files: 1, unpushed_commits: 0, branch: "main"}}

        command.list(git: true, json: true)

        expect(listed.first["unsaved"]).to eq("members" => 1, "unknown" => 0, "missing" => 1, "total" => 2, "incomplete" => false)
      end

      it "adds the unknown count when git couldn't answer for some checkouts" do
        git_answers[main] = {unsaved: :unknown}
        git_answers[login] = {unsaved: :unknown}

        command.list(git: true)

        expect(output.string).to match(/^app\s+3\s+0\s+unknown\s/)
      end

      it "shows unknown when git couldn't answer for any checkout" do
        roots.delete("app.worktree-login")
        roots.delete("app.worktree-old")
        git_answers[main] = {unsaved: :unknown}

        command.list(git: true)

        expect(output.string).to match(/^app\s+1\s+0\s+unknown\s/)
      end

      it "adds unsaved and unconfigured_worktrees to the JSON only with --git" do
        git_answers[login] = {unsaved: :unknown}
        roots["notes"] = FileUtils.mkdir_p(File.join(@root, "notes")).first

        command.list(git: true, json: true)

        expect(listed.map { |p| p["unsaved"] }).to eq([{"members" => 1, "unknown" => 1, "missing" => 1, "total" => 2, "incomplete" => false}, nil])
        expect(listed.map { |p| p["unconfigured_worktrees"] }).to eq([0, 0])
      end

      it "reports unconfigured worktrees as unknown and the counts as incomplete when listing times out" do
        allow(catalog).to receive(:members).and_wrap_original do |original, *args, **kwargs|
          sleep 5 if kwargs[:include_unconfigured]
          original.call(*args, **kwargs)
        end

        allow(facts).to receive(:git_deadline).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.2)
        command.list(git: true, json: true)

        expect(listed.first["unconfigured_worktrees"]).to be_nil
        expect(listed.first["unsaved"]).to include("incomplete" => true)

        output.truncate(0)
        output.rewind
        command.list(git: true)

        expect(output.string).to include("worktrees not listed").and include("unconfigured worktrees unknown")
        expect(output.string).not_to match(/\b0 unconfigured/)
      end

      it "runs no git without --git" do
        command.list(json: true)

        expect(listed.first).not_to have_key("unsaved")
        expect(git_calls).to be_empty
      end

      it "skips git for projects filtered out by --running" do
        sessions.replace(%w[app])

        command.list(git: true, running_only: true)

        expect(git_calls).not_to be_empty
        git_calls.clear
        sessions.clear
        command.list(git: true, running_only: true)
        expect(git_calls).to be_empty
      end
    end

    context "with real git repositories" do
      let(:fake_git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
      let(:main) { File.join(@root, "real") }
      let(:wt_a) { File.join(main, ".worktrees", "a") }
      let(:spike) { File.join(main, ".worktrees", "spike") }

      def sh(*cmd, chdir:)
        out, status = Open3.capture2e(*cmd, chdir: chdir)
        raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      end

      def commit(dir, message)
        sh("git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", message, chdir: dir)
      end

      before do
        FileUtils.mkdir_p(main)
        sh("git", "init", "-q", "-b", "main", chdir: main)
        File.write(File.join(main, "README.md"), "hi\n")
        sh("git", "add", "README.md", chdir: main)
        commit(main, "initial")
        sh("git", "worktree", "add", "-q", "-b", "a", wt_a, chdir: main)
        sh("git", "worktree", "add", "-q", "-b", "spike", spike, chdir: main)
        roots["real"] = main
        roots["real.worktree-a"] = wt_a
      end

      it "reports clean checkouts and lists a worktree with no workspace config" do
        command.show(name: "real", json: true)

        expect(payload["members"].map { |m| m["workspace"] }).to eq(["real", "real.worktree-a", nil])
        expect(member("real")["git"]).to include("branch" => "main", "changed_files" => 0, "unsaved" => "no", "available" => true)
        unconfigured = payload["members"].last
        expect(unconfigured).to include("path" => File.realpath(spike), "kind" => "worktree", "configured" => false, "exists" => true,
          "running" => false, "headless" => false, "open_asks" => nil, "pipeline" => nil)
        expect(unconfigured["git"]).to include("branch" => "spike", "unsaved" => "no")
        expect(payload["summary"]).to include("workspaces" => 2, "unsaved_members" => 0)
      end

      it "reports changed tracked files and unpushed commits, ignoring untracked files" do
        File.write(File.join(wt_a, "README.md"), "changed\n")
        File.write(File.join(wt_a, "untracked.txt"), "x")
        commit(spike, "unpushed")

        command.show(name: "real", json: true)

        expect(member("real.worktree-a")["git"]).to include("changed_files" => 1, "unsaved" => "yes")
        expect(payload["members"].last["git"]).to include("unpushed_commits" => 1, "unsaved" => "yes")
        expect(payload["summary"]["unsaved_members"]).to eq(2)
      end

      it "reports a deleted worktree directory as missing" do
        FileUtils.rm_rf(wt_a)

        command.show(name: "real", json: true)

        expect(member("real.worktree-a")).to include("exists" => false)
        expect(member("real.worktree-a")["git"]).to include("unsaved" => "missing")
      end

      it "leaves the unconfigured worktree out with --no-git" do
        command.show(name: "real", json: true, git: false)

        expect(payload["members"].size).to eq(2)
      end

      it "prints the unconfigured worktree as (no config) in the text view" do
        command.show(name: "real")

        expect(output.string).to match(/^\(no config\)\s+worktree\s+spike\s+-\s+-\s+-\s+-\s+clean$/)
      end

      it "counts unconfigured worktrees in list --git and says how many there are" do
        File.write(File.join(wt_a, "README.md"), "changed\n")

        command.list(git: true)

        expect(output.string).to match(%r{^real\s+2\s+0\s+1 of 3\s+~/real\s+\(1 unconfigured worktree\)$})
      end
    end
  end
end
