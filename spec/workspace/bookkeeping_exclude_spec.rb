require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"

RSpec.describe Workspace::BookkeepingExclude do
  around do |example|
    Dir.mktmpdir("bookkeeping") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "app") }
  let(:workspace_git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:git_exclude) { Workspace::GitExclude.new(git: workspace_git) }
  let(:exclude_file) { File.join(repo, ".git", "info", "exclude") }
  subject(:excluder) { described_class.new(git: workspace_git, git_exclude: git_exclude) }

  def git(*args)
    out, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", *args)
    raise out unless status.success?
    out
  end

  def listed
    File.exist?(exclude_file) ? File.read(exclude_file).lines.map(&:chomp) : []
  end

  before do
    FileUtils.mkdir_p(File.join(repo, ".claude"))
    git("init", "-q")
  end

  describe "#backup" do
    it "lists one pattern for every backup, once" do
      path = File.join(repo, ".claude", "settings.json.workspace-backup-20261022090551")
      File.write(path, "x")

      expect(excluder.backup(path)).to be(true)
      excluder.backup(path)

      expect(listed.count("*.workspace-backup-*")).to eq(1)
      expect(git("status", "--porcelain")).not_to include("workspace-backup")
    end

    it "does nothing outside a git checkout" do
      path = File.join(@dir, "settings.json.workspace-backup-1")
      File.write(path, "x")

      expect(excluder.backup(path)).to be(false)
    end

    it "tolerates an exclude file that can't be written" do
      path = File.join(repo, "a.workspace-backup-1")
      File.write(path, "x")
      allow(git_exclude).to receive(:add).and_raise(Errno::EACCES)

      expect(excluder.backup(path)).to be(false)
    end
  end

  describe "#created" do
    let(:path) { File.join(repo, ".claude", "settings.json") }

    it "lists an untracked file by its path from the checkout root" do
      File.write(path, "{}")

      expect(excluder.created(path)).to be(true)

      expect(listed).to include("/.claude/settings.json")
      expect(git("status", "--porcelain")).not_to include("settings.json")
    end

    it "never lists a file git tracks" do
      File.write(path, "{}")
      git("add", ".claude/settings.json")

      expect(excluder.created(path)).to be(false)
      expect(listed).not_to include("/.claude/settings.json")
    end

    it "tolerates git being unable to answer" do
      File.write(path, "{}")
      allow(workspace_git).to receive(:tracked?).and_raise(Workspace::Error, "boom")

      expect(excluder.created(path)).to be(false)
    end
  end
end
