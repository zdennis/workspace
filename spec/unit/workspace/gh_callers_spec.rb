require "tmpdir"

# Every caller of `gh` takes the process call as a keyword. Each one is built
# here with a recording runner that pins the exact gh argv, and then with no
# runner at all, with the standard library's process call stubbed, to pin the
# default: today's exact call, with no time limit, environment variable or
# process group that the caller did not have before.
RSpec.describe "gh callers" do
  let(:no_prompt) { Workspace::TimedProcess::NO_PROMPT }
  let(:ok_status) { Struct.new(:ok) { def success? = ok }.new(true) }
  let(:calls) { [] }

  def runner_keyword(klass, name)
    klass.instance_method(:initialize).parameters.find { |_, param| param == name }
  end

  describe Workspace::GhPullRequests do
    let(:git) do
      Class.new do
        def remote_url(_path) = "git@github.com:acme/widgets.git"
      end.new
    end
    let(:runner) do
      ->(*argv) do
        calls << argv
        ["{\"number\":7,\"url\":\"u\",\"state\":\"OPEN\"}", "", ok_status]
      end
    end

    it "takes an optional runner: keyword" do
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "runs gh auth status, then gh pr view for the branch on the remote's repository" do
      gh = described_class.new(git: git, runner: runner)
      gh.usable?
      gh.status_for("feature", "/repo")

      expect(calls).to eq([
        %w[gh auth status],
        %w[gh pr view feature --repo acme/widgets --json number,url,state]
      ])
    end

    it "defaults to Open3.capture3 with the arguments as they are" do
      expect(Open3).to receive(:capture3).with("gh", "auth", "status").and_return(["", "", ok_status])

      expect(described_class.new(git: git).usable?).to be(true)
    end
  end

  describe Workspace::PullRequestStatus do
    let(:runner) do
      ->(args, chdir:, timeout:) do
        calls << {args: args, chdir: chdir, timeout: timeout}
        ["{}", "", true]
      end
    end

    it "takes an optional runner: keyword" do
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "asks gh pr view for the checkout's branch with the summary fields" do
      described_class.new(runner: runner).summary("/repo")

      expect(calls).to eq([{args: ["pr", "view", "--json", "number,url,title,state"], chdir: "/repo",
                            timeout: described_class::DEFAULT_TIMEOUT}])
    end

    it "asks gh pr view for the full fields in #call" do
      described_class.new(runner: runner).call("/repo")

      expect(calls.map { |c| c[:args] }).to eq([["pr", "view", "--json", "number,url,title,state,isDraft,reviewDecision,mergeable,statusCheckRollup"]])
    end

    it "asks for a numbered pull request's head with --repo" do
      described_class.new(runner: runner).head("/repo", number: 12, repo: "github.com/acme/widgets")

      expect(calls.map { |c| [c[:args], c[:chdir]] }).to eq([
        [["pr", "view", "12", "--repo", "github.com/acme/widgets", "--json", "state,isCrossRepository,headRefName,headRefOid,headRepository,headRepositoryOwner"], "/repo"]
      ])
    end

    it "defaults to a process group call of gh with prompts off" do
      expect(Open3).to receive(:popen3)
        .with(no_prompt, "gh", "pr", "view", "--json", "number,url,title,state", chdir: "/repo", pgroup: true)
        .and_raise(Errno::ENOENT)

      expect(described_class.new.summary("/repo")).to eq({"available" => false, "reason" => "gh_missing"})
    end
  end

  describe Workspace::PullRequestFeedback do
    let(:runner) do
      ->(args, chdir:, timeout:, max_bytes:) do
        calls << {args: args, chdir: chdir, timeout: timeout, max_bytes: max_bytes}
        ["", "no pull requests found for branch", false]
      end
    end

    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    it "takes an optional runner: keyword" do
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "asks gh pr view for number and url first, with the time and size limits" do
      expect { described_class.new(runner: runner).call(@dir, branch: "feature") }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("no_pull_request") }

      expect(calls).to eq([{args: ["pr", "view", "--json", "number,url"], chdir: @dir,
                            timeout: described_class::DEFAULT_TIMEOUT, max_bytes: described_class::MAX_OUTPUT_BYTES}])
    end

    it "asks the GraphQL API for the pull request on the host from its URL" do
      answers = [
        ["{\"url\":\"https://github.com/acme/widgets/pull/9\"}", "", true],
        ["", "boom", false]
      ]
      recording = ->(args, **opts) do
        calls << args
        answers.shift || ["", "", false]
      end

      expect { described_class.new(runner: recording).call(@dir) }.to raise_error(Workspace::Error)

      expect(calls[0]).to eq(["pr", "view", "--json", "number,url"])
      expect(calls[1].first(10)).to eq(%w[api graphql --hostname github.com -f owner=acme -f name=widgets -F number=9])
      expect(calls[1].last).to start_with("query=")
    end

    it "defaults to a process group call of gh with prompts off" do
      expect(Open3).to receive(:popen3)
        .with(no_prompt, "gh", "pr", "view", "--json", "number,url", chdir: @dir, pgroup: true)
        .and_raise(Errno::ENOENT)

      expect { described_class.new.call(@dir) }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gh_unavailable") }
    end
  end

  describe Workspace::Commands::PullRequest do
    let(:status) do
      Class.new do
        def call(_path) = {"found" => false}
      end.new
    end
    let(:runner) do
      ->(argv, chdir:, timeout:) do
        calls << {argv: argv, chdir: chdir, timeout: timeout}
        ["https://github.com/acme/widgets/pull/3\n", "", true]
      end
    end

    def build(**options)
      described_class.new(git: nil, project_config: nil, project_detector: nil, status: status, output: StringIO.new, **options)
    end

    it "takes an optional runner: keyword" do
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "runs gh pr create --fill, with --draft when asked, under the create time limit" do
      build(runner: runner).find_or_create("/repo", draft: true)
      build(runner: runner).find_or_create("/repo")

      expect(calls).to eq([
        {argv: %w[gh pr create --fill --draft], chdir: "/repo", timeout: described_class::CREATE_TIMEOUT},
        {argv: %w[gh pr create --fill], chdir: "/repo", timeout: described_class::CREATE_TIMEOUT}
      ])
    end

    it "defaults to a process group call of gh with prompts off" do
      expect(Open3).to receive(:popen3)
        .with(no_prompt, "gh", "pr", "create", "--fill", chdir: "/repo", pgroup: true)
        .and_raise(Errno::ENOENT)

      expect { build.find_or_create("/repo") }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gh_unavailable") }
    end
  end

  describe Workspace::TicketSource do
    let(:which) { ->(_program) { true } }
    let(:runner) do
      ->(argv, chdir:, timeout:) do
        calls << {argv: argv, chdir: chdir, timeout: timeout}
        ["{}", "", true]
      end
    end

    def ref(kind, number, repo: nil)
      Workspace::StartRef::Ref.new(kind: kind, input: "#{kind}#{number}", key: nil, branch: nil,
        parsed: {number: number, repo: repo})
    end

    it "takes an optional runner: keyword" do
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "views a pull request and an issue with the fields each has" do
      source = described_class.new(runner: runner, which: which)
      source.fetch(ref("github_pr", "5", repo: "acme/widgets"), chdir: "/repo")
      source.fetch(ref("github_issue", "6"), chdir: "/repo")

      expect(calls).to eq([
        {argv: %w[gh pr view 5 --repo acme/widgets --json title,body,url,isCrossRepository], chdir: "/repo",
         timeout: described_class::DEFAULT_TIMEOUT},
        {argv: %w[gh issue view 6 --json title,body,url], chdir: "/repo", timeout: described_class::DEFAULT_TIMEOUT}
      ])
    end

    it "defaults to a process group call of gh with prompts off" do
      expect(Open3).to receive(:popen3)
        .with(no_prompt, "gh", "issue", "view", "6", "--json", "title,body,url", chdir: "/repo", pgroup: true)
        .and_raise(Errno::ENOENT)

      expect { described_class.new(which: which).fetch(ref("github_issue", "6"), chdir: "/repo") }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("ticket_source_unavailable") }
    end
  end

  describe Workspace::Git do
    it "takes an optional gh_runner: keyword beside runner:" do
      expect(runner_keyword(described_class, :gh_runner)).to eq([:key, :gh_runner])
      expect(runner_keyword(described_class, :runner)).to eq([:key, :runner])
    end

    it "defaults to Open3.capture3 with prompts off, from chdir" do
      expect(Open3).to receive(:capture3)
        .with({"GH_PROMPT_DISABLED" => "1"}, "gh", "pr", "checkout", "4", "--worktree", "/wt", "--branch", "pr-4", chdir: "/repo")
        .and_raise(Errno::ENOENT)

      expect { described_class.new(output: StringIO.new).checkout_pr_worktree("/wt", number: "4", repo: nil, branch: "pr-4", chdir: "/repo", quiet: true) }
        .to raise_error(Workspace::Error, /`gh` is not installed/)
    end
  end
end
