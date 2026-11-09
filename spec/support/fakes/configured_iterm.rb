# frozen_string_literal: true

# An iTerm fake whose session map is given.
class ConfiguredITerm < CLITestHelpers::FakeITerm
  attr_reader :session_map

  def initialize(session_map: {})
    super()
    @session_map = session_map
  end
end
