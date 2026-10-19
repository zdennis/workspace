module Workspace
  # The verdict on a workspace's stages: a port of the app's `src/core/spine/model.ts`, so the CLI
  # and the app judge a stage alike. Each stage's file status is a claim; the gates it declares, its
  # `## Done when` list and its sub-stages are the evidence. Evidence can hold a `completed` claim
  # back (`disputed`), or say a stage not marked completed looks done (`looks_completed`), which never
  # moves it.
  #
  # Pure: it reads only the {SpineTree} and a {Facts} value, and runs nothing. A fact that is nil was
  # not read, and every gate that needs it is `unchecked`; `pending` and `unchecked` never dispute.
  #
  # A stage that has opted in to a check (see {SpineFile#check}) and claims `completed` reads `checking`
  # until a verdict (no `passed` yet) and `check_failed` after a `failed` one. A dispute outranks both:
  # evidence against the claim is shown first, and the check is still reported in `check`. Neither state is
  # done, so `current`, `waits_on` and the roll-up hold the stage back.
  module SpineEvaluator
    # What one evaluation is checked against. Every field may be nil: not read, or unknown.
    #
    # @!attribute plan [PlanFact, nil] the workspace's plan file
    # @!attribute git [GitFact, nil] the branch against its upstream; nil also when the remote branch
    #   is gone or the ahead count could not be read
    # @!attribute pr [PrFact, nil] the branch's pull request; nil when GitHub can't say
    # @!attribute review [ReviewFact, nil] the review agent and the pull request's review decision;
    #   nil when the agent's state can't be read or there is nothing to review (0 ahead)
    # @!attribute panes [Array<Pane>, nil] the workspace's panes, agent and shell; nil when the
    #   daemon didn't answer
    Facts = Struct.new(:plan, :git, :pr, :review, :panes, keyword_init: true)

    # @!attribute exists [Boolean] whether the plan file exists
    # @!attribute total [Integer] tasks
    # @!attribute open [Integer] tasks neither done nor skipped
    PlanFact = Struct.new(:exists, :total, :open, keyword_init: true)

    # @!attribute upstream [Boolean] whether an upstream is configured (false: never pushed)
    # @!attribute ahead [Integer] commits not on the upstream
    GitFact = Struct.new(:upstream, :ahead, keyword_init: true)

    # @!attribute state [String] `none` (no pull request yet), `open`, `merged` or `closed`
    # @!attribute checks [String] `none`, `pending`, `pass` or `fail`
    # @!attribute failing [Integer, nil] failing checks, for the words only
    # @!attribute total [Integer, nil] all checks, for the words only
    PrFact = Struct.new(:state, :checks, :failing, :total, keyword_init: true)

    # @!attribute agent_done [Boolean] the review agent's state is `done`
    # @!attribute changes_requested [Boolean] the pull request's review decision is `CHANGES_REQUESTED`
    ReviewFact = Struct.new(:agent_done, :changes_requested, keyword_init: true)

    # @!attribute pane [String] tmux pane id, e.g. `%6`
    # @!attribute waiting [Boolean] waits on a person (a waiting state or an open question)
    # @!attribute working [Boolean]
    # @!attribute since [Object, nil] when it started working, passed through as `owner_since`
    Pane = Struct.new(:pane, :waiting, :working, :since, keyword_init: true)

    PANE_ID = /\A%\d+\z/
    DONE = %w[completed skipped].freeze
    GATE_NAMES = {
      "plan" => "The plan", "checklist" => "The checklist", "pushed" => "The push", "pr" => "The pull request",
      "ci" => "CI", "merged" => "The merge", "review" => "The review"
    }.freeze
    # How a failing gate reads after "Marked completed, but".
    DISPUTE_WORDS = {
      "no_plan" => "there is no plan file", "no_tasks" => "the plan has no tasks",
      "tasks_open" => "the plan has open tasks", "no_criteria" => "there are no Done when items",
      "unticked" => "Done when items are unticked", "no_upstream" => "the branch was never pushed",
      "ahead" => "the branch has unpushed commits", "no_pr" => "there is no pull request",
      "pr_open" => "the pull request is not merged", "pr_closed" => "the pull request was closed",
      "checks_failing" => "CI is failing", "review_running" => "the review agent hasn't finished",
      "changes_requested" => "changes were requested on the pull request"
    }.freeze
    private_constant :PANE_ID, :DONE, :GATE_NAMES, :DISPUTE_WORDS

    # @param tree [SpineTree]
    # @param facts [Facts]
    # @return [Hash] {SpineTree#to_h} with every stage evaluated (see {.evaluate_stages}), plus
    #   `evaluated: true` and `current` (the first top-level stage not done, by path, or nil)
    def self.call(tree, facts = Facts.new)
      stages = evaluate_stages(tree.stages, facts)
      tree.to_h.merge("stages" => stages, "evaluated" => true, "current" => current(stages))
    end

    # @param stages [Array<SpineTree::Stage>] one level of stages, in order
    # @param facts [Facts]
    # @return [Array<Hash>] each {SpineTree::Stage#to_h} plus `state`, `from_sub_stages`,
    #   `looks_completed`, `gate_results`, `disputes`, `waits_on`, `owner_state`, `owner_since`,
    #   `checker`, `checker_state`, `dimmed` and `current`; `rollup` is over the children's evaluated states, and `children` are
    #   evaluated the same way
    def self.evaluate_stages(stages, facts = Facts.new) = level(stages, facts, false)

    # @param docs [Array<Hash>] one level of evaluated stages
    # @return [String, nil] the path of the first whose evaluated state is not `completed` or `skipped`
    def self.current(docs) = docs.find { |doc| !DONE.include?(doc["state"]) }&.fetch("path")

    # @param gate [String] one of {SpineTree::GATES}
    # @param done_when [Hash] the stage's `done_when` (`total`, `done`)
    # @param facts [Facts]
    # @return [Hash] `gate`, `result` (`pass`, `fail`, `pending`, `unchecked`), `reason` (a stable code) and `message`
    def self.gate_result(gate, done_when, facts)
      result, reason, message = check(gate, done_when, facts)
      {"gate" => gate, "result" => result, "reason" => reason, "message" => message}
    end

    def self.level(stages, facts, dimmed)
      docs = stages.map { |stage| evaluate(stage, facts, dimmed) }
      first = {}
      docs.each { |doc| first[doc["id"]] ||= doc }
      docs.each do |doc|
        doc["waits_on"] = doc["depends_on"].select { |id| first[id] && !DONE.include?(first[id]["state"]) }
      end
    end

    def self.evaluate(stage, facts, dimmed)
      doc = stage.to_h
      status = stage.status
      children = level(stage.children, facts, dimmed || status == "skipped")
      rollup = children.empty? ? nil : SpineRollup.call(children.map { |child| child["state"] })
      from_sub_stages = status == "unknown" && !rollup.nil?
      effective = SpineRollup.effective(status, rollup)
      gates = stage.gates.map { |gate| gate_result(gate, doc["done_when"], facts) }

      done, total = doc["done_when"].values_at("done", "total")
      criteria_open = total.positive? && done < total
      open = rollup ? rollup["total"] - rollup["done"] : 0

      disputes = []
      if effective == "completed"
        gates.each do |gate|
          next unless gate["result"] == "fail"
          next if gate["gate"] == "checklist" && criteria_open
          disputes << {"kind" => "gate", "gate" => gate["gate"], "message" => "Marked completed, but #{DISPUTE_WORDS.fetch(gate["reason"])}"}
        end
        disputes << {"kind" => "done_when", "done" => done, "total" => total, "message" => "Marked completed, but #{done} of #{total} Done when items are ticked"} if criteria_open
        disputes << {"kind" => "sub_stages", "open" => open, "total" => rollup["total"], "message" => "Marked completed, but #{open} of #{rollup["total"]} sub-stages are open"} if open.positive?
      end

      evidence = !gates.empty? || total.positive? || rollup&.fetch("status") == "completed"
      looks_completed = %w[not_started in_progress].include?(effective) && evidence &&
        gates.all? { |gate| gate["result"] == "pass" } && !criteria_open && open.zero?
      owner_state, owner_since = owner(doc["owner"], facts)
      checker = checker_of(doc["checked_by"])
      checker_state, = owner(checker, facts)
      state = if !disputes.empty? then "disputed"
      elsif stage.check_failed? then "check_failed"
      elsif stage.awaiting_check? then "checking"
      else effective
      end

      doc.delete("children")
      doc.delete("rollup")
      doc["rollup"] = rollup if rollup
      doc.merge(
        "state" => state, "from_sub_stages" => from_sub_stages,
        "looks_completed" => looks_completed, "gate_results" => gates, "disputes" => disputes, "waits_on" => [],
        "owner_state" => owner_state, "owner_since" => owner_since, "checker" => checker, "checker_state" => checker_state, "dimmed" => dimmed,
        "current" => current(children), "children" => children
      )
    end

    # The pane id in a `checked_by` label (`claude %27` is `%27`), else the label as written.
    def self.checker_of(label)
      return nil if label.nil?
      label[/(?<![\w%])%\d+\b/] || label
    end

    def self.owner(owner, facts)
      return [nil, nil] unless owner&.match?(PANE_ID)
      return ["unknown", nil] if facts.panes.nil?
      pane = facts.panes.find { |p| p.pane == owner }
      return ["gone", nil] unless pane
      return ["waiting", nil] if pane.waiting
      return ["working", pane.since] if pane.working
      ["idle", nil]
    end

    def self.check(gate, done_when, facts)
      case gate
      when "plan" then check_plan(facts.plan)
      when "checklist" then check_checklist(done_when)
      when "pushed" then check_pushed(facts)
      when "pr" then check_pr(facts.pr)
      when "ci" then check_ci(facts.pr)
      when "merged" then check_merged(facts.pr)
      when "review" then check_review(facts.review)
      end
    end

    def self.unread(gate) = ["unchecked", "not_read", "#{GATE_NAMES.fetch(gate)} wasn't checked"]

    def self.check_plan(plan)
      return unread("plan") if plan.nil?
      return ["fail", "no_plan", "No plan file"] unless plan.exists
      return ["fail", "no_tasks", "The plan has no tasks"] if plan.total.zero?
      return ["fail", "tasks_open", "#{plan.open} of #{plan.total} tasks open"] if plan.open.positive?
      ["pass", "plan_done", "All #{plan.total} tasks done"]
    end

    def self.check_checklist(done_when)
      done, total = done_when.values_at("done", "total")
      return ["fail", "no_criteria", "No Done when items"] if total.zero?
      return ["fail", "unticked", "#{done} of #{total} ticked"] if done < total
      ["pass", "all_ticked", "#{done} of #{total} ticked"]
    end

    def self.check_pushed(facts)
      return ["pass", "merged", "The pull request is merged"] if facts.pr&.state == "merged"
      git = facts.git
      return unread("pushed") if git.nil?
      return ["fail", "no_upstream", "Never pushed"] unless git.upstream
      return ["fail", "ahead", "#{git.ahead} #{(git.ahead == 1) ? "commit" : "commits"} not pushed"] if git.ahead.positive?
      ["pass", "pushed", "Pushed"]
    end

    def self.check_pr(pr)
      return unread("pr") if pr.nil?
      case pr.state
      when "open" then ["pass", "pr_open", "Pull request open"]
      when "merged" then ["pass", "pr_merged", "Pull request merged"]
      when "closed" then ["fail", "pr_closed", "Pull request closed"]
      else ["fail", "no_pr", "No pull request"]
      end
    end

    def self.check_ci(pr)
      return unread("ci") if pr.nil?
      return ["unchecked", "no_pr", "No pull request"] if pr.state == "none"
      counts = (pr.failing && pr.total) ? "#{pr.failing} of #{pr.total} checks" : nil
      case pr.checks
      when "pass" then ["pass", "checks_passing", "Checks passing"]
      when "fail" then ["fail", "checks_failing", counts ? "#{counts} failing" : "Checks failing"]
      when "pending" then ["pending", "checks_pending", "Checks running"]
      else ["unchecked", "no_checks", "No checks"]
      end
    end

    def self.check_merged(pr)
      return unread("merged") if pr.nil?
      case pr.state
      when "merged" then ["pass", "pr_merged", "Pull request merged"]
      when "open" then ["fail", "pr_open", "Pull request not merged"]
      when "closed" then ["fail", "pr_closed", "Pull request closed"]
      else ["fail", "no_pr", "No pull request"]
      end
    end

    def self.check_review(review)
      return unread("review") if review.nil?
      return ["pass", "review_done", "Review done"] if review.agent_done && !review.changes_requested
      return ["fail", "changes_requested", "Changes requested"] if review.changes_requested
      ["fail", "review_running", "Review not finished"]
    end

    private_class_method :level, :evaluate, :owner, :checker_of, :check, :unread, :check_plan, :check_checklist,
      :check_pushed, :check_pr, :check_ci, :check_merged, :check_review
  end
end
