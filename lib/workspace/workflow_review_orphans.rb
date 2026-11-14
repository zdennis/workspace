module Workspace
  # The review windows no round is using: windows a review round opened (found by their `@workspace-review` mark,
  # which a rename keeps) whose run is over or unknown, or whose run does not record them on the round it is on.
  # {#find} only reads (`doctor` lists them); {#close} closes one and removes its reviewer binding (`workflow sweep`).
  #
  # A window is the round's while the run is going, on the step the mark names, `reviewing`, and its round records
  # the window's pane or window id, or is still being delivered (a delivery closes the run's other windows itself).
  # A window the step's `review_window` names (kept by a rejected or stopped round for the next one) is in use while
  # the run is on that step, in any state.
  # A window whose run file can't be read is left alone: nothing can say it is over. A window stamped by another run
  # store ({WorkflowRunStore#stamp}: another `HOME` or `XDG_STATE_HOME` on the same tmux server, such as a scheduler's)
  # is not this store's to judge and is left out. Only a positive read from this store (`run_over`, `not_recorded`)
  # makes a window `closable`; one whose run this store does not have (`run_unknown`) is reported, never closed,
  # since it may be another store's window opened before windows were stamped.
  class WorkflowReviewOrphans
    # Each `why` {#find} answers, in words, for the sweep's and doctor's rows.
    WHY = {"run_over" => "its run is over", "run_unknown" => "no workflow run in this state directory has its id", "not_recorded" => "its run's review round does not use it"}.freeze

    # @param tmux [Workspace::Tmux] lists sessions and their marked windows, and closes a window
    # @param store [Workspace::WorkflowRunStore] reads the run a mark names, going or archived
    # @param panes [Workspace::WorkflowPanes] removes a closed window's reviewer binding
    def initialize(tmux:, store:, panes:)
      @tmux = tmux
      @store = store
      @panes = panes
    end

    # @param workspace [String, nil] only that workspace's session; nil looks at every session of the default tmux server
    # @return [Array<Hash{Symbol=>Object}>] one per orphan: :session, :window, :pane, :review (the mark), :run_id,
    #   :step, :round, :workspace (the run's, nil for an unknown run), :run (the stored run, nil when unknown) and
    #   :why (`run_over`, `run_unknown` or `not_recorded`) and :closable (true only for `run_over` and `not_recorded`);
    #   empty when tmux can't be read
    def find(workspace: nil)
      unreadable = nil
      unreadable_ids = -> { unreadable ||= @store.unreadable(archived: true).map { |path| File.basename(path, ".json") } }
      sessions(workspace).flat_map do |session|
        @tmux.review_windows(session).filter_map { |window| orphan(session, window, unreadable_ids) }
      end
    rescue Workspace::Error, SystemCallError
      []
    end

    # Closes an orphan's window, and removes the reviewer binding its pane had to the run.
    #
    # @param orphan [Hash{Symbol=>Object}] one {#find} answered
    # @return [Boolean] whether tmux closed it; false, closing nothing, for one that is not `closable`
    def close(orphan)
      return false unless orphan[:closable]
      closed = @tmux.kill_window(orphan[:window])
      @panes.unbind(orphan[:run_id], role: "reviewer", pane: orphan[:pane]) if closed && orphan[:pane]
      closed
    end

    private

    def sessions(workspace)
      return @tmux.sessions unless workspace
      @tmux.custom_socket_option(workspace) ? [] : [@tmux.session_name_for(workspace)]
    end

    def orphan(session, window, unreadable_ids)
      run_id, step, round = WorkflowPanes.parse_review_mark(window[:review])
      return nil unless run_id
      return nil if window[:store] && window[:store] != @store.stamp
      run = read_run(run_id, unreadable_ids)
      return nil if run == :unreadable
      # A session of that name on the default server is not the workspace's when the workspace runs on its own socket.
      return nil if run && @tmux.custom_socket_option(run.workspace)
      why = if run.nil? then "run_unknown"
      elsif WorkflowRunStore::TERMINAL_STATES.include?(run.state) then "run_over"
      elsif !in_use?(run, step, window) then "not_recorded"
      end
      return nil unless why
      {session: session, window: window[:window], pane: window[:pane], review: window[:review], run_id: run_id, step: step, round: round,
       workspace: run&.workspace, run: run, why: why, closable: why != "run_unknown"}
    end

    # The stored run; nil when no run has the id; :unreadable when a run file of that id (going or archived) is
    # there and can't be read ({WorkflowRunStore#unreadable}, listed once per {#find}), or the read failed otherwise.
    def read_run(run_id, unreadable_ids)
      @store.run(run_id)
    rescue Workspace::Error => e
      (e.code == "unknown_run" && !unreadable_ids.call.include?(run_id)) ? nil : :unreadable
    rescue SystemCallError
      :unreadable
    end

    def in_use?(run, step, window)
      state = run.steps[step]
      return false unless run.current == step && state
      # The window a rejected or stopped round left for the step's next round, while the author works again or that
      # round is held.
      kept = state.to_h["review_window"]
      return true if kept.is_a?(Hash) && !kept["window"].nil? && kept["window"] == window[:window]
      round = state.review
      return false unless state.state == "reviewing" && round.is_a?(Hash)
      round["delivery"] == "delivering" || (!round["pane"].nil? && round["pane"] == window[:pane]) || (!round["window"].nil? && round["window"] == window[:window])
    end
  end
end
