# A {FakeLockLiveness} that records each `alive?` question, so a spec can tell how many passes read a lock.
class CountingLockLiveness < FakeLockLiveness
  attr_reader :checks

  def initialize(**)
    super
    @checks = []
  end

  def alive?(pid:, started:)
    @checks << pid
    super
  end
end
