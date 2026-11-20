module Workspace
  # The shape of one workflow definition as a graph of nodes and edges: a `.start` terminal, a node per step, a
  # `<group>.group` fork and `<group>.join` join node around the siblings of a `fan_out` group (each sibling
  # node, and its gate node, carries `"group"`, the fork and join `"group_id"`; the group's `on_fail` goto is a `fail`
  # edge from the join; each `fail` edge carries `"loop_key"`, the run's `loops` key for it), a
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
    def self.build(definition, origins: {})
      new(definition, origins)
    end

    # @return [Hash] "nodes" (each "id", "kind", "title", "annotations"), "edges" (each "from", "to", "kind",
    #   "label") and "legend", in that order
    attr_reader :to_h

    def initialize(definition, origins)
      @origins = origins
      @groups = definition["groups"].is_a?(Hash) ? definition["groups"] : {}
      @nodes = [node(".start", "start", "Start", {})]
      @edges = []
      @fails = []
      @rejects = []
      @tails = [".start"]
      @open = nil
      steps = Array(definition["steps"]).select { |step| step.is_a?(Hash) }
      steps.each { |step| add_step(step) }
      close_group
      @nodes << node(".end", "end", "End", {})
      @tails.each { |tail| @edges << edge(tail, ".end", "next", nil) }
      ids = steps.map { |each| each["id"] }
      @fails.select! { |each| ids.include?(each["to"]) }
      @to_h = WorkflowRun.deep_freeze("nodes" => @nodes, "edges" => @edges + @fails + @rejects, "legend" => legend(definition))
      freeze
    end

    private

    def add_step(step)
      id = step["id"]
      gid = (step["group"].is_a?(String) && !step["group"].empty?) ? step["group"] : nil
      close_group if @open && @open[:id] != gid
      open_group(gid) if gid && @open.nil?
      entry = gid ? [@open[:fork]] : @tails
      chain = add_chain(step, gid)
      entry.each { |tail| @edges << edge(tail, id, "next", nil) }
      chain.each_cons(2) { |from, to| @edges << edge(from, to, "next", nil) }
      if gid
        @open[:tails] << chain.last
      else
        @tails = [chain.last]
      end
      @fails << fail_edge(id, id, step["on_fail"]) if step["on_fail"].is_a?(Hash)
    end

    def add_chain(step, gid)
      id = step["id"]
      title = step["title"] || id
      @nodes << node(id, "step", title, step_annotations(step, @origins[id]), gid)
      chain = [id]
      if step["review"].is_a?(Hash)
        review = step["review"]
        @nodes << node("#{id}.review", "review", "#{title} review", review_annotations(review), gid)
        chain << "#{id}.review"
        @rejects << edge("#{id}.review", id, "review_rejected", review["max_rounds"] && "max_rounds #{review["max_rounds"]}")
      end
      if step["gate"] == "approve"
        @nodes << node("#{id}.gate", "gate", "#{title} gate", {}, gid)
        chain << "#{id}.gate"
        @rejects << edge("#{id}.gate", id, "reject", "reject (or --to an earlier step)")
      end
      chain
    end

    def open_group(gid)
      group = group_of(gid)
      fork = "#{gid}.group"
      annotations = %w[checkout execution_mode].each_with_object({}) { |key, found| found[key] = group[key] if set?(group[key]) }
      @nodes << node(fork, "fork", "Fan out: #{group["title"] || gid}", annotations, nil, gid)
      @tails.each { |tail| @edges << edge(tail, fork, "next", nil) }
      @tails = [fork]
      @open = {id: gid, fork: fork, tails: []}
    end

    def close_group
      return unless @open
      gid = @open[:id]
      group = group_of(gid)
      join = "#{gid}.join"
      @nodes << node(join, "join", "Join: #{group["title"] || gid}", {}, nil, gid)
      @open[:tails].each { |tail| @edges << edge(tail, join, "next", nil) }
      @tails = [join]
      @fails << fail_edge(join, gid, group["on_fail"]) if group["on_fail"].is_a?(Hash)
      @open = nil
    end

    def group_of(gid)
      @groups[gid].is_a?(Hash) ? @groups[gid] : {}
    end

    def fail_edge(from, owner, on_fail)
      edge(from, on_fail["goto"], "fail", fail_label(on_fail)).merge("loop_key" => "#{owner}->#{on_fail["goto"]}")
    end

    def node(id, kind, title, annotations, group = nil, group_id = nil)
      node = {"id" => id, "kind" => kind, "title" => title, "annotations" => annotations}
      node["group"] = group if group
      node["group_id"] = group_id if group_id
      node
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
