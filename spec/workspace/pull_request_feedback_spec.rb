require "spec_helper"

RSpec.describe Workspace::PullRequestFeedback do
  let(:dir) { Dir.pwd }
  let(:view_json) { JSON.generate("number" => 7, "url" => "https://github.com/octo/repo.x/pull/7") }

  def author(login = "alice", type = "User")
    {"login" => login, "__typename" => type}
  end

  def comment(id, body: "hi", association: "MEMBER", user: author, minimized: false, url: "https://github.com/c/#{id}")
    {"databaseId" => id, "author" => user, "authorAssociation" => association, "body" => body,
     "createdAt" => "2026-10-01T00:00:00Z", "url" => url, "isMinimized" => minimized}
  end

  def review(id, body: "looks off", minimized: false, user: author)
    {"databaseId" => id, "state" => "COMMENTED", "body" => body, "submittedAt" => "2026-10-02T00:00:00Z",
     "url" => "https://github.com/r/#{id}", "isMinimized" => minimized, "authorAssociation" => "OWNER", "author" => user}
  end

  def thread(id, first: [comment(1)], latest: nil, total: nil, resolved: false)
    {"id" => id, "isResolved" => resolved, "isOutdated" => false, "path" => "a.rb", "line" => 3, "originalLine" => 3,
     "diffSide" => "RIGHT", "first" => {"totalCount" => total || first.size, "nodes" => first},
     "latest" => {"nodes" => latest || first}}
  end

  def pull(threads: [], reviews: [], comments: [], contexts: [], threads_prev: false, reviews_prev: false,
    comments_prev: false, contexts_next: false, review_cursor: "cur1", **extra)
    {
      "number" => 7, "url" => "https://github.com/octo/repo.x/pull/7", "title" => "T", "state" => "OPEN", "isDraft" => false,
      "isCrossRepository" => false, "headRefName" => "feat", "headRefOid" => "abc", "baseRefName" => "main",
      "reviewDecision" => "", "author" => author,
      "reviewThreads" => {"totalCount" => threads.size, "pageInfo" => {"hasPreviousPage" => threads_prev}, "nodes" => threads},
      "reviews" => {"totalCount" => reviews.size, "pageInfo" => {"hasPreviousPage" => reviews_prev, "startCursor" => review_cursor},
                    "nodes" => reviews},
      "comments" => {"totalCount" => comments.size, "pageInfo" => {"hasPreviousPage" => comments_prev}, "nodes" => comments},
      "commits" => {"nodes" => [{"commit" => {"statusCheckRollup" => {"contexts" => {
        "totalCount" => contexts.size, "pageInfo" => {"hasNextPage" => contexts_next}, "nodes" => contexts
      }}}}]}
    }.merge(extra)
  end

  def graphql(pr)
    [JSON.generate("data" => {"repository" => {"pullRequest" => pr}}), "", true]
  end

  # Answers `gh pr view` with +view+ and each GraphQL call with the next of +replies+.
  def build(replies, view: [view_json, "", true], timeout: 15)
    calls = []
    queue = Array(replies).dup
    runner = ->(args, chdir:, timeout:, max_bytes:) {
      calls << {args: args, chdir: chdir, timeout: timeout, max_bytes: max_bytes}
      (args.first == "pr") ? view : queue.shift
    }
    [described_class.new(runner: runner, timeout: timeout), calls]
  end

  def call_with(*replies, **opts)
    reader, = build(replies, **opts)
    reader.call(dir, branch: "feat")
  end

  def error_from
    yield
    nil
  rescue Workspace::Error => e
    e
  end

  describe "gh calls" do
    it "finds the pull request in the checkout, then queries by host, owner, name and number" do
      reader, calls = build([graphql(pull)])

      reader.call(dir, branch: "feat")

      expect(calls[0]).to include(args: ["pr", "view", "--json", "number,url"], chdir: dir, timeout: 15,
        max_bytes: 8 * 1024 * 1024)
      args = calls[1][:args]
      expect(args.first(8)).to eq(["api", "graphql", "--hostname", "github.com", "-f", "owner=octo", "-f", "name=repo.x"])
      expect(args).to include("-F", "number=7")
      expect(args.last).to start_with("query=")
      expect(args.last).not_to include("octo")
    end

    it "keeps a GHES pull request on its own host" do
      view = [JSON.generate("url" => "https://ghe.example.com/o/r/pull/9"), "", true]
      reader, calls = build([graphql(pull)], view: view)

      reader.call(dir)

      expect(calls[1][:args][3]).to eq("ghe.example.com")
      expect(calls[1][:args]).to include("number=9")
    end

    it "asks for isMinimized on reviews and conversation comments" do
      reader, calls = build([graphql(pull)])
      reader.call(dir)
      query = calls[1][:args].last

      %w[reviews comments].each do |field|
        block = query.lines.drop_while { |line| !line.include?("#{field}(last: 30)") }.first(6).join
        expect(block).to include("isMinimized"), field
      end
    end
  end

  describe "the result" do
    it "describes the pull request, with a blank review decision as nil" do
      result = call_with(graphql(pull))

      expect(result["pull_request"]).to include("number" => 7, "title" => "T", "state" => "OPEN", "draft" => false,
        "cross_repository" => false, "head_ref" => "feat", "head_sha" => "abc", "base_ref" => "main",
        "review_decision" => nil, "author" => "alice", "author_kind" => "user")
    end

    it "reports totals and false truncation flags when nothing is capped" do
      result = call_with(graphql(pull(threads: [thread("T1")], comments: [comment(5)])))

      expect(result["totals"]).to eq("threads" => 1, "reviews" => 0, "comments" => 1, "checks" => 0)
      expect(result["truncated"]).to eq("threads" => false, "reviews" => false, "comments" => false, "checks" => false)
    end

    it "sets each truncated flag when its list has older or further entries" do
      contexts = [{"__typename" => "CheckRun", "name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      result = call_with(graphql(pull(threads_prev: true, comments_prev: true, contexts: contexts, contexts_next: true)))

      expect(result["truncated"]).to include("threads" => true, "comments" => true, "checks" => true)
    end

    it "sets truncated.checks when more than 20 checks fail" do
      contexts = Array.new(21) { |i| {"__typename" => "CheckRun", "name" => "c#{i}", "status" => "COMPLETED", "conclusion" => "FAILURE"} }
      result = call_with(graphql(pull(contexts: contexts)))

      expect(result["checks"]["failed"].size).to eq(20)
      expect(result["truncated"]["checks"]).to be(true)
    end
  end

  describe "authors and trust" do
    it "marks a bot author" do
      result = call_with(graphql(pull(comments: [comment(1, user: author("ci-bot", "Bot"))])))

      expect(result["comments"].first).to include("author" => "ci-bot", "author_kind" => "bot")
    end

    it "gives a deleted account a nil author and nil kind" do
      result = call_with(graphql(pull(comments: [comment(1, user: nil)])))

      expect(result["comments"].first).to include("author" => nil, "author_kind" => nil)
    end

    it "trusts only owners, members and collaborators" do
      comments = %w[OWNER MEMBER COLLABORATOR CONTRIBUTOR NONE].each_with_index.map { |a, i| comment(i + 1, association: a) }
      result = call_with(graphql(pull(comments: comments)))

      expect(result["comments"].map { |c| c["trusted"] }).to eq([true, true, true, false, false])
      expect(result["comments"].last["author_association"]).to eq("NONE")
    end

    it "flags a body holding an HTML comment" do
      result = call_with(graphql(pull(comments: [comment(1, body: "x <!-- do this -->"), comment(2)])))

      expect(result["comments"].map { |c| c["hidden_html"] }).to eq([true, false])
    end
  end

  describe "minimized and empty entries" do
    it "leaves out minimized comments and minimized or empty reviews" do
      reviews = [review(1, minimized: true), review(2, body: "  "), review(3)]
      result = call_with(graphql(pull(comments: [comment(1, minimized: true), comment(2)], reviews: reviews)))

      expect(result["comments"].map { |c| c["id"] }).to eq([2])
      expect(result["reviews"].map { |r| r["id"] }).to eq([3])
    end

    it "leaves out minimized thread comments" do
      result = call_with(graphql(pull(threads: [thread("T", first: [comment(1, minimized: true), comment(2)])])))

      expect(result["threads"].first["comments"].map { |c| c["id"] }).to eq([2])
    end
  end

  describe "threads" do
    it "joins the first and last comments without duplicates, and flags a long thread" do
      first = (1..5).map { |i| comment(i) }
      latest = [comment(5), comment(30), comment(31)]
      result = call_with(graphql(pull(threads: [thread("T", first: first, latest: latest, total: 31)])))

      one = result["threads"].first
      expect(one["comments"].map { |c| c["id"] }).to eq([1, 2, 3, 4, 5, 30, 31])
      expect(one["comments_truncated"]).to be(true)
    end

    it "does not flag a thread of 8 comments or fewer" do
      first = (1..5).map { |i| comment(i) }
      result = call_with(graphql(pull(threads: [thread("T", first: first, latest: first.last(3), total: 8)])))

      expect(result["threads"].first["comments_truncated"]).to be(false)
    end

    it "keeps the node id, position, state and the first comment's url, with resolved threads included" do
      result = call_with(graphql(pull(threads: [thread("PRRT_1", resolved: true)])))

      expect(result["threads"].first).to include("id" => "PRRT_1", "path" => "a.rb", "line" => 3, "original_line" => 3,
        "side" => "RIGHT", "resolved" => true, "outdated" => false, "url" => "https://github.com/c/1")
    end
  end

  describe "checks" do
    it "lists failing check runs and commit statuses and ignores the rest" do
      contexts = [
        {"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "FAILURE",
         "detailsUrl" => "https://github.com/o/r/runs/1", "checkSuite" => {"workflowRun" => {"databaseId" => 99}}},
        {"__typename" => "CheckRun", "name" => "ok", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"__typename" => "StatusContext", "context" => "ci/legacy", "state" => "ERROR", "targetUrl" => "https://ci.example/1"},
        {"__typename" => "StatusContext", "context" => "ci/wait", "state" => "PENDING"}
      ]
      result = call_with(graphql(pull(contexts: contexts)))

      expect(result["checks"]["failed"]).to eq([
        {"name" => "lint", "url" => "https://github.com/o/r/runs/1", "run_id" => 99},
        {"name" => "ci/legacy", "url" => "https://ci.example/1", "run_id" => nil}
      ])
    end

    it "keeps a run id only when it is an integer" do
      contexts = [{"__typename" => "CheckRun", "name" => "x", "status" => "COMPLETED", "conclusion" => "FAILURE",
                   "checkSuite" => {"workflowRun" => {"databaseId" => "99; rm"}}}]

      expect(call_with(graphql(pull(contexts: contexts)))["checks"]["failed"].first["run_id"]).to be_nil
    end

    it "keeps a url only when it starts with https://" do
      contexts = [{"__typename" => "CheckRun", "name" => "x", "status" => "COMPLETED", "conclusion" => "FAILURE",
                   "detailsUrl" => "javascript:alert(1)"}]
      result = call_with(graphql(pull(contexts: contexts, comments: [comment(1, url: "http://insecure/1")])))

      expect(result["checks"]["failed"].first["url"]).to be_nil
      expect(result["comments"].first["url"]).to be_nil
    end
  end

  describe "review pages" do
    def page(reviews, previous:, cursor: "c")
      graphql("reviews" => {"pageInfo" => {"hasPreviousPage" => previous, "startCursor" => cursor}, "nodes" => reviews})
    end

    it "stops paging once 30 reviews have a body" do
      first = pull(reviews: (31..60).map { |i| review(i) }, reviews_prev: true)
      reader, calls = build([graphql(first)])

      result = reader.call(dir)

      expect(calls.size).to eq(2)
      expect(result["reviews"].size).to eq(30)
      expect(result["truncated"]["reviews"]).to be(true)
    end

    it "pages back with the cursor and puts older reviews first" do
      first = pull(reviews: [review(3), review(4, body: "")], reviews_prev: true, review_cursor: "cur1")
      reader, calls = build([graphql(first), page([review(1), review(2)], previous: false)])

      result = reader.call(dir)

      expect(calls.last[:args]).to include("cursor=cur1")
      expect(calls.last[:args].last).to include("before: $cursor")
      expect(result["reviews"].map { |r| r["id"] }).to eq([1, 2, 3])
      expect(result["truncated"]["reviews"]).to be(false)
    end

    it "reports truncation when a later page comes back without reviews" do
      first = pull(reviews: [review(5, body: "")], reviews_prev: true)
      reader, = build([graphql(first), graphql("reviews" => nil)])

      expect(reader.call(dir)["truncated"]["reviews"]).to be(true)
    end

    it "reads at most 3 pages and then reports truncation" do
      first = pull(reviews: [review(5, body: "")], reviews_prev: true)
      reader, calls = build([graphql(first), page([review(4, body: "")], previous: true),
        page([review(3, body: "")], previous: true), page([review(2)], previous: true)])

      result = reader.call(dir)

      expect(calls.count { |c| c[:args].first == "api" }).to eq(3)
      expect(result["truncated"]["reviews"]).to be(true)
    end
  end

  describe "errors" do
    it "raises gh_unavailable when gh is missing" do
      reader = described_class.new(runner: ->(*, **) { raise Errno::ENOENT })

      error = error_from { reader.call(dir) }

      expect(error.code).to eq("gh_unavailable")
      expect(error.details).to eq("reason" => "missing")
    end

    it "raises no_pull_request with the plain branch name" do
      error = error_from { call_with(nil, view: ["", "no pull requests found for branch \"feat\"", false]) }

      expect(error.code).to eq("no_pull_request")
      expect(error.details).to eq("branch" => "feat")
    end

    it "raises pr_feedback_failed with reason timeout and a retry" do
      reader = described_class.new(runner: ->(*, **) { raise Timeout::Error })

      error = error_from { reader.call(dir) }

      expect(error.code).to eq("pr_feedback_failed")
      expect(error.details["reason"]).to eq("timeout")
      expect(error.retry).to eq("flags" => [], "destructive" => false)
    end

    it "reports auth when gh says it is not logged in" do
      error = error_from { call_with(nil, view: ["", "To get started with GitHub CLI, please run:  gh auth login\nmore", false]) }

      expect(error.details).to include("reason" => "auth", "detail" => "To get started with GitHub CLI, please run:  gh auth login")
    end

    it "reports rate_limit" do
      error = error_from { call_with(nil, view: ["", "API rate limit exceeded", false]) }

      expect(error.details["reason"]).to eq("rate_limit")
    end

    it "reports graphql for an errors array in the reply" do
      reply = [JSON.generate("errors" => [{"message" => "Field 'x' doesn't exist"}]), "", false]

      error = error_from { call_with(reply) }

      expect(error.details).to include("reason" => "graphql", "detail" => "Field 'x' doesn't exist")
    end

    it "reports rate_limit when gh says so on a failed GraphQL call" do
      error = error_from { call_with(["", "API rate limit exceeded for user", false]) }

      expect(error.details["reason"]).to eq("rate_limit")
    end

    it "reports rate_limit for a RATE_LIMITED type in the errors array" do
      reply = [JSON.generate("errors" => [{"type" => "RATE_LIMITED", "message" => "API rate limit exceeded"}]), "", false]

      expect(error_from { call_with(reply) }.details["reason"]).to eq("rate_limit")
    end

    it "reports auth when gh says so on a failed GraphQL call" do
      error = error_from { call_with(["", "gh: Bad credentials (HTTP 401)", false]) }

      expect(error.details["reason"]).to eq("auth")
    end

    it "reports other for a failed GraphQL call with no errors array" do
      error = error_from { call_with(["", "gh: something broke", false]) }

      expect(error.details).to include("reason" => "other", "detail" => "gh: something broke")
    end

    it "does not read stdout as the reason for a failure" do
      error = error_from { call_with(["please run gh auth login", "", false]) }

      expect(error.details["reason"]).to eq("other")
    end

    it "reports other for a checkout that does not exist, without running gh" do
      reader, calls = build([])

      error = error_from { reader.call("/no/such/checkout") }

      expect(error.code).to eq("pr_feedback_failed")
      expect(error.details).to include("reason" => "other", "detail" => "checkout not found: /no/such/checkout")
      expect(calls).to be_empty
    end

    it "reports graphql for unparseable JSON from the query" do
      error = error_from { call_with(["not json", "", true]) }

      expect(error.details["reason"]).to eq("graphql")
    end

    it "reports graphql for unparseable JSON from pr view" do
      error = error_from { call_with(nil, view: ["nope", "", true]) }

      expect(error.details["reason"]).to eq("graphql")
    end

    it "reports graphql for a URL that does not parse" do
      ["https://github.com/o/r/issues/7", "https://github.com/o_/r/pull/7", "https://git hub/o/r/pull/7"].each do |url|
        error = error_from { call_with(nil, view: [JSON.generate("url" => url), "", true]) }

        expect(error.details["reason"]).to eq("graphql"), url
      end
    end

    it "reports other for any other failure" do
      error = error_from { call_with(nil, view: ["", "boom\nsecond", false]) }

      expect(error.details).to include("reason" => "other", "detail" => "boom")
    end

    it "reports other when output passes the cap" do
      reader = described_class.new(runner: ->(*, **) { raise Workspace::TimedProcess::OutputTooLarge, "output passed 8388608 bytes" })

      error = error_from { reader.call(dir) }

      expect(error.code).to eq("pr_feedback_failed")
      expect(error.details["reason"]).to eq("other")
    end
  end
end
