# frozen_string_literal: true

require "delegate"

# A run store over a real one that can answer +find+ of one id from a snapshot
# taken earlier, as a second process that read the run before it changed would.
class PinnedFindStore < SimpleDelegator
  def initialize(store)
    super
    @pinned = {}
  end

  def pin_find(id)
    @pinned[id] = __getobj__.find(id)
  end

  def find(id)
    @pinned.fetch(id) { super }
  end

  def run(id)
    Workspace::WorkflowRun.from_h(find(id))
  end
end
