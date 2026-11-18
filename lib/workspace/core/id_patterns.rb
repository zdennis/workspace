module Workspace
  # The name rules several sub-systems share, kept in core so none of them
  # reads another's class for a pattern.
  module IdPatterns
    # Library entry names: lowercase letters, digits and hyphens.
    LIBRARY_NAME = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

    # Workflow and step ids: they become file names and binding fields.
    WORKFLOW_ID = /\A[a-z0-9][a-z0-9_-]{0,39}\z/

    # The rule {WORKFLOW_ID} checks, in words, for messages.
    WORKFLOW_ID_RULE = "lowercase letters, digits, '-' and '_'"

    # The ids a definition read from stdin or from a file path gets when its text names none and its file name is not an id.
    STDIN_ID = "stdin"
    FILE_ID = "file"

    # The background task types that hold a step (the labels Claude Code lists), and the shape of a
    # task id. The Stop hook boundary and `workflow advance --background-task` both check against these.
    BACKGROUND_TASK_TYPES = ["subagent", "workflow", "shell", "monitor", "MCP task", "cloud session"].freeze
    BACKGROUND_TASK_ID = /\A[\w-]{1,64}\z/

    # The states a plan task may be in, in the order the counts list them.
    TASK_STATES = %w[done in_progress skipped blocked todo].freeze

    # A string `id:` in a definition's text, if it parses far enough to have one.
    def self.claimed_id(text)
      value = YAML.safe_load(text)&.then { |doc| doc["id"] if doc.is_a?(Hash) }
      value if value.is_a?(String)
    rescue Psych::Exception, ArgumentError
      nil
    end

    # The id a definition file with no string `id:` key is read as: its name without the extension
    # when that is a workflow id, else {FILE_ID}.
    def self.file_id(path)
      name = File.basename(path, ".*")
      WORKFLOW_ID.match?(name) ? name : FILE_ID
    end
  end
end
