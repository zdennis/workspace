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

  subject(:command) { described_class.new(catalog: catalog, tmux: tmux, output: output, home: @root) }

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
      described_class.new(catalog: catalog, tmux: tmux, output: output, home: other_home).list

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
end
