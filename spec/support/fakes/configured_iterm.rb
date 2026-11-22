# frozen_string_literal: true

# An iTerm fake whose session map and single-session windows are given.
class ConfiguredITerm < CLITestHelpers::FakeITerm
  attr_reader :session_map

  def initialize(session_map: {}, single_session_windows: [])
    super()
    @session_map = session_map
    @single_session_windows = single_session_windows
  end

  def single_session_windows(tail_lines: 200) = @single_session_windows
end
