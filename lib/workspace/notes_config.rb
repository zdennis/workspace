module Workspace
  # Reads `notes.instructions` from a project's YAML config, as written by
  # `workspace config set notes.instructions true|false`: whether `start` and
  # `launch` send the agent the built-in `notes` pack.
  #
  # Like {CommandsConfig}, callers pass the already-resolved parent project name
  # (see {WorkspaceLineage}).
  class NotesConfig
    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Boolean] false only when the project sets `notes.instructions` to false;
    #   unset, or a value `config set` would refuse, is true
    # @raise [Workspace::ConfigParseError] if the project's config file can't be parsed
    def instructions?(name)
      notes = @project_settings.load(name)["notes"]
      value = notes.is_a?(Hash) ? notes["instructions"] : nil
      value.to_s != "false"
    end
  end
end
