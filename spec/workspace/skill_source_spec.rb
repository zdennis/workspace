require "spec_helper"

RSpec.describe Workspace::SkillSource do
  include SkillsFixture

  def resolve(dir) = described_class.new(workspace_dir: dir).resolve

  it "gives a plain checkout's realpath" do
    link = File.join(@tmp, "link-to-checkout")
    File.symlink(checkout, link)

    source = resolve(link)

    expect(source.root).to eq("#{checkout}/lib/skills")
    expect(source.kind).to eq("checkout")
  end

  context "under Homebrew" do
    let(:keg) { File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0", "libexec") }

    before do
      build_checkout(keg)
      FileUtils.rm_rf(File.join(keg, ".git"))
    end

    it "gives the opt path, which brew upgrade re-points" do
      FileUtils.mkdir_p(File.join(@tmp, "prefix", "opt"))
      File.symlink(File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0"), File.join(@tmp, "prefix", "opt", "workspace"))
      FileUtils.mkdir_p(File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0"))

      source = resolve(keg)

      expect(source.root).to eq("#{@tmp}/prefix/opt/workspace/libexec/lib/skills")
      expect(source.kind).to eq("homebrew")
    end

    it "gives the same shape under a /usr/local style prefix" do
      prefix = File.join(@tmp, "usr", "local")
      keg2 = File.join(prefix, "Cellar", "workspace", "1.0.0", "libexec")
      build_checkout(keg2)
      FileUtils.mkdir_p(File.join(prefix, "opt"))
      File.symlink(File.join(prefix, "Cellar", "workspace", "1.0.0"), File.join(prefix, "opt", "workspace"))

      expect(resolve(keg2).root).to eq("#{prefix}/opt/workspace/libexec/lib/skills")
    end

    it "falls back to the realpath when there is no opt link" do
      expect(resolve(keg).root).to eq("#{keg}/lib/skills")
    end
  end

  context "from a linked worktree" do
    let(:main) { File.join(@tmp, "main") }
    let(:wt) { File.join(@tmp, "main-wt") }

    before do
      build_checkout(main)
      FileUtils.rm_rf(File.join(main, ".git"))
      git_in(@tmp, "init", "-q", main)
      git_in(main, "add", "-A")
      git_in(main, "commit", "-q", "-m", "x")
      git_in(main, "worktree", "add", "-q", "-b", "feature", wt)
    end

    it "refuses with skill_source_worktree, whatever HOME and PATH are" do
      path = ENV["PATH"]
      saved_home = ENV["HOME"]
      begin
        ENV["PATH"] = ""
        ENV["HOME"] = File.join(@tmp, "nowhere")

        expect { resolve(wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("skill_source_worktree")
          expect(e.details["path"]).to eq(File.realpath(wt))
        }
      ensure
        ENV["PATH"] = path
        ENV["HOME"] = saved_home
      end
    end

    it "accepts the main checkout the worktree belongs to" do
      expect(resolve(main).root).to eq("#{main}/lib/skills")
    end

    it "refuses a .git file it cannot read as a worktree's, rather than link into it" do
      File.write(File.join(wt, ".git"), "garbage")

      expect { resolve(wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("skill_source_worktree") }
    end
  end

  it "reports skills_source_missing when a skill directory is gone" do
    FileUtils.rm_rf("#{checkout}/lib/skills/workspace-inbox")

    expect { resolve(checkout) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("skills_source_missing")
      expect(e.details["missing"]).to eq(["workspace-inbox"])
    }
  end
end
