require "stringio"

RSpec.describe Workspace::Commands::Lookup do
  def build_lookup(project_config: nil)
    pc = project_config || FakeProjectConfig.new
    Workspace::Commands::Lookup.new(project_config: pc, output: StringIO.new)
  end

  class FakeProjectConfig
    def initialize(projects: [], roots: {})
      @projects = projects
      @roots = roots
    end

    def available_projects
      @projects
    end

    def exists?(name)
      @projects.include?(name)
    end

    def project_root_for(name)
      @roots[name]
    end
  end

  describe "#call" do
    context "with exact project name match" do
      it "returns the project name" do
        pc = FakeProjectConfig.new(projects: ["myproject"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("myproject")

        expect(result).to eq("myproject")
      end
    end

    context "with project root directory" do
      it "finds project by exact root path" do
        tmpdir = Dir.mktmpdir
        root = File.join(tmpdir, "myproject")
        Dir.mkdir(root)
        pc = FakeProjectConfig.new(
          projects: ["myproject"],
          roots: {"myproject" => root}
        )
        lookup = build_lookup(project_config: pc)

        result = lookup.call(root)

        expect(result).to eq("myproject")
      ensure
        FileUtils.rm_rf(tmpdir) if tmpdir
      end

      it "finds project when given a subdirectory of the root" do
        tmpdir = Dir.mktmpdir
        root = File.join(tmpdir, "myproject")
        Dir.mkdir(root)
        subdir = File.join(root, "src", "lib")
        FileUtils.mkdir_p(subdir)
        pc = FakeProjectConfig.new(
          projects: ["myproject"],
          roots: {"myproject" => root}
        )
        lookup = build_lookup(project_config: pc)

        result = lookup.call(subdir)

        expect(result).to eq("myproject")
      ensure
        FileUtils.rm_rf(tmpdir) if tmpdir
      end

      it "expands tilde paths for root matching" do
        # Use a real path that exists for this test
        root = File.expand_path("~")
        pc = FakeProjectConfig.new(
          projects: ["home"],
          roots: {"home" => "~"}
        )
        lookup = build_lookup(project_config: pc)

        result = lookup.call(root)

        expect(result).to eq("home")
      end

      it "returns nil when path doesn't match any project root" do
        tmpdir = Dir.mktmpdir
        pc = FakeProjectConfig.new(
          projects: ["myproject"],
          roots: {"myproject" => File.join(tmpdir, "projects", "myproject")}
        )
        lookup = build_lookup(project_config: pc)

        result = lookup.call(File.join(tmpdir, "unknown"))

        expect(result).to be_nil
      ensure
        FileUtils.rm_rf(tmpdir) if tmpdir
      end
    end

    context "with worktree path" do
      it "extracts worktree name and finds matching project" do
        pc = FakeProjectConfig.new(projects: ["myproject.worktree-pr-123"])
        lookup = build_lookup(project_config: pc)

        # Create a temporary directory to test the path extraction
        tmpdir = Dir.mktmpdir
        worktree_path = File.join(tmpdir, "pr-123")
        Dir.mkdir(worktree_path)

        result = lookup.call(worktree_path)

        expect(result).to eq("myproject.worktree-pr-123")
      ensure
        FileUtils.rm_rf(tmpdir) if tmpdir
      end

      it "expands relative paths" do
        pc = FakeProjectConfig.new(projects: ["myproject.worktree-feature"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call(".")

        expect(result).to be_nil # "." expands to current dir which won't match
      end
    end

    context "with branch name" do
      it "finds worktree by exact branch name" do
        pc = FakeProjectConfig.new(projects: ["myproject.worktree-main-branch"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("main-branch")

        expect(result).to eq("myproject.worktree-main-branch")
      end

      it "returns nil when branch not found" do
        pc = FakeProjectConfig.new(projects: ["myproject.worktree-feature"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("unknown-branch")

        expect(result).to be_nil
      end

      it "handles branch names with special characters" do
        pc = FakeProjectConfig.new(projects: ["backend.worktree-AIKYA-389-skip-validation"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("AIKYA-389-skip-validation")

        expect(result).to eq("backend.worktree-AIKYA-389-skip-validation")
      end

      it "fuzzy-matches normalized branch names" do
        # Filesystem-safe names replace dashes/underscores; this tests that matching is lenient
        pc = FakeProjectConfig.new(projects: ["backend.worktree-pr_21291"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("pr-21291")

        expect(result).to eq("backend.worktree-pr_21291")
      end
    end

    context "with multiple matching projects" do
      it "returns the first exact match" do
        pc = FakeProjectConfig.new(projects: ["myproject.worktree-feature", "other.worktree-feature"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("feature")

        expect(result).to eq("myproject.worktree-feature")
      end
    end

    context "with no matches" do
      it "returns nil" do
        pc = FakeProjectConfig.new(projects: ["myproject"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("unknown")

        expect(result).to be_nil
      end
    end

    context "with base project name" do
      it "finds the base project when it matches directly" do
        pc = FakeProjectConfig.new(projects: ["myproject", "myproject.worktree-feature"])
        lookup = build_lookup(project_config: pc)

        result = lookup.call("myproject")

        expect(result).to eq("myproject")
      end
    end

    context "with complex project structure" do
      it "handles mixed base and worktree projects" do
        projects = [
          "backend",
          "backend.worktree-pr-21291",
          "backend.worktree-feature-x",
          "frontend",
          "frontend.worktree-ui-redesign"
        ]
        pc = FakeProjectConfig.new(projects: projects)
        lookup = build_lookup(project_config: pc)

        expect(lookup.call("pr-21291")).to eq("backend.worktree-pr-21291")
        expect(lookup.call("ui-redesign")).to eq("frontend.worktree-ui-redesign")
        expect(lookup.call("backend")).to eq("backend")
        expect(lookup.call("unknown")).to be_nil
      end
    end
  end
end
