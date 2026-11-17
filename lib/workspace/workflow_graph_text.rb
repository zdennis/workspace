module Workspace
  # The words every workflow graph renderer shares: an edge's label and the legend as one line.
  module WorkflowGraphText
    # @param edge [Hash] an edge of {WorkflowGraph#to_h}, or of {WorkflowGraphStates.mark}
    # @return [String, nil] nil for a plain `next` edge; `fail: max 3`, `reject (or --to an earlier step)` and
    #   `review_rejected: max_rounds 6` for the loop edges, with ` (looped 2)` after a `fail` edge a run took
    def self.edge_label(edge)
      label = case edge["kind"]
      when "next" then nil
      when "reject" then edge["label"] || "reject"
      else [edge["kind"], edge["label"]].compact.join(": ")
      end
      looped = edge["loops"].is_a?(Integer) && edge["loops"].positive?
      looped ? "#{label} (looped #{edge["loops"]})" : label
    end

    # @param node [Hash] a node of {WorkflowGraph#to_h}, or of {WorkflowGraphStates.mark}
    # @return [String] the words a renderer shows for the node; a marked node adds its state, such as
    #   `Implement [passed x3]`, `Verify [current, 3 attempts]` or `Plan gate [waiting]`
    def self.node_title(node)
      title = node["title"].to_s
      origin = node.dig("annotations", "origin")
      title += " (from #{origin})" if origin
      return title unless node["state"]
      passes = node["passes"].to_i
      attempts = node["attempts"].to_i
      mark = node["state"].to_s
      mark += " x#{passes}" if passes > 1
      mark += ", #{attempts} attempts" if attempts > 1 && attempts > passes
      "#{title} [#{mark}]"
    end

    # @param legend [Hash] the `legend` of {WorkflowGraph#to_h}
    # @return [String, nil] such as `max_attempts 17, timeout 8h, budget 40000000 tokens (stop)`; nil when empty
    def self.legend_line(legend)
      parts = legend.map do |key, value|
        case key
        when "timeout", "stall" then "#{key} #{duration(value)}"
        when "budget" then "budget #{value["tokens"]} tokens (#{value["action"]})"
        else "#{key} #{value}"
        end
      end
      parts.empty? ? nil : parts.join(", ")
    end

    # @param seconds [Numeric]
    # @return [String] whole hours, minutes and seconds such as `1h30m` or `45m`
    def self.duration(seconds)
      total = seconds.to_i
      return "#{seconds}s" unless seconds.is_a?(Numeric)
      parts = [[total / 3600, "h"], [total % 3600 / 60, "m"], [total % 60, "s"]]
      shown = parts.reject { |count, _| count.zero? }.map { |count, unit| "#{count}#{unit}" }
      shown.empty? ? "0s" : shown.join
    end
  end
end
