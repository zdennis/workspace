module Workspace
  # Draws a {WorkflowGraph} model as Graphviz DOT. Every node id, in node and edge statements alike, is written
  # double-quoted through the same escaper as the labels. Pure: reads the model hash only.
  module WorkflowGraphDot
    # @param model [Hash] {WorkflowGraph#to_h}
    # @return [String] the digraph, ending in a newline
    def self.render(model)
      lines = ["digraph workflow {", "  rankdir=LR;"]
      legend = WorkflowGraphText.legend_line(model["legend"])
      lines << "  labelloc=b;" << "  label=#{quote(legend)};" if legend
      model["nodes"].each { |node| lines << "  #{quote(node["id"])} [#{attributes(node)}];" }
      model["edges"].each do |edge|
        attrs = []
        label = WorkflowGraphText.edge_label(edge)
        attrs << "style=dashed" << "label=#{quote(label)}" if label
        lines << "  #{quote(edge["from"])} -> #{quote(edge["to"])}#{" [#{attrs.join(", ")}]" unless attrs.empty?};"
      end
      lines << "}"
      lines.join("\n") + "\n"
    end

    def self.attributes(node)
      case node["kind"]
      when "start" then "shape=point"
      when "end" then "shape=doublecircle, label=\"\""
      when "gate" then "shape=diamond, label=#{quote(WorkflowGraphText.node_title(node))}"
      when "review" then "shape=box, peripheries=2, label=#{quote(WorkflowGraphText.node_title(node))}"
      else "shape=box, label=#{quote(WorkflowGraphText.node_title(node))}"
      end
    end

    def self.quote(value)
      lines = value.to_s.split(/\r?\n|\r/, -1).map do |line|
        TerminalText.escape(line).gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")
      end
      "\"#{lines.join("\\n")}\""
    end
    private_class_method :attributes, :quote
  end
end
