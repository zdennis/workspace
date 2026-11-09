# frozen_string_literal: true

module Workspace
  # One Mutex per tmux pane id, made on first use. Safe to ask from several threads.
  class PaneLocks
    def initialize
      @locks = {}
      @guard = Mutex.new
    end

    # @param pane_id [String] tmux pane id, e.g. "%5"
    # @return [Mutex] the same Mutex for the same pane id on every call
    def for(pane_id)
      @guard.synchronize { @locks[pane_id] ||= Mutex.new }
    end
  end
end
