module Workspace
  # Renders {TemplateVariables} into the blocks of docs/README.template.md that sit
  # between `<!-- BEGIN GENERATED: name -->` and `<!-- END GENERATED: name -->`
  # markers. `script/generate-template-docs` rewrites the file; a spec fails
  # when the checked-in file differs from what this renders.
  module TemplateVariablesDocs
    BLOCK = /(<!-- BEGIN GENERATED: (\S+) -->\n).*?(<!-- END GENERATED: \2 -->)/m

    # @param text [String] a document containing generated-block markers
    # @return [String] the document with every block re-rendered
    # @raise [ArgumentError] for a block name this module doesn't render
    def self.rewrite(text)
      text.gsub(BLOCK) { "#{$1}#{render($2)}#{$3}" }
    end

    # @param name [String] "placeholders"
    # @return [String] the block's body, ending in a newline
    # @raise [ArgumentError] for an unknown name
    def self.render(name)
      case name
      when "placeholders" then placeholders_table
      else raise ArgumentError, "unknown generated block #{name.inspect}"
      end
    end

    def self.placeholders_table
      rows = TemplateVariables::ROWS.map do |row|
        "| `{{#{row.name}}}` | #{kinds_cell(row)} | #{required_cell(row)} | #{cell(row.description)} | #{cell(row.source)} | `#{cell(row.sample)}` |"
      end
      ["| Placeholder | Kinds | Required | Description | Source | Sample |", "|-------------|-------|----------|-------------|--------|--------|", *rows].join("\n") + "\n"
    end
    private_class_method :placeholders_table

    # The kinds the renderer fills the placeholder for, e.g. "project, worktree".
    def self.kinds_cell(row) = row.kinds.join(", ")
    private_class_method :kinds_cell

    # The kinds in which a template holding the placeholder needs a value, or "no".
    def self.required_cell(row)
      kinds = row.kinds.select { |kind| row.required[kind] }
      kinds.empty? ? "no" : kinds.join(", ")
    end
    private_class_method :required_cell

    # Escapes the pipes that would end a table cell.
    def self.cell(text) = text.gsub("|", "\\|")
    private_class_method :cell
  end
end
