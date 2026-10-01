require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::ProjectCatalog do
  include FakeCheckouts

  # Stands in for ProjectConfig: workspace name => root, no tmuxinator files.
  let(:fake_config_class) do
    Class.new do
      def initialize(roots)
        @roots = roots
      end

      def available_projects = @roots.keys.sort

      def project_root_for(name) = @roots[name]
    end
  end

  let(:vcs) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:roots) { {} }
  subject(:catalog) { described_class.new(project_config: fake_config_class.new(roots), git: vcs) }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def project_named(name) = catalog.all.find { |project| project.name == name }

  describe "#all" do
    it "is empty with no workspaces" do
      expect(catalog.all).to eq([])
    end

    it "groups a main checkout with its worktrees under the main workspace's name" do
      main = make_main_checkout(File.join(@root, "app"))
      login = make_linked_worktree(main, File.join(main, ".worktrees", "login"))
      roots.merge!("app" => main, "app.worktree-login" => login)

      expect(catalog.all.size).to eq(1)
      project = catalog.all.first
      expect(project.name).to eq("app")
      expect(project.id).to eq(File.join(main, ".git"))
      expect(project.path).to eq(main)
      expect(project.vcs).to eq("git")
      expect(project.members.map(&:to_h)).to eq([
        {workspace: "app", path: main, kind: "main", configured: true, exists: true},
        {workspace: "app.worktree-login", path: login, kind: "worktree", configured: true, exists: true}
      ])
    end

    it "lists the main member first and the rest by workspace name" do
      main = make_main_checkout(File.join(@root, "app"))
      roots["app.worktree-b"] = make_linked_worktree(main, File.join(@root, "b"))
      roots["app.worktree-a"] = make_linked_worktree(main, File.join(@root, "a"))
      roots["app"] = main

      expect(catalog.all.first.members.map(&:workspace)).to eq(%w[app app.worktree-a app.worktree-b])
    end

    it "groups worktrees that live outside the main checkout, regardless of config names" do
      main = make_main_checkout(File.join(@root, "app"))
      roots["app"] = main
      roots["renamed-branch-workspace"] = make_linked_worktree(main, File.join(@root, "far", "away"))

      expect(catalog.all.size).to eq(1)
      expect(catalog.all.first.members.map(&:workspace)).to eq(%w[app renamed-branch-workspace])
    end

    it "groups a worktree under a project whose main checkout has no config, naming it from the path" do
      main = make_main_checkout(File.join(@root, "svc"))
      roots["svc.worktree-x"] = make_linked_worktree(main, File.join(main, ".worktrees", "x"))

      project = catalog.all.first
      expect(project.name).to eq("svc")
      expect(project.path).to eq(main)
      expect(project.members.map(&:kind)).to eq(["worktree"])
    end

    it "keys the project by the realpath of the git dir when the root is reached through a symlink" do
      main = make_main_checkout(File.join(@root, "app"))
      link = File.join(@root, "app-link")
      File.symlink(main, link)
      roots["app"] = main
      roots["app-alias"] = link

      expect(catalog.all.size).to eq(1)
      expect(catalog.all.first.members.map(&:path).uniq).to eq([main])
    end

    it "walks up from a root that is a subdirectory of a checkout" do
      main = make_main_checkout(File.join(@root, "mono"))
      FileUtils.mkdir_p(File.join(main, "services", "api"))
      roots["api"] = File.join(main, "services", "api")

      project = catalog.all.first
      expect(project.id).to eq(File.join(main, ".git"))
      expect(project.path).to eq(main)
      expect(project.name).to eq("mono")
    end

    it "makes a non-git workspace its own single-member project keyed by its realpath" do
      notes = File.join(@root, "notes")
      FileUtils.mkdir_p(notes)
      roots["notes"] = notes

      project = catalog.all.first
      expect(project.to_h.except(:members)).to eq(name: "notes", id: notes, path: notes, vcs: "none")
      expect(project.members.map(&:to_h)).to eq([{workspace: "notes", path: notes, kind: "main", configured: true, exists: true}])
    end

    it "treats a submodule as its own project, separate from the superproject" do
      main = make_main_checkout(File.join(@root, "super"))
      sub = make_submodule(main, File.join(main, "vendor", "lib"), "lib")
      roots.merge!("super" => main, "lib" => sub)

      expect(catalog.all.map(&:name)).to eq(%w[lib super])
      expect(project_named("lib").path).to eq(sub)
      expect(project_named("lib").id).to eq(File.join(main, ".git", "modules", "lib"))
    end

    it "names and paths a bare repository by its git dir, with only worktree members" do
      bare = File.join(@root, "app.git")
      FileUtils.mkdir_p(bare)
      wt_gitdir = File.join(bare, "worktrees", "main")
      FileUtils.mkdir_p(wt_gitdir)
      File.write(File.join(wt_gitdir, "commondir"), "../..\n")
      checkout = File.join(@root, "checkouts", "main")
      FileUtils.mkdir_p(checkout)
      File.write(File.join(checkout, ".git"), "gitdir: #{wt_gitdir}\n")
      roots["app.worktree-main"] = checkout

      project = catalog.all.first
      expect(project.name).to eq("app")
      expect(project.id).to eq(bare)
      expect(project.path).to eq(bare)
      expect(project.members.map(&:kind)).to eq(["worktree"])
    end

    context "when a checkout is gone" do
      it "attaches a worktree-named workspace to the project whose main workspace has that prefix" do
        main = make_main_checkout(File.join(@root, "app"))
        roots["app"] = main
        roots["app.worktree-old"] = File.join(main, ".worktrees", "old")

        project = catalog.all.first
        expect(catalog.all.size).to eq(1)
        expect(project.members.map(&:to_h)).to eq([
          {workspace: "app", path: main, kind: "main", configured: true, exists: true},
          {workspace: "app.worktree-old", path: File.join(main, ".worktrees", "old"), kind: "worktree", configured: true, exists: false}
        ])
      end

      it "attaches even when the main checkout is missing too" do
        roots["app"] = File.join(@root, "gone", "app")
        roots["app.worktree-old"] = File.join(@root, "gone", "app", ".worktrees", "old")

        project = catalog.all.first
        expect(catalog.all.size).to eq(1)
        expect(project.vcs).to eq("unknown")
        expect(project.members.map(&:exists)).to eq([false, false])
        expect(project.members.map(&:kind)).to eq(%w[main worktree])
      end

      it "makes a standalone missing workspace its own project" do
        roots["lost"] = File.join(@root, "lost")

        project = catalog.all.first
        expect(project.to_h.except(:members)).to eq(name: "lost", id: File.join(@root, "lost"), path: File.join(@root, "lost"), vcs: "unknown")
        expect(project.members.first.exists).to be(false)
      end

      it "makes an unmatched worktree-named workspace its own project named after its config" do
        roots["other.worktree-x"] = File.join(@root, "nowhere")

        project = catalog.all.first
        expect(project.name).to eq("other.worktree-x")
        expect(project.members.map(&:kind)).to eq(["worktree"])
      end

      it "treats a config with no root: as a missing checkout" do
        roots["rootless"] = nil

        project = catalog.all.first
        expect(project.members.first.exists).to be(false)
        expect(project.members.first.path).to eq("")
      end

      it "keeps two configs whose missing roots share a path as separate projects" do
        gone = File.join(@root, "gone")
        roots["one"] = gone
        roots["two"] = gone

        expect(catalog.all.map { |p| p.members.map(&:workspace) }).to eq([%w[one], %w[two]])
        expect(catalog.all.map(&:id).uniq.size).to eq(2)
      end

      context "when two projects share a name" do
        let(:main_a) { make_main_checkout(File.join(@root, "a", "app")) }
        let(:main_b) { make_main_checkout(File.join(@root, "b", "app")) }

        before do
          roots["wt-a"] = make_linked_worktree(main_a, File.join(@root, "wa"))
          roots["wt-b"] = make_linked_worktree(main_b, File.join(@root, "wb"))
        end

        it "attaches a missing worktree config to the group whose main checkout contains its old root" do
          roots["app.worktree-old"] = File.join(main_b, ".worktrees", "old")

          by_path = catalog.all.to_h { |p| [p.path, p.members.map(&:workspace)] }
          expect(by_path[main_a]).to eq(%w[wt-a])
          expect(by_path[main_b]).to eq(%w[app.worktree-old wt-b])
        end

        it "leaves it standalone when the groups can't be told apart" do
          roots["app.worktree-old"] = File.join(@root, "nowhere")

          expect(catalog.all.map(&:name)).to match_array(["app", "app", "app.worktree-old"])
          expect(catalog.all.find { |p| p.name == "app" && p.members.size > 1 }).to be_nil
        end
      end

      it "treats a non-string root: as no root" do
        roots["weird"] = {"path" => "/tmp"}
        roots["list"] = ["/tmp"]

        expect(catalog.all.map(&:id)).to eq(%w[workspace:list workspace:weird])
        expect(catalog.all.flat_map(&:members).map(&:path)).to eq(["", ""])
      end

      it "keeps unrelated configs with no root: as separate projects" do
        roots["one"] = nil
        roots["two"] = ""

        expect(catalog.all.map(&:id)).to eq(%w[workspace:one workspace:two])
      end
    end

    it "names a monorepo's project after the repository when only subdirectories have configs" do
      main = make_main_checkout(File.join(@root, "mono"))
      FileUtils.mkdir_p(File.join(main, "packages", "web"))
      roots["web"] = File.join(main, "packages", "web")

      project = catalog.all.first
      expect(project.name).to eq("mono")
      expect(project.path).to eq(main)
    end

    it "reports a checkout whose gitdir is missing as vcs broken, keyed by its path" do
      stale = File.join(@root, "stale")
      FileUtils.mkdir_p(stale)
      File.write(File.join(stale, ".git"), "gitdir: #{File.join(@root, "gone", ".git", "worktrees", "stale")}\n")
      roots["stale"] = stale

      project = catalog.all.first
      expect(project.to_h.except(:members)).to eq(name: "stale", id: stale, path: stale, vcs: "broken")
    end

    it "keeps two clones of the same repository name as separate projects" do
      a = make_main_checkout(File.join(@root, "a", "app"))
      b = make_main_checkout(File.join(@root, "b", "app"))
      roots["app"] = a
      roots["app-b"] = b

      expect(catalog.all.map(&:path)).to eq([a, b])
      expect(catalog.all.map(&:id).uniq.size).to eq(2)
    end

    it "sorts projects by name then path" do
      z = make_main_checkout(File.join(@root, "z", "same"))
      y = make_main_checkout(File.join(@root, "y", "same"))
      first = make_main_checkout(File.join(@root, "aaa"))
      roots.merge!("zeta" => z, "yota" => y, "alpha" => first)

      expect(catalog.all.map(&:path)).to eq([first, y, z].sort_by { |p| [File.basename(p), p] })
    end

    it "is memoized" do
      roots["a"] = File.join(@root, "a")
      expect(catalog.all).to equal(catalog.all)
    end
  end

  describe "#find" do
    let!(:main) { make_main_checkout(File.join(@root, "app")) }
    let!(:login) { make_linked_worktree(main, File.join(main, ".worktrees", "login")) }

    before { roots.merge!("app" => main, "app.worktree-login" => login) }

    it "finds a project by name" do
      expect(catalog.find("app").path).to eq(main)
    end

    it "finds a project by a member workspace name" do
      expect(catalog.find("app.worktree-login").path).to eq(main)
    end

    it "finds a project by its path, a member's path or its git dir" do
      expect(catalog.find(main).name).to eq("app")
      expect(catalog.find(login).name).to eq("app")
      expect(catalog.find(File.join(main, ".git")).name).to eq("app")
    end

    it "raises an unknown-project error for no match" do
      expect { catalog.find("nope") }.to raise_error(Workspace::Error, "Unknown project 'nope'")
    end

    it "raises an unknown-project error for a path that matches no project" do
      FileUtils.mkdir_p(File.join(@root, "stray"))

      expect { catalog.find(File.join(@root, "stray")) }.to raise_error(Workspace::Error, /Unknown project/)
    end

    context "with two clones sharing a name" do
      let!(:other) { make_main_checkout(File.join(@root, "elsewhere", "app")) }

      before { roots["other-wt"] = make_linked_worktree(other, File.join(@root, "wt", "other")) }

      it "raises a usage error listing each candidate path on one line" do
        expect { catalog.find("app") }.to raise_error(Workspace::UsageError) { |error|
          expect(error.message).to eq("Ambiguous project 'app': #{main}, #{other} (pass a path to choose one)")
        }
      end

      it "accepts a path to choose one" do
        expect(catalog.find(other).path).to eq(other)
      end

      it "still resolves a member workspace name that is unique" do
        expect(catalog.find("other-wt").path).to eq(other)
      end
    end

    it "stands in a member-less project for an unconfigured repository's path" do
      repo = make_main_checkout(File.join(@root, "fresh"))

      project = catalog.find(repo)

      expect(project.to_h).to include(name: "fresh", id: File.join(repo, ".git"), path: repo, vcs: "git", members: [])
    end
  end

  describe "#for_cwd" do
    let!(:main) { make_main_checkout(File.join(@root, "app")) }
    let!(:login) { make_linked_worktree(main, File.join(main, ".worktrees", "login")) }

    before { roots.merge!("app" => main, "app.worktree-login" => login) }

    it "finds the project from the main checkout, a worktree or a subdirectory" do
      FileUtils.mkdir_p(File.join(login, "lib", "deep"))

      expect(catalog.for_cwd(main).name).to eq("app")
      expect(catalog.for_cwd(login).name).to eq("app")
      expect(catalog.for_cwd(File.join(login, "lib", "deep")).name).to eq("app")
    end

    it "finds the project from a worktree that has no workspace config" do
      spike = make_linked_worktree(main, File.join(@root, "spike"))

      expect(catalog.for_cwd(spike).path).to eq(main)
    end

    it "picks the right clone when two share a name" do
      other = make_main_checkout(File.join(@root, "elsewhere", "app"))
      roots["other"] = other

      expect(catalog.for_cwd(other).path).to eq(other)
      expect(catalog.for_cwd(main).path).to eq(main)
    end

    it "returns a project with no members for a repository with no workspaces" do
      repo = make_main_checkout(File.join(@root, "fresh"))

      project = catalog.for_cwd(repo)

      expect(project.name).to eq("fresh")
      expect(project.id).to eq(File.join(repo, ".git"))
      expect(project.members).to eq([])
    end

    it "names an unconfigured bare repository after its directory minus .git" do
      bare = File.join(@root, "svc.git")
      FileUtils.mkdir_p(File.join(bare, "worktrees", "a"))
      FileUtils.mkdir_p(File.join(@root, "svc-a"))
      File.write(File.join(@root, "svc-a", ".git"), "gitdir: #{bare}/worktrees/a\n")
      File.write(File.join(bare, "worktrees", "a", "commondir"), "../..\n")

      project = catalog.for_cwd(File.join(@root, "svc-a"))

      expect(project.name).to eq("svc")
      expect(project.id).to eq(bare)
    end

    it "finds a non-git project from inside its directory" do
      notes = File.join(@root, "notes")
      FileUtils.mkdir_p(File.join(notes, "sub"))
      roots["notes"] = notes

      expect(catalog.for_cwd(File.join(notes, "sub")).name).to eq("notes")
    end

    it "raises when the directory is in no project" do
      FileUtils.mkdir_p(File.join(@root, "stray"))

      expect { catalog.for_cwd(File.join(@root, "stray")) }.to raise_error(Workspace::Error, /No project found for #{@root}\/stray/)
    end

    it "does not match a sibling directory that merely shares a prefix" do
      notes = File.join(@root, "notes")
      FileUtils.mkdir_p([notes, "#{notes}-extra"])
      roots["notes"] = notes

      expect { catalog.for_cwd("#{notes}-extra") }.to raise_error(Workspace::Error, /No project found/)
    end
  end

  describe "key assignment for configs with no usable root" do
    it "gives the shared missing path to the first config by name, whatever order they are listed in" do
      gone = File.join(@root, "gone")
      roots.merge!("b" => gone, "a" => gone)

      expect(catalog.all.map { |project| [project.name, project.id] }).to eq([["a", gone], ["b", "workspace:b"]])
    end
  end
end
