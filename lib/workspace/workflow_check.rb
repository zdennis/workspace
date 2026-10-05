require "fileutils"

module Workspace
  # Runs a workflow step's `status:` command in the run's checkout and says
  # how it ended. The command runs through `sh -c` in its own process group,
  # with its output in a log file the step's failure names; one that runs
  # past its time limit, or whose run moved on while it ran, is stopped,
  # group and all.
  class WorkflowCheck
    # Seconds a stopped check gets between SIGTERM and SIGKILL.
    KILL_GRACE = 5

    # Seconds between two looks at whether the run still wants the check.
    STOP_POLL = 2

    # @param clock [#call] monotonic seconds
    # @param sleeper [#call] sleeps the given seconds
    # @param kill_grace [Numeric] see {KILL_GRACE}
    # @param stop_poll [Numeric] see {STOP_POLL}
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) },
      kill_grace: KILL_GRACE, stop_poll: STOP_POLL)
      @clock = clock
      @sleeper = sleeper
      @kill_grace = kill_grace
      @stop_poll = stop_poll
    end

    # @param command [String] a shell command
    # @param cwd [String] the directory it runs in
    # @param timeout [Numeric] seconds it may run
    # @param log [String] the file its stdout and stderr go to
    # @param stop_when [#call, nil] asked every {STOP_POLL} seconds; true stops the check
    #   (its run was cancelled or moved to another step)
    # @return [Hash] :exit_code (nil when it was stopped or never started),
    #   :timed_out, and :error (why it has no exit code) when there is one
    def call(command:, cwd:, timeout:, log:, stop_when: nil)
      FileUtils.mkdir_p(File.dirname(log))
      pid = Process.spawn("sh", "-c", command, chdir: cwd, pgroup: true, in: File::NULL, out: [log, "w"], err: [:child, :out])
      status = wait(pid, timeout, stop_when)
      return {exit_code: status.exitstatus, timed_out: false} if status.is_a?(Process::Status)
      stop(pid)
      return {exit_code: nil, timed_out: true} if status == :timed_out
      {exit_code: nil, timed_out: false, error: "stopped: the run moved on"}
    rescue SystemCallError => e
      {exit_code: nil, timed_out: false, error: "could not run the check (#{e.class})"}
    end

    private

    # @return [Process::Status, Symbol] how it exited, or :timed_out or :stopped
    def wait(pid, seconds, stop_when = nil)
      deadline = @clock.call + seconds
      asked = @clock.call
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        now = @clock.call
        return :timed_out if now >= deadline
        if stop_when && now - asked >= @stop_poll
          asked = now
          return :stopped if stop_when.call
        end
        @sleeper.call(0.1)
      end
    end

    def stop(pid)
      signal("TERM", pid)
      return if wait(pid, @kill_grace).is_a?(Process::Status)
      signal("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
