require "json"
require "timeout"

module Workspace
  # Reads what reviewers and CI said about a checkout's pull request: the
  # review threads, the review summaries, the conversation comments and the
  # failing checks. It only reads, through two `gh` calls (`gh pr view` to find
  # the pull request, then one GraphQL query), and every cap is reported in
  # `truncated`. Bodies are text someone else wrote and are returned whole; the
  # caller shortens and escapes them.
  class PullRequestFeedback
    # Seconds each `gh` call may take.
    DEFAULT_TIMEOUT = 15.0

    # Most stdout read from one `gh` call.
    MAX_OUTPUT_BYTES = 8 * 1024 * 1024

    # Most pages of review summaries read.
    MAX_REVIEW_PAGES = 3

    # Review summaries with a body that end the paging.
    REVIEW_BODIES_WANTED = 30

    # A thread keeps its first this many comments and its last {LAST_COMMENTS}.
    FIRST_COMMENTS = 5
    LAST_COMMENTS = 3

    TRUSTED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze
    HOST = /\A[A-Za-z0-9.-]+\z/
    OWNER = /\A[A-Za-z0-9-]{1,39}\z/
    REPO = /\A[A-Za-z0-9._-]{1,100}\z/
    PULL_URL = %r{\Ahttps://([^/]+)/([^/]+)/([^/]+)/pull/(\d+)\z}
    NOT_LOGGED_IN = /gh auth login|not logged in|not authenticated|authentication required|bad credentials|http 401|requires authentication/i
    RATE_LIMIT = /rate limit/i
    NO_PULL_REQUEST = /no pull requests found/i
    private_constant :TRUSTED_ASSOCIATIONS, :HOST, :OWNER, :REPO, :PULL_URL, :NOT_LOGGED_IN, :RATE_LIMIT, :NO_PULL_REQUEST

    COMMENT_FIELDS = "databaseId author { login __typename } authorAssociation body createdAt url isMinimized".freeze
    private_constant :COMMENT_FIELDS

    REVIEW_FIELDS = "databaseId state body submittedAt url isMinimized authorAssociation author { login __typename }".freeze
    private_constant :REVIEW_FIELDS

    QUERY = <<~GRAPHQL.freeze
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            number url title state isDraft isCrossRepository headRefName headRefOid baseRefName reviewDecision
            author { login __typename }
            reviewThreads(last: 100) {
              totalCount
              pageInfo { hasPreviousPage }
              nodes {
                id isResolved isOutdated path line originalLine diffSide
                first: comments(first: #{FIRST_COMMENTS}) { totalCount nodes { #{COMMENT_FIELDS} } }
                latest: comments(last: #{LAST_COMMENTS}) { nodes { #{COMMENT_FIELDS} } }
              }
            }
            reviews(last: 30) {
              totalCount
              pageInfo { hasPreviousPage startCursor }
              nodes { #{REVIEW_FIELDS} }
            }
            comments(last: 30) {
              totalCount
              pageInfo { hasPreviousPage }
              nodes { #{COMMENT_FIELDS} }
            }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      totalCount
                      pageInfo { hasNextPage }
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion detailsUrl checkSuite { workflowRun { databaseId } } }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL
    private_constant :QUERY

    REVIEWS_PAGE_QUERY = <<~GRAPHQL.freeze
      query($owner: String!, $name: String!, $number: Int!, $cursor: String!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviews(last: 30, before: $cursor) {
              pageInfo { hasPreviousPage startCursor }
              nodes { #{REVIEW_FIELDS} }
            }
          }
        }
      }
    GRAPHQL
    private_constant :REVIEWS_PAGE_QUERY

    # @param runner [#call] `(args, chdir:, timeout:, max_bytes:)` returning `[stdout, stderr, success]`;
    #   defaults to {TimedProcess}
    # @param timeout [Numeric] seconds each `gh` call may take
    def initialize(runner: method(:run_gh), timeout: DEFAULT_TIMEOUT)
      @runner = runner
      @timeout = timeout
    end

    # @param path [String] the checkout; `gh` finds the pull request from its current branch
    # @param branch [String, nil] the branch name, reported in `no_pull_request`
    # @return [Hash] `{"pull_request" => {"number", "url", "title", "state", "draft", "cross_repository",
    #   "head_ref", "head_sha", "base_ref", "review_decision", "author", "author_kind"}, "threads" => [{"id",
    #   "path", "line", "original_line", "side", "resolved", "outdated", "url", "comments" => [comment],
    #   "comments_truncated"}] (resolved ones included), "reviews" => [review] (only with a body, oldest first),
    #   "comments" => [comment], "checks" => {"failed" => [{"name", "url", "run_id"}]}, "totals" => {"threads",
    #   "reviews", "comments", "checks"}, "truncated" => {"threads", "reviews", "comments", "checks"}}`. A
    #   comment is `{"id", "author", "author_kind", "author_association", "trusted", "body", "hidden_html",
    #   "created_at", "url"}`; a review has `state` and `submitted_at` instead of `created_at`. `author` is nil for
    #   a deleted account, `run_id` and every `url` are nil unless an integer or an https URL.
    # @raise [Workspace::Error] `gh_unavailable` (`details.reason` `missing`), `no_pull_request`
    #   (`details.branch`), or `pr_feedback_failed` (`details.reason` `timeout`, `auth`, `rate_limit`, `graphql`
    #   or `other`, and `details.detail`)
    def call(path, branch: nil)
      raise failed("other", "checkout not found: #{path}") unless Dir.exist?(path)
      owner, host, name, number = locate(path, branch)
      pull = fetch_pull(path, host, owner, name, number)
      reviews, reviews_truncated = collect_reviews(path, host, owner, name, number, pull["reviews"])
      assemble(pull, reviews, reviews_truncated)
    rescue Errno::ENOENT
      raise Workspace::Error.new("gh is not installed. Install it from https://cli.github.com, then run 'gh auth login'.",
        code: "gh_unavailable", details: {"reason" => "missing"})
    rescue Timeout::Error
      raise failed("timeout", "gh did not answer within #{@timeout} seconds", retry_with: {"flags" => [], "destructive" => false})
    rescue TimedProcess::OutputTooLarge => e
      raise failed("other", e.message)
    end

    private

    def run_gh(args, chdir:, timeout:, max_bytes:)
      TimedProcess.run(["gh", *args], chdir: chdir, timeout: timeout, max_bytes: max_bytes)
    end

    def gh(args, path)
      @runner.call(args, chdir: path, timeout: @timeout, max_bytes: MAX_OUTPUT_BYTES)
    end

    def failed(reason, detail, retry_with: nil)
      Workspace::Error.new("Could not read the pull request feedback: #{detail}", code: "pr_feedback_failed",
        details: {"reason" => reason, "detail" => detail.to_s[0, 200]}, retry_with: retry_with)
    end

    def first_line(text)
      text.to_s.scrub.lines.map(&:strip).find { |line| !line.empty? }.to_s[0, 200]
    end

    def failure_from(stdout, stderr)
      said = stderr.to_s
      detail = first_line(stderr)
      detail = first_line(stdout) if detail.empty?
      return failed("auth", detail) if said.match?(NOT_LOGGED_IN)
      return failed("rate_limit", detail) if said.match?(RATE_LIMIT)
      failed("other", detail.empty? ? "gh failed" : detail)
    end

    # @return [Array(String, String, String, Integer)] owner, host, name, number
    def locate(path, branch)
      stdout, stderr, success = gh(["pr", "view", "--json", "number,url"], path)
      unless success
        if stderr.to_s.match?(NO_PULL_REQUEST)
          raise Workspace::Error.new("No pull request found for branch '#{branch}'.", code: "no_pull_request",
            details: {"branch" => branch})
        end
        raise failure_from(stdout, stderr)
      end
      url = parse_json(stdout)["url"].to_s
      match = PULL_URL.match(url)
      raise failed("graphql", "unreadable pull request URL") unless match
      host, owner, name, number = match.captures
      unless host.match?(HOST) && owner.match?(OWNER) && name.match?(REPO)
        raise failed("graphql", "unreadable pull request URL")
      end
      [owner, host, name, Integer(number, 10)]
    end

    def parse_json(text)
      doc = JSON.parse(text.to_s)
      raise JSON::ParserError, "not an object" unless doc.is_a?(Hash)
      doc
    rescue JSON::ParserError
      raise failed("graphql", "unreadable reply from gh")
    end

    def graphql(path, host, owner, name, number, query, extra = {})
      args = ["api", "graphql", "--hostname", host, "-f", "owner=#{owner}", "-f", "name=#{name}",
        "-F", "number=#{number}"]
      extra.each { |key, value| args.push("-f", "#{key}=#{value}") }
      args.push("-f", "query=#{query}")
      stdout, stderr, success = gh(args, path)
      doc = begin
        JSON.parse(stdout.to_s)
      rescue JSON::ParserError
        nil
      end
      if doc.is_a?(Hash) && doc["errors"]
        raise failure_from(stdout, stderr) if stderr.to_s.match?(NOT_LOGGED_IN) || stderr.to_s.match?(RATE_LIMIT)
        message = Array(doc["errors"]).map { |error| error.is_a?(Hash) ? error["message"] : error }.first.to_s
        detail = message.empty? ? "GraphQL errors" : message[0, 200]
        rate_limited = Array(doc["errors"]).any? { |error| error.is_a?(Hash) && error["type"] == "RATE_LIMITED" }
        raise failed(rate_limited ? "rate_limit" : "graphql", detail)
      end
      raise failure_from(stdout, stderr) unless success
      pull = doc.is_a?(Hash) ? doc.dig("data", "repository", "pullRequest") : nil
      raise failed("graphql", "unreadable reply from gh") unless pull.is_a?(Hash)
      pull
    end

    def fetch_pull(path, host, owner, name, number)
      graphql(path, host, owner, name, number, QUERY)
    end

    # Pages back through the review summaries until enough have a body.
    # @return [Array(Array<Hash>, Boolean)] the review nodes, oldest first, and whether older ones were left out
    def collect_reviews(path, host, owner, name, number, first_page)
      nodes = Array(first_page&.dig("nodes")).grep(Hash)
      info = first_page&.dig("pageInfo") || {}
      pages = 1
      while info["hasPreviousPage"] && pages < MAX_REVIEW_PAGES && nodes.count { |node| body?(node) } < REVIEW_BODIES_WANTED
        page = graphql(path, host, owner, name, number, REVIEWS_PAGE_QUERY, "cursor" => info["startCursor"])["reviews"]
        return [nodes, true] unless page.is_a?(Hash)
        nodes = Array(page["nodes"]).grep(Hash) + nodes
        info = page&.dig("pageInfo") || {}
        pages += 1
      end
      [nodes, info["hasPreviousPage"] == true]
    end

    def body?(node)
      !node["isMinimized"] && !node["body"].to_s.strip.empty?
    end

    def assemble(pull, reviews, reviews_truncated)
      threads = pull["reviewThreads"] || {}
      comments = pull["comments"] || {}
      contexts = pull.dig("commits", "nodes", 0, "commit", "statusCheckRollup", "contexts") || {}
      failed_checks = failing_checks(contexts["nodes"])
      {
        "pull_request" => pull_request(pull),
        "threads" => Array(threads["nodes"]).grep(Hash).map { |thread| thread(thread) },
        "reviews" => reviews.select { |review| body?(review) }.map { |review| review(review) },
        "comments" => Array(comments["nodes"]).grep(Hash).reject { |comment| comment["isMinimized"] }.map { |comment| comment(comment) },
        "checks" => {"failed" => failed_checks.first(PullRequestStatus::MAX_FAILED_CHECKS)},
        "totals" => {"threads" => threads["totalCount"], "reviews" => pull.dig("reviews", "totalCount"),
                     "comments" => comments["totalCount"], "checks" => contexts["totalCount"]},
        "truncated" => {
          "threads" => threads.dig("pageInfo", "hasPreviousPage") == true,
          "reviews" => reviews_truncated,
          "comments" => comments.dig("pageInfo", "hasPreviousPage") == true,
          "checks" => contexts.dig("pageInfo", "hasNextPage") == true || failed_checks.size > PullRequestStatus::MAX_FAILED_CHECKS
        }
      }
    end

    def pull_request(pull)
      {
        "number" => pull["number"], "url" => https(pull["url"]), "title" => pull["title"], "state" => pull["state"],
        "draft" => pull["isDraft"], "cross_repository" => pull["isCrossRepository"], "head_ref" => pull["headRefName"],
        "head_sha" => pull["headRefOid"], "base_ref" => pull["baseRefName"],
        "review_decision" => (pull["reviewDecision"].to_s.empty? ? nil : pull["reviewDecision"])
      }.merge(person(pull["author"]))
    end

    def person(author)
      author = {} unless author.is_a?(Hash)
      {"author" => author["login"], "author_kind" => {"Bot" => "bot"}.fetch(author["__typename"], author["login"] ? "user" : nil)}
    end

    def trust(node)
      association = node["authorAssociation"]
      {"author_association" => association, "trusted" => TRUSTED_ASSOCIATIONS.include?(association)}
    end

    def body_fields(node)
      body = node["body"].to_s
      {"body" => body, "hidden_html" => body.include?("<!--")}
    end

    def comment(node)
      {"id" => node["databaseId"]}.merge(person(node["author"]), trust(node), body_fields(node),
        "created_at" => node["createdAt"], "url" => https(node["url"]))
    end

    def review(node)
      {"id" => node["databaseId"], "state" => node["state"]}.merge(person(node["author"]), trust(node), body_fields(node),
        "submitted_at" => node["submittedAt"], "url" => https(node["url"]))
    end

    # A thread's first comments and last comments joined by comment id, minimized ones left out.
    def thread(node)
      first = node["first"] || {}
      joined = (Array(first["nodes"]) + Array(node.dig("latest", "nodes"))).grep(Hash).uniq { |c| c["databaseId"] }
      {
        "id" => node["id"], "path" => node["path"], "line" => node["line"], "original_line" => node["originalLine"],
        "side" => node["diffSide"], "resolved" => node["isResolved"] == true, "outdated" => node["isOutdated"] == true,
        "url" => https(Array(first["nodes"]).first&.dig("url")),
        "comments" => joined.reject { |c| c["isMinimized"] }.map { |c| comment(c) },
        "comments_truncated" => first["totalCount"].to_i > FIRST_COMMENTS + LAST_COMMENTS
      }
    end

    def failing_checks(nodes)
      Array(nodes).grep(Hash).select { |entry| PullRequestStatus.outcome(entry) == :failing }.map do |entry|
        run_id = entry.dig("checkSuite", "workflowRun", "databaseId")
        {"name" => (entry["name"] || entry["context"]).to_s, "url" => https(entry["detailsUrl"] || entry["targetUrl"]),
         "run_id" => run_id.is_a?(Integer) ? run_id : nil}
      end
    end

    def https(url)
      (url.is_a?(String) && url.start_with?("https://")) ? url : nil
    end
  end
end
