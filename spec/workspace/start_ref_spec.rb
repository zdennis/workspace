require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe Workspace::StartRef do
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  subject(:resolver) { described_class.new(git: git, lineage: Workspace::WorkspaceLineage.new) }

  describe "#call" do
    it "reads a JIRA key" do
      ref = resolver.call("PROJ-123")

      expect(ref).to have_attributes(kind: "jira", key: "PROJ-123", branch: "PROJ-123", pr: nil)
    end

    it "reads the key out of a JIRA URL" do
      ref = resolver.call("https://acme.atlassian.net/browse/PROJ-123")

      expect(ref).to have_attributes(kind: "jira", key: "PROJ-123", branch: "PROJ-123")
    end

    it "reads a pull request URL as the pr-<n> branch start checks it out under" do
      ref = resolver.call("https://github.com/org/repo/pull/41")

      expect(ref).to have_attributes(kind: "github_pr", key: "org/repo#41", branch: "pr-41")
      expect(ref.pr).to include(repo: "org/repo", number: "41")
    end

    it "reads a bare #n as a pull request in the current repository" do
      ref = resolver.call("#41")

      expect(ref).to have_attributes(kind: "github_pr", key: "#41", branch: "pr-41")
      expect(ref.pr).to include(repo: nil, number: "41")
    end

    it "reads an issue URL as the issue-<n> branch" do
      ref = resolver.call("https://github.com/org/repo/issues/42")

      expect(ref).to have_attributes(kind: "github_issue", key: "org/repo#42", branch: "issue-42", pr: nil)
      expect(ref.parsed).to include(repo: "org/repo", number: "42")
    end

    it "keys an issue that parsing gave no repository for by its number" do
      allow(git).to receive(:parse_start_input).and_return({type: :issue_url, value: "issue-42"})

      expect(resolver.call("whatever")).to have_attributes(kind: "github_issue", key: "#42", branch: "issue-42")
    end

    it "treats anything else as a branch" do
      ref = resolver.call("feature/x")

      expect(ref).to have_attributes(kind: "branch", key: "feature/x", branch: "feature/x", pr: nil)
    end

    it "keeps the input as given" do
      expect(resolver.call("PROJ-123").input).to eq("PROJ-123")
    end
  end

  describe ".slug" do
    it "makes lowercase hyphenated ASCII" do
      expect(described_class.slug("Fix the Login: redirect (v2)!")).to eq("fix-the-login-redirect-v2")
      expect(described_class.slug("Café  crème -- à la mode")).to eq("cafe-creme-a-la-mode")
    end

    it "is empty for a title with no letters or digits, and for nil" do
      expect(described_class.slug("日本語 !!!")).to eq("")
      expect(described_class.slug(nil)).to eq("")
    end

    it "does not fail on bytes that are not valid UTF-8" do
      expect(described_class.slug("Fix \xFF login".b.force_encoding("UTF-8"))).to eq("fix-login")
    end

    it "cuts a long title at a word boundary" do
      slug = described_class.slug("Make the login redirect go to the page the person asked for originally")

      expect(slug).to eq("make-the-login-redirect-go-to-the-page")
      expect(slug.length).to be <= described_class::SLUG_MAX
    end

    it "cuts one very long word at the limit" do
      expect(described_class.slug("a" * 100)).to eq("a" * 40)
    end

    it "gives a valid git ref component" do
      ["../x", "a/b\\c", "x.lock", "-rf", "a..b", "@{", "~^:?*[ "].each do |title|
        expect(described_class.slug(title)).to match(/\A[a-z0-9]*(-[a-z0-9]+)*\z/)
      end
    end
  end

  describe "#slugged" do
    it "adds the slug to a JIRA key and to an issue branch, leaving the original ref alone" do
      jira = resolver.call("PROJ-123")
      issue = resolver.call("https://github.com/o/r/issues/42")

      expect(resolver.slugged(jira, "Fix login").branch).to eq("PROJ-123-fix-login")
      expect(resolver.slugged(issue, "Fix login").branch).to eq("issue-42-fix-login")
      expect(jira.branch).to eq("PROJ-123")
    end

    it "leaves a pull request, a branch, and a ref with no usable title unchanged" do
      expect(resolver.slugged(resolver.call("#9"), "Fix").branch).to eq("pr-9")
      expect(resolver.slugged(resolver.call("feature/x"), "Fix").branch).to eq("feature/x")
      expect(resolver.slugged(resolver.call("PROJ-1"), nil).branch).to eq("PROJ-1")
      expect(resolver.slugged(resolver.call("PROJ-1"), "!!!").branch).to eq("PROJ-1")
    end
  end

  describe "#project" do
    around do |example|
      Dir.mktmpdir("start-ref") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def sh(*args, dir:)
      out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
      raise out unless status.success?
    end

    let(:repo) { File.join(@dir, "api") }
    let(:linked) { File.join(@dir, "api-x") }

    before do
      FileUtils.mkdir_p(repo)
      sh("init", "-q", dir: repo)
      sh("commit", "-q", "--allow-empty", "-m", "init", dir: repo)
      sh("worktree", "add", "-q", "-b", "x", linked, dir: repo)
    end

    it "names the checkout it is run in" do
      project = resolver.project(repo)

      expect(project).to have_attributes(root: repo, name: "api", from_worktree: false)
    end

    it "resolves a linked worktree to its parent repository" do
      project = resolver.project(linked)

      expect(project).to have_attributes(root: repo, name: "api", from_worktree: true)
    end
  end
end
