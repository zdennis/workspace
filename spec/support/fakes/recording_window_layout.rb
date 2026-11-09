# frozen_string_literal: true

# A window layout fake that records the entries it was asked to tile.
class RecordingWindowLayout < CLITestHelpers::FakeWindowLayout
  attr_reader :tiled_entries

  def tile(entries)
    @tiled_entries = entries
    nil
  end
end
