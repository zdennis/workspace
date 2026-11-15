# frozen_string_literal: true

# Fake of Workspace::PaneDispatch#await_ready, the wait a review round's delivery makes for its window's agent: answers
# ready by default, or not ready (closing the window it was given through +tmux+, as the real one does, unless the
# agent waits at a screen), or raises the error it was given. Records each call.
class RecordingPaneReadiness
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param ready [Boolean] whether the agent is ready
  # @param waiting [String, nil] the screen a not-ready agent waits at (`trust`, ...), which keeps its window
  # @param error [Workspace::Error, nil] raised instead of answering
  # @param tmux [FakeTmux, nil] closes the window of a not-ready agent that waits at no screen
  def initialize(ready: true, waiting: nil, error: nil, tmux: nil)
    @ready = ready
    @waiting = waiting
    @error = error
    @tmux = tmux
    @calls = []
  end

  def await_ready(name, pane, kind, window: nil, keep: false)
    @calls << [:await_ready, name, pane, kind, keep ? {window: window, keep: true} : {window: window}]
    raise @error if @error
    result = Workspace::AgentReadiness::Result.new(ready: @ready, pane: pane, pane_id: pane, label: "Claude Code", reason: @ready ? nil : "timed out")
    closed = (!@ready && !@waiting && !keep && window) ? @tmux&.kill_window(window) || false : false
    Workspace::PaneDispatch::Spawned.new(pane: pane, ready: result, label: "Claude Code", closed: closed, waiting: @ready ? nil : @waiting)
  end
end
