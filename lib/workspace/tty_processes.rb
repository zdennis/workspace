require_relative "timed_process"

module Workspace
  # Lists the command names of the processes attached to one terminal device (`ps -o comm= -t ttysNNN`).
  class TtyProcesses
    TIMEOUT = 2
    TTY_PATTERN = %r{\A/dev/(ttys\d+)\z}

    # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`
    def initialize(runner: TimedProcess.method(:run))
      @runner = runner
    end

    # @param tty [String] a device path such as `/dev/ttys003`
    # @return [Array<String>, nil] the command names on that terminal; nil for a path that is not an
    #   iTerm-style tty (ps is not run), a failed ps or one that timed out
    def commands(tty)
      name = tty.to_s[TTY_PATTERN, 1]
      return nil unless name

      stdout, _, success = @runner.call(["ps", "-o", "comm=", "-t", name], chdir: "/", timeout: TIMEOUT)
      return nil unless success

      stdout.to_s.lines.map(&:strip).reject(&:empty?)
    rescue SystemCallError, Timeout::Error
      nil
    end
  end
end
