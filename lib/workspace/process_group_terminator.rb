require "open3"

module Workspace
  # Stops a recorded process group: SIGTERM (to the whole group, or to its
  # leader alone), then SIGKILL to the whole group if anything in it is still
  # running after +stop_timeout+ seconds. Used for a `kind: "process"` lock
  # holder's pgid by `dev down`, `--force` and `lock clear devenv`.
  #
  # {#terminate} trusts its caller to have checked the holder is still alive;
  # {#stop_holder} does that check itself, so a recycled pgid is never
  # signalled.
  #
  # The kernel answers EPERM both for a group holding only unreaped zombies
  # and for a live group owned by another user, so every EPERM is settled by
  # looking at the group's members: all zombies (or none) is "not running",
  # anything else raises rather than reporting a stop that never happened.
  class ProcessGroupTerminator
    # @param clock [#call] returns monotonic seconds
    # @param sleeper [#call] sleeps for the given seconds
    # @param poll_interval [Numeric] seconds between checks while waiting for the group to exit
    # @param own_pgid [Integer] the calling process's own group, which is never signalled
    # @param kill [#call] sends a signal, called as `kill.call(signal, target)` like `Process.kill`
    # @param member_states [#call] called with a pgid, returns the `ps` state
    #   (e.g. "S", "Z+") of every process in that group
    # @param member_owners [#call] called with a pgid, returns the user names
    #   owning that group's live processes, named in the not-permitted error
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      sleeper: ->(seconds) { sleep(seconds) }, poll_interval: 0.1, own_pgid: Process.getpgrp,
      kill: ->(signal, target) { Process.kill(signal, target) }, member_states: method(:ps_member_states),
      member_owners: method(:ps_member_owners))
      @clock = clock
      @sleeper = sleeper
      @poll_interval = poll_interval
      @own_pgid = own_pgid
      @kill = kill
      @member_states = member_states
      @member_owners = member_owners
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
    # @param guard [#call, nil] re-checked just before each signal; once it
    #   returns false (the group id may now name someone else) nothing more is sent
    # @return [Symbol] :not_running (nothing to signal), :terminated (exited
    #   after SIGTERM), or :killed (SIGKILL was sent)
    # @raise [Workspace::Error] for an unsafe pgid (<= 1, or the caller's own
    #   group), or a live group this user may not signal
    def terminate(pgid, stop_timeout:, leader: nil, guard: nil)
      pgid = Integer(pgid)
      if pgid <= 1 || pgid == @own_pgid
        raise Workspace::Error, "refusing to signal process group #{pgid}"
      end
      return :not_running if guard && !guard.call
      return :not_running unless signal("TERM", leader ? Integer(leader) : -pgid, pgid)

      deadline = @clock.call + stop_timeout
      while @clock.call < deadline
        return :terminated unless running?(pgid)
        @sleeper.call(@poll_interval)
      end
      return :terminated unless running?(pgid)
      return :terminated if guard && !guard.call
      return :terminated unless signal("KILL", -pgid, pgid)
      :killed
    end

    # @param pgid [Integer]
    # @return [Boolean] whether any process in the group can still be signalled
    # @raise [Workspace::Error] if the group has live members this user may not signal
    def running?(pgid)
      signal(0, -Integer(pgid), Integer(pgid))
    end

    # Whether a process holder's group outlives its wrapper: the wrapper's
    # pid is gone but its recorded group still has running members. Shared by
    # `dev` (orphan reporting) and {LockStore} (a kept `devenv` holder).
    #
    # @param holder [Hash] a `kind: "process"` lock holder record ("pid", "pgid")
    # @param pid_alive [#call] called with a pid, whether any process has it
    # @return [Boolean]
    # @raise [Workspace::Error] if the group has live members this user may not signal
    def orphan_running?(holder, pid_alive: method(:pid_alive?))
      !!holder["pgid"] && !pgid_reused?(holder, pid_alive: pid_alive) && running?(holder["pgid"])
    end

    # The wrapper led its group, so its pgid is its pid. A live process
    # with that pid is not the dead wrapper, and the kernel only hands out a
    # pid once no group uses it: the recorded group is gone and the id now
    # names an unrelated process (group) that must never be signalled.
    #
    # @param holder [Hash] a `kind: "process"` lock holder record whose wrapper is gone
    # @param pid_alive [#call] called with a pid, whether any process has it
    # @return [Boolean]
    def pgid_reused?(holder, pid_alive: method(:pid_alive?))
      holder["pgid"] == holder["pid"] && pid_alive.call(holder["pid"])
    end

    # @param pgid [Integer]
    # @return [Array<Integer>] pids of the group's members that are not
    #   zombies, whoever owns them
    # @raise [Workspace::Error] if the process table cannot be read
    def live_member_pids(pgid)
      ps_members(Integer(pgid)).filter_map { |pid, state, _user| pid unless state.start_with?("Z") }
    end

    private

    def pid_alive?(pid)
      @kill.call(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # @return [Boolean] whether the signal was delivered; false when there is
    #   nothing left to signal
    def signal(name, target, pgid)
      @kill.call(name, target)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # A zombie leader cannot take its signal; the rest of its group still can.
      return signal(name, -pgid, pgid) if target != -pgid
      raise not_permitted(pgid) if live_members?(pgid)
      false
    end

    def live_members?(pgid)
      @member_states.call(pgid).any? { |state| !state.start_with?("Z") }
    end

    def not_permitted(pgid)
      owners = owners_of(pgid)
      owned_by = owners.empty? ? "" : "owned by #{owners.join(", ")}: "
      Workspace::Error.new("process group #{pgid} has running processes this user is not permitted to signal " \
        "(#{owned_by}another user's processes, or its id was reused by them), so it was not signalled. " \
        "Inspect it with: ps -axo pid,pgid,user,stat,command | awk '$2 == #{pgid}'")
    end

    # The owners only enrich the error, so a failed lookup just leaves them out.
    def owners_of(pgid)
      @member_owners.call(pgid)
    rescue Workspace::Error
      []
    end

    def ps_member_states(pgid)
      ps_members(pgid).map { |_pid, state, _user| state }
    end

    def ps_member_owners(pgid)
      ps_members(pgid).filter_map { |_pid, state, user| user unless state.start_with?("Z") }.uniq
    end

    # `ps` runs in a process group of its own, so a caller listing its own
    # group (the dev wrapper) never finds `ps` in it.
    #
    # @return [Array<Array(Integer, String, String)>] [pid, state, user] for each process in the group
    def ps_members(pgid)
      stdout, stderr, status = Open3.capture3({"LC_ALL" => "C"}, "ps", "-axo", "pid=,pgid=,stat=,user=", pgroup: true)
      raise Workspace::Error, "could not read the process table (ps failed: #{stderr.strip})" unless status.success?
      stdout.lines.filter_map do |line|
        # user is the last column and may contain spaces, so it takes the rest of the line.
        pid, group, state, user = line.strip.split(nil, 4)
        [pid.to_i, state, user] if group.to_i == pgid && state
      end
    end
  end
end
