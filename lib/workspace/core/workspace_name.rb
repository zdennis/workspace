module Workspace
  # The one place a workspace name is compared or settled. New names are
  # written in lowercase, but configs written earlier keep their mixed case on disk,
  # and macOS file systems ignore case, so `notes` and `Notes` reach the same
  # files and socket. Callers use #resolve at an input, and .same? to compare.
  class WorkspaceName
    # What joins a project name to a worktree suffix in a worktree workspace name.
    SEPARATOR = ".worktree-"

    # Splits a worktree workspace name at its first separator.
    #
    # @param name [String, nil] a project or worktree config name
    # @return [Array(String, String), nil] [project, suffix], nil when the name has no separator
    def self.split(name)
      return nil unless name&.include?(SEPARATOR)
      name.split(SEPARATOR, 2)
    end

    # @return [Boolean] whether the name has a separator
    def self.worktree?(name)
      !split(name).nil?
    end

    # @return [String, nil] the project part of a worktree name, else the name itself
    def self.project_of(name)
      split(name)&.first || name
    end

    # @return [String] the worktree workspace name for a project and suffix, in lowercase
    def self.join(project, suffix)
      normalize("#{project}#{SEPARATOR}#{suffix}")
    end

    # @return [Boolean] whether the name differs from its lowercase form
    def self.mixed_case?(name)
      name != normalize(name)
    end

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
    # @param state [Workspace::State, nil] read only to keep an active workspace
    #   with no config from being taken over by a suffix hit
    def initialize(project_config:, state: nil)
      @project_config = project_config
      @state = state
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

    # Settles a name a person typed. The exact name (any case) wins; else the
    # one config whose worktree suffix (the part after the separator) equals
    # the name, ignoring case. An active workspace with no config keeps its name,
    # even over a tie.
    #
    # @param name [String, nil]
    # @return [String, nil] the full on-disk name, nil when nothing matches
    # @raise [Workspace::Error] `ambiguous_workspace` when several configs share the suffix
    def for_input(name)
      return nil if name.nil? || name.empty?

      exact = match(name)
      return exact if exact

      hits = @project_config.available_projects.select do |existing|
        suffix = WorkspaceLineage.split_worktree_name(existing)&.last
        !suffix.nil? && self.class.same?(suffix, name)
      end
      return nil if hits.empty?

      if @state
        @state.load
        return nil if @state.keys.any? { |key| self.class.same?(key, name) }
      end
      return hits.first if hits.size == 1

      matches = hits.sort
      raise Workspace::Error.new("'#{name}' matches more than one workspace: #{matches.join(", ")}. Give the full name.",
        code: "ambiguous_workspace", details: {"name" => name, "matches" => matches})
    end
  end
end
