module Workspace
  # Draws a {WorkflowGraph} model as Mermaid `stateDiagram-v2` text. A model id is never written as a state id:
  # each non-terminal node is numbered `n0`, `n1`, ... in model order and declared with its quoted label, and the
  # `.start` and `.end` terminals are `[*]`. A node a run marked ({WorkflowGraphStates}) gets the `classDef` of its
  # state. Pure: reads the model hash only.
  module WorkflowGraphMermaid
    # The `classDef` of each node state {WorkflowGraphStates} marks.
    STATE_STYLES = {
      "passed" => "fill:#d4edda,stroke:#28a745",
      "current" => "fill:#cce5ff,stroke:#0366d6,stroke-width:3px",
      "waiting" => "fill:#fff3cd,stroke:#d39e00",
      "failed" => "fill:#f8d7da,stroke:#cb2431",
      "pending" => "fill:#f6f8fa,stroke:#959da5"
    }.freeze

    # @param model [Hash] {WorkflowGraph#to_h}
    # @return [String] the diagram, ending in a newline
    def self.render(model)
      ids = {}
      model["nodes"].each { |node| ids[node["id"]] = "n#{ids.size}" unless terminal?(node) }
      lines = ["stateDiagram-v2"]
      model["nodes"].each do |node|
        lines << "    state \"#{text(WorkflowGraphText.node_title(node))}\" as #{ids[node["id"]]}" unless terminal?(node)
      end
      model["edges"].each do |edge|
        label = WorkflowGraphText.edge_label(edge)
        lines << "    #{ids.fetch(edge["from"], "[*]")} --> #{ids.fetch(edge["to"], "[*]")}#{" : #{text(label)}" if label}"
      end
      marked = model["nodes"].select { |node| ids.key?(node["id"]) && STATE_STYLES.key?(node["state"]) }
      marked.map { |node| node["state"] }.uniq.each { |state| lines << "    classDef #{state} #{STATE_STYLES[state]}" }
      marked.each { |node| lines << "    class #{ids[node["id"]]} #{node["state"]}" }
      legend = WorkflowGraphText.legend_line(model["legend"])
      if legend && ids.any?
        lines << "    note right of #{ids.values.first}" << "        #{text(legend)}" << "    end note"
      end
      lines.join("\n") + "\n"
    end

    def self.terminal?(node)
      %w[start end].include?(node["kind"])
    end

    def self.text(value)
      TerminalText.escape(value.to_s.gsub(/\s*[\r\n]+\s*/, " ").strip).gsub("#", "#35;").gsub(";", "#59;").delete("<>").gsub("\"", "#quot;")
    end
    private_class_method :terminal?, :text
  end
end
