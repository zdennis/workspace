require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe Workspace::DeliveryFacts do
  let(:git) { Workspace::Git.new(output: StringIO.new) }
  subject(:facts) { described_class.new(git: git) }

  around do |example|
    Dir.mktmpdir("delivery") do |dir|
      @dir = dir
      example.run
    end
  end

  def sh(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise out unless status.success?
    out
  end

  def commit(dir, name)
    File.write(File.join(dir, name), name)
    sh(dir, "add", name)
    sh(dir, "commit", "-qm", name)
  end

  def repo_with_origin
    origin = File.join(@dir, "origin.git")
    clone = File.join(@dir, "clone")
    Open3.capture2e("git", "init", "-q", "--bare", "-b", "main", origin)
    Open3.capture2e("git", "clone", "-q", origin, clone)
    sh(clone, "checkout", "-q", "-b", "main")
    commit(clone, "base")
    sh(clone, "push", "-q", "-u", "origin", "main")
    sh(clone, "checkout", "-q", "-b", "feat")
    commit(clone, "work")
    clone
  end

  it "is nil for a nil or empty path or branch, or a missing directory" do
    expect(facts.read(nil, "feat")).to be_nil
    expect(facts.read(@dir, nil)).to be_nil
    expect(facts.read(@dir, "")).to be_nil
    expect(facts.read(File.join(@dir, "gone"), "feat")).to be_nil
  end

  it "is nil for a repository with no base ref and no remote" do
    repo = File.join(@dir, "repo")
    Open3.capture2e("git", "init", "-q", "-b", "trunk", repo)
    commit(repo, "a")

    expect(facts.read(repo, "trunk")).to be_nil
  end

  it "is nil when the branch does not exist" do
    repo = repo_with_origin

    expect(facts.read(repo, "nope")).to be_nil
  end

  it "is nil when git raises" do
    allow(git).to receive(:branch_vs_base).and_raise(Workspace::Error, "git is not installed.")

    expect(facts.read(@dir, "feat")).to be_nil
  end

  it "reads an unpushed branch against origin's default branch" do
    repo = repo_with_origin

    expect(facts.read(repo, "feat")).to include("base" => "origin/main", "remote" => true, "upstream" => nil, "upstream_gone" => false,
      "pushed" => false, "merged" => false, "ahead_of_base" => 1)
  end

  it "reads a pushed branch" do
    repo = repo_with_origin
    sh(repo, "push", "-q", "-u", "origin", "feat")

    expect(facts.read(repo, "feat")).to include("upstream" => "origin/feat", "pushed" => true, "ahead_of_upstream" => 0, "merged" => false)
  end

  it "counts the branch, not HEAD, when another branch is checked out" do
    repo = repo_with_origin
    sh(repo, "checkout", "-q", "main")

    expect(facts.read(repo, "feat")).to include("ahead_of_base" => 1, "merged" => false)
  end

  it "reports upstream_gone when the upstream is configured but its branch was deleted" do
    repo = repo_with_origin
    sh(repo, "push", "-q", "-u", "origin", "feat")
    sh(repo, "push", "-q", "origin", "--delete", "feat")

    result = facts.read(repo, "feat")

    expect(result).to include("upstream" => "origin/feat", "upstream_gone" => true, "pushed" => false, "ahead_of_upstream" => nil, "merged" => false)
  end

  it "has no pushed answer with no remote, and counts the local default branch" do
    repo = File.join(@dir, "repo")
    Open3.capture2e("git", "init", "-q", "-b", "main", repo)
    commit(repo, "a")
    sh(repo, "checkout", "-q", "-b", "feat")
    commit(repo, "b")

    expect(facts.read(repo, "feat")).to include("remote" => false, "pushed" => nil, "base" => "main", "merged" => false, "ahead_of_base" => 1)
  end

  describe "Git#merged_into_base?" do
    it "is the shared answer: true, false, or nil when unknown" do
      repo = repo_with_origin

      expect(git.merged_into_base?(repo, "feat")).to be(false)
      expect(git.merged_into_base?(repo, "main")).to be(true)
      expect(git.merged_into_base?(repo, "nope")).to be_nil
    end
  end
end
