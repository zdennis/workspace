module Workspace
  # The one rule for which workspaces a status command reports on: the
  # current workspace, one project's members, or everything.
  class StatusScope
    # @!attribute kind [Symbol] :workspace, :project or :all
    # @!attribute workspace [String, nil] the workspace name, for :workspace
    # @!attribute project [ProjectCatalog::Project, nil] the project, for :project
    Scope = Struct.new(:kind, :workspace, :project, keyword_init: true)

    # @param project_detector [Workspace::ProjectDetector] finds the workspace of a directory
    # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects
    def initialize(project_detector:, catalog:)
      @project_detector = project_detector
      @catalog = catalog
    end

    # @param name [String, nil] the --name value; not checked here
    # @param project [nil, true, String] nil for no --project, true for a bare one, else its NAME
    # @param all [Boolean, nil] the --all flag
    # @param working_dir [String] where the current workspace is looked for
    # @return [Scope]
    # @raise [Workspace::UsageError] if more than one of name, project and all is given
    # @raise [Workspace::Error] `unknown_workspace` for an unknown project, or a bare
    #   project whose workspace is in no project; `not_in_workspace` when the current
    #   workspace is needed and the directory is in none
    def resolve(name:, project:, all:, working_dir:)
      given = [name, project, all].count { |value| value && value != "" }
      raise UsageError, "Give only one of --name, --project and --all." if given > 1

      return Scope.new(kind: :all) if all
      return Scope.new(kind: :workspace, workspace: name) if name && name != ""
      return Scope.new(kind: :project, project: @catalog.find(project)) if project.is_a?(String) && project != ""

      current = current_workspace(working_dir)
      return Scope.new(kind: :workspace, workspace: current) unless project

      Scope.new(kind: :project, project: project_of(current))
    end

    # The scope of `workflow status --needs-me`: the runs still going in every workspace, so no flag means
    # `:needs_me` with nothing narrowed. `--name` or `--project` narrows it to one workspace or one project,
    # still only runs going. `--all` is refused: it means finished runs too, which this never shows.
    #
    # @param name [String, nil] the --name value
    # @param project [nil, true, String] as for {#resolve}
    # @param all [Boolean, nil] the --all flag
    # @param working_dir [String] where a bare --project looks for the current workspace
    # @return [Scope] kind :needs_me, with `workspace` or `project` set when narrowed
    # @raise [Workspace::UsageError] for --all, or more than one of --name and --project
    # @raise [Workspace::Error] as {#resolve} for --project
    def resolve_needs_me(name:, project:, all:, working_dir:)
      raise UsageError, "--needs-me lists runs still going and takes no --all: it never shows finished runs." if all
      narrowed = resolve(name: name, project: project, all: nil, working_dir: working_dir) if (name && name != "") || (project && project != "")
      Scope.new(kind: :needs_me, workspace: narrowed&.workspace, project: narrowed&.project)
    end

    private

    def current_workspace(working_dir)
      current = @project_detector.detect(working_dir) || deepest_member(working_dir)
      return current if current

      raise Error.new(
        "Not in a workspace. Run from a workspace checkout, or pass --name WORKSPACE, --project NAME or --all.",
        code: "not_in_workspace", details: {"path" => working_dir}
      )
    end

    def deepest_member(working_dir)
      members = @catalog.all.filter_map do |project|
        member = @catalog.member_at(project, working_dir)
        member if member&.workspace
      end
      members.max_by { |member| member.path.length }&.workspace
    end

    def project_of(workspace)
      found = @catalog.all.find { |project| project.members.any? { |member| member.workspace == workspace } }
      return found if found

      raise Error.new("Workspace '#{workspace}' is in no project", code: "unknown_workspace", details: {"name" => workspace})
    end
  end
end
