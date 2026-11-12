# frozen_string_literal: true

require "delegate"

# A run store over a real one that can answer +run+ of one id from a snapshot
# taken earlier, as a second process that read the run before it changed would.
class PinnedFindStore < SimpleDelegator
  def initialize(store)
    super
    @pinned = {}
  end

  def pin_find(id)
    @pinned[id] = __getobj__.run(id)
  end

  def run(id)
    @pinned.fetch(id) { super }
  end
end
