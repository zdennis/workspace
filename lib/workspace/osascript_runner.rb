require "open3"

module Workspace
  # Runs one AppleScript through `osascript` and gives up after a time limit.
  # A wedged iTerm2 never answers, so without a limit every caller waits as
  # long as iTerm2 does. When the limit passes, the `osascript` process group
  # is stopped (SIGTERM, then SIGKILL after a second) and the answer is empty.
  class OsascriptRunner
    DEFAULT_TIMEOUT = 5

    # What one run produced. +stdout+ is empty when the run timed out or
    # could not start.
    Result = Struct.new(:stdout, :success, :timed_out) do
      alias_method :success?, :success
      alias_method :timed_out?, :timed_out
    end

    # @param timeout [Numeric] seconds to wait for an answer
    # @param command [Array<String>] the program to run; `-e <script>` follows
    def initialize(timeout: DEFAULT_TIMEOUT, command: ["osascript"])
      @timeout = timeout
      @command = command
    end

    # @return [Integer, Float] seconds this runner waits
    attr_reader :timeout

    # @param script [String] AppleScript source
    # @return [Result]
    def call(script)
      Open3.popen3(*@command, "-e", script, pgroup: true) do |stdin, stdout, stderr, waiter|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        [out, err].each { |reader| reader.report_on_exception = false }
        unless waiter.join(@timeout)
          stop_group(waiter)
          return Result.new("", false, true)
        end
        Result.new(out.value, waiter.value.success?, false)
      end
    rescue SystemCallError
      # No osascript (not macOS): nothing to report, same as an empty answer.
      Result.new("", false, false)
    end

    private

    def stop_group(waiter)
      Process.kill("TERM", -waiter.pid)
      Process.kill("KILL", -waiter.pid) unless waiter.join(1)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
