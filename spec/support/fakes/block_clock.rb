# frozen_string_literal: true

# A clock whose +now+ is the given block, for specs that need each reading to
# do something (count calls, release a lock, jump ahead).
class BlockClock
  def initialize(&now)
    @now = now
  end

  def now
    @now.call
  end
end
