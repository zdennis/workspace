module Workspace
  # Finds the checkout and branch a command such as `rebase` or `push` works on:
  # the named workspace, else the one the working directory is in.
  class WorkspaceCheckout
    # @param git [Workspace::Git]
    # @param project_config [Workspace::ProjectConfig] finds a named workspace's checkout
    # @param project_detector [Workspace::ProjectDetector] names the workspace of a directory
    def initialize(git:, project_config:, project_detector:)
      @git = git
      @project_config = project_config
      @project_detector = project_detector
    end

    # @param name [String, nil] the workspace; nil means the one +working_dir+ is in
    # @param working_dir [String]
    # @param allow_detached [Boolean] return a nil branch for a detached HEAD instead of raising
    # @return [Hash] `{"workspace" =>, "path" =>, "branch" =>}`
    # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, or an uncoded error for a detached HEAD
    def resolve(name, working_dir:, allow_detached: false)
      name ||= @project_detector.detect(working_dir)
      unless name
        raise Workspace::Error.new("No workspace found for #{working_dir}. Run from inside a workspace or pass --name.",
          code: "not_in_workspace", details: {"path" => working_dir})
      end
      root = @project_config.project_root_for(name)
      raise Workspace::Error.new("Unknown project '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root

      path = File.expand_path(root)
      branch = @git.worktree_branch(path)
      raise Workspace::Error, "'#{name}' is on a detached HEAD at #{path}. Check out a branch first." if branch.nil? && !allow_detached

      {"workspace" => name, "path" => path, "branch" => branch}
    end
  end
end
