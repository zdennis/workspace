module Workspace
  # Draws a {WorkflowGraph} model as plain text: one box per node in a column, and a left rail that carries each
  # loop edge (`fail`, `reject`, `review_rejected`) from its source up to its target, one lane per edge, with the
  # edge's label after the source box. A `fan_out` group is a `(Fan out: ..., side by side)` line, its siblings
  # indented and joined by no arrows, and a `(Join: ...)` line. A step's review box sits under it; the legend is the last line. Titles go
  # through {TerminalText.escape}. Pure: reads the model hash only.
  module WorkflowGraphAscii
    LANE_WIDTH = 3

    # @param model [Hash] {WorkflowGraph#to_h}
    # @return [String] the diagram, ending in a newline
    def self.render(model)
      loops = model["edges"].reject { |edge| edge["kind"] == "next" }
      positions = model["nodes"].each_with_index.to_h { |node, index| [node["id"], index] }
      lanes = loops.sort_by { |edge| -(positions[edge["from"]] - positions[edge["to"]]).abs }
      margin = lanes.size * LANE_WIDTH
      rows = []
      mids = {}
      model["nodes"].each_with_index do |node, index|
        previous = model["nodes"][index - 1] unless index.zero?
        rows.concat(sibling?(node, previous) ? [""] : connector(node, previous)) unless index.zero?
        block, mid = block(node)
        mids[node["id"]] = rows.size + mid
        rows.concat(block)
      end
      grid = rows.map { |row| (" " * margin) + row }
      lanes.each_with_index { |edge, lane| draw(grid, lane * LANE_WIDTH, margin, mids[edge["from"]], mids[edge["to"]]) }
      loops.each do |edge|
        grid[mids[edge["from"]]] += "  " + TerminalText.escape(WorkflowGraphText.edge_label(edge))
      end
      legend = WorkflowGraphText.legend_line(model["legend"])
      lines = grid.map(&:rstrip)
      lines << "" << "Run limits: #{legend}" if legend
      lines.join("\n") + "\n"
    end

    def self.connector(node, previous)
      return ["      |", "      v"] if node["group"] && node["group"] == previous["group"]
      ["  |", "  v"]
    end

    def self.block(node)
      title = TerminalText.escape(WorkflowGraphText.node_title(node))
      return [["(#{title})"], 0] if %w[start end].include?(node["kind"])
      return [["(#{title}, side by side)"], 0] if node["kind"] == "fork"
      return [["(#{title})"], 0] if node["kind"] == "join"
      text = [title]
      detail = review_detail(node["annotations"]) if node["kind"] == "review"
      text << detail if detail
      width = text.map(&:length).max
      edge = (node["kind"] == "gate") ? "=" : "-"
      box = ["+#{edge * (width + 2)}+"] + text.map { |line| "| #{line.ljust(width)} |" } + ["+#{edge * (width + 2)}+"]
      box = box.map { |line| "    #{line}" } if node["group"]
      [box, 1]
    end

    def self.sibling?(node, previous)
      node["kind"] == "step" && node["group"] && previous["group"] == node["group"]
    end

    def self.review_detail(annotations)
      parts = []
      from = Array(annotations["from"]).map { |name| TerminalText.escape(name) }
      parts << "need #{annotations["need"]} of: #{from.join(", ")}" if annotations["need"] && !from.empty?
      must = Array(annotations["must"]).map { |name| TerminalText.escape(name) }
      parts << "must: #{must.join(", ")}" unless must.empty?
      parts.empty? ? nil : parts.join("; ")
    end

    def self.draw(grid, column, margin, from_row, to_row)
      top, bottom = [from_row, to_row].minmax
      (top..bottom).each { |row| put(grid, row, column, "|") }
      [from_row, to_row].each do |row|
        (column + 1...margin).each { |at| put(grid, row, at, "-") }
        put(grid, row, column, "+")
      end
      put(grid, to_row, margin - 1, ">")
    end

    def self.put(grid, row, column, char)
      grid[row] = grid[row].ljust(column + 1) if grid[row].length <= column
      grid[row][column] = char
    end
    private_class_method :connector, :block, :sibling?, :review_detail, :draw, :put
  end
end
