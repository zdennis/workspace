# frozen_string_literal: true

# Captures the completion callback instead of polling tmux on a thread, so
# specs can decide exactly when a stage finishes.
class FakeSentinelPoller
  # What a spec reads off the fake; the real poller has no such readers.
  CONTROL_METHODS = %i[session_name pane token deadline on_complete on_error on_timeout stopped?].freeze

  attr_reader :session_name, :pane, :token, :deadline, :on_complete, :on_error, :on_timeout

  def initialize(session_name:, pane:, token: nil, deadline: nil)
    @session_name = session_name
    @pane = pane
    @token = token
    @deadline = deadline
  end

  def start(on_error: nil, on_timeout: nil, &block)
    @on_complete = block
    @on_error = on_error
    @on_timeout = on_timeout
    self
  end

  def stop
    @stopped = true
  end

  def stopped? = !!@stopped
end
