module Workspace
  # The stages of a workspace that has no `spine/` folder, guessed from its plan file, its workflow
  # runs, the review agent and the pull request: a port of the app's `src/core/spine/inferred.ts`, so
  # `spine show --evaluate` gives the same inferred stages the app shows.
  #
  # {.stages} is the rules alone and runs nothing. An instance gathers what {.stages} needs beyond
  # {SpineFacts}' own reads: the workspace's runs still going (from the run files and the pane
  # bindings) and whether its checkout is a linked worktree (from its `.git` file).
  class SpineInferred
    # The gates {SpineFacts#read} is asked for, so it makes the one `gh` read (Verify, Ship and the
    # merged rule read the pull request) and the review read (Review reads the agent and the ahead count).
    FACT_GATES = %w[pushed pr ci merged review].freeze

    TITLES = {"research" => "Research", "plan" => "Plan", "implement" => "Implement", "verify" => "Verify",
              "review" => "Review", "ship" => "Ship"}.freeze

    # The default template's Ship gates, so Ship's facts show as gates.
    SHIP_GATES = %w[pushed pr ci merged].freeze

    STEP_STATUS = {"pending" => "not_started", "waiting" => "in_progress", "running" => "in_progress",
                   "checking" => "in_progress", "passed" => "completed", "failed" => "blocked"}.freeze

    # Steps a workflow (rpiv) names like a stage; its run outranks the plan.
    RUN_STAGES = %w[research plan implement verify].freeze
    private_constant :TITLES, :SHIP_GATES, :STEP_STATUS, :RUN_STAGES

    # @!attribute plan [Hash, nil] `exists`, `counts` (as {PlanFile#counts}), `state` (as {PlanState#derive})
    #   and `owner_pane`; nil when the plan file could not be read
    # @!attribute runs [Array<Hash>] the workspace's runs still going, oldest first: `step` (the current
    #   step's id), `pane` and `steps` (`id`, `state`, in the definition's order)
    # @!attribute review_ready [Boolean] the review agent is done and the branch is ahead of its base
    # @!attribute ship [Boolean] the checkout is a linked worktree, which ships
    Input = Struct.new(:plan, :runs, :review_ready, :ship, keyword_init: true)

    # One inferred stage before evaluation, shaped as {SpineEvaluator} reads a {SpineTree::Stage}.
    Stage = Struct.new(:kind, :number, :status, :owner, :gates, :source, keyword_init: true) do
      def id = kind

      def children = []

      def awaiting_check? = false

      def check_failed? = false

      def to_h
        {
          "path" => kind, "file" => nil, "number" => number, "id" => kind, "revision" => nil, "title" => TITLES.fetch(kind),
          "description" => nil, "status" => status, "status_raw" => nil, "note" => nil, "kind" => kind, "owner" => owner,
          "depends_on" => [], "gates" => gates, "artifacts" => [], "play" => nil, "agent" => nil,
          "updated" => nil, "updated_by" => nil, "check" => nil, "checked_by" => nil, "checked_at" => nil, "check_note" => nil, "modified_at" => nil,
          "done_when" => {"total" => 0, "done" => 0, "items" => []}, "warnings" => [], "truncated" => false, "children" => []
        }
      end
    end

    # @param input [Input]
    # @param facts [SpineEvaluator::Facts]
    # @return [Array<Hash>] the evaluated stages ({SpineEvaluator.evaluate_stages}), Research to Review and
    #   Ship for a worktree, each with `inferred: true` and `source` (`plan`, `workflow`, `review` or `pr`)
    def self.stages(input, facts)
      plan = input.plan
      run = input.runs.find { |r| r["steps"].any? { |step| RUN_STAGES.include?(step["id"]) } }
      pick = lambda do |kind, number, status, source, owner = nil|
        step = run && run["steps"].find { |s| s["id"] == kind }
        if step
          Stage.new(kind: kind, number: number, status: STEP_STATUS.fetch(step["state"], "unknown"),
            owner: (run["step"] == kind) ? run["pane"] : nil, gates: [], source: "workflow")
        else
          Stage.new(kind: kind, number: number, status: status, owner: owner, gates: [], source: source)
        end
      end

      implement = pick.call("implement", 30, implement_status(plan), "plan", plan&.fetch("owner_pane", nil))
      pr = facts.pr
      merged = pr&.state == "merged"
      research = if plan.nil? then "unknown"
      elsif plan["exists"] then "skipped"
      else "not_started"
      end
      stages = [
        # Work past a plan file has moved on from research.
        pick.call("research", 10, research, "plan"),
        pick.call("plan", 20, plan_status(plan), "plan"),
        implement,
        pick.call("verify", 40, verify_status(implement.status, pr&.checks), "pr"),
        Stage.new(kind: "review", number: 50, owner: nil, gates: [],
          status: if merged then "completed"
                  elsif input.review_ready then "in_progress"
                  else "not_started"
                  end,
          source: merged ? "pr" : "review")
      ]
      if input.ship
        status = if merged then "completed"
        elsif pr&.state == "open" then "in_progress"
        else "not_started"
        end
        stages << Stage.new(kind: "ship", number: 60, status: status, owner: nil, gates: SHIP_GATES, source: "pr")
      end
      # Merged work is past every stage; what was never seen done was passed over, not left open.
      if merged
        stages = stages.map do |s|
          next s if s.status == "completed"
          s.dup.tap do |settled|
            settled.status = "skipped"
            settled.source = "pr"
          end
        end
      end
      SpineEvaluator.evaluate_stages(stages, facts).zip(stages).map do |doc, stage|
        doc.merge("inferred" => true, "source" => stage.source)
      end
    end

    def self.plan_status(plan)
      return "unknown" if plan.nil?
      return "not_started" unless plan["exists"]
      c = plan["counts"]
      # Empty is drafting; tasks never started wait for the plan to be approved.
      return "in_progress" if c["total"].zero? || (c["done"] + c["in_progress"] + c["skipped"] + c["blocked"]).zero?
      "completed"
    end

    def self.implement_status(plan)
      return "unknown" if plan.nil?
      c = plan["counts"]
      return "not_started" if !plan["exists"] || c["total"].zero?
      return "completed" if plan["state"] == "done" || c["left"].zero?
      return "blocked" if plan["state"] == "blocked" || c["blocked"].positive?
      started = (c["done"] + c["in_progress"] + c["skipped"]).positive? || %w[working waiting].include?(plan["state"])
      started ? "in_progress" : "not_started"
    end

    # Not tracked: the checks say how it is going, and it is done only once Implement is and they pass.
    def self.verify_status(implement, checks)
      case checks
      when "fail" then "blocked"
      when "pending" then "in_progress"
      when "pass" then (implement == "completed") ? "completed" : "not_started"
      else "not_started"
      end
    end

    private_class_method :plan_status, :implement_status, :verify_status

    # @param workflow_store [Workspace::WorkflowRunStore] the runs still going
    # @param workflow_panes [Workspace::WorkflowPanes] the pane each run is bound to
    # @param git [Workspace::Git] whether the checkout is a linked worktree
    # @param plan_state [Workspace::PlanState] the plan's `state`, as `plan status` derives it
    def initialize(workflow_store:, workflow_panes:, git:, plan_state: PlanState.new)
      @workflow_store = workflow_store
      @workflow_panes = workflow_panes
      @git = git
      @plan_state = plan_state
    end

    # @param workspace [String]
    # @param checkout [String] the workspace's checkout
    # @param result [SpineFacts::Result] a {SpineFacts#read} made with {FACT_GATES}
    # @return [Array<Hash>] see {.stages}
    def infer(workspace:, checkout:, result:)
      readings = result.readings
      input = Input.new(
        plan: plan_input(readings),
        runs: runs_of(workspace),
        review_ready: !!result.facts.review&.agent_done && readings.review_ahead.to_i.positive?,
        ship: worktree?(checkout)
      )
      self.class.stages(input, result.facts)
    end

    # @return [Hash, nil] the current inferred stage as a `goal` stage (`path`, `title`, `status`, `owner`, `source: "inferred"`);
    #   nil when the plan could not be read, or no stage is current
    def current_stage(workspace:, checkout:, result:)
      return nil if result.readings.plan.nil?
      docs = infer(workspace: workspace, checkout: checkout, result: result)
      doc = docs.find { |each| each["path"] == SpineEvaluator.current(docs) }
      doc && {"path" => doc["path"], "title" => doc["title"], "status" => doc["status"], "owner" => doc["owner"], "source" => "inferred"}
    end

    private

    # The session counts as live when the daemon answered; otherwise it is unknown, never `stopped`.
    def plan_input(readings)
      plan = readings.plan
      return nil if plan.nil?
      return {"exists" => false, "counts" => PlanFile.parse("").counts, "state" => "empty", "owner_pane" => nil} if plan == :missing
      owner = plan.owner_pane
      pane = owner && readings.panes&.find { |candidate| candidate["pane_id"] == owner }
      state = @plan_state.derive(plan: plan, session_live: readings.panes ? true : nil, pane_state: pane && pane["state"],
        pane_since: pane && pane["state_since"], open_asks: Array(readings.asks).size)
      {"exists" => true, "counts" => plan.counts, "state" => state, "owner_pane" => owner}
    end

    # The store reads only whole runs: every defined step has its state.
    def runs_of(workspace)
      @workflow_store.active.select { |run| run["workspace"] == workspace }.map do |run|
        steps = run["definition"]["steps"].map { |step| {"id" => step["id"], "state" => run["steps"].fetch(step["id"])["state"]} }
        {"step" => run["current"], "pane" => @workflow_panes.pane_of(run["id"]) || run["pane"], "steps" => steps}
      end
    rescue Workspace::Error, SystemCallError
      []
    end

    # As the project catalog tells a worktree from the main checkout: a `.git` file naming a linked worktree.
    def worktree?(checkout)
      layout = @git.checkout_layout(checkout)
      !!(layout && !layout[:broken] && layout[:linked])
    rescue Workspace::Error, SystemCallError
      false
    end
  end
end
