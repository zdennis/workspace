module Workspace
  # The shape of one workflow definition as a graph of nodes and edges: a `.start` terminal, a node per step, a
  # `<step>.review` node after a step with `review:`, a `<step>.gate` node after a step with `gate: approve`, and
  # an `.end` terminal. A model id that is not a step id holds a `.`, which a step id never does, so no step can
  # collide with one. A `fail` edge whose `goto` is not a step id (a hand-edited stored run) is left out, so
  # every edge joins two declared nodes. Pure: it reads a definition hash and does no I/O; renderers map model
  # ids to their own.
  class WorkflowGraph
    STEP_ANNOTATIONS = %w[produces status require guard uses timeout on_timeout max_attempts context].freeze
    REVIEW_ANNOTATIONS = %w[from need must max_rounds].freeze
    LEGEND_KEYS = %w[max_attempts timeout timeout_action stall budget].freeze

    # @param definition [Hash] {WorkflowDefinition#to_h}, or a stored run's definition
    # @param origins [Hash{String=>String}] step id to the `extends:` parent it came from
    # @return [WorkflowGraph] frozen
    # @raise [Workspace::Error] code `invalid_workflow` for a definition with a `fan_out` group, which this model
    #   would draw as steps in a row
    def self.build(definition, origins: {})
      WorkflowDefinition.refuse_groups(definition, doing: "graphed", later: "the graph drawing a group's steps side by side (a later change)")
      new(definition, origins)
    end

    # @return [Hash] "nodes" (each "id", "kind", "title", "annotations"), "edges" (each "from", "to", "kind",
    #   "label") and "legend", in that order
    attr_reader :to_h

    def initialize(definition, origins)
      steps = Array(definition["steps"]).select { |step| step.is_a?(Hash) }
      nodes = [node(".start", "start", "Start", {})]
      edges = []
      path = [".start"]
      fails = []
      rejects = []
      steps.each do |step|
        id = step["id"]
        title = step["title"] || id
        nodes << node(id, "step", title, step_annotations(step, origins[id]))
        path << id
        if step["review"].is_a?(Hash)
          review = step["review"]
          nodes << node("#{id}.review", "review", "#{title} review", review_annotations(review))
          path << "#{id}.review"
          rejects << edge("#{id}.review", id, "review_rejected", review["max_rounds"] && "max_rounds #{review["max_rounds"]}")
        end
        if step["gate"] == "approve"
          nodes << node("#{id}.gate", "gate", "#{title} gate", {})
          path << "#{id}.gate"
          rejects << edge("#{id}.gate", id, "reject", "reject (or --to an earlier step)")
        end
        fails << edge(id, step["on_fail"]["goto"], "fail", fail_label(step["on_fail"])) if step["on_fail"].is_a?(Hash)
      end
      nodes << node(".end", "end", "End", {})
      path << ".end"
      path.each_cons(2) { |from, to| edges << edge(from, to, "next", nil) }
      ids = steps.map { |each| each["id"] }
      fails.select! { |each| ids.include?(each["to"]) }
      @to_h = WorkflowRun.deep_freeze("nodes" => nodes, "edges" => edges + fails + rejects, "legend" => legend(definition))
      freeze
    end

    private

    def node(id, kind, title, annotations)
      {"id" => id, "kind" => kind, "title" => title, "annotations" => annotations}
    end

    def edge(from, to, kind, label)
      {"from" => from, "to" => to, "kind" => kind, "label" => label}
    end

    def step_annotations(step, origin)
      annotations = STEP_ANNOTATIONS.each_with_object({}) do |key, found|
        found[key] = step[key] if set?(step[key])
      end
      annotations.delete("context") if annotations["context"] == "fresh"
      annotations["origin"] = origin if set?(origin) && origin != "own"
      annotations
    end

    def review_annotations(review)
      REVIEW_ANNOTATIONS.each_with_object({}) do |key, found|
        found[key] = review[key] if set?(review[key])
      end
    end

    def fail_label(on_fail)
      label = ["max #{on_fail["max"]}"]
      label << "backoff #{whole(on_fail["backoff"])}s" if set?(on_fail["backoff"])
      label << "except #{Array(on_fail["except"]).join(", ")}" if set?(on_fail["except"])
      label.join(", ")
    end

    def whole(number)
      (number.is_a?(Float) && number == number.floor) ? number.to_i : number
    end

    def legend(definition)
      LEGEND_KEYS.each_with_object({}) do |key, found|
        found[key] = definition[key] if set?(definition[key])
      end
    end

    def set?(value)
      !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
    end
  end
end
