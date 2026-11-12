module Workspace
  # Which workspaces a `template` verb that works on several of them acts on: names given, `--all`,
  # `--project [NAME]`, or with none of them the workspace of the working directory. It reads the
  # selection only; each verb decides what to do with the names, and reads each workspace's own state
  # when its turn comes.
  class TemplateSelection
    # @param status_scope [Workspace::StatusScope] settles `--all`, `--project` and the current workspace
    # @param catalog [Workspace::ProjectCatalog] lists each project's configured workspaces
    # @param project_config [Workspace::ProjectConfig] says whether a named workspace has a config
    def initialize(status_scope:, catalog:, project_config:)
      @status_scope = status_scope
      @catalog = catalog
      @project_config = project_config
    end

    # @param names [Array<String>] workspaces given by name
    # @param all [Boolean, nil] every workspace that has a config
    # @param project [nil, true, String] nil for no `--project`, true for a bare one, else its NAME
    # @param working_dir [String] where the current workspace is looked for
    # @return [Array<String>] workspace names, each once, in the order given (a project's in the catalog's order)
    # @raise [Workspace::UsageError] for names with `--all` or `--project`, or both flags
    # @raise [Workspace::Error] `unknown_workspace` for a name with no config or an unknown project;
    #   `not_in_workspace` when no flag and no name is given outside a workspace
    def call(names: [], all: false, project: nil, working_dir: Dir.pwd)
      raise UsageError, "Give workspace names, or --all, or --project, not a mix." if names.any? && (all || project)
      raise UsageError, "Give only one of --all and --project." if all && project

      return named(names) if names.any?

      scope = resolve_scope(project, all, working_dir)
      case scope.kind
      when :workspace then [scope.workspace]
      when :project then configured(scope.project)
      else @catalog.all.flat_map { |found| configured(found) }.uniq
      end
    end

    private

    # StatusScope's not-in-workspace hint names `--name`, which these verbs don't take; say what they do.
    def resolve_scope(project, all, working_dir)
      @status_scope.resolve(name: nil, project: project, all: all || nil, working_dir: working_dir)
    rescue Error => e
      raise unless e.code == "not_in_workspace"
      raise Error.new("Not in a workspace. Run from a workspace checkout, or pass workspace NAMEs, --project NAME or --all.",
        code: e.code, details: e.details)
    end

    def named(names)
      names.uniq.each do |name|
        next if @project_config.exists?(name)
        raise Error.new("No workspace '#{name}'.", code: "unknown_workspace", details: {"name" => name})
      end
    end

    def configured(project)
      project.members.select { |member| member.workspace && member.configured }.map(&:workspace)
    end
  end
end
