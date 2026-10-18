module Workspace
  # Reads `spine.template` and `spine.auto`, as written by `workspace config set`:
  # which spine template `spine init` and `start` use, and whether `start` runs
  # `spine init` on its own. Both are layered global < project < worktree and read
  # through {ConfigResolver}.
  class SpineConfig
    # The template used when nothing sets one.
    DEFAULT_TEMPLATE = "default"

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param workspace [String] a workspace or project name
    # @return [Hash{String=>String}] "name" of the template and its "source": `worktree`,
    #   `project`, `global` or `default`. A stored value that is not a string is the default.
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def template(workspace)
      hit = @config_resolver.view(workspace: workspace).resolve("spine.template").winner
      name = hit.value.strip if hit&.value.is_a?(String)
      return {"name" => DEFAULT_TEMPLATE, "source" => "default"} if name.to_s.empty?
      {"name" => name, "source" => hit.layer}
    end

    # @param workspace [String] a workspace or project name
    # @return [Boolean] true only when `spine.auto` is set to true
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def auto?(workspace)
      @config_resolver.view(workspace: workspace).raw("spine.auto").to_s == "true"
    end
  end
end
