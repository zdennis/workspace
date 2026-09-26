module Workspace
  # The wrapper process behind `workspace dev __run`: holds the `devenv` lock
  # for exactly as long as the dev command runs.
  #
  # The command runs through the shell with the worktree root as cwd and
  # inherits the wrapper's stdin, stdout and stderr (the pane's TTY). It
  # stays in the wrapper's own process group, so it keeps the terminal:
  # Ctrl-C reaches wrapper and child together, and reading stdin never
  # raises SIGTTIN. The wrapper never `exec`s, so it is alive to release the
  # lock when the command exits; a SIGKILLed wrapper is left to dead-pid
  # reaping.
  #
  # The wrapper must lead its process group, since that group is recorded in
  # the lock and signalled as a whole. `dev down` and `--takeover` send
  # SIGTERM (or SIGHUP) to the wrapper pid only; the wrapper forwards it once
  # to the whole group, reaching the command's own children too, and ignores
  # the copy delivered back to itself.
  class DevRunner
    LOCK_NAME = "devenv"
    DEFAULT_POLL_SECONDS = 1

    # @param liveness [Workspace::LockHolder] supplies this process's start time
    # @param output [IO] receives the header and exit-status lines
    # @param env [Hash] environment lookup (for TMUX_PANE)
    # @param trap [#call] installs a signal handler, called as `trap.call(signal, handler)`
    #   like `Signal.trap`, returning the previous handler
    # @param spawner [#call] called as `spawner.call(command, chdir)`, returns the child pid
    # @param kill [#call] sends a signal, called as `kill.call(signal, target)` like `Process.kill`
    # @param pgrp [#call] returns this process's process group id
    # @param sleeper [#call] sleeps between polls while queued
    # @param poll [Numeric] seconds between polls while queued
    def initialize(liveness:, output: $stdout, env: ENV,
      trap: ->(signal, handler) { Signal.trap(signal, handler) },
      spawner: ->(command, chdir) { Process.spawn("/bin/sh", "-c", command, chdir: chdir) },
      kill: ->(signal, target) { Process.kill(signal, target) },
      pgrp: -> { Process.getpgrp },
      sleeper: ->(seconds) { sleep(seconds) }, poll: DEFAULT_POLL_SECONDS)
      @liveness = liveness
      @output = output
      @env = env
      @trap = trap
      @spawner = spawner
      @kill = kill
      @pgrp = pgrp
      @sleeper = sleeper
      @poll = poll
    end

    # Acquires `devenv`, runs +command+ to completion, and releases the lock.
    #
    # @param store [Workspace::LockStore] the namespace's lock store
    # @param command [String] shell command to run
    # @param worktree [String] worktree root, used as the command's cwd
    # @param branch [String, nil] branch recorded in the lock holder
    # @param wait [Boolean] queue FIFO behind the current holder instead of failing
    # @return [Integer] the child's exit status, 128 + signal number if it was
    #   killed (or the wait was interrupted), or 4 if the lock was cleared while queued
    # @raise [Workspace::Error] if the lock is held by someone else (without
    #   +wait+), the wrapper does not lead its process group, or the command
    #   cannot be started
    def call(store:, command:, worktree:, branch: nil, wait: false)
      holder = identity(worktree, branch)
      waited = acquire!(store, holder, wait)
      return waited if waited
      begin
        code = run(command, worktree)
      ensure
        store.release(LOCK_NAME, holder[:pid])
      end
      @output.puts "[workspace] #{command} #{describe_exit(code)}; devenv lock released"
      code
    end

    # @param worktree [String]
    # @param branch [String, nil]
    # @return [Hash] this wrapper's `kind: "process"` lock identity
    # @raise [Workspace::Error] if this process's start time cannot be read,
    #   or it does not lead its own process group
    def identity(worktree, branch)
      started = @liveness.start_time(Process.pid)
      raise Workspace::Error, "cannot read the start time of pid #{Process.pid}" unless started
      pgid = @pgrp.call
      unless pgid == Process.pid
        raise Workspace::Error, "the dev wrapper must lead its own process group (pid #{Process.pid}, pgid #{pgid}); " \
          "start it with `workspace dev up` or from an interactive shell"
      end
      {
        kind: "process",
        pid: Process.pid,
        started: started,
        pgid: pgid,
        pane: @env["TMUX_PANE"],
        worktree: worktree,
        branch: branch
      }
    end

    private

    # @return [Integer, nil] an exit code if the wrapper should stop without running
    def acquire!(store, holder, wait)
      result = store.acquire(LOCK_NAME, identity: holder, waiter_pid: holder[:pid], waiter_started: holder[:started], wait: wait)
      case result[:status]
      when :acquired, :already_held then nil
      when :queued then wait_in_queue(store, holder[:pid])
      when :deadlock then raise Workspace::Error, "pid #{holder[:pid]} already holds or waits for the #{result[:other]} lock"
      else raise Workspace::Error, held_message(result[:holder])
      end
    end

    # Signal handlers only record the signal: the store is flock-guarded, and
    # a handler touching it while the loop holds the flock would block forever.
    def wait_in_queue(store, pid)
      @output.puts "[workspace] Trying to obtain workspace #{LOCK_NAME} lock..."
      @output.flush
      interrupted = nil
      previous = %w[INT TERM HUP].to_h { |sig| [sig, @trap.call(sig, proc { interrupted ||= 128 + Signal.list[sig] })] }
      loop do
        if interrupted
          store.dequeue(LOCK_NAME, pid)
          return interrupted
        end
        case store.poll(LOCK_NAME, pid)[:status]
        when :acquired then return nil
        when :cleared
          @output.puts "[workspace] #{LOCK_NAME} lock was cleared while waiting."
          return 4
        end
        @sleeper.call(@poll)
      end
    ensure
      previous&.each { |sig, handler| @trap.call(sig, handler) }
    end

    def held_message(other)
      return "#{LOCK_NAME} lock is not free: others are queued for it" unless other
      details = {"pane" => other["pane"], "worktree" => other["worktree"], "branch" => other["branch"]}
        .filter_map { |k, v| "#{k} #{v}" if v }
      "#{LOCK_NAME} lock is held by pid #{other["pid"]}#{" (#{details.join(", ")})" unless details.empty?}"
    end

    def run(command, worktree)
      @child_pid = nil
      @pending_signal = nil
      @forwarded = []
      previous = {"INT" => @trap.call("INT", proc {})}
      %w[TERM HUP].each { |sig| previous[sig] = @trap.call(sig, proc { forward(sig) }) }

      @output.puts "[workspace] #{LOCK_NAME} lock held for #{worktree}; running: #{command}"
      @output.flush
      @child_pid = spawn_child(command, worktree)
      forward(@pending_signal) if @pending_signal
      _, status = Process.wait2(@child_pid)
      status.exitstatus || 128 + status.termsig
    ensure
      previous&.each { |sig, handler| @trap.call(sig, handler) }
    end

    def spawn_child(command, worktree)
      @spawner.call(command, worktree)
    rescue SystemCallError => e
      raise Workspace::Error, "cannot run #{command} in #{worktree}: #{e.message}"
    end

    # Forwards +signal+ once to the whole process group. The wrapper ignores
    # that signal first, so the copy the kernel delivers back to it cannot run
    # this handler again or, after the handlers are restored, kill the wrapper
    # before it releases the lock.
    def forward(signal)
      return @pending_signal = signal unless @child_pid
      return if @forwarded.include?(signal)
      @forwarded << signal
      @trap.call(signal, "IGNORE")
      @kill.call(signal, -Process.pid)
    rescue Errno::ESRCH
      nil
    end

    def describe_exit(code)
      signal = code > 128 && Signal.signame(code - 128)
      signal ? "exited on SIG#{signal} (status #{code})" : "exited with status #{code}"
    end
  end
end
