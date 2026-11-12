module Workspace
  # Reads `tmuxinator.template` and `tmuxinator.worktree_template`, as written by
  # `workspace config set`: which `template` library set a new tmuxinator config is
  # rendered from. Both are layered global < project < worktree and read through
  # {ConfigResolver}.
  class TmuxinatorTemplateConfig
    # The set used when nothing sets one.
    DEFAULT_TEMPLATE = "default"

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param kind [Symbol] `:project` or `:worktree`; the worktree kind reads
    #   `tmuxinator.worktree_template` first and follows `tmuxinator.template` when that is unset
    # @param workspace [String, nil] a workspace or project name; nil reads the global file alone
    # @return [Hash{String=>String}] "name" of the set and its "source": `worktree`,
    #   `project`, `global` or `default`. A stored value that is not a valid name (a hand-edited
    #   file can hold one) is treated as unset.
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def name(kind, workspace:)
      view = @config_resolver.view(workspace: workspace, upto: workspace ? nil : "global")
      keys = (kind == :worktree) ? %w[tmuxinator.worktree_template tmuxinator.template] : %w[tmuxinator.template]
      keys.each do |key|
        hit = view.resolve(key).winner
        value = hit.value.strip if hit&.value.is_a?(String)
        return {"name" => value, "source" => hit.layer} if value.to_s.match?(IdPatterns::LIBRARY_NAME)
      end
      {"name" => DEFAULT_TEMPLATE, "source" => "default"}
    end
  end
end
