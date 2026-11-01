require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowProject do
  around do |example|
    Dir.mktmpdir("wf-project") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:detector) { instance_double(Workspace::ProjectDetector, detect_from_marker: nil, detect_from_roots: nil) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil, project_root_for: nil) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:start_ref) { instance_double(Workspace::StartRef) }
  let(:config) { Workspace::Config.new }
  let(:errors) { StringIO.new }
  subject(:resolver) do
    described_class.new(project_detector: detector, project_config: project_config, git: git, start_ref: start_ref, config: config, error_output: errors)
  end

  def checkout(name)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.join(path, ".git"))
    path
  end

  def project_of(name)
    Workspace::StartRef::Project.new(root: File.join(@dir, name), name: name, from_worktree: false)
  end

  describe "#for_directory from a checkout with no marker and no state entry" do
    it "names the project from the checkout, in the spelling of an existing config the user's config ties to it" do
      path = checkout("own")
      allow(start_ref).to receive(:project).with(path).and_return(project_of("own"))
      allow(project_config).to receive(:existing_name).with("own").and_return("Own")
      allow(project_config).to receive(:project_root_for).with("Own").and_return(path)

      expect(resolver.for_directory(path)).to have_attributes(project: "Own", registered: true)
    end

    it "takes the parent project when the checkout is a worktree of a project the config ties to it" do
      main = checkout("app")
      tree = File.join(@dir, "tree")
      FileUtils.mkdir_p([tree, File.join(main, ".git", "worktrees", "fix")])
      File.write(File.join(tree, ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "fix")}\n")
      File.write(File.join(main, ".git", "worktrees", "fix", "commondir"), "../..\n")
      allow(start_ref).to receive(:project).with(tree).and_return(project_of("app"))
      allow(project_config).to receive(:existing_name).with("app").and_return("app")
      allow(project_config).to receive(:project_root_for).with("app").and_return(main)

      expect(resolver.for_directory(tree).project).to eq("app")
    end

    it "is nil for a checkout whose directory name is a project the user's config puts in another repository" do
      mine = checkout("myapp")
      clone = checkout("evil/myapp")
      allow(start_ref).to receive(:project).with(clone).and_return(project_of("myapp"))
      allow(project_config).to receive(:existing_name).with("myapp").and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)

      expect(resolver.for_directory(clone)).to be_nil
      expect(errors.string).to eq("")
    end

    it "is nil for a checkout whose name has no config at all" do
      path = checkout("MixedCase")
      allow(start_ref).to receive(:project).with(path).and_return(project_of("MixedCase"))

      expect(resolver.for_directory(path)).to be_nil
    end

    it "is nil outside a git checkout" do
      expect(resolver.for_directory(@dir)).to be_nil
    end
  end

  def mark(path, text)
    File.write(File.join(path, ".workspace-project"), text)
    path
  end

  describe "#workspace" do
    let(:mine) { checkout("myapp") }

    it "gives the detector's workspace when there is no marker" do
      allow(detector).to receive(:detect).with(@dir).and_return("found")

      expect(resolver.workspace(@dir)).to eq("found")
    end

    it "gives the detector's workspace for a marker the user's config ties to the checkout" do
      mark(mine, "myapp")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(detector).to receive(:detect).with(mine).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)

      expect(resolver.workspace(mine)).to eq("myapp")
    end

    it "refuses, as not_in_workspace, a marker at the checkout's own root naming a workspace of another repository" do
      stranger = mark(checkout("stranger"), "myapp")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(detector).to receive(:detect).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)

      expect { resolver.workspace(stranger) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("not_in_workspace")
        expect(e.details).to include("marker" => "myapp")
      }
      FileUtils.mkdir_p(File.join(stranger, "lib"))
      expect { resolver.workspace(File.join(stranger, "lib")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end

    it "gives nothing, and does not refuse, for a marker found above the checkout's own root" do
      outer = mark(checkout("outer"), "outer-ws")
      inner = checkout("outer/inner")
      allow(detector).to receive(:detect_from_marker).and_return("outer-ws")
      allow(detector).to receive(:detect).and_return("outer-ws")
      allow(project_config).to receive(:project_root_for).with("outer-ws").and_return(outer)

      expect(resolver.workspace(inner)).to be_nil
      expect(resolver.workspace(File.join(inner, "sub"))).to be_nil
    end
  end

  describe "#for_directory with the active project roots" do
    let(:main) { checkout("app") }

    it "uses the project the state puts the directory in when the project's main config is at that repository" do
      allow(detector).to receive(:detect_from_roots).with(main).and_return("app.worktree-fix")
      allow(project_config).to receive(:project_root_for).with("app").and_return(main)

      expect(resolver.for_directory(main)).to have_attributes(project: "app", registered: true)
    end

    it "ignores the state's project when its main config is in another repository" do
      evil = checkout("evil")
      allow(detector).to receive(:detect_from_roots).with(evil).and_return("app.worktree-evd")
      allow(project_config).to receive(:project_root_for).with("app").and_return(main)
      allow(project_config).to receive(:project_root_for).with("app.worktree-evd").and_return(evil)
      allow(start_ref).to receive(:project).with(evil).and_return(project_of("evil"))

      expect(resolver.for_directory(evil)).to be_nil
    end
  end

  describe "#for_directory with a .workspace-project file" do
    let(:mine) { checkout("myapp") }
    let(:stranger) { checkout("stranger") }

    it "uses the name when the user's config puts that project at a checkout of the same repository" do
      mark(mine, "myapp")
      allow(detector).to receive(:detect_from_marker).with(mine).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)

      expect(resolver.for_directory(mine).project).to eq("myapp")
      expect(errors.string).to eq("")
    end

    it "uses it from a subdirectory, and from a linked worktree whose git common dir is the project's" do
      main = mine
      FileUtils.mkdir_p(File.join(main, "lib"))
      tree = File.join(@dir, "tree")
      FileUtils.mkdir_p([tree, File.join(main, ".git", "worktrees", "fix")])
      File.write(File.join(tree, ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "fix")}\n")
      File.write(File.join(main, ".git", "worktrees", "fix", "commondir"), "../..\n")
      allow(detector).to receive(:detect_from_marker).and_return("myapp.worktree-fix")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(main)

      expect(resolver.for_directory(File.join(main, "lib")).project).to eq("myapp")
      expect(resolver.for_directory(tree).project).to eq("myapp")
    end

    it "uses the name for the very same checkout even when git can't say where its common dir is" do
      broken = File.join(@dir, "broken")
      FileUtils.mkdir_p(broken)
      File.write(File.join(broken, ".git"), "gitdir: #{File.join(@dir, "missing")}\n")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(broken)

      expect(resolver.for_directory(broken).project).to eq("myapp")
      other = File.join(@dir, "other-broken")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, ".git"), "gitdir: #{File.join(@dir, "missing")}\n")
      mark(other, "myapp")
      expect(resolver.for_directory(other)).to be_nil
    end

    it "ignores a name whose project is another repository, and warns" do
      mark(stranger, "myapp")
      allow(detector).to receive(:detect_from_marker).with(stranger).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)

      expect(resolver.for_directory(stranger)).to be_nil
      expect(errors.string).to include("names \"myapp\"", "does not put that workspace at this checkout")
    end

    it "is not tied by a worktree config that start wrote for the other repository's checkout" do
      mark(stranger, "myapp.worktree-evd")
      allow(detector).to receive(:detect_from_marker).with(stranger).and_return("myapp.worktree-evd")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(mine)
      allow(project_config).to receive(:project_root_for).with("myapp.worktree-evd").and_return(stranger)

      allow(detector).to receive(:detect).with(stranger).and_return("myapp.worktree-evd")

      expect(resolver.for_directory(stranger)).to be_nil
      expect(errors.string).to eq("")
      expect(resolver.workspace(stranger)).to eq("myapp.worktree-evd")
    end

    it "targets a worktree by its own config even when the project's main config is gone, has no root or its root is gone" do
      mark(stranger, "px.worktree-px")
      allow(detector).to receive(:detect_from_marker).and_return("px.worktree-px")
      allow(detector).to receive(:detect).and_return("px.worktree-px")
      allow(project_config).to receive(:project_root_for).with("px.worktree-px").and_return(stranger)

      [nil, File.join(@dir, "gone")].each do |main_root|
        allow(project_config).to receive(:project_root_for).with("px").and_return(main_root)

        expect(resolver.workspace(stranger)).to eq("px.worktree-px")
        FileUtils.mkdir_p(File.join(stranger, "lib"))
        expect(resolver.workspace(File.join(stranger, "lib"))).to eq("px.worktree-px")
        expect(resolver.for_directory(stranger)).to be_nil
      end
      expect(errors.string).to eq("")
    end

    it "refuses a main checkout whose own config's root is gone" do
      mark(mine, "myapp")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(File.join(@dir, "gone"))

      expect { resolver.workspace(mine) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end

    it "ties a registered project that is not a git checkout by its root, for the root and below it" do
      plain = File.join(@dir, "plain")
      FileUtils.mkdir_p(File.join(plain, "lib"))
      elsewhere = File.join(@dir, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      allow(project_config).to receive(:existing_name).with("plain").and_return("plain")
      allow(project_config).to receive(:project_root_for).with("plain").and_return(plain)

      expect(resolver.for_directory(plain)).to have_attributes(project: "plain")
      allow(detector).to receive(:detect_from_roots).with(File.join(plain, "lib")).and_return("plain")
      expect(resolver.for_directory(File.join(plain, "lib")).project).to eq("plain")
      sibling = File.join(@dir, "plain2")
      FileUtils.mkdir_p(sibling)
      allow(detector).to receive(:detect_from_roots).with(sibling).and_return("plain")
      expect(resolver.for_directory(sibling)).to be_nil
      expect(resolver.for_directory(elsewhere)).to be_nil
      expect(resolver.for_directory(File.join(@dir, "plain-two"))).to be_nil
    end

    it "has no project when the name has no main config, only a worktree one" do
      mark(stranger, "myapp.worktree-evd")
      allow(detector).to receive(:detect_from_marker).and_return("myapp.worktree-evd")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(nil)
      allow(project_config).to receive(:project_root_for).with("myapp.worktree-evd").and_return(stranger)

      expect(resolver.for_directory(stranger)).to be_nil
    end

    it "ignores a name that has no config, and one that is not a directory name, without asking for its root" do
      mark(mine, "ghost")
      allow(detector).to receive(:detect_from_marker).and_return("ghost", "../myapp", nil)
      expect(project_config).to receive(:project_root_for).with("ghost").and_return(nil)
      expect(project_config).not_to receive(:project_root_for).with("../myapp")
      allow(start_ref).to receive(:project).with(mine).and_return(project_of("myapp"))

      expect(resolver.for_directory(mine)).to be_nil
      expect(resolver.for_directory(mine)).to be_nil
    end

    it "ignores a project whose root is gone or not a checkout" do
      mark(mine, "myapp")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_return(File.join(@dir, "gone"))

      expect(resolver.for_directory(mine)).to be_nil
    end

    it "answers no tie, and does not raise, when reading the config or the checkout fails" do
      mark(mine, "myapp")
      allow(detector).to receive(:detect_from_marker).and_return("myapp")
      allow(project_config).to receive(:project_root_for).with("myapp").and_raise(Errno::EACCES)

      expect(resolver.for_directory(mine)).to be_nil
      expect { resolver.workspace(mine) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end

    it "treats a marker above the checkout as the outer checkout's: no project, no warning, and the checkout's own name still counts" do
      outer = mark(checkout("outer"), "outer-ws")
      inner = checkout("outer/inner")
      allow(detector).to receive(:detect_from_marker).with(inner).and_return("outer-ws")
      allow(project_config).to receive(:project_root_for).with("outer-ws").and_return(outer)
      allow(project_config).to receive(:project_root_for).with("inner").and_return(inner)
      allow(project_config).to receive(:existing_name).with("inner").and_return("inner")
      allow(start_ref).to receive(:project).with(inner).and_return(project_of("inner"))

      expect(resolver.for_directory(inner).project).to eq("inner")
      expect(errors.string).to eq("")
    end
  end

  describe "a project name that can't be one directory" do
    it "warns when --name picks it, and still answers the project" do
      allow(project_config).to receive(:existing_name).with("-dash").and_return("-dash")

      expect(resolver.for_workspace("-dash").project).to eq("-dash")
      expect(errors.string).to include("\"-dash\" can't be a directory under #{config.workspace_projects_dir}/")
    end

    it "says nothing for a usable name" do
      allow(project_config).to receive(:existing_name).with("app").and_return("app")

      resolver.for_workspace("app")
      expect(errors.string).to eq("")
    end
  end

  describe "#for_workspace" do
    it "gives the parent project of the workspace as spelled on disk" do
      allow(project_config).to receive(:existing_name).with("APP.worktree-x").and_return("app.worktree-x")

      expect(resolver.for_workspace("APP.worktree-x")).to have_attributes(project: "app", registered: true)
    end

    it "refuses a workspace with no config as unknown_workspace" do
      expect { resolver.for_workspace("typo") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "typo")
      }
    end
  end
end
