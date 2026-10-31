module Workspace
  # Whether a workspace's `IMPLEMENTATION_PLAN.md` says `status: paused`, read
  # fresh on each call. A notes directory or plan that can't be read is not paused.
  class PlanPaused
    # @param workspace [String] the workspace whose plan is read
    # @param dir_resolver [#call] given the workspace, its notes directory
    def initialize(workspace:, dir_resolver:)
      @workspace = workspace
      @dir_resolver = dir_resolver
    end

    # @return [Boolean]
    def call
      PlanFile.read(PlanFile.path_in(@dir_resolver.call(@workspace)))&.status == "paused"
    rescue Workspace::Error, SystemCallError
      false
    end
  end
end
