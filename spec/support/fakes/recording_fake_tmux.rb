# frozen_string_literal: true

require_relative "fake_tmux"

# A FakeTmux that lists the tmux calls made on it, outermost call only (a call the fake makes to
# itself is not one more tmux call), so a spec can pin which calls a code path makes.
#
#   tmux = RecordingFakeTmux.new(details: [{id: "%5", window: 0, index: 1, pid: 100}])
#   tmux.calls  # => [:pane_details, :server_pid_for_pane, :capture_screen_styled]
class RecordingFakeTmux < FakeTmux
  CONTROL_METHODS = (FakeTmux::CONTROL_METHODS + %i[calls calls=]).freeze
  RECORDED = %i[pane_details server_pid_for_pane capture_screen capture_screen_styled capture_pane deliver send_key].freeze

  attr_accessor :calls

  def initialize(**options)
    super
    @calls = []
    @depth = 0
  end

  RECORDED.each do |name|
    define_method(name) do |*args, **kw, &block|
      @calls << name if @depth.zero?
      @depth += 1
      begin
        super(*args, **kw, &block)
      ensure
        @depth -= 1
      end
    end
  end

  # The calls with each run of the same call collapsed to one, for paths that poll a screen.
  def call_runs = @calls.chunk_while { |a, b| a == b }.map(&:first)
end
