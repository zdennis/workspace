require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe Workspace::StartRef do
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  subject(:resolver) { described_class.new(git: git, lineage: LineageSupport.lineage) }

  describe "#call" do
    it "reads a JIRA key" do
      ref = resolver.call("PROJ-123")

      expect(ref).to have_attributes(kind: "jira", key: "PROJ-123", branch: "PROJ-123", pr: nil)
    end

    it "reads the key out of a JIRA URL" do
      ref = resolver.call("https://acme.atlassian.net/browse/PROJ-123")

      expect(ref).to have_attributes(kind: "jira", key: "PROJ-123", branch: "PROJ-123")
    end

    it "reads a lowercase key in a JIRA URL as the ticket" do
      ref = resolver.call("https://acme.atlassian.net/browse/proj-123")

      expect(ref).to have_attributes(kind: "jira", key: "PROJ-123")
    end

    it "uses the key as written outside a repository" do
      allow(git).to receive(:root).and_return(nil)

      expect(resolver.call("PROJ-1").branch).to eq("PROJ-1")
    end

    context "with a branch that matches a JIRA key without case" do
      before do
        allow(git).to receive(:root).and_return("/src/app")
        allow(git).to receive(:local_branch_names).with("/src/app").and_return(locals)
        allow(git).to receive(:branch_names).with("/src/app").and_return(locals + remotes)
      end

      let(:locals) { [] }
      let(:remotes) { [] }

      context "that is local" do
        let(:locals) { %w[Proj-1 main] }

        it "uses its real name" do
          expect(resolver.call("PROJ-1")).to have_attributes(input: "PROJ-1", key: "PROJ-1", branch: "Proj-1")
        end
      end

      context "that is a lowercase branch with no uppercase sibling" do
        let(:locals) { %w[proj-1 main] }

        it "reuses the existing branch under its own name" do
          expect(resolver.call("PROJ-1").branch).to eq("proj-1")
        end
      end

      context "that is local while another is on origin" do
        let(:locals) { %w[PROJ-1] }
        let(:remotes) { %w[proj-1] }

        it "prefers the local name" do
          expect(resolver.call("PROJ-1").branch).to eq("PROJ-1")
        end
      end

      context "when a stray uppercase branch sorts before the lowercase one" do
        let(:locals) { %w[PROJ-1 proj-1] }

        it "prefers the exact lowercase key" do
          expect(resolver.call("PROJ-1").branch).to eq("proj-1")
        end
      end

      context "that is local in another case while the exact lowercase key is on origin" do
        let(:locals) { %w[Proj-1] }
        let(:remotes) { %w[proj-1] }

        it "prefers the local name" do
          expect(resolver.call("PROJ-1").branch).to eq("Proj-1")
        end
      end

      context "when origin has the exact lowercase key and a stray uppercase one" do
        let(:remotes) { %w[PROJ-1 proj-1] }

        it "prefers the exact lowercase key" do
          expect(resolver.call("PROJ-1").branch).to eq("proj-1")
        end
      end

      context "when branches differ only in case among the any-case matches" do
        let(:locals) { %w[Proj-1 PROJ-1] }

        it "picks the same one whatever the order" do
          expect(resolver.call("PROJ-1").branch).to eq("PROJ-1")
        end
      end

      context "that is only on origin" do
        let(:remotes) { %w[Proj-1] }

        it "uses the name origin has" do
          expect(resolver.call("PROJ-1").branch).to eq("Proj-1")
        end
      end

      context "for a key that lowercases to a pull request or issue branch" do
        let(:locals) { %w[pr-12 issue-9] }

        it "keeps the key as parsed" do
          expect(resolver.call("PR-12").branch).to eq("PR-12")
          expect(resolver.call("ISSUE-9").branch).to eq("ISSUE-9")
          expect(resolver.call("https://acme.atlassian.net/browse/PR-12").branch).to eq("PR-12")
        end
      end

      it "reads the branches of the root it is given, or uses the names it is handed" do
        allow(git).to receive(:local_branch_names).with("/other").and_return(%w[Proj-1])
        allow(git).to receive(:branch_names).with("/other").and_return(%w[Proj-1])

        expect(resolver.call("PROJ-1", root: "/other").branch).to eq("Proj-1")
        expect(resolver.call("PROJ-1", root: "/other", names: described_class::BranchNames.new(local: [], all: [])).branch).to eq("PROJ-1")
      end
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

  describe "#kind" do
    it "reads the kind of a ref without running git or reading branches" do
      allow(git).to receive(:root)
      allow(git).to receive(:local_branch_names)
      allow(git).to receive(:branch_names)

      kinds = %w[PROJ-1 #9 https://github.com/o/r/issues/4 https://github.com/o/r/pull/3 feature/x].map { |ref| resolver.kind(ref) }

      expect(kinds).to eq(%w[jira github_pr github_issue github_pr branch])
      expect(git).not_to have_received(:root)
      expect(git).not_to have_received(:local_branch_names)
      expect(git).not_to have_received(:branch_names)
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
