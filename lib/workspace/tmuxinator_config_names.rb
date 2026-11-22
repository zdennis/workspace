module Workspace
  # The names of the workspaces that have a tmuxinator config
  # (`workspace.<name>.yml` in the tmuxinator directory), template files left out.
  #
  # Depends on nothing but the config's `tmuxinator_dir`, so a caller that must
  # list the names without building {ProjectConfig} can use it.
  class TmuxinatorConfigNames
    # @param config [Workspace::Config] answers `tmuxinator_dir`
    def initialize(config:)
      @config = config
    end

    # @return [Array<String>] sorted workspace names
    def call
      Dir.glob(File.join(@config.tmuxinator_dir, "workspace.*.yml"))
        .map { |f| File.basename(f, ".yml").delete_prefix("workspace.") }
        .reject { |n| n.match?(/^project-.*template$/) }
        .sort
    end

    # So an instance can stand where {ProjectConfig} is used only to list names.
    alias_method :available_projects, :call
  end
end
