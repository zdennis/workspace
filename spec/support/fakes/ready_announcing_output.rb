# frozen_string_literal: true

require "stringio"

# A StringIO that wakes a waiter once "ready" has been written (or +announce+ is called), so a
# spec waits on +wait_ready+ instead of polling the text. +wait_for_text+ does the same for any text.
class ReadyAnnouncingOutput < StringIO
  def initialize(*)
    super
    @ready = Queue.new
    @mutex = Mutex.new
    @changed = ConditionVariable.new
  end

  def write(*args)
    written = super
    announce if string.include?("ready")
    @mutex.synchronize { @changed.broadcast }
    written
  end

  def announce
    @ready << true
  end

  def wait_ready(timeout: 5)
    @ready.pop(timeout: timeout) || raise("daemon did not print \"ready\" within #{timeout}s")
  end

  def wait_for_text(text, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @mutex.synchronize do
      until string.include?(text)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise("did not see #{text.inspect} within #{timeout}s") if remaining <= 0
        @changed.wait(@mutex, remaining)
      end
    end
  end
end
