module Workspace
  # The agent daemon's workflow nudge for one workspace: wakes a workflow run when the main agent's turn ends
  # in its pane, and ticks the nudger from the socket watcher. Holds when the main agent's current turn began
  # in each pane.
  class WorkflowNudge
    # @param workspace [String] the workspace served, named to the workflow nudger
    # @param nudger [Workspace::WorkflowNudger, nil] wakes a workflow run when a turn ends in its pane; nil wakes none
    # @param hook_log [Workspace::HookEventLog, nil] passed to the nudger so its decision lines share the log's ids
    # @param turn_settled [#call] called once a turn's workflow advance has exited, or at once when none was woken
    # @param clock [#call] returns the current Time, for when a turn began
    def initialize(workspace:, nudger:, turn_settled:, hook_log: nil, clock: -> { Time.now })
      @workspace = workspace
      @nudger = nudger
      @hook_log = hook_log
      @turn_settled = turn_settled
      @clock = clock
      # When the main agent's current turn began, by pane id.
      @turn_starts = {}
    end

    # Follows one hook event of the main agent (a sub-agent's is ignored): a prompt records when the turn
    # began, a new conversation forgets it, and a Stop wakes the run bound to the pane. The run is told when
    # that turn began, so a turn already under way when the step's line was typed does not decide the step; a
    # turn whose start was not seen is sent without one. `turn_settled` is called once the advance the Stop
    # woke has exited, or at once when the nudger is nil or woke no run.
    #
    # @param message [Hash] the `session_event` message
    # @return [void]
    def session_event(message)
      return unless message["agent_id"].nil?

      pane_id = message["pane_id"]
      case message["event"]
      when "user_prompt" then @turn_starts[pane_id] = @clock.call
      # A new conversation: a prompt this daemon then fails to see leaves no start, so its turn's end counts.
      when "session_start", "session_end" then @turn_starts.delete(pane_id)
      when "stop" then turn_ended(pane_id, message)
      end
    end

    # The socket watcher's tick: lets the nudger do its periodic work. Does nothing without a nudger.
    #
    # @return [void]
    def tick
      @nudger&.tick(@workspace, hook_log: @hook_log)
    end

    private

    def turn_ended(pane_id, message)
      woken = @nudger&.turn_ended(@workspace, pane_id, turn_started: @turn_starts[pane_id], background: message["background_tasks"],
        transcript_path: message["transcript_path"], hook_log: @hook_log, on_exit: @turn_settled)
      @turn_settled.call if woken.nil?
    end
  end
end
