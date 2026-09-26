module Workspace
  # Stops a recorded process group: SIGTERM (to the whole group, or to its
  # leader alone), then SIGKILL to the whole group if anything in it is still
  # running after +stop_timeout+ seconds. Used for a `kind: "process"` lock
  # holder's pgid by `dev down`, `--takeover` and `lock clear devenv`.
  #
  # {#terminate} trusts its caller to have checked the holder is still alive;
  # {#stop_holder} does that check itself, so a recycled pgid is never
  # signalled.
  class ProcessGroupTerminator
    # @param clock [#call] returns monotonic seconds
    # @param sleeper [#call] sleeps for the given seconds
    # @param poll_interval [Numeric] seconds between checks while waiting for the group to exit
    # @param own_pgid [Integer] the calling process's own group, which is never signalled
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      sleeper: ->(seconds) { sleep(seconds) }, poll_interval: 0.1, own_pgid: Process.getpgrp)
      @clock = clock
      @sleeper = sleeper
      @poll_interval = poll_interval
      @own_pgid = own_pgid
    end

    # Stops a `kind: "process"` lock holder (the dev wrapper): SIGTERM to the
    # wrapper pid, which forwards it once to its group, then SIGKILL to the
    # group after +stop_timeout+. Nothing is signalled unless the holder's pid
    # is still running with its recorded start time.
    #
    # @param holder [Hash] the lock holder record ("pid", "started", "pgid")
    # @param liveness [Workspace::LockHolder] checks pid + start time
    # @param stop_timeout [Numeric] seconds to wait after SIGTERM before SIGKILL
    # @return [Symbol] :gone (holder no longer alive; nothing signalled), or
    #   any result of {#terminate}
    # @raise [Workspace::Error] if liveness cannot be read, or from {#terminate}
    def stop_holder(holder, liveness:, stop_timeout:)
      return :gone unless liveness.alive?(pid: holder["pid"], started: holder["started"])
      terminate(holder["pgid"] || holder["pid"], stop_timeout: stop_timeout, leader: holder["pid"])
    end

    # @param pgid [Integer] process group to stop
    # @param stop_timeout [Numeric] seconds to wait after SIGTERM before SIGKILL
    # @param leader [Integer, nil] send the SIGTERM to this pid alone instead
    #   of the whole group (a wrapper that forwards it itself)
    # @return [Symbol] :not_running (nothing to signal), :terminated (exited
    #   after SIGTERM), or :killed (SIGKILL was sent)
    # @raise [Workspace::Error] for an unsafe pgid (<= 1, or the caller's own
    #   group) or a group this user may not signal
    def terminate(pgid, stop_timeout:, leader: nil)
      pgid = Integer(pgid)
      if pgid <= 1 || pgid == @own_pgid
        raise Workspace::Error, "refusing to signal process group #{pgid}"
      end
      return :not_running unless signal("TERM", leader ? Integer(leader) : -pgid)

      deadline = @clock.call + stop_timeout
      while @clock.call < deadline
        return :terminated unless running?(pgid)
        @sleeper.call(@poll_interval)
      end
      return :terminated unless running?(pgid)

      begin
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        return :terminated
      end
      :killed
    end

    # @param pgid [Integer]
    # @return [Boolean] whether any process in the group can still be signalled
    def running?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      # EPERM here means only unreaped zombies are left in the group.
      false
    end

    private

    def signal(name, target)
      Process.kill(name, target)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      raise Workspace::Error, "not permitted to signal #{(target < 0) ? "process group #{-target}" : "pid #{target}"}"
    end
  end
end
