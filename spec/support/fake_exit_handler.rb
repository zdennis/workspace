# Replaces Kernel.exit in tests to prevent SystemExit from killing the RSpec process.
# Raises a custom exception that behaves like SystemExit for test assertions
# but does not trigger SimpleCov's at_exit error detection.
class FakeSystemExit < RuntimeError
  attr_reader :status

  def initialize(status = 0)
    @status = status
    super("exit #{status}")
  end
end

module FakeExitHandler
  def self.exit(status = 0)
    raise FakeSystemExit.new(status)
  end
end
