require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LibraryInstaller do
  around do |example|
    Dir.mktmpdir("library-installer") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:store) { Workspace::LibraryStore.new(dir: File.join(@dir, "library"), scope: "global") }
  let(:main) { File.join(@dir, "app") }
  let(:worktree) { File.join(main, ".worktrees", "feature") }
  let(:exclude) { File.join(main, ".git", "info", "exclude") }
  subject(:installer) { described_class.new(git: git) }

  def run_git(*args)
    _, err, status = Open3.capture3("git", "-c", "user.name=t", "-c", "user.email=t@example.com",
      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args)
    raise err unless status.success?
  end

  def entry(kind, name)
    store.find(kind, name).slice("ref", "kind", "name", "scope", "path")
  end

  before do
    FileUtils.mkdir_p(main)
    run_git("-C", main, "init", "--quiet")
    FileUtils.mkdir_p(File.join(main, ".claude", "agents"))
    File.write(File.join(main, ".claude", "agents", "tracked.md"), "the repo's own\n")
    FileUtils.mkdir_p(File.join(main, ".claude", "skills", "shipped"))
    File.write(File.join(main, ".claude", "skills", "shipped", "SKILL.md"), "the repo's skill\n")
    run_git("-C", main, "add", ".")
    run_git("-C", main, "commit", "--quiet", "-m", "init")
    run_git("-C", main, "worktree", "add", "--quiet", "-b", "feature", worktree)
    store.write("agent", "reviewer", "You review.\n")
    skill = File.join(@dir, "skill-src")
    FileUtils.mkdir_p(File.join(skill, "scripts"))
    File.write(File.join(skill, "SKILL.md"), "# Tests\n")
    File.write(File.join(skill, "scripts", "run.sh"), "echo\n")
    store.copy_tree("skill", "write-tests", skill)
  end

  def status
    Open3.capture2("git", "-C", worktree, "status", "--porcelain").first
  end

  it "copies an agent into .claude/agents and excludes it in the common dir, leaving the worktree clean" do
    result = installer.copy(entry("agent", "reviewer"), worktree: worktree)

    dest = File.join(worktree, ".claude", "agents", "reviewer.md")
    expect(result).to eq("ref" => "agent/reviewer", "scope" => "global", "source" => store.path_for("agent", "reviewer"),
      "path" => dest, "outcome" => "copied")
    expect(File.read(dest)).to eq("You review.\n")
    expect(File.read(exclude).lines.map(&:chomp)).to include("/.claude/agents/reviewer.md")
    expect(status).to eq("")
  end

  it "copies a skill directory into .claude/skills, every file, excluded as a directory" do
    result = installer.copy(entry("skill", "write-tests"), worktree: worktree)

    dest = File.join(worktree, ".claude", "skills", "write-tests")
    expect(result).to include("path" => dest, "outcome" => "copied")
    expect(File.read(File.join(dest, "scripts", "run.sh"))).to eq("echo\n")
    expect(File.read(exclude).lines.map(&:chomp)).to include("/.claude/skills/write-tests/")
    expect(status).to eq("")
  end

  it "leaves a tracked file alone when GIT_LITERAL_PATHSPECS is set in the environment" do
    store.write("agent", "tracked", "from the library\n")
    old = ENV["GIT_LITERAL_PATHSPECS"]
    ENV["GIT_LITERAL_PATHSPECS"] = "1"

    result = installer.copy(entry("agent", "tracked"), worktree: worktree)

    expect(result["outcome"]).to eq("skipped_tracked")
    expect(File.read(File.join(worktree, ".claude", "agents", "tracked.md"))).to eq("the repo's own\n")
    expect(status).to eq("")
  ensure
    ENV["GIT_LITERAL_PATHSPECS"] = old
  end

  it "copies the file a linked entry points to, not the link" do
    source = File.join(@dir, "Linked.md")
    File.write(source, "linked body\n")
    store.link("agent", "linked", source)

    installer.copy(entry("agent", "linked"), worktree: worktree)

    dest = File.join(worktree, ".claude", "agents", "linked.md")
    expect(File.symlink?(dest)).to be false
    expect(File.read(dest)).to eq("linked body\n")
  end

  it "is unchanged on a second copy, adds the exclude line once, and replaces a changed untracked copy" do
    installer.copy(entry("agent", "reviewer"), worktree: worktree)

    expect(installer.copy(entry("agent", "reviewer"), worktree: worktree)["outcome"]).to eq("unchanged")
    store.write("agent", "reviewer", "Changed.\n")
    expect(installer.copy(entry("agent", "reviewer"), worktree: worktree)["outcome"]).to eq("replaced")
    expect(File.read(File.join(worktree, ".claude", "agents", "reviewer.md"))).to eq("Changed.\n")
    expect(File.read(exclude).lines.count("/.claude/agents/reviewer.md\n")).to eq(1)
  end

  it "replaces a skill directory as a whole, dropping files the new one lacks" do
    installer.copy(entry("skill", "write-tests"), worktree: worktree)
    store.write("skill", "write-tests", "# Only SKILL.md\n")

    expect(installer.copy(entry("skill", "write-tests"), worktree: worktree)["outcome"]).to eq("replaced")
    expect(Dir.children(File.join(worktree, ".claude", "skills", "write-tests"))).to eq(["SKILL.md"])
  end

  it "never overwrites a file the repo tracks, and does not exclude it" do
    store.write("agent", "tracked", "library version\n")
    store.write("skill", "shipped", "library skill\n")

    expect(installer.copy(entry("agent", "tracked"), worktree: worktree)["outcome"]).to eq("skipped_tracked")
    expect(installer.copy(entry("skill", "shipped"), worktree: worktree)["outcome"]).to eq("skipped_tracked")
    expect(File.read(File.join(worktree, ".claude", "agents", "tracked.md"))).to eq("the repo's own\n")
    expect(File.read(File.join(worktree, ".claude", "skills", "shipped", "SKILL.md"))).to eq("the repo's skill\n")
    excluded = File.exist?(exclude) ? File.read(exclude) : ""
    expect(excluded).not_to include("tracked.md")
    expect(excluded).not_to include("shipped")
    expect(status).to eq("")
  end

  it "never writes through a symlinked .claude/skills, which hides tracked files from git" do
    shared = File.join(worktree, "skills")
    FileUtils.mkdir_p(File.join(shared, "write-tests"))
    File.write(File.join(shared, "write-tests", "SKILL.md"), "the repo's real skill\n")
    FileUtils.rm_rf(File.join(worktree, ".claude", "skills"))
    File.symlink("../skills", File.join(worktree, ".claude", "skills"))

    expect(installer.copy(entry("skill", "write-tests"), worktree: worktree)["outcome"]).to eq("skipped_linked")
    expect(File.read(File.join(shared, "write-tests", "SKILL.md"))).to eq("the repo's real skill\n")
    expect(File.exist?(exclude) ? File.read(exclude) : "").not_to include("write-tests")
  end

  it "never writes through a symlinked .claude, such as a shared dotfiles directory" do
    dotfiles = File.join(@dir, "dotfiles")
    FileUtils.mkdir_p(File.join(dotfiles, "agents"))
    File.write(File.join(dotfiles, "agents", "reviewer.md"), "mine\n")
    FileUtils.rm_rf(File.join(worktree, ".claude"))
    File.symlink(dotfiles, File.join(worktree, ".claude"))

    expect(installer.copy(entry("agent", "reviewer"), worktree: worktree)["outcome"]).to eq("skipped_linked")
    expect(File.read(File.join(dotfiles, "agents", "reviewer.md"))).to eq("mine\n")
  end

  it "replaces an untracked symlink at the destination, never its target" do
    target = File.join(@dir, "elsewhere.md")
    File.write(target, "You review.\n")
    dest = File.join(worktree, ".claude", "agents", "reviewer.md")
    File.symlink(target, dest)

    expect(installer.copy(entry("agent", "reviewer"), worktree: worktree)["outcome"]).to eq("replaced")
    expect(File.symlink?(dest)).to be false
    expect(File.read(target)).to eq("You review.\n")
  end

  it "never overwrites a tracked file whose name differs only in case" do
    FileUtils.mkdir_p(File.join(main, ".claude", "skills", "Capital"))
    File.write(File.join(main, ".claude", "agents", "Reviewer.md"), "tracked capital\n")
    File.write(File.join(main, ".claude", "skills", "Capital", "SKILL.md"), "tracked skill\n")
    run_git("-C", main, "add", ".")
    run_git("-C", main, "commit", "--quiet", "-m", "capitals")
    store.write("skill", "capital", "library skill\n")

    expect(installer.copy(entry("agent", "reviewer"), worktree: main)["outcome"]).to eq("skipped_tracked")
    expect(installer.copy(entry("skill", "capital"), worktree: main)["outcome"]).to eq("skipped_tracked")
    expect(File.read(File.join(main, ".claude", "agents", "Reviewer.md"))).to eq("tracked capital\n")
    expect(File.read(File.join(main, ".claude", "skills", "Capital", "SKILL.md"))).to eq("tracked skill\n")
  end

  it "puts back what was at the destination when the copy can't be moved into place" do
    dest = File.join(worktree, ".claude", "agents", "reviewer.md")
    File.write(dest, "untracked old\n")
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(/reviewer\.md\.tmp-/, dest).and_raise(Errno::EACCES)

    expect { installer.copy(entry("agent", "reviewer"), worktree: worktree) }.to raise_error(Errno::EACCES)
    expect(File.read(dest)).to eq("untracked old\n")
    expect(Dir.children(File.dirname(dest)).sort).to eq(["reviewer.md", "tracked.md"])
  end

  it "keeps a tracked file the worktree deleted" do
    store.write("agent", "tracked", "library version\n")
    File.delete(File.join(worktree, ".claude", "agents", "tracked.md"))

    expect(installer.copy(entry("agent", "tracked"), worktree: worktree)["outcome"]).to eq("skipped_tracked")
    expect(File.exist?(File.join(worktree, ".claude", "agents", "tracked.md"))).to be false
  end

  it "works in a main checkout too, excluding in its own .git" do
    installer.copy(entry("agent", "reviewer"), worktree: main)

    expect(File.read(exclude)).to include("/.claude/agents/reviewer.md\n")
    expect(Open3.capture2("git", "-C", main, "status", "--porcelain", "--", ".claude").first).to eq("")
  end

  it "appends the exclude line on a line of its own when the file lacks a final newline" do
    FileUtils.mkdir_p(File.dirname(exclude))
    File.write(exclude, "# mine")

    installer.copy(entry("agent", "reviewer"), worktree: worktree)

    expect(File.read(exclude)).to eq("# mine\n/.claude/agents/reviewer.md\n")
  end

  describe "#install" do
    it "installs, then reports unchanged, and writes nothing on a dry run" do
      dest = File.join(worktree, ".claude", "agents", "reviewer.md")

      expect(installer.install(entry("agent", "reviewer"), worktree: worktree, dry_run: true)).to eq("result" => "installed", "path" => dest)
      expect(File.exist?(dest)).to be(false)
      expect(installer.install(entry("agent", "reviewer"), worktree: worktree)).to eq("result" => "installed", "path" => dest)
      expect(installer.install(entry("agent", "reviewer"), worktree: worktree)).to eq("result" => "unchanged", "path" => dest)
      expect(File.read(exclude).lines.map(&:chomp)).to include("/.claude/agents/reviewer.md")
    end

    it "refuses different content with library_install_exists unless forced" do
      dest = File.join(worktree, ".claude", "agents", "reviewer.md")
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, "mine\n")

      expect { installer.install(entry("agent", "reviewer"), worktree: worktree) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_install_exists") }
      expect(File.read(dest)).to eq("mine\n")
      expect(installer.install(entry("agent", "reviewer"), worktree: worktree, force: true)["result"]).to eq("installed")
      expect(File.read(dest)).to eq("You review.\n")
    end

    it "refuses a tracked path with path_tracked" do
      store.write("agent", "tracked", "from the library\n")

      expect { installer.install(entry("agent", "tracked"), worktree: worktree, force: true) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("path_tracked") }
      expect(File.read(File.join(worktree, ".claude", "agents", "tracked.md"))).to eq("the repo's own\n")
    end

    it "refuses a symlinked kind directory with path_linked" do
      FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
      FileUtils.mkdir_p(File.join(worktree, ".claude"))
      FileUtils.rm_rf(File.join(worktree, ".claude", "agents"))
      File.symlink(File.join(@dir, "elsewhere"), File.join(worktree, ".claude", "agents"))

      expect { installer.install(entry("agent", "reviewer"), worktree: worktree) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("path_linked") }
      expect(Dir.children(File.join(@dir, "elsewhere"))).to be_empty
    end
  end

  describe "#uninstall" do
    it "removes the copy and keeps the exclude line, then reports absent" do
      installer.install(entry("skill", "write-tests"), worktree: worktree)
      dest = File.join(worktree, ".claude", "skills", "write-tests")

      expect(installer.uninstall("skill", "write-tests", worktree: worktree, dry_run: true)["result"]).to eq("removed")
      expect(File.directory?(dest)).to be(true)
      expect(installer.uninstall("skill", "write-tests", worktree: worktree)).to eq("result" => "removed", "path" => dest)
      expect(File.exist?(dest)).to be(false)
      expect(store.find("skill", "write-tests")).not_to be_nil
      expect(File.read(exclude)).to include("/.claude/skills/write-tests/")
      expect(installer.uninstall("skill", "write-tests", worktree: worktree)["result"]).to eq("absent")
    end

    it "never deletes a tracked path" do
      expect { installer.uninstall("agent", "tracked", worktree: worktree) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("path_tracked") }
      expect(File.exist?(File.join(worktree, ".claude", "agents", "tracked.md"))).to be(true)
    end

    it "refuses a symlinked .claude and a name that climbs out" do
      FileUtils.mkdir_p(File.join(@dir, "elsewhere", "skills", "write-tests"))
      FileUtils.rm_rf(File.join(worktree, ".claude"))
      File.symlink(File.join(@dir, "elsewhere"), File.join(worktree, ".claude"))

      expect { installer.uninstall("skill", "write-tests", worktree: worktree) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("path_linked") }
      expect(File.directory?(File.join(@dir, "elsewhere", "skills", "write-tests"))).to be(true)
      expect { installer.uninstall("skill", "../../x", worktree: main) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_path_outside") }
    end
  end
end
