require "fileutils"

module Workspace
  # Runs a workflow step's `status:` command in the run's checkout and says
  # how it ended. The command runs through `sh -c` in its own process group,
  # with its output in a log file the step's failure names; one that runs
  # past its time limit, or whose run moved on while it ran, is stopped,
  # group and all. A caller interrupted or terminated while it waits stops the group too.
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

    # What a check is told about its run: `WORKSPACE_RUN_ID`, `WORKSPACE_RUN_ARTIFACTS` and `WORKSPACE_RUN_BASE_SHA`
    # (empty for a run with no recorded commit), and every inherited `GIT_*` variable removed, so a caller's
    # `GIT_DIR`, `GIT_INDEX_FILE` or `GIT_CONFIG_*` can't steer the check.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @return [Hash{String=>String, nil}]
    def self.env_for(run)
      run = WorkflowRun.from_h(run)
      ENV.keys.select { |name| name.start_with?("GIT_") }.to_h { |name| [name, nil] }.merge(
        "WORKSPACE_RUN_ID" => run.id, "WORKSPACE_RUN_ARTIFACTS" => run.artifacts_dir.to_s,
        "WORKSPACE_RUN_BASE_SHA" => run.base_sha.to_s
      )
    end

    # Runs either a shell `command:` (through `sh -c`) or an `argv:` array (no shell: the program and its
    # arguments go to the kernel as they are, so an argument is never split or expanded). Give exactly one.
    #
    # @param command [String, nil] a shell command
    # @param argv [Array<String>, nil] a program and its arguments, run without a shell
    # @param cwd [String] the directory it runs in
    # @param timeout [Numeric] seconds it may run
    # @param log [String] the file its stdout and stderr go to
    # @param stop_when [#call, nil] asked every {STOP_POLL} seconds; true stops the check
    #   (its run was cancelled or moved to another step)
    # @param env [Hash{String=>String}] added to the command's environment
    # @return [Hash] :exit_code (nil when it was stopped or never started),
    #   :timed_out, and :error (why it has no exit code) when there is one
    # @raise [ArgumentError] when both or neither of command: and argv: are given, or argv: is empty
    def call(cwd:, timeout:, log:, command: nil, argv: nil, stop_when: nil, env: {})
      raise ArgumentError, "give exactly one of command: or argv:" if command.nil? == argv.nil?
      raise ArgumentError, "argv: must be a non-empty array" if argv && (!argv.is_a?(Array) || argv.empty?)
      log_io = open_log(log)
      opts = {chdir: cwd, pgroup: true, in: File::NULL, out: log_io, err: [:child, :out]}
      pid = begin
        if argv
          Process.spawn(env, [argv[0], argv[0]], *argv[1..], **opts)
        else
          Process.spawn(env, "sh", "-c", command, **opts)
        end
      ensure
        log_io.close
      end
      status = nil
      begin
        status = wait(pid, timeout, stop_when)
      ensure
        stop(pid) unless status.is_a?(Process::Status)
      end
      return {exit_code: status.exitstatus, timed_out: false} if status.is_a?(Process::Status)
      return {exit_code: nil, timed_out: true} if status == :timed_out
      {exit_code: nil, timed_out: false, error: "stopped: the run moved on"}
    rescue SystemCallError => e
      {exit_code: nil, timed_out: false, error: "could not run the check (#{e.class})"}
    end

    private

    # Opens the log without following a link at its last component, and refuses a log whose directory is a
    # link: the log lives in a checkout an agent can write.
    def open_log(log)
      dir = File.dirname(log)
      FileUtils.mkdir_p(dir)
      raise Errno::ELOOP, dir if File.lstat(dir).symlink?
      io = File.open(log, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW | File::NONBLOCK, 0o600)
      return io if io.stat.file?
      io.close
      raise Errno::EINVAL, log
    end

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

    # TERM, a grace period, then KILL. If the stop itself is interrupted the group still gets KILL.
    def stop(pid)
      exited = false
      signal("TERM", pid)
      exited = wait(pid, @kill_grace).is_a?(Process::Status)
    rescue Errno::ECHILD
      exited = true
    ensure
      unless exited
        signal("KILL", pid)
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
