# Holds one slot of a {Workspace::ScanSlotLimiter} directory, as another
# monitor's scan would, through the public +with_scan_slot+: a thread takes the
# slot and waits on a Queue until {#release}. Each thread has its own holds, so
# several of these take several slots.
class HeldScanSlot
  # @param dir [String] the slot directory
  # @param limit [Integer] how many slots the holding limiter may pick from
  # @return [HeldScanSlot] holding a slot; +held?+ is false when none was free
  def self.take(dir:, limit:, logger: Workspace::Logger.new)
    new(dir: dir, limit: limit, logger: logger)
  end

  def initialize(dir:, limit:, logger:)
    @gate = Queue.new
    taken = Queue.new
    @thread = Thread.new do
      held = false
      Workspace::ScanSlotLimiter.new(dir: dir, limit: limit, logger: logger).with_scan_slot do
        held = true
        taken << true
        @gate.pop
      end
    ensure
      taken << false unless held
    end
    @held = taken.pop
  end

  # @return [Boolean] whether a slot was free and is now held
  def held? = @held

  # Lets the holding thread finish, which frees the slot.
  def release
    @gate << :release if @held
    @thread.join
  end
end
