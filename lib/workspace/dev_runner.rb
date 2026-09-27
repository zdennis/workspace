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
  #
  # The lock is released only once nothing else is left in the wrapper's
  # group: a process the command left behind, or one running as another user
  # (a server under `sudo`) that the wrapper cannot signal, keeps the dev
  # environment running after the command exits, so a second one must not start.
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
    # @param poll [Numeric] seconds between polls while queued, or while
    #   waiting for the process group to empty
    # @param group_members [#call] called with a pgid, returns the pids of that
    #   group's live (non-zombie) members, whoever owns them
    def initialize(liveness:, output: $stdout, env: ENV,
      trap: ->(signal, handler) { Signal.trap(signal, handler) },
      spawner: ->(command, chdir) { Process.spawn("/bin/sh", "-c", command, chdir: chdir) },
      kill: ->(signal, target) { Process.kill(signal, target) },
      pgrp: -> { Process.getpgrp },
      sleeper: ->(seconds) { sleep(seconds) }, poll: DEFAULT_POLL_SECONDS,
      group_members: ->(pgid) { ProcessGroupTerminator.new.live_member_pids(pgid) })
      @liveness = liveness
      @output = output
      @env = env
      @trap = trap
      @spawner = spawner
      @kill = kill
      @pgrp = pgrp
      @sleeper = sleeper
      @poll = poll
      @group_members = group_members
    end

    # Acquires `devenv`, runs +command+ to completion, and releases the lock.
    #
    # @param store [Workspace::LockStore] the namespace's lock store
    # @param command [String] shell command to run
    # @param worktree [String] worktree root, used as the command's cwd
    # @param branch [String, nil] branch recorded in the lock holder
    # @param wait [Boolean] queue FIFO behind the current holder instead of failing
    # @param priority [Boolean] queue ahead of everyone already waiting (`dev up --takeover`)
    # @return [Integer] the child's exit status, 128 + signal number if it was
    #   killed (or the wait was interrupted), or 4 if the lock was cleared while queued
    # @raise [Workspace::Error] if the lock is held by someone else (without
    #   +wait+), the wrapper does not lead its process group, or the command
    #   cannot be started
    def call(store:, command:, worktree:, branch: nil, wait: false, priority: false)
      holder = identity(worktree, branch)
      waited = acquire!(store, holder, wait, priority)
      return waited if waited
      begin
        code = run(command, worktree)
      ensure
        store.release(LOCK_NAME, holder[:pid])
      end
      @output.puts "[workspace] #{command} #{describe_exit(code)}; #{LOCK_NAME} lock released"
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
    def acquire!(store, holder, wait, priority)
      result = store.acquire(LOCK_NAME, identity: holder, waiter_pid: holder[:pid], waiter_started: holder[:started],
        wait: wait, priority: priority)
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
        when :acquired
          # A signal that landed during the poll must still win: give the
          # promoted hold back rather than run after the caller gave up.
          next if interrupted
          return nil
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
      @termsig = nil
      @skipped = false
      @forwarded = []
      previous = {"INT" => @trap.call("INT", proc {})}
      %w[TERM HUP].each { |sig| previous[sig] = @trap.call(sig, proc { forward(sig) }) }

      # A stop request that arrived before the child exists means it never runs.
      if @pending_signal
        @skipped = true
        @termsig = Signal.list[@pending_signal]
        return 128 + @termsig
      end
      @output.puts "[workspace] #{LOCK_NAME} lock held for #{worktree}; running: #{command}"
      @output.flush
      @child_pid = spawn_child(command, worktree)
      forward(@pending_signal) if @pending_signal
      _, status = Process.wait2(@child_pid)
      @termsig = status.termsig
      wait_for_group
      status.exitstatus || 128 + status.termsig
    ensure
      previous&.each { |sig, handler| @trap.call(sig, handler) }
    end

    # Runs with the stop-signal handlers still in place, so a SIGTERM that
    # arrives meanwhile is still forwarded to the group. A process table that
    # can't be read counts as a group still running.
    def wait_for_group
      announced = false
      loop do
        others = other_group_members
        return if others&.empty?
        unless announced
          what = others ? "#{others.size} process(es)" : "processes"
          @output.puts "[workspace] Command exited; waiting for #{what} left in process group #{Process.pid} " \
            "to exit before releasing the #{LOCK_NAME} lock."
          @output.flush
          announced = true
        end
        @sleeper.call(@poll)
      end
    end

    def other_group_members
      @group_members.call(Process.pid) - [Process.pid]
    rescue Workspace::Error
      nil
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

    # Only a child killed by a signal is described as such: one that exits
    # normally with a status above 128 (e.g. `exit 130`) is just that status.
    def describe_exit(code)
      signal = @termsig && "SIG#{Signal.signame(@termsig)}"
      return "not started (#{signal} arrived first)" if @skipped
      signal ? "exited on #{signal} (status #{code})" : "exited with status #{code}"
    end
  end
end
