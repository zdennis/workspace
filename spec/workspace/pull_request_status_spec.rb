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
end
