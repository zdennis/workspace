module Workspace
  # Marks a {WorkflowGraph} model with where one run stands: a `state` on each step, gate and review node
  # (`passed`, `current`, `waiting`, `failed` or `pending`), `passes` and `attempts` on each step node, and
  # `loops` (the run's count for that edge) on each `fail` edge. A step takes its stored state, not its history,
  # so a step a loop sent back and that passed again reads `passed`. The `.start` and `.end` terminals take no
  # state. Pure: reads the model hash and the run only.
  module WorkflowGraphStates
    # The step states of an agent at work on the run's current step.
    ACTIVE = %w[running checking reviewing].freeze

    # The step states of a step about to be sent.
    QUEUED = %w[queued delivering waiting].freeze

    # The attempt outcomes that count as a pass.
    PASSING = %w[passed overridden].freeze

    # @param model [Hash] {WorkflowGraph#to_h}
    # @param run [WorkflowRun]
    # @return [Hash] a frozen copy of +model+ with the run's marks
    def self.mark(model, run)
      nodes = model["nodes"].map { |node| node_with(node, run) }
      edges = model["edges"].map do |edge|
        (edge["kind"] == "fail") ? edge.merge("loops" => loops(run, edge)) : edge
      end
      WorkflowRun.deep_freeze(model.merge("nodes" => nodes, "edges" => edges))
    end

    def self.node_with(node, run)
      case node["kind"]
      when "step"
        step = run.step(node["id"])
        attempts = step ? step.attempts : []
        node.merge("state" => step_state(node["id"], step, run), "passes" => attempts.count { |each| PASSING.include?(each.outcome) },
          "attempts" => attempts.size)
      when "gate" then node.merge("state" => gate_state(owner(node), run))
      when "review" then node.merge("state" => review_state(owner(node), run))
      else node
      end
    end

    def self.step_state(id, step, run)
      state = step&.state
      current = run.current == id
      return "passed" if state == "passed"
      return "failed" if current && ACTIVE.include?(state) && ended?(run)
      return "current" if current && ACTIVE.include?(state)
      return "waiting" if QUEUED.include?(state) || (current && run.state == "waiting")
      return "failed" if state == "failed"
      "pending"
    end

    def self.gate_state(id, run)
      step = run.step(id)
      gate = step&.gate
      return "pending" unless gate.is_a?(Hash)
      case gate["state"]
      when "approved" then "passed"
      when "waiting" then "waiting"
      when "rejected" then rerunning?(id, step, run) ? "pending" : "failed"
      else "pending"
      end
    end

    def self.review_state(id, run)
      step = run.step(id)
      return "pending" unless step
      return "waiting" if step.review_live? || step.review_held?
      outcome = step.last_attempt&.review_outcome
      return "passed" if outcome.is_a?(Hash) && outcome["passed"] == true
      return "failed" if step.review_stopped? || (outcome.is_a?(Hash) && outcome["passed"] == false && !rerunning?(id, step, run))
      "pending"
    end

    # The step runs again, or a reject --to moved the run to another step and the run goes on.
    def self.rerunning?(id, step, run)
      (ACTIVE + QUEUED).include?(step.state) || (run.current != id && !ended?(run))
    end

    def self.ended?(run)
      RunLiveness::TERMINAL_STATES.include?(run.state)
    end

    def self.owner(node)
      node["id"].sub(/\.(gate|review)\z/, "")
    end

    def self.loops(run, edge)
      count = run.loops.is_a?(Hash) ? run.loops["#{edge["from"]}->#{edge["to"]}"] : nil
      count.is_a?(Integer) ? count : 0
    end
    private_class_method :node_with, :step_state, :gate_state, :review_state, :rerunning?, :ended?, :owner, :loops
  end
end
