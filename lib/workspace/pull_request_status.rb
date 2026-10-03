require "json"
require "open3"
require "timeout"

module Workspace
  # Reads the pull request for a checkout's branch with `gh pr view`, which
  # only reads. The answer is always a fact, never an exception: `gh`
  # missing, a failure or a timeout is `available: false` with a reason, and a
  # branch with no pull request is `available: true, found: false`.
  class PullRequestStatus
    # Seconds `gh` may take.
    DEFAULT_TIMEOUT = 10.0

    # Longest failing-check list returned.
    MAX_FAILED_CHECKS = 20

    FIELDS = "number,url,title,state,isDraft,reviewDecision,mergeable,statusCheckRollup".freeze
    private_constant :FIELDS

    FAILED_CONCLUSIONS = %w[FAILURE TIMED_OUT CANCELLED STARTUP_FAILURE ACTION_REQUIRED STALE].freeze
    PASSED_CONCLUSIONS = %w[SUCCESS NEUTRAL SKIPPED].freeze
    FAILED_STATES = %w[FAILURE ERROR].freeze
    private_constant :FAILED_CONCLUSIONS, :PASSED_CONCLUSIONS, :FAILED_STATES

    # @param runner [#call] `(args, chdir:, timeout:)` returning `[stdout, stderr, success]`;
    #   defaults to running `gh` without a prompt, in a process group stopped on timeout
    # @param timeout [Numeric] seconds `gh` may take
    def initialize(runner: method(:run_gh), timeout: DEFAULT_TIMEOUT)
      @runner = runner
      @timeout = timeout
    end

    # @param path [String] the checkout; `gh` finds the pull request from its current branch
    # @return [Hash] `{"available" => true, "found" => false}`, or `{"available" => true, "found" => true,
    #   "number", "url", "title", "state", "draft", "review_decision", "mergeable", "checks" => {"total",
    #   "passing", "failing", "pending", "failed" => [names]}}`, or `{"available" => false, "reason" =>
    #   "gh_missing" | "timeout" | "error"}` (`detail` only with "error")
    def call(path)
      stdout, stderr, success = @runner.call(["pr", "view", "--json", FIELDS], chdir: path, timeout: @timeout)
      return facts(JSON.parse(stdout)) if success
      return {"available" => true, "found" => false} if stderr.to_s.include?("no pull requests found")
      {"available" => false, "reason" => "error", "detail" => stderr.to_s.scrub.lines.first.to_s.strip[0, 200]}
    rescue Errno::ENOENT
      {"available" => false, "reason" => "gh_missing"}
    rescue Timeout::Error
      {"available" => false, "reason" => "timeout"}
    rescue JSON::ParserError, SystemCallError
      {"available" => false, "reason" => "error", "detail" => "unreadable reply from gh"}
    end

    private

    def run_gh(args, chdir:, timeout:)
      Open3.popen3({"GH_PROMPT_DISABLED" => "1"}, "gh", *args, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, waiter|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        [out, err].each { |reader| reader.report_on_exception = false }
        unless waiter.join(timeout)
          stop_group(waiter)
          raise Timeout::Error
        end
        [out.value, err.value, waiter.value.success?]
      end
    end

    def stop_group(waiter)
      Process.kill("TERM", -waiter.pid)
      Process.kill("KILL", -waiter.pid) unless waiter.join(1)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def facts(doc)
      raise JSON::ParserError, "not an object" unless doc.is_a?(Hash)
      {
        "available" => true, "found" => true,
        "number" => doc["number"], "url" => doc["url"], "title" => doc["title"], "state" => doc["state"],
        "draft" => doc["isDraft"], "review_decision" => blank_to_nil(doc["reviewDecision"]),
        "mergeable" => doc["mergeable"], "checks" => checks(doc["statusCheckRollup"])
      }
    end

    def blank_to_nil(value)
      (value.nil? || value == "") ? nil : value
    end

    # Check runs carry `status` and `conclusion`; commit statuses carry `state`.
    def checks(rollup)
      entries = Array(rollup).grep(Hash)
      failed = []
      passing = pending = 0
      entries.each do |entry|
        case outcome(entry)
        when :passing then passing += 1
        when :failing then failed << (entry["name"] || entry["context"]).to_s
        else pending += 1
        end
      end
      {"total" => entries.size, "passing" => passing, "failing" => failed.size, "pending" => pending,
       "failed" => failed.first(MAX_FAILED_CHECKS)}
    end

    def outcome(entry)
      if entry.key?("state")
        return :failing if FAILED_STATES.include?(entry["state"])
        return :passing if entry["state"] == "SUCCESS"
        return :pending
      end
      return :pending unless entry["status"] == "COMPLETED"
      return :failing if FAILED_CONCLUSIONS.include?(entry["conclusion"])
      PASSED_CONCLUSIONS.include?(entry["conclusion"]) ? :passing : :pending
    end
  end
end
