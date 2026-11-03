module Workspace
  # What +workflow start+ seeds into a run's inputs from a ticket and a prompt.
  module WorkflowSeed
    module_function

    # The task input: the ticket's "KEY: title (url)" line, then the prompt after a blank line.
    #
    # @param ticket [Hash, nil] a ticket with "key" and optional "title" and "url"
    # @param prompt [String, nil]
    # @return [String, nil] nil when there is neither
    def task_text(ticket, prompt)
      line = ticket && [ticket["key"] + (ticket["title"] ? ": #{ticket["title"]}" : ""), ("(#{ticket["url"]})" if ticket["url"])].compact.join(" ")
      [line, prompt].compact.join("\n\n").then { |text| text.empty? ? nil : text }
    end

    # Whether a seed may fill an input: the definition declares it and +--input+ did not set it.
    #
    # @param definition [#to_h] a workflow definition
    # @param name [String] the input name
    # @param inputs [Hash] the inputs already given
    # @return [Boolean]
    def fillable?(definition, name, inputs)
      definition.to_h["inputs"].key?(name) && !inputs.key?(name)
    end
  end
end
