module Workspace
  # Stops a `kind: "process"` lock holder's process group for `lock clear`
  # and `dev down`, or, when that group can't be stopped, keeps the lock
  # naming it so no second dev environment starts beside it.
  #
  # A group can't be stopped when it has live processes this user may not
  # signal (another user's, e.g. a server under `sudo`), when it is still
  # running +kill_grace+ seconds after SIGKILL (`dev.kill_grace`, default
  # {KILL_GRACE_SECONDS}), or when its wrapper is already gone but the group runs on (unless its id was reused). The
  # lock is then re-asserted with {LockStore#keep_process_holder}.
  #
  # Runs with the store unlocked: the wrapper needs the flock to release,
  # and would otherwise sit blocked until SIGKILL.
  class ProcessHolderStopper
    # Default seconds a SIGKILLed group may take to disappear (`dev.kill_grace`).
    KILL_GRACE_SECONDS = 2
    KILL_POLL_SECONDS = 0.1

    # Builds a stopper wired from a caller's own collaborators of the same
    # names, so `Dev` and `Lock` need not repeat the five-argument list.
    #
    # @param terminator [Workspace::ProcessGroupTerminator]
    # @param lock_holder [Workspace::LockHolder] checks the holder's pid + start time
    # @param error_output [IO]
    # @param clock [#now]
    # @param sleeper [#call]
    # @return [Workspace::ProcessHolderStopper]
    def self.for(terminator:, lock_holder:, error_output:, clock:, sleeper:)
      new(terminator: terminator, liveness: lock_holder, error_output: error_output, clock: clock, sleeper: sleeper)
    end

    # @param terminator [Workspace::ProcessGroupTerminator]
    # @param liveness [Workspace::LockHolder] checks the holder's pid + start time
    # @param error_output [IO] receives why a group could not be stopped and that its lock was kept
    # @param clock [#now] monotonic seconds, for the post-SIGKILL grace period
    # @param sleeper [#call] sleeps between checks during that grace period
    def initialize(terminator:, liveness:, error_output:, clock:, sleeper:)
      @terminator = terminator
      @liveness = liveness
      @error_output = error_output
      @clock = clock
      @sleeper = sleeper
    end

    # @param store [Workspace::LockStore]
    # @param name [String] lock name
    # @param holder [Hash] the holder record
    # @param stop_timeout [Numeric] seconds between SIGTERM and SIGKILL
    # @param kill_grace [Numeric] seconds the group may take to disappear after SIGKILL
    # @param retry_command [String] the command to run once the group is stopped by hand
    # @param cleared_by [String, nil] identity recorded in the audit log if the lock is kept
    # @param clearer [Hash, nil] this process's `clearing` marker (see {#clearer}),
    #   dropped from the holder if the lock is kept
    # @return [Symbol] :terminated, :killed or :gone (nothing the holder
    #   started is known to be running, so its lock may go), or :kept (the
    #   reason and the kept lock were reported on +error_output+)
    def stop(store, name, holder, stop_timeout:, retry_command:, cleared_by: nil, kill_grace: KILL_GRACE_SECONDS, clearer: nil)
      pid = holder["pid"]
      pgid = holder["pgid"] || pid
      result, reason = attempt(holder, pgid, pid, stop_timeout, kill_grace)
      return result unless reason

      @error_output.puts "Could not stop process group #{pgid} (pid #{pid}): #{reason}"
      keep(store, name, holder, pgid, pid, retry_command, cleared_by, clearer)
      :kept
    end

    # The `clearing` marker naming the process +pid+, recorded on a process
    # holder it is stopping so a concurrent `lock clear`, `dev down` or `dev
    # up --takeover` leaves that holder to it. Without a readable start time
    # there is no marker, since its liveness could not be checked.
    #
    # @param pid [Integer] the stopping process's pid
    # @return [Hash, nil] {"pid", "started"}
    def clearer(pid)
      started = @liveness.start_time(pid)
      started && {"pid" => pid, "started" => started}
    rescue Workspace::Error
      nil
    end

    private

    # @return [Array(Symbol, String)] the stop's result, and why the group
    #   can't be stopped (nil when it was)
    def attempt(holder, pgid, pid, stop_timeout, kill_grace)
      result = @terminator.stop_holder(holder, liveness: @liveness, stop_timeout: stop_timeout)
    rescue Workspace::Error => e
      [nil, e.message]
    else
      case result
      when :gone, :not_running
        # :not_running means the wrapper exited just before its SIGTERM,
        # so nothing was signalled: its group may still be running.
        return [:gone, "its wrapper pid #{pid} is gone, but the group is still running"] if orphan_group_running?(holder)
        warn_reused_group(holder, pgid, pid)
        [:gone, nil]
      when :killed
        [:killed, survives_kill?(pgid, kill_grace) ? "it was still running #{seconds_label(kill_grace)} after SIGKILL" : nil]
      else
        [result, nil]
      end
    end

    # The lock must keep naming a holder whose group could not be stopped,
    # even if its wrapper released it meanwhile (it exits with its
    # command); only a hold someone else already started under is left alone.
    def keep(store, name, holder, pgid, pid, retry_command, cleared_by, clearer)
      other = store.keep_process_holder(name, holder, cleared_by: cleared_by, clearer: clearer)
      if other
        @error_output.puts "Could not keep #{name} lock for process group #{pgid}: it is now held by pid #{other["pid"]}" \
          "#{" (#{other["worktree"]})" if other["worktree"]}, while process group #{pgid} may still be running. " \
          "Have its owner run `kill -TERM -#{pgid}`; the lock frees on its own once the group is empty."
      else
        @error_output.puts "Kept #{name} lock: it still names pid #{pid}, so no second dev environment starts while " \
          "process group #{pgid} runs. Have its owner run `kill -TERM -#{pgid}`; the lock frees on its own once the " \
          "group is empty, then run: #{retry_command}"
      end
    end

    # A wrapper that is gone (killed, or exited on its own) can leave its
    # group running, e.g. another user's server; its lock goes on naming
    # it until the group itself has stopped. One that can't be checked
    # counts as running.
    def orphan_group_running?(holder)
      @terminator.orphan_running?(holder)
    rescue Workspace::Error
      true
    end

    # A gone wrapper's pid taken by a live process means its group is gone
    # and the id names something unrelated: reported, never signalled, and
    # nothing to stop by hand.
    def warn_reused_group(holder, pgid, pid)
      return unless @terminator.pgid_reused?(holder)
      @error_output.puts "Process group #{pgid} was not signalled: its holder pid #{pid} is gone, and the id now " \
        "belongs to an unrelated process."
    end

    # A SIGKILLed group can take a moment to disappear; one that outlives
    # the grace period (or can no longer be checked) counts as still running.
    def survives_kill?(pgid, kill_grace)
      deadline = @clock.now + kill_grace
      loop do
        return false unless @terminator.running?(pgid)
        return true if @clock.now >= deadline
        @sleeper.call(KILL_POLL_SECONDS)
      end
    rescue Workspace::Error
      true
    end

    def seconds_label(seconds)
      "#{(seconds % 1).zero? ? seconds.to_i : seconds}s"
    end
  end
end
