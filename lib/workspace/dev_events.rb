module Workspace
  # Writes the event-log lines that say the dev environment started or
  # stopped: `dev_started` and `dev_stopped`, both under the project's name,
  # with `data` of `workspace` and `lock` (and `reason` on a stop). They let a
  # reader refetch `dev status --json` when something changed instead of
  # polling it.
  #
  # The wrapper writes `dev_started` once its command is running and
  # `dev_stopped` with reason `exit` when the command ended on its own. Whoever
  # stops it (`dev down`, `dev up --force`) writes the stop itself, with
  # reason `down` or `forced`, and a holder removed because its wrapper died
  # is `reaped`.
  #
  # {EventLog#record} never raises, and a worktree that cannot be resolved
  # writes nothing, so no caller is ever failed by an event.
  class DevEvents
    LOCK_NAME = "devenv"

    # The `reason` values of `dev_stopped`.
    REASONS = %w[down exit reaped forced].freeze

    # @param event_log [Workspace::EventLog] where the lines go
    # @param lineage [Workspace::WorkspaceLineage] names the project and workspace of a worktree path
    def initialize(event_log:, lineage:)
      @event_log = event_log
      @lineage = lineage
    end

    # @param project [String] the project's name
    # @param workspace [String] the workspace's name (the project's own for its main checkout)
    # @return [void]
    def started(project:, workspace:)
      @event_log.record(type: "dev_started", project: project, data: {"workspace" => workspace, "lock" => LOCK_NAME})
    end

    # @param project [String] the project's name
    # @param workspace [String] the workspace's name
    # @param reason [String] one of {REASONS}
    # @return [void]
    def stopped(project:, workspace:, reason:)
      @event_log.record(type: "dev_stopped", project: project,
        data: {"workspace" => workspace, "lock" => LOCK_NAME, "reason" => reason})
    end

    # Writes `dev_stopped` for the environment a lock holder record describes,
    # naming the project and workspace from the holder's worktree.
    #
    # @param holder [Hash, nil] a holder or delegate record with a "worktree"
    # @param reason [String] one of {REASONS}
    # @return [void]
    def holder_stopped(holder, reason:)
      worktree = holder && holder["worktree"]
      return unless worktree.is_a?(String) && File.directory?(worktree)
      lineage = @lineage.resolve(cwd: worktree)
      stopped(project: lineage.name, workspace: lineage.worktree || lineage.name, reason: reason)
    rescue Workspace::Error
      nil
    end

    # A lock store's report that it removed a dead holder. Only the dev
    # environment's own wrapper counts, not a workflow run or another lock.
    #
    # @param name [String] the lock's name
    # @param holder [Hash] the removed holder's summary
    # @return [void]
    def reaped(name, holder)
      return unless name == LOCK_NAME && holder["kind"] == "process"
      holder_stopped(holder, reason: "reaped")
    end
  end
end
