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

  subject(:command) do
    described_class.new(catalog: catalog, tmux: tmux, state: state, config: state_config, lock_namespace: lock_namespace,
      lock_holder: liveness, dev: dev, output: output, error_output: error_output, home: @root)
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
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "error" => "boom")
    end

    it "lets an unexpected failure raise without --json" do
      allow(catalog).to receive(:all).and_raise(NoMethodError, "boom")

      expect { command.list }.to raise_error(NoMethodError)
    end

    it "shows a full path when it is outside the home directory" do
      other_home = File.join(@root, "elsewhere")
      roots["app"] = make_main_checkout(File.join(@root, "app"))
      described_class.new(catalog: catalog, tmux: tmux, state: state, config: state_config, lock_namespace: lock_namespace,
        lock_holder: liveness, dev: dev, output: output, home: other_home).list

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

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "projects" => [])
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
          "schema_version" => 1,
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

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "projects" => [])
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
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "error" => "boom")
      end
    end

    it "raises a failure as an error when not in JSON mode" do
      allow(catalog).to receive(:all).and_raise(Workspace::Error, "boom")

      expect { command.list }.to raise_error(Workspace::Error, "boom")
      expect(output.string).to eq("")
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

        expect(command.show(name: "app", json: true)).to eq(exit_code: 0)

        expect(payload["schema_version"]).to eq(1)
        expect(payload["project"]).to eq("name" => "app", "id" => File.join(@root, "app", ".git"), "path" => File.join(@root, "app"), "vcs" => "git")
        expect(payload["members"].map { |m| m["workspace"] }).to eq(%w[app app.worktree-login app.worktree-old])
        expect(member("app")).to include("kind" => "main", "configured" => true, "exists" => true, "running" => true,
          "headless" => false, "open_asks" => 0, "pipeline" => {"entries" => 2})
        expect(member("app.worktree-login")).to include("kind" => "worktree", "running" => true, "headless" => true,
          "open_asks" => 2, "pipeline" => {"entries" => 0})
        expect(payload["summary"]).to eq("workspaces" => 3, "running" => 2, "open_asks" => 2, "pipeline_entries" => 2)
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

        command.show(name: "app")

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
        expect(payload).to eq("schema_version" => 1, "error" => "Unknown project 'nope'")
      end

      it "prints a JSON error when the working directory is in no project" do
        FileUtils.mkdir_p(File.join(@root, "stray"))

        expect(command.show(json: true, cwd: File.join(@root, "stray"))).to eq(exit_code: 1)
        expect(payload["error"]).to start_with("No project found for")
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

        expect(command.show(name: "app", json: true)).to eq(exit_code: 0)

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
          expect(command.show(name: "app", json: true)).to eq(exit_code: 0)

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

      expect(payload.keys).to eq(%w[schema_version project members locks dev summary])
    end
  end
end
