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
  class DevRunner
    LOCK_NAME = "devenv"

    # @param store [Workspace::LockStore] the namespace's lock store
    # @param liveness [Workspace::LockHolder] supplies this process's start time
    # @param output [IO] receives the header and exit-status lines
    # @param env [Hash] environment lookup (for TMUX_PANE)
    # @param trap [#call] installs a signal handler, called as `trap.call(signal, handler)`
    #   like `Signal.trap`, returning the previous handler
    # @param spawner [#call] called as `spawner.call(command, chdir)`, returns the child pid
    def initialize(store:, liveness:, output: $stdout, env: ENV,
      trap: ->(signal, handler) { Signal.trap(signal, handler) },
      spawner: ->(command, chdir) { Process.spawn("/bin/sh", "-c", command, chdir: chdir) })
      @store = store
      @liveness = liveness
      @output = output
      @env = env
      @trap = trap
      @spawner = spawner
    end

    # Acquires `devenv`, runs +command+ to completion, and releases the lock.
    #
    # @param command [String] shell command to run
    # @param worktree [String] worktree root, used as the command's cwd
    # @param branch [String, nil] branch recorded in the lock holder
    # @return [Integer] the child's exit status, or 128 + signal number if it was killed
    # @raise [Workspace::Error] if the lock is held by someone else or the command cannot be started
    def call(command:, worktree:, branch: nil)
      holder = identity(worktree, branch)
      acquire!(holder)
      begin
        code = run(command, worktree)
      ensure
        @store.release(LOCK_NAME, holder[:pid])
      end
      @output.puts "[workspace] #{command} #{describe_exit(code)}; devenv lock released"
      code
    end

    # @param worktree [String]
    # @param branch [String, nil]
    # @return [Hash] this wrapper's `kind: "process"` lock identity
    # @raise [Workspace::Error] if this process's start time cannot be read
    def identity(worktree, branch)
      started = @liveness.start_time(Process.pid)
      raise Workspace::Error, "cannot read the start time of pid #{Process.pid}" unless started
      {
        kind: "process",
        pid: Process.pid,
        started: started,
        pgid: Process.getpgrp,
        pane: @env["TMUX_PANE"],
        worktree: worktree,
        branch: branch
      }
    end

    private

    def acquire!(holder)
      result = @store.acquire(LOCK_NAME, identity: holder, waiter_pid: holder[:pid], waiter_started: holder[:started])
      case result[:status]
      when :acquired, :already_held then nil
      when :deadlock then raise Workspace::Error, "pid #{holder[:pid]} already holds or waits for the #{result[:other]} lock"
      else raise Workspace::Error, held_message(result[:holder])
      end
    end

    def held_message(other)
      return "#{LOCK_NAME} lock is not free: other agents are queued for it" unless other
      details = {"pane" => other["pane"], "worktree" => other["worktree"], "branch" => other["branch"]}
        .filter_map { |k, v| "#{k} #{v}" if v }
      "#{LOCK_NAME} lock is held by pid #{other["pid"]}#{" (#{details.join(", ")})" unless details.empty?}"
    end

    def run(command, worktree)
      @child_pid = nil
      @pending_signal = nil
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

    def forward(signal)
      return @pending_signal = signal unless @child_pid
      Process.kill(signal, @child_pid)
    rescue Errno::ESRCH
      nil
    end

    def describe_exit(code)
      signal = code > 128 && Signal.signame(code - 128)
      signal ? "exited on SIG#{signal} (status #{code})" : "exited with status #{code}"
    end
  end
end
