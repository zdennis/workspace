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
  end
end
