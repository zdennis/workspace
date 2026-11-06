# frozen_string_literal: true

require "stringio"

# A StringIO that wakes a waiter once "ready" has been written (or +announce+ is called), so a
# spec waits on +wait_ready+ instead of polling the text.
class ReadyAnnouncingOutput < StringIO
  def initialize(*)
    super
    @ready = Queue.new
  end

  def write(*args)
    written = super
    announce if string.include?("ready")
    written
  end

  def announce
    @ready << true
  end

  def wait_ready(timeout: 5)
    @ready.pop(timeout: timeout) || raise("daemon did not print \"ready\" within #{timeout}s")
  end
end
