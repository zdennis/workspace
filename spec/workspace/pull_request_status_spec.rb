require "tmpdir"

RSpec.describe Workspace::PullRequestStatus do
  def runner_returning(stdout: "", stderr: "", success: true)
    calls = []
    runner = ->(args, chdir:, timeout:) {
      calls << {args: args, chdir: chdir, timeout: timeout}
      [stdout, stderr, success]
    }
    [runner, calls]
  end

  def pr_json(rollup: [], **overrides)
    JSON.generate({"number" => 7, "url" => "https://github.com/o/r/pull/7", "title" => "Fix it", "state" => "OPEN", "isDraft" => false,
                   "reviewDecision" => "", "mergeable" => "MERGEABLE", "statusCheckRollup" => rollup}.merge(overrides))
  end

  it "asks gh only to read the branch's pull request, in the checkout, with a timeout" do
    runner, calls = runner_returning(stdout: pr_json)

    described_class.new(runner: runner, timeout: 3).call("/work/tree")

    expect(calls).to eq([{args: ["pr", "view", "--json", "number,url,title,state,isDraft,reviewDecision,mergeable,statusCheckRollup"],
                          chdir: "/work/tree", timeout: 3}])
  end

  it "reports the pull request's state, with a blank review decision as nil" do
    runner, = runner_returning(stdout: pr_json(isDraft: true))

    expect(described_class.new(runner: runner).call("/w")).to include(
      "available" => true, "found" => true, "number" => 7, "state" => "OPEN", "draft" => true,
      "review_decision" => nil, "mergeable" => "MERGEABLE", "url" => "https://github.com/o/r/pull/7"
    )
  end

  it "keeps a review decision that is set" do
    runner, = runner_returning(stdout: pr_json(reviewDecision: "APPROVED"))

    expect(described_class.new(runner: runner).call("/w")["review_decision"]).to eq("APPROVED")
  end

  describe "checks" do
    let(:rollup) do
      [
        {"__typename" => "CheckRun", "name" => "rspec", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "FAILURE"},
        {"__typename" => "CheckRun", "name" => "deploy", "status" => "IN_PROGRESS", "conclusion" => ""},
        {"__typename" => "CheckRun", "name" => "docs", "status" => "COMPLETED", "conclusion" => "SKIPPED"},
        {"__typename" => "StatusContext", "context" => "ci/legacy", "state" => "ERROR"},
        {"__typename" => "StatusContext", "context" => "ci/ok", "state" => "SUCCESS"},
        {"__typename" => "StatusContext", "context" => "ci/wait", "state" => "PENDING"}
      ]
    end

    it "counts passing, failing and pending across check runs and commit statuses" do
      runner, = runner_returning(stdout: pr_json(rollup: rollup))

      expect(described_class.new(runner: runner).call("/w")["checks"]).to eq(
        "total" => 7, "passing" => 3, "failing" => 2, "pending" => 2, "failed" => ["lint", "ci/legacy"]
      )
    end

    it "caps the failing names but not the count" do
      many = Array.new(25) { |i| {"name" => "c#{i}", "status" => "COMPLETED", "conclusion" => "FAILURE"} }
      runner, = runner_returning(stdout: pr_json(rollup: many))

      checks = described_class.new(runner: runner).call("/w")["checks"]

      expect(checks["failing"]).to eq(25)
      expect(checks["failed"].size).to eq(described_class::MAX_FAILED_CHECKS)
    end

    it "reads no checks as zero, not as passing" do
      runner, = runner_returning(stdout: pr_json(rollup: nil))

      expect(described_class.new(runner: runner).call("/w")["checks"]).to eq("total" => 0, "passing" => 0, "failing" => 0, "pending" => 0, "failed" => [])
    end
  end

  it "reports a branch with no pull request as found: false" do
    runner, = runner_returning(stderr: %(no pull requests found for branch "cli/phase-2"\n), success: false)

    expect(described_class.new(runner: runner).call("/w")).to eq("available" => true, "found" => false)
  end

  it "reports another gh failure with its first line, cut" do
    runner, = runner_returning(stderr: "HTTP 401: bad credentials#{"!" * 400}\nsecond line", success: false)

    result = described_class.new(runner: runner).call("/w")

    expect(result).to include("available" => false, "reason" => "error")
    expect(result["detail"]).to start_with("HTTP 401: bad credentials")
    expect(result["detail"].length).to eq(200)
  end

  it "scrubs invalid UTF-8 in a gh error so the result encodes as JSON" do
    runner, = runner_returning(stderr: "bad \xFF thing", success: false)

    expect { JSON.generate(described_class.new(runner: runner).call("/w")) }.not_to raise_error
  end

  it "reports a missing gh" do
    runner = ->(*, **) { raise Errno::ENOENT, "gh" }

    expect(described_class.new(runner: runner).call("/w")).to eq("available" => false, "reason" => "gh_missing")
  end

  it "reports a timeout" do
    runner = ->(*, **) { raise Timeout::Error }

    expect(described_class.new(runner: runner).call("/w")).to eq("available" => false, "reason" => "timeout")
  end

  it "reports a reply that isn't the expected JSON" do
    ["not json", "[]"].each do |reply|
      runner, = runner_returning(stdout: reply)

      expect(described_class.new(runner: runner).call("/w")).to include("available" => false, "reason" => "error")
    end
  end

  describe "the default runner" do
    def with_fake_gh(script)
      Dir.mktmpdir do |dir|
        gh = File.join(dir, "gh")
        File.write(gh, "#!/bin/sh\n#{script}\n")
        File.chmod(0o755, gh)
        original = ENV["PATH"]
        ENV["PATH"] = "#{dir}:#{original}"
        begin
          yield dir
        ensure
          ENV["PATH"] = original
        end
      end
    end

    it "runs gh in the checkout with prompts turned off" do
      with_fake_gh(%(echo "{\\"number\\":1,\\"title\\":\\"$GH_PROMPT_DISABLED $(basename "$PWD")\\"}")) do |dir|
        result = described_class.new.call(dir)

        expect(result).to include("found" => true, "number" => 1, "title" => "1 #{File.basename(dir)}")
      end
    end

    it "stops a gh that outlives the timeout" do
      with_fake_gh("sleep 30") do |dir|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result = described_class.new(timeout: 0.3).call(dir)

        expect(result).to eq("available" => false, "reason" => "timeout")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      end
    end
  end

  describe "#head" do
    def head_json(**overrides)
      JSON.generate({"state" => "OPEN", "isCrossRepository" => false, "headRefName" => "fix/thing", "headRefOid" => "a" * 40,
                     "headRepository" => {"id" => "R_1", "name" => "api"}, "headRepositoryOwner" => {"id" => "U_1", "login" => "acme"}}.merge(overrides))
    end

    it "asks gh for the numbered pull request of the named repository" do
      runner, calls = runner_returning(stdout: head_json)

      described_class.new(runner: runner, timeout: 3).head("/w", number: 12, repo: "github.com/acme/api")

      expect(calls).to eq([{args: ["pr", "view", "12", "--repo", "github.com/acme/api", "--json",
        "state,isCrossRepository,headRefName,headRefOid,headRepository,headRepositoryOwner"], chdir: "/w", timeout: 3}])
    end

    it "reports the head branch, commit and repository" do
      runner, = runner_returning(stdout: head_json)

      expect(described_class.new(runner: runner).head("/w", number: 12, repo: "github.com/acme/api")).to eq(
        "available" => true, "state" => "OPEN", "cross_repository" => false, "head_ref" => "fix/thing",
        "head_sha" => "a" * 40, "head_owner" => "acme", "head_name" => "api"
      )
    end

    it "leaves the head repository nil when gh gives none (a deleted fork)" do
      runner, = runner_returning(stdout: head_json("headRepository" => nil, "headRepositoryOwner" => nil))

      expect(described_class.new(runner: runner).head("/w", number: 12, repo: "github.com/acme/api")).to include("head_owner" => nil, "head_name" => nil)
    end

    it "reports not_logged_in apart from other failures, with gh\x27s first line" do
      runner, = runner_returning(stderr: "\nTo get started with GitHub CLI, please run:  gh auth login\n", success: false)

      expect(described_class.new(runner: runner).head("/w", number: 12, repo: "github.com/acme/api")).to eq(
        "available" => false, "reason" => "not_logged_in", "detail" => "To get started with GitHub CLI, please run:  gh auth login"
      )
    end

    it "reports any other failure as error with gh\x27s first line" do
      runner, = runner_returning(stderr: "GraphQL: Could not resolve to a PullRequest with the number of 12.\n", success: false)

      expect(described_class.new(runner: runner).head("/w", number: 12, repo: "github.com/acme/api")).to eq(
        "available" => false, "reason" => "error", "detail" => "GraphQL: Could not resolve to a PullRequest with the number of 12."
      )
    end

    it "reports gh missing, a timeout and an unreadable reply as facts" do
      missing = ->(*, **) { raise Errno::ENOENT }
      slow = ->(*, **) { raise Timeout::Error }
      garbled, = runner_returning(stdout: "[]")

      expect(described_class.new(runner: missing).head("/w", number: 1, repo: "h/o/n")).to eq("available" => false, "reason" => "gh_missing")
      expect(described_class.new(runner: slow).head("/w", number: 1, repo: "h/o/n")).to eq("available" => false, "reason" => "timeout")
      expect(described_class.new(runner: garbled).head("/w", number: 1, repo: "h/o/n")).to include("available" => false, "reason" => "error")
    end
  end

  describe ".github_repo" do
    it "reads https, ssh:// and scp-like origin URLs" do
      expect(described_class.github_repo("https://github.com/acme/api.git")).to eq(%w[github.com acme api])
      expect(described_class.github_repo("https://github.com/acme/api")).to eq(%w[github.com acme api])
      expect(described_class.github_repo("https://x-token@ghe.example.com/acme/api.js.git")).to eq(%w[ghe.example.com acme api.js])
      expect(described_class.github_repo("ssh://git@github.com/acme/api.git")).to eq(%w[github.com acme api])
      expect(described_class.github_repo("git@github.com:acme/api.git")).to eq(%w[github.com acme api])
    end

    it "refuses anything else" do
      ["/tmp/remote.git", "file:///tmp/remote.git", "ssh://git@github.com:22/acme/api.git", "https://github.com/acme/api/extra",
        "https://github.com/ac_me/api", "https://github.com/acme/a%20pi", "git@github.com:acme", "", nil].each do |url|
        expect(described_class.github_repo(url)).to be_nil, url.inspect
      end
    end
  end

  describe ".outcome" do
    it "reads a check run by status and conclusion and a commit status by state" do
      expect(described_class.outcome({"status" => "COMPLETED", "conclusion" => "FAILURE"})).to eq(:failing)
      expect(described_class.outcome({"status" => "COMPLETED", "conclusion" => "SKIPPED"})).to eq(:passing)
      expect(described_class.outcome({"status" => "IN_PROGRESS"})).to eq(:pending)
      expect(described_class.outcome({"state" => "ERROR"})).to eq(:failing)
      expect(described_class.outcome({"state" => "SUCCESS"})).to eq(:passing)
      expect(described_class.outcome({"state" => "PENDING"})).to eq(:pending)
    end
  end
end
