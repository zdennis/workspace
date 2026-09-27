module Workspace
  # Runs the user's notify command for a session alert (a pane waiting on a
  # person, or idle too long) without ever holding up the caller.
  #
  # The command comes from the user's own config and runs through the shell,
  # like `dev.up`. Everything about the alert, including the agent's message,
  # reaches it only as environment variables, never as text spliced into the
  # command line, so a message can't inject shell syntax.
  #
  # Each run happens on its own thread in its own process group. A command
  # still running after the timeout, or when the notifier is stopped, gets
  # SIGTERM, then SIGKILL, sent to that group (never to the daemon's own), and
  # is always reaped. SIGKILL goes out after the grace period even when the
  # command itself has exited, so a child that ignored SIGTERM can't outlive it.
  class Notifier
    # Seconds a notify command may run before it is stopped.
    DEFAULT_TIMEOUT = 10

    # Seconds between SIGTERM and SIGKILL for a command past its timeout.
    KILL_GRACE = 2

    # Runs allowed at once. Past this, an alert is skipped with a warning, so
    # a command that always hangs can't pile up threads and processes.
    MAX_IN_FLIGHT = 4

    # @param command [String] the shell command to run
    # @param timeout [Numeric] seconds before a run is stopped
    # @param kill_grace [Numeric] seconds between SIGTERM and SIGKILL
    # @param max_in_flight [Integer] runs allowed at once
    # @param spawner [#call] Process.spawn-compatible, injected for tests
    # @param error_output [IO] where failures and skipped alerts are reported
    # @param label [String] prefix for those reports, naming the command that notified
    def initialize(command:, timeout: DEFAULT_TIMEOUT, kill_grace: KILL_GRACE, max_in_flight: MAX_IN_FLIGHT,
      spawner: Process.method(:spawn), error_output: $stderr, label: "workspace agent")
      @command = command
      @timeout = timeout
      @kill_grace = kill_grace
      @max_in_flight = max_in_flight
      @spawner = spawner
      @error_output = error_output
      @label = label
      @threads = []
      @pids = []
      @stopped = false
      @lock = Mutex.new
    end

    # Starts the command in the background and returns at once.
    #
    # @param env [Hash{String => String}] environment variables describing the alert
    # @return [Thread, nil] the thread running the command, or nil if skipped
    def notify(env)
      @lock.synchronize do
        return nil if @stopped
        @threads.select!(&:alive?)
        if @threads.size >= @max_in_flight
          report "#{@label}: skipped notify command for #{env["WORKSPACE_ALERT_TEXT"]} " \
            "(#{@threads.size} earlier runs still going)"
          return nil
        end
        thread = Thread.new { run(env) }
        @threads << thread
        thread
      end
    end

    # Waits for in-flight runs, each of which ends within its timeout plus
    # grace. Used by tests and shutdown.
    #
    # @param limit [Numeric] seconds to wait for each run
    # @return [void]
    def wait(limit = @timeout + @kill_grace + 1)
      @lock.synchronize { @threads.dup }.each { |thread| thread.join(limit) }
    end

    # Stops every run still going (SIGTERM, then SIGKILL after the grace
    # period) and refuses new ones. Returns within about twice the grace
    # period. Safe to call more than once.
    #
    # @return [void]
    def stop
      pids = @lock.synchronize do
        @stopped = true
        @pids.dup
      end
      terminate(pids)
      wait(@kill_grace)
    end

    private

    def run(env)
      pid = @spawner.call(env, @command, pgroup: true, in: File::NULL, out: File::NULL)
      waiter = Process.detach(pid)
      # A stop that landed between the spawn and this registration never saw
      # the pid, so the run stops itself.
      stopped = @lock.synchronize do
        @pids << pid
        @stopped
      end
      return terminate([pid], waiter) if stopped

      if waiter.join(@timeout)
        status = waiter.value
        report "#{@label}: notify command failed (#{status})" if status && !status.success? && !@stopped
        return
      end
      return if @stopped

      report "#{@label}: notify command still running after #{@timeout}s; stopping it"
      terminate([pid], waiter)
    rescue => e
      report "#{@label}: notify command failed to start: #{e.message}"
    ensure
      @lock.synchronize { @pids.delete(pid) } if pid
    end

    # Waits out the grace period only while some group still has members, but
    # always sends SIGKILL at the end: the command exiting on SIGTERM says
    # nothing about a child of it that ignored the signal.
    def terminate(pids, waiter = nil)
      pids.each { |pid| signal_group("TERM", pid) }
      deadline = monotonic + @kill_grace
      sleep 0.05 while pids.any? { |pid| group_alive?(pid) } && monotonic < deadline
      pids.each { |pid| signal_group("KILL", pid) }
      waiter&.join(@kill_grace)
    end

    # With pgroup: true the child leads a group whose id is its own pid, so
    # this reaches the command and anything it started, but never the daemon.
    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A closed or broken stream must never keep a run from being stopped.
    def report(message)
      @error_output.puts message
    rescue
      nil
    end
  end
end
