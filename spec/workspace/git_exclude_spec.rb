require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"

RSpec.describe Workspace::GitExclude do
  around do |example|
    Dir.mktmpdir("git-exclude") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "app") }
  subject(:excludes) { described_class.new(git: Workspace::Git.new(output: StringIO.new, input: StringIO.new)) }

  def git(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args)
    raise out unless status.success?
    out
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-q")
    git("commit", "-q", "--allow-empty", "-m", "start")
  end

  it "adds its pattern to an exclude file holding bytes in another encoding, from a process with no UTF-8 locale, and only once" do
    file = File.join(repo, ".git", "info", "exclude")
    FileUtils.mkdir_p(File.dirname(file))
    File.binwrite(file, "caf\xE9/\n".b)

    without_utf8_locale do
      expect(excludes.add(repo, "/.workflow/")).to be true
      expect(excludes.add(repo, "/.workflow/")).to be true
    end

    expect(File.binread(file)).to eq("caf\xE9/\n/.workflow/\n".b)
  end

  it "hides a directory from `git status` without touching .gitignore" do
    FileUtils.mkdir_p(File.join(repo, ".workflow", "wr_1"))
    File.write(File.join(repo, ".workflow", "wr_1", "plan.md"), "plan\n")

    expect(excludes.add(repo, "/.workflow/")).to be true

    expect(git("status", "--porcelain")).to eq("")
    expect(File.exist?(File.join(repo, ".gitignore"))).to be false
  end

  it "lists a pattern once, however often it is added, and keeps what was there" do
    file = File.join(repo, ".git", "info", "exclude")
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "# mine\n*.log")

    2.times { excludes.add(repo, "/.workflow/") }

    expect(File.read(file)).to eq("# mine\n*.log\n/.workflow/\n")
  end

  it "writes the common dir's file for a linked worktree, which is the one git reads there" do
    linked = File.join(@dir, "app-feature")
    git("worktree", "add", "-q", "-b", "feature", linked)
    File.write(File.join(linked, "notes.md"), "x\n")
    FileUtils.mkdir_p(File.join(linked, ".workflow"))
    File.write(File.join(linked, ".workflow", "a.md"), "x\n")

    excludes.add(linked, "/.workflow/")

    expect(git("status", "--porcelain", dir: linked)).to eq("?? notes.md\n")
    expect(File.read(File.join(repo, ".git", "info", "exclude"))).to include("/.workflow/\n")
  end

  it "does nothing outside a git checkout" do
    plain = File.join(@dir, "plain")
    FileUtils.mkdir_p(plain)

    expect(excludes.add(plain, "/.workflow/")).to be false
    expect(Dir.children(plain)).to eq([])
  end
end
