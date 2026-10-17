module Workspace
  # The one place a workspace name is compared or settled. Names are lowercase
  # going forward, but configs written earlier keep their mixed case on disk,
  # and macOS file systems ignore case, so `notes` and `Notes` reach the same
  # files and socket. Callers use #resolve at an input, and .same? to compare.
  class WorkspaceName
    # @param name [String, nil]
    # @return [String, nil] the name in lowercase
    def self.normalize(name)
      name&.downcase
    end

    # @return [Boolean] whether two names are the same workspace, ignoring case
    def self.same?(first, second)
      !first.nil? && !second.nil? && first.casecmp?(second)
    end

    # @param project_config [Workspace::ProjectConfig] lists the workspaces that have a config
    def initialize(project_config:)
      @project_config = project_config
    end

    # @return [String, nil] the name of the existing config that +name+ matches
    #   ignoring case (the exact spelling first), nil when none does
    def match(name)
      return nil if name.nil?

      projects = @project_config.available_projects
      projects.find { |existing| existing == name } || projects.find { |existing| self.class.same?(existing, name) }
    end

    # @return [String, nil] the on-disk name of the config +name+ matches, else
    #   the name in lowercase; nil stays nil
    def resolve(name)
      return nil if name.nil?

      match(name) || self.class.normalize(name)
    end
  end
end
