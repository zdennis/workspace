module Workspace
  # What a workspace's stages are judged against: the plan file, the branch against its upstream,
  # the pull request, the review agent and the panes, mapped into {SpineEvaluator::Facts} by the
  # rules of the app's `src/core/spine/facts.ts`, so the CLI and the app read the same facts alike.
  #
  # {#read} makes the live reads for one workspace, each source at most once: the plan file, a few
  # local git calls, one daemon snapshot and one `gh pr view` read in parallel threads, and the open
  # questions. `gh` runs only when it is on the PATH and a declared gate needs it. {#facts_from} is
  # the mapping alone, for a caller that already holds the readings (the snapshot). A source that
  # can't answer leaves its fact nil, so its gates read `unchecked`; nothing here raises.
  class SpineFacts
    # Seconds `gh pr view` may take.
    GH_TIMEOUT = 5.0

    # Seconds the agent daemon may take to answer.
    DAEMON_TIMEOUT = 1.0

    # Seconds the local git reads may take in total.
    GIT_TIMEOUT = 5.0

    # The gates a pull request answers. `pushed` needs it only when git can't pass the gate.
    PR_GATES = %w[pr ci merged review].freeze

    PR_STATES = {"OPEN" => "open", "MERGED" => "merged", "CLOSED" => "closed"}.freeze
    private_constant :PR_GATES, :PR_STATES

    # What a caller already read for one workspace. A nil field was not read.
    #
    # @!attribute plan [PlanFile, Symbol, nil] the parsed plan; `:missing` when there is no plan file
    # @!attribute git [Hash, nil] `branch` (nil when detached), `upstream` (the `@{u}` ref, nil when it
    #   doesn't resolve), `upstream_configured` (whether `branch.<name>.merge` is set) and `ahead`
    #   (commits not on the upstream, nil when git couldn't count); nil when it isn't a checkout
    # @!attribute pull_request [Hash, nil] a {PullRequestStatus#call} answer
    # @!attribute panes [Array<Hash>, nil] the daemon snapshot's `panes`; nil when it didn't answer
    # @!attribute daemon_reason [String, nil] why it didn't (`no_daemon`, `timeout`, `error`)
    # @!attribute asks [Array<Hash>, nil] the open questions, each with its `pane`
    # @!attribute review_ahead [Integer, nil] commits the branch has that its base lacks
    # @!attribute review [Boolean] whether the review fact is wanted
    Readings = Struct.new(:plan, :git, :pull_request, :panes, :daemon_reason, :asks, :review_ahead, :review, keyword_init: true)

    # @!attribute facts [SpineEvaluator::Facts]
    # @!attribute sources [Hash{String => String}] `plan`, `git`, `gh`, `review`, `panes`: each `ok`,
    #   `unavailable` or `not_needed`
    # @!attribute reasons [Hash{String => String}] for a source that isn't `ok`, or a fact left nil, a
    #   stable code: `not_read`, `detached`, `upstream_gone`, `ahead_unknown`,
    #   `no_upstream`, `gh_missing`, `timeout`, `error`, `not_found`, `unknown_state`, `no_daemon`,
    #   `nothing_ahead`, `no_review_gate` (`not_read` with `gh` `not_needed`: no gate needed it, or
    #   the caller didn't read it)
    Result = Struct.new(:facts, :sources, :reasons, keyword_init: true)

    # @param git [Workspace::Git] branch, upstream and ahead reads
    # @param pull_request_status [Workspace::PullRequestStatus] the one `gh pr view`
    # @param snapshot_client [Workspace::AgentSnapshotClient] the one daemon snapshot
    # @param review [Workspace::Commands::Review] the review agent's state and the ahead-of-base count
    # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
    # @param which [#call] whether an executable is on the PATH
    # @param daemon_timeout [Numeric] seconds the daemon may take
    # @param git_timeout [Numeric] seconds the local git reads may take in total
    # @param gh_timeout [Numeric] seconds to wait for the `gh` thread; {PullRequestStatus} holds its own limit
    def initialize(git:, pull_request_status:, snapshot_client:, review:, ask_store_for:, which: Which,
      daemon_timeout: DAEMON_TIMEOUT, git_timeout: GIT_TIMEOUT, gh_timeout: GH_TIMEOUT)
      @git = git
      @pull_request_status = pull_request_status
      @snapshot_client = snapshot_client
      @review = review
      @ask_store_for = ask_store_for
      @which = which
      @daemon_timeout = daemon_timeout
      @git_timeout = git_timeout
      @gh_timeout = gh_timeout
    end

    # The live reads for one workspace, then {#facts_from}.
    #
    # @param workspace [String]
    # @param checkout [String] the workspace's checkout
    # @param notes_dir [String] where its plan file is
    # @param gates [Array<String>] every gate declared anywhere in the tree (see {.gates_in})
    # @return [Result]
    def read(workspace:, checkout:, notes_dir:, gates:)
      daemon = background { daemon_snapshot(workspace) }
      git = bounded(@git_timeout) { git_reading(checkout) }
      gh = if !gh_needed?(gates, git) then nil
      elsif @which.call("gh") then background { @pull_request_status.call(checkout) }
      else {"available" => false, "reason" => "gh_missing"}
      end
      review = gates.include?("review")
      review_ahead = review ? bounded(@git_timeout) { @review.commits_ahead_of_base(checkout) } : nil
      plan = plan_reading(notes_dir)
      asks = open_asks(workspace)
      panes, daemon_reason = join(daemon, @daemon_timeout + 0.5, timed_out: [nil, "timeout"], failed: [nil, "error"])
      if gh.is_a?(Thread)
        gh = join(gh, @gh_timeout + 1, timed_out: {"available" => false, "reason" => "timeout"},
          failed: {"available" => false, "reason" => "error"})
      end
      pull_request = gh
      facts_from(workspace, Readings.new(plan: plan, git: git, pull_request: pull_request, panes: panes,
        daemon_reason: daemon_reason, asks: asks, review_ahead: review_ahead, review: review))
    end

    # @param checkout [String] the workspace's checkout
    # @return [Integer, nil] commits the branch has that its base lacks, for {Readings#review_ahead};
    #   nil when git can't answer within the time limit
    def commits_ahead_of_base(checkout)
      bounded(@git_timeout) { @review.commits_ahead_of_base(checkout) }
    end

    # @param stages [Array<SpineTree::Stage>]
    # @return [Array<String>] the gates declared by these stages and every stage under them
    def self.gates_in(stages)
      stages.flat_map { |stage| stage.gates + gates_in(stage.children) }.uniq
    end

    # The facts.ts mapping over readings already held. It runs nothing, with one exception: when the
    # review fact is wanted and the daemon answered `no_daemon`, the review agent's last recorded states
    # are read from the event log, as `review show` does.
    #
    # @param workspace [String]
    # @param readings [Readings]
    # @return [Result]
    def facts_from(workspace, readings)
      sources = {}
      reasons = {}
      facts = SpineEvaluator::Facts.new(
        plan: plan_fact(readings.plan, sources, reasons),
        git: git_fact(readings.git, sources, reasons),
        pr: pr_fact(readings.pull_request, readings.git, sources, reasons),
        review: review_fact(workspace, readings, sources, reasons),
        panes: panes_of(readings.panes, readings.asks, readings.daemon_reason, sources, reasons)
      )
      Result.new(facts: facts, sources: sources, reasons: reasons)
    end

    private

    def plan_fact(plan, sources, reasons)
      return note(sources, reasons, "plan", "unavailable", "not_read") if plan.nil?
      sources["plan"] = "ok"
      return SpineEvaluator::PlanFact.new(exists: false, total: 0, open: 0) if plan == :missing
      counts = plan.counts
      SpineEvaluator::PlanFact.new(exists: true, total: counts["total"], open: [counts["total"] - counts["done"] - counts["skipped"], 0].max)
    end

    def git_fact(git, sources, reasons)
      return note(sources, reasons, "git", "unavailable", "not_read") if git.nil?
      # Detached: there is no branch to push.
      return note(sources, reasons, "git", "unavailable", "detached") if git["branch"].nil?
      sources["git"] = "ok"
      return SpineEvaluator::GitFact.new(upstream: false, ahead: 0) if git["upstream"].nil? && !git["upstream_configured"]
      # Deleted on the remote (usually after a merge): what is still unpushed can't be told.
      return note(sources, reasons, "git", "unavailable", "upstream_gone") if git["upstream"].nil?
      # The count failed, so whether it is pushed can't be told.
      return note(sources, reasons, "git", "unavailable", "ahead_unknown") if git["ahead"].nil?
      SpineEvaluator::GitFact.new(upstream: true, ahead: git["ahead"])
    end

    def pr_fact(pull_request, git, sources, reasons)
      return note(sources, reasons, "gh", "unavailable", "not_read") if git.nil?
      return note(sources, reasons, "gh", "unavailable", "detached") if git["branch"].nil?
      gone = git["upstream"].nil? && git["upstream_configured"]
      # Never pushed: no pull request, whatever GitHub says.
      if git["upstream"].nil? && !gone
        note(sources, reasons, "gh", "not_needed", "no_upstream")
        return SpineEvaluator::PrFact.new(state: "none", checks: "none")
      end
      return note(sources, reasons, "gh", "not_needed", "not_read") if pull_request.nil?
      # No remote, not GitHub, or a failed query: GitHub can't say.
      return note(sources, reasons, "gh", "unavailable", pull_request["reason"] || "error") unless pull_request["available"]
      sources["gh"] = "ok"
      unless pull_request["found"]
        # A remote branch deleted after its merge: whether there was a pull request can't be told.
        return note(sources, reasons, nil, nil, "not_found", key: "pr") if gone
        return SpineEvaluator::PrFact.new(state: "none", checks: "none")
      end
      state = PR_STATES[pull_request["state"]]
      return note(sources, reasons, nil, nil, "unknown_state", key: "pr") if state.nil?
      return note(sources, reasons, nil, nil, "upstream_gone", key: "pr") if gone && state != "merged"
      checks = pull_request["checks"] || {}
      SpineEvaluator::PrFact.new(state: state, checks: checks_of(checks), failing: checks["failing"], total: checks["total"])
    end

    def checks_of(checks)
      return "fail" if checks["failing"].to_i.positive?
      return "pending" if checks["pending"].to_i.positive?
      checks["passing"].to_i.positive? ? "pass" : "none"
    end

    def review_fact(workspace, readings, sources, reasons)
      return note(sources, reasons, "review", "not_needed", "no_review_gate") unless readings.review
      agent = @review.agent_facts_from(workspace, panes: readings.panes, unavailable: readings.daemon_reason)
      return note(sources, reasons, "review", "unavailable", agent["reason"] || "error") unless agent["available"]
      sources["review"] = "ok"
      # Nothing on the branch to review, as after a merge: not checked rather than failing.
      return note(sources, reasons, nil, nil, "nothing_ahead", key: "review") if readings.review_ahead == 0
      pr = readings.pull_request
      SpineEvaluator::ReviewFact.new(
        agent_done: agent["state"] == "done",
        changes_requested: !!(pr && pr["available"] && pr["found"] && pr["review_decision"] == "CHANGES_REQUESTED")
      )
    end

    def panes_of(panes, asks, daemon_reason, sources, reasons)
      return note(sources, reasons, "panes", "unavailable", daemon_reason || "not_read") if panes.nil?
      sources["panes"] = "ok"
      asked = Array(asks).group_by { |ask| ask["pane"] }
      panes.map do |pane|
        id = pane["pane_id"]
        # A shell pane can own a stage; it is there, never waiting or working.
        next SpineEvaluator::Pane.new(pane: id, waiting: false, working: false, since: nil) unless AgentProvider.find(pane["kind"].to_s)
        working = pane["state"] == "working"
        SpineEvaluator::Pane.new(pane: id, waiting: pane["state"] == "waiting" || asked.key?(id), working: working,
          since: working ? pane["state_since"] : nil)
      end
    end

    # Records why a fact is nil and returns nil; +source+ nil leaves the source's status alone.
    def note(sources, reasons, source, status, reason, key: source)
      sources[source] = status if source
      reasons[key] = reason
      nil
    end

    # A branch never pushed has no pull request, and a pushed one passes `pushed` without GitHub; only
    # a merged pull request can pass `pushed` otherwise.
    def gh_needed?(gates, git)
      return false if git.nil? || git["branch"].nil? || (git["upstream"].nil? && !git["upstream_configured"])
      gates.any? { |gate| PR_GATES.include?(gate) } || (gates.include?("pushed") && !pushed?(git))
    end

    def pushed?(git) = !git["upstream"].nil? && git["ahead"] == 0

    def git_reading(checkout)
      branch = @git.worktree_branch(checkout)
      return {"branch" => nil} unless branch
      upstream = @git.upstream_branch(checkout)
      {
        "branch" => branch, "upstream" => upstream,
        "upstream_configured" => upstream ? true : !@git.upstream_config(checkout, branch).nil?,
        "ahead" => upstream && @git.commits_ahead_of_upstream(checkout)
      }
    rescue Workspace::Error, SystemCallError
      nil
    end

    def plan_reading(notes_dir)
      plan = PlanFile.read(PlanFile.path_in(notes_dir))
      return :missing if plan.nil?
      plan unless plan.warnings.any? { |warning| warning["code"] == "unreadable" }
    end

    def open_asks(workspace)
      @ask_store_for.call(workspace).list(open_only: true)
    rescue Workspace::Error
      nil
    end

    def daemon_snapshot(workspace)
      [Array(@snapshot_client.fetch(workspace, timeout: @daemon_timeout)["panes"]), nil]
    rescue AgentSnapshotClient::Unavailable => e
      [nil, e.reason.to_s]
    rescue Workspace::Error
      [nil, "error"]
    end

    def background(&block)
      Thread.new do
        Thread.current.report_on_exception = false
        block.call
      end
    end

    # A killed thread runs its `ensure` blocks, so a git read stops its own process group
    # (`Git#capture_git`); `gh` runs under {TimedProcess}'s own limit.
    def join(thread, timeout, timed_out: nil, failed: nil)
      return thread.value if thread.join(timeout)
      thread.kill
      timed_out
    rescue
      failed
    end

    def bounded(timeout, &block) = join(background(&block), timeout)
  end
end
