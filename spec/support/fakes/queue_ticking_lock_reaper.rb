# frozen_string_literal: true

# A lock reaper whose +tick+ pushes onto the given queue and reaps nothing, so a spec waits on the queue.
class QueueTickingLockReaper
  def initialize(queue)
    @queue = queue
  end

  def tick(_cwds)
    @queue << true
    0
  end
end
