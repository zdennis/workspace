# frozen_string_literal: true

# Stands in for NameMigration's startup locks: runs the block, and says while it runs which name is held,
# so a spec can tell a step ran inside the lock.
class RecordingStartupLocks
  CONTROL_METHODS = %i[held taken].freeze

  # @return [String, nil] the name whose lock the running block holds
  attr_reader :held

  # @return [Array<String>] every name a block ran under, in order
  attr_reader :taken

  def initialize
    @held = nil
    @taken = []
  end

  def hold_if_possible(name)
    @taken << name
    @held = name
    yield
  ensure
    @held = nil
  end
end
