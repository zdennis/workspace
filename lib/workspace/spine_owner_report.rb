module Workspace
  # Records `spine_changed` with `change: "owner_finished"` when the agent that owns a started stage
  # ends its turn, so a reader can show "the stage's agent finished" without watching the pane.
  #
  # Two signals feed it: the agent daemon's Stop hook for a pane ({#turn_ended}), which reports each
  # stage whose `owner` is that pane and that is still `in_progress`, at every turn end; and
  # {SpineWatcher}, which calls {#stage_completed} once when a stage with an owner moves to
  # `completed`. A Stop never reports a completed stage, so a restart of the daemon or a reused pane
  # id cannot report an old completion again. A pane that owns no stage writes nothing.
  class SpineOwnerReport
    # @param workspace [String] the workspace name
    # @param dir_resolver [#call] given the workspace name, returns its notes directory, or nil
    # @param event_log [Workspace::EventLog] gets `spine_changed`
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, dir_resolver:, event_log:, logger: Workspace::Logger.new)
      @workspace = workspace
      @dir_resolver = dir_resolver
      @event_log = event_log
      @logger = logger
    end

    # The pane's agent ended its main turn.
    #
    # @param pane_id [String] the tmux pane id
    # @return [Integer] how many lines were written
    def turn_ended(pane_id)
      return 0 if pane_id.to_s.empty?
      dir = @dir_resolver.call(@workspace)
      return 0 unless dir
      written = 0
      SpineTree.read(dir).each_stage do |stage|
        file = stage.file
        next unless file&.read? && file.status == "in_progress" && file.value("owner") == pane_id
        written += 1 if record(stage.path, pane_id, "in_progress")
      end
      written
    rescue => e
      @logger.debug { "spine owner report: #{e.class}: #{e.message}" }
      0
    end

    # A stage with an owner moved to `completed`.
    #
    # @param path [String] the stage's path
    # @param owner [String] the owner pane id
    # @param check [String, nil] the stage's `check` value
    # @return [Boolean] whether a line was written
    def stage_completed(path, owner, check)
      return false if owner.to_s.empty?
      record(path, owner, %w[required pending].include?(check) ? "checking" : "completed")
    end

    private

    def record(path, owner, state)
      !!@event_log.record(type: "spine_changed", project: @workspace,
        data: {"workspace" => @workspace, "path" => path, "change" => "owner_finished", "owner" => owner, "state" => state})
    end
  end
end
