module Workspace
  # Reads `notes.instructions` from a project's YAML config, as written by
  # `workspace config set notes.instructions true|false`: whether `start` and
  # `launch` send the agent the built-in `notes` pack.
  #
  # Like {CommandsConfig}, the key is read through {ConfigResolver}.
  class NotesConfig
    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param workspace [String] a workspace or project name
    # @return [Boolean] false only when `notes.instructions` is set to false;
    #   unset, or a value `config set` would refuse, is true
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def instructions?(workspace)
      @config_resolver.view(workspace: workspace).raw("notes.instructions").to_s != "false"
    end
  end
end
