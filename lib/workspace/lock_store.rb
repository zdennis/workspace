require "json"
require "fileutils"
require "time"

module Workspace
  # Reads and mutates one namespace's `locks.json`, guarded by `flock` so
  # concurrent CLI invocations serialize their read-modify-write cycles.
  #
  # The one-lock-per-agent rule ({#acquire}'s deadlock check) is scoped per
  # namespace: an agent may hold or wait for one lock in *this* store, but
  # nothing stops it from also holding a lock in another namespace/store.
  #
  # The lock itself is held on a sentinel file (`locks.lock`), never on
  # `locks.json` directly: `locks.json` is rewritten via tmp-file-then-rename
  # on every op (the same atomic-write idiom used elsewhere in this codebase),
  # and a rename would otherwise leave a held flock pointing at the deleted
  # inode instead of the file a later reader opens.
  #
  # A holder record's `kind` is "agent" (this PR) or "process" (a wrapper
  # process, for the dev-environment lock in a later PR) — both are stored
  # and reaped identically, since liveness only depends on pid + start time.
  # A process holder also records its "pgid" and "branch", so `dev down`,
  # `--takeover` and `lock clear` can signal its whole process group; a
  # queued process waiter carries the same fields into its promotion.
  #
  # An agent holder whose coding agent has finished its turn is marked idle
  # (`idle_since`, epoch seconds) by `workspace session-event`. Once it has
  # been idle for at least +idle_grace+, the head of the queue takes the lock
  # over on its next poll. The displaced agent is recorded in the entry's
  # `displaced` list until it next runs `acquire` or `release`, which read it
  # back through {#pop_displaced}. `kind: "process"` holders are never marked
  # idle and never taken over.
  class LockStore
    DEFAULT_IDLE_GRACE = 300

    # @param dir [String] this namespace's lock store directory
    # @param liveness [Workspace::LockHolder] checks whether a recorded pid is still alive
    # @param logger [Workspace::Logger] debug logger
    # @param clock [#call] returns the current wall-clock time in epoch seconds, for idle tracking
    # @param idle_grace [Numeric] seconds an agent holder may stay idle before the head waiter may take over
    # @param audit_log [Workspace::LockAuditLog] append-only `locks.jsonl` writer for this namespace
    # @param terminator [Workspace::ProcessGroupTerminator, nil] checks whether a
    #   kept process holder's group still runs; without one, such a group
    #   always counts as running
    def initialize(dir:, liveness:, logger: Workspace::Logger.new, clock: -> { Time.now.to_i }, idle_grace: DEFAULT_IDLE_GRACE,
      audit_log: nil, terminator: nil)
      @dir = dir
      @liveness = liveness
      @logger = logger
      @clock = clock
      @idle_grace = idle_grace
      @lockfile_path = File.join(dir, "locks.lock")
      @data_path = File.join(dir, "locks.json")
      @audit_log = audit_log || LockAuditLog.new(dir: dir, logger: logger)
      @terminator = terminator
    end

    # Acquires +name+ for +identity+, or enqueues behind the current holder
    # when +wait+ is true. Refuses when this same agent already holds or
    # waits for a different lock (the v1 deadlock rule): an agent may hold or
    # wait for exactly one lock at a time.
    #
    # @param name [String] lock name
    # @param identity [Hash] the calling agent, from {LockHolder#current}
    # @param waiter_pid [Integer] pid of this `acquire` invocation itself, used to track the wait
    # @param waiter_started [String] that process's `ps` start time
    # @param task [String, nil] free-text description shown in status/queue messages
    # @param wait [Boolean] enqueue instead of refusing when the lock is busy
    # @param priority [Boolean] go ahead of everyone already queued (`dev up
    #   --takeover`): take a free lock even with others waiting, or enqueue at
    #   the head, in the same flocked step so no release can promote past it;
    #   the queue entry is marked "takeover", which {#clear} keeps
    # @return [Hash] :status is one of :acquired, :already_held, :held, :queued, :deadlock
    def acquire(name, identity:, waiter_pid:, waiter_started:, task: nil, wait: false, priority: false)
      with_lock do |data|
        reap!(data)
        entry = data[name] ||= empty_entry
        holder = entry["holder"]

        if LockHolder.same_agent?(holder, identity)
          holder.delete("unclaimed")
          holder.delete("takeover")
          holder["idle_since"] = nil
          next {status: :already_held}
        end

        if (other = other_hold_or_wait(data, name, identity))
          next {status: :deadlock, other: other}
        end

        if holder.nil? && (entry["queue"].empty? || priority)
          entry["holder"] = build_holder(identity, task, waiter_pid: waiter_pid)
          audit(:acquire, name, holder: holder_summary(entry["holder"]))
          next {status: :acquired}
        end

        next {status: :held, holder: holder} unless wait

        existing_index = entry["queue"].index { |w| w["agent_pid"] == identity[:pid] && w["agent_started"] == identity[:started] }
        if existing_index
          waiter = entry["queue"].delete_at(existing_index)
          waiter["waiter_pid"] = waiter_pid
          waiter["waiter_started"] = waiter_started
          waiter["takeover"] = true if priority
          entry["queue"].insert(priority ? 0 : existing_index, waiter)
          position = priority ? 1 : existing_index + 1
        elsif priority
          entry["queue"].unshift(build_waiter(identity, waiter_pid, waiter_started, task).merge("takeover" => true))
          position = 1
        else
          entry["queue"] << build_waiter(identity, waiter_pid, waiter_started, task)
          position = entry["queue"].size
        end
        total = entry["queue"].size + (holder ? 1 : 0)
        {status: :queued, position: position, total: total, holder: holder}
      end
    end

    # Checks progress for a queued `acquire --wait`, called once per poll.
    # When this waiter heads the queue and the holder is an agent that has
    # been idle for at least +idle_grace+, the lock is taken over here, in the
    # same flocked step, and the displaced holder is recorded.
    #
    # @param name [String] lock name
    # @param waiter_pid [Integer] the waiting process's own pid
    # @return [Hash] :status is one of :acquired, :queued, :cleared; an
    #   :acquired result from a takeover also carries :took_over (the
    #   displaced holder record)
    def poll(name, waiter_pid)
      with_lock do |data|
        reap!(data)
        entry = data[name]
        next {status: :cleared} unless entry

        claimed = claim!(entry, waiter_pid, name)
        next claimed if claimed

        holder = entry["holder"]
        index = entry["queue"].index { |w| w["waiter_pid"] == waiter_pid }
        next {status: :cleared} unless index
        {status: :queued, position: index + 1, total: entry["queue"].size + (holder ? 1 : 0), holder: holder}
      end
    end

    # Releases +name+ if +pid+ is its current holder. Idempotent: releasing a
    # lock this pid does not hold is a no-op.
    #
    # @param name [String] lock name
    # @param pid [Integer] the releasing agent's pid
    # @return [Boolean] whether a hold was actually released
    def release(name, pid)
      with_lock do |data|
        reap!(data)
        entry = data[name]
        next false unless entry
        holder = entry["holder"]
        next false unless holder && holder["pid"] == pid
        entry["holder"] = nil
        audit(:release, name, holder: holder_summary(holder))
        promote!(entry, name)
        true
      end
    end

    # Releases every lock +identity+ holds and removes it from every queue it
    # is waiting in. Queue entries are matched on the agent recorded in them,
    # not the waiter pid, since a queued wait runs in its own background
    # process; that orphaned waiter then sees :cleared on its next {#poll}.
    #
    # @param identity [Hash] the agent, from {LockHolder#current}
    # @return [Array<String>] names of locks actually released
    def release_all(identity)
      with_lock do |data|
        reap!(data)
        released = []
        data.each do |name, entry|
          entry["queue"].reject! { |w| w["agent_pid"] == identity[:pid] && w["agent_started"] == identity[:started] }
          next unless LockHolder.same_agent?(entry["holder"], identity)
          holder = entry["holder"]
          entry["holder"] = nil
          audit(:release, name, holder: holder_summary(holder))
          promote!(entry, name)
          released << name
        end
        released
      end
    end

    # Runs the reap pass every mutating op starts with, on its own, so a
    # caller with no lock op to run (the session-monitor daemon) can keep
    # `locks.json` current. Reaps are audited as an op-time reap is, plus
    # +source+ when given.
    # Unlike an op, it never waits for the store flock: while another process
    # holds it, this returns 0 at once and the caller retries on its next
    # pass. A pass that changes nothing leaves `locks.json` untouched, so a
    # long-running caller on older code never rewrites fields newer code added.
    #
    # @param source [String, nil] recorded as the `source` field of each reap
    #   audit event, so these reaps can be told apart from an op-time reap
    # @return [Integer] how many holders and waiters were reaped
    def reap(source: nil)
      reaped = with_lock(nonblocking: true, write_unchanged: false) do |data|
        reap!(data, source: source)
        @pending_events.count { |e| e[:event] == "reap" }
      end
      reaped || 0
    end

    # Reaps dead holders and waiters, promoting the next live waiter, and
    # returns +name+'s holder afterwards. Unlike {#status}, a crashed holder's
    # record is removed rather than just flagged stale.
    #
    # @param name [String] lock name
    # @return [Hash, nil] the live holder record, or nil if the lock is free
    def current_holder(name)
      with_lock do |data|
        reap!(data)
        data[name]&.dig("holder")
      end
    end

    # Records a denied edit for the audit log, without mutating `locks.json`.
    # Runs under the same shared flock {#status} uses, so it never blocks a
    # concurrent mutating op and never contends with the fast, non-flocked
    # {LockEnforcer#check} pre-check; only genuinely denied edits reach here,
    # so the hot path (no contention) never touches the audit log at all.
    #
    # @param name [String] lock name
    # @param denier [Hash] the denied agent's identity, from {LockHolder#current}
    # @param holder [Hash] the current holder record
    # @return [void]
    def record_deny(name, denier:, holder:)
      with_lock(readonly: true) do |data|
        audit(:deny, name, agent: identity_summary(denier), holder: holder_summary(holder))
        data
      end
    end

    # Abandons a wait, e.g. on SIGINT/SIGTERM while blocked in `acquire
    # --wait`: removes the waiter from the queue, or releases the lock if it
    # was already promoted to this waiter, so an interrupted wait never
    # leaves its agent holding a lock it was never told about.
    #
    # @param name [String] lock name
    # @param waiter_pid [Integer]
    # @return [Symbol] :released, :dequeued, or :absent
    def dequeue(name, waiter_pid)
      with_lock do |data|
        entry = data[name]
        next :absent unless entry
        if entry["holder"] && entry["holder"]["waiter_pid"] == waiter_pid
          entry["holder"] = nil
          promote!(entry, name)
          next :released
        end
        removed = entry["queue"].reject! { |w| w["waiter_pid"] == waiter_pid }
        removed ? :dequeued : :absent
      end
    end

    # Ends a timed-out wait in one step: claims the lock if it was promoted
    # to this waiter since its last poll, or takes it over exactly as {#poll}
    # would, otherwise leaves the queue.
    #
    # @param name [String] lock name
    # @param waiter_pid [Integer]
    # @return [Hash] :status is :acquired or :dequeued; a takeover also
    #   carries :took_over, as from {#poll}
    def claim_or_dequeue(name, waiter_pid)
      with_lock do |data|
        reap!(data)
        entry = data[name]
        next {status: :dequeued} unless entry
        claimed = claim!(entry, waiter_pid, name)
        next claimed if claimed
        entry["queue"].reject! { |w| w["waiter_pid"] == waiter_pid }
        {status: :dequeued}
      end
    end

    # Removes a lock's holder and queue unconditionally, with no liveness
    # check. Yields the holder record first (if any), so a caller can run a
    # kind-specific side effect.
    #
    # With +keep_process_holder+, a `kind: "process"` holder is left in
    # place, and so is its queue: each waiter is marked `clearing` with
    # +clearer+ instead, which holds it back from promotion (and everyone
    # behind it) while that clearer runs. {#finish_clear} removes those
    # waiters once the group is stopped; {#keep_process_holder} unmarks them,
    # so they go on waiting when it can't be. A live waiter queued by `dev up
    # --takeover` is not marked: it means to replace this holder, not wait
    # on it, so it stays first in line and {#finish_clear} (or the holder's
    # own release) promotes it. Without +clearer+ the marked waiters are
    # removed at once instead. The holder's process group has to be
    # stopped outside the flock (the wrapper needs it to release), and the
    # lock must keep naming the holder until that has succeeded, or a second
    # dev environment could start beside one that is still running. The
    # caller then removes it with {#finish_clear}, or keeps it with
    # {#keep_process_holder}. The `clear` audit event is written here either
    # way, with `holder_kept` when the holder was left in place.
    #
    # A kept holder is marked `clearing` with +clearer+ (the `lock clear`
    # process's pid and start time) until {#finish_clear} or
    # {#keep_process_holder} ends that clear (`dev down` and `dev up
    # --takeover` mark it the same way, with {#mark_clearing}), so a second,
    # concurrent clear
    # neither stops the same group again nor writes a second `clear` event:
    # it gets in_progress: true back instead, with nothing changed and
    # nothing yielded. A marker whose clearer is no longer running (it
    # crashed or was killed mid-stop) is ignored and replaced, so it never
    # wedges the lock.
    #
    # @param name [String] lock name
    # @param cleared_by [String, nil] identity recorded for logging
    # @param keep_process_holder [Boolean] leave a `kind: "process"` holder in place
    # @param clearer [Hash, nil] "pid" and "started" of the clearing process,
    #   recorded on a kept holder; nil records no marker
    # @yieldparam holder [Hash, nil] the holder being cleared
    # @return [Hash, nil] the removed {holder:, queue:}, with pending: true
    #   and the takeover waiters left queued (takeovers:) when the holder
    #   was kept; {holder:, clearing:, in_progress: true} when another live
    #   clear of that holder is under way; nil if the lock had no entry
    def clear(name, cleared_by: nil, keep_process_holder: false, clearer: nil)
      with_lock(lenient: true) do |data|
        entry = data[name]
        next nil unless entry
        holder = entry["holder"]
        keep = keep_process_holder && holder && holder["kind"] == "process"
        if keep && (marker = live_clearing_marker(holder))
          @logger.debug { "lock: #{name} is already being cleared by pid #{marker["pid"]}" }
          next {holder: holder, clearing: marker, in_progress: true}
        end
        yield holder if block_given?
        if keep
          takeovers, queue = entry["queue"].partition { |w| w["takeover"] && waiter_alive?(w) }
          if clearer
            marker = clearer.slice("pid", "started")
            holder["clearing"] = marker
            queue.each { |w| w["clearing"] = marker }
          else
            entry["queue"] = takeovers
          end
          @logger.debug { "lock: clearing #{name}#{" by #{cleared_by}" if cleared_by}, holder kept until stopped" }
          audit(:clear, name, holder: holder_summary(holder), queue_size: queue.size, cleared_by: cleared_by, holder_kept: true,
            takeovers_kept: takeovers.empty? ? nil : takeovers.size)
          next {holder: holder, queue: queue, takeovers: takeovers, pending: true}
        end
        data.delete(name)
        @logger.debug { "lock: cleared #{name}#{" by #{cleared_by}" if cleared_by}" }
        audit(:clear, name, holder: holder_summary(holder), queue_size: entry["queue"].size, cleared_by: cleared_by)
        {holder: holder, queue: entry["queue"]}
      end
    end

    # Completes a {#clear} that kept a `kind: "process"` holder, once its
    # process group is stopped: removes that holder if the lock still names
    # it (same pid and start time), logging a `release` by +cleared_by+,
    # removes the waiters that clear marked, then promotes anyone who queued
    # since. A holder that already released or was reaped is left as it is,
    # and so is whoever holds the lock now.
    #
    # @param name [String] lock name
    # @param holder [Hash] the holder record {#clear} returned
    # @param cleared_by [String, nil] identity recorded for logging
    # @param clearer [Hash, nil] the +clearer+ given to {#clear}
    # @return [Hash, nil] nil once the lock no longer names +holder+ (removed
    #   here, or released on its own), or the record of whoever else held it
    #   by then
    def finish_clear(name, holder, cleared_by: nil, clearer: nil)
      with_lock(lenient: true) do |data|
        entry = data[name]
        next nil unless entry
        entry["queue"].reject! { |w| waiter_marked_by?(w, clearer) }
        current = entry["holder"]
        other = nil
        if same_process?(current, holder)
          entry["holder"] = nil
          @logger.debug { "lock: cleared #{name}#{" by #{cleared_by}" if cleared_by}" }
          audit(:release, name, holder: holder_summary(holder), cleared_by: cleared_by)
        else
          other = current
        end
        promote!(entry, name)
        data.delete(name) if entry["holder"].nil? && entry["queue"].empty? && !entry["displaced"]
        other
      end
    end

    # Ends a {#clear} that kept a `kind: "process"` holder whose process group
    # could not be stopped: the lock must go on naming it for as long as that
    # group runs. The holder is marked `kept`, so it is not reaped once its
    # wrapper is gone while its group still runs (see {#holder_alive?}). If
    # its hold ended in the meantime, it is restored, and a waiter promoted
    # since but not yet told goes back to the head of the queue.
    #
    # Only a `clearing` marker naming +clearer+ is dropped: one left by
    # another clearer that is still stopping the group stays in place. The
    # waiters {#clear} marked for +clearer+ are unmarked, so they go on
    # waiting for this holder.
    #
    # @param name [String] lock name
    # @param holder [Hash] the holder record {#clear} returned
    # @param cleared_by [String, nil] identity recorded for logging
    # @param clearer [Hash, nil] "pid" and "started" of the process ending its stop
    # @return [Hash, nil] nil once the lock names +holder+ again, or the
    #   record of whoever holds it instead and already knows it (a hold that
    #   cannot be taken back)
    def keep_process_holder(name, holder, cleared_by: nil, clearer: nil)
      with_lock(lenient: true) do |data|
        entry = data[name] ||= empty_entry
        entry["queue"].each { |w| drop_clearing_marker!(w, clearer) }
        current = entry["holder"]
        if same_process?(current, holder)
          current["kept"] = true
          drop_clearing_marker!(current, clearer)
          next nil
        end
        next current if current && !current["unclaimed"]

        entry["holder"] = drop_clearing_marker!(holder.except("unclaimed", "takeover"), clearer).merge("kept" => true)
        if current
          entry["queue"].unshift(waiter_from_holder(current))
          audit(:takeover, name, from: holder_summary(current), to: holder_summary(holder), cleared_by: cleared_by)
        else
          audit(:acquire, name, holder: holder_summary(holder), cleared_by: cleared_by)
        end
        @logger.debug { "lock: restored kept holder pid #{holder["pid"]} of #{name}" }
        nil
      end
    end

    # Marks a `kind: "process"` holder as being stopped by +clearer+ (`dev
    # down` or `dev up --takeover`), exactly as {#clear} marks it for `lock
    # clear`, unless another live clearer is already stopping it. The marker
    # is dropped by {#unmark_clearing} or {#keep_process_holder}, or with
    # the holder once it releases.
    #
    # @param name [String] lock name
    # @param holder [Hash] the holder record about to be stopped
    # @param clearer [Hash, nil] "pid" and "started" of the stopping process;
    #   nil only checks for another clearer
    # @return [Hash, nil] the marker of another live clearer (nothing is
    #   marked then), or nil
    def mark_clearing(name, holder, clearer)
      with_lock(lenient: true) do |data|
        current = data.dig(name, "holder")
        next nil unless same_process?(current, holder)
        marker = live_clearing_marker(current)
        next marker if marker && !same_clearer?(marker, clearer)
        current["clearing"] = clearer.slice("pid", "started") if clearer
        nil
      end
    end

    # Drops the `clearing` marker {#mark_clearing} put on +holder+, if it
    # still names +clearer+.
    #
    # @param name [String] lock name
    # @param holder [Hash] the holder record that was being stopped
    # @param clearer [Hash, nil] "pid" and "started" of the stopping process
    # @return [void]
    def unmark_clearing(name, holder, clearer)
      return unless clearer
      with_lock(lenient: true) do |data|
        current = data.dig(name, "holder")
        drop_clearing_marker!(current, clearer) if same_process?(current, holder)
        nil
      end
    end

    # Marks every lock held by +identity+ idle (its agent finished a turn) or
    # active again. Only `kind: "agent"` holders matching both pid and start
    # time are touched, so another pane's or agent's hold is never changed.
    # An already-idle holder keeps its original `idle_since`.
    #
    # @param identity [Hash] the agent, from {LockHolder#current}
    # @param idle [Boolean] true to set `idle_since`, false to clear it
    # @return [Array<String>] names of locks whose idle state changed
    def mark_idle(identity, idle:)
      with_lock do |data|
        data.filter_map do |name, entry|
          holder = entry["holder"]
          next unless LockHolder.same_agent?(holder, identity) && holder["kind"] != "process"
          clamp_idle_since!(holder)
          next if idle == !holder["idle_since"].nil?
          holder["idle_since"] = idle ? @clock.call : nil
          name
        end
      end
    end

    # Cheap pre-check for {#mark_idle}, safe to run on every hook: reads
    # `locks.json` without the flock (it is only ever replaced by an atomic
    # rename) and reports whether any agent holder in +pane+ would change
    # state. Never raises.
    #
    # @param pane [String, nil] tmux pane id; nil matches any pane
    # @param idle [Boolean] the state {#mark_idle} would set
    # @return [Boolean]
    def idle_change_possible?(pane:, idle:)
      return false unless File.exist?(@data_path)
      data = JSON.parse(File.read(@data_path))
      return false unless data.is_a?(Hash)
      data.each_value.any? do |entry|
        holder = entry.is_a?(Hash) && entry["holder"]
        next false unless holder.is_a?(Hash) && holder["kind"] != "process"
        next false if pane && holder["pane"] != pane
        idle == !holder["idle_since"].is_a?(Numeric)
      end
    rescue SystemCallError, JSON::ParserError
      false
    end

    # Removes and returns the records of locks taken over from +identity+
    # while it was idle, so the displaced agent is told exactly once.
    #
    # @param identity [Hash] the agent, from {LockHolder#current}
    # @param name [String, nil] one lock name, or nil for every lock
    # @return [Array<Hash>] displacement records, each with "name", "at" and
    #   "idle_since" (epoch seconds), and "by" (the new holder's pane, task, worktree)
    def pop_displaced(identity, name: nil)
      return [] unless File.exist?(@data_path)
      with_lock do |data|
        data.each_with_object([]) do |(lock_name, entry), found|
          next if name && lock_name != name
          mine, others = (entry["displaced"] || []).partition { |r| r["pid"] == identity[:pid] && r["started"] == identity[:started] }
          next if mine.empty?
          others.empty? ? entry.delete("displaced") : entry["displaced"] = others
          found.concat(mine.map { |r| r.merge("name" => lock_name) })
        end
      end
    end

    # @return [Array<String>] every lock name with an entry in this namespace
    def names
      with_lock { |data| data.keys }
    end

    # Read-only: never reaps or rewrites `locks.json`. A holder or waiter that
    # would be reaped away on the next mutating op is instead annotated with
    # `"stale" => true` so `workspace lock status` can show it as STALE.
    #
    # @param name [String, nil] a single lock name, or nil for every lock
    # @return [Hash] name => {"holder" => ..., "queue" => [...]}, holder/queue
    #   entries carrying a `"stale"` flag
    def status(name = nil)
      with_lock(readonly: true) do |data|
        annotated = data.transform_values { |entry| annotate_entry(entry) }
        name ? annotated.slice(name) : annotated
      end
    end

    private

    # @param lenient [Boolean] when true, a corrupt or unparseable
    #   `locks.json` reads as empty instead of raising, so `clear` always has
    #   a way to reset the file rather than being wedged by the same
    #   corruption it exists to fix.
    # @param nonblocking [Boolean] when true and another process holds the
    #   store flock, returns nil at once without yielding
    # @param write_unchanged [Boolean] when false, `locks.json` is rewritten
    #   only if the block changed the data it was given
    def with_lock(lenient: false, readonly: false, nonblocking: false, write_unchanged: true)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.chmod(0o700, @dir)
      result = nil
      lock_mode = readonly ? File::RDONLY : (File::RDWR | File::CREAT)
      File.open(@lockfile_path, lock_mode | File::CREAT, 0o600) do |f|
        flock_mode = readonly ? File::LOCK_SH : File::LOCK_EX
        return nil unless f.flock(nonblocking ? flock_mode | File::LOCK_NB : flock_mode)
        @pending_events = []
        data = lenient ? read_data_lenient : read_data
        original = Marshal.load(Marshal.dump(data)) unless write_unchanged
        result = within_liveness_snapshot { yield data }
        unchanged = !write_unchanged && data == original
        write_data(data) unless readonly || unchanged
        flush_audit_events
      end
      result
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access lock store at #{@dir} (#{e.class}: errno #{e.errno})"
    ensure
      @pending_events = nil
    end

    def read_data
      return {} unless File.exist?(@data_path)
      content = File.read(@data_path)
      return {} if content.strip.empty?
      parsed = JSON.parse(content)
      raise corrupt_data_error unless parsed.is_a?(Hash)
      parsed.transform_values { |entry| normalize_entry(entry) }
    rescue JSON::ParserError
      raise corrupt_data_error
    end

    def read_data_lenient
      read_data
    rescue Workspace::Error
      @logger.debug { "lock: corrupt #{@data_path}, starting empty for clear" }
      {}
    end

    def corrupt_data_error
      Workspace::Error.new("#{@data_path} is corrupt; run `workspace lock clear` to reset it")
    end

    def normalize_entry(entry)
      return empty_entry unless entry.is_a?(Hash)
      normalized = {"holder" => normalize_holder(entry["holder"]), "queue" => normalize_queue(entry["queue"])}
      displaced = normalize_displaced(entry["displaced"])
      normalized["displaced"] = displaced unless displaced.empty?
      normalized
    end

    def normalize_displaced(records)
      return [] unless records.is_a?(Array)
      records.select { |r| r.is_a?(Hash) && r["pid"] && r["started"] }
    end

    # Drops a holder record missing the fields liveness checks require,
    # rather than letting it crash reap!/status downstream. A non-numeric
    # `idle_since` reads as active, so {#mark_idle} can record a real one.
    def normalize_holder(holder)
      return nil if holder.nil?
      unless holder.is_a?(Hash) && holder["pid"] && holder["started"]
        @logger.debug { "lock: dropping malformed holder entry: #{holder.inspect}" }
        return nil
      end
      holder["idle_since"] = nil unless holder["idle_since"].is_a?(Numeric)
      holder
    end

    # Drops queue entries missing the fields liveness/promotion require.
    def normalize_queue(queue)
      return [] unless queue.is_a?(Array)
      queue.select do |w|
        valid = w.is_a?(Hash) && w["waiter_pid"] && w["waiter_started"]
        @logger.debug { "lock: dropping malformed queue entry: #{w.inspect}" } unless valid
        valid
      end
    end

    def empty_entry
      {"holder" => nil, "queue" => []}
    end

    def write_data(data)
      tmp = "#{@data_path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @data_path)
    end

    def now_iso
      Time.now.utc.iso8601
    end

    # An agent may hold or wait for only one lock at a time (the v1 deadlock
    # rule): scans every other lock in this namespace for a hold or queue
    # entry belonging to the same agent identity.
    def other_hold_or_wait(data, current_name, identity)
      data.each do |name, entry|
        next if name == current_name
        holder = entry["holder"]
        return name if holder && holder["pid"] == identity[:pid] && holder["started"] == identity[:started]
        if entry["queue"].any? { |w| w["agent_pid"] == identity[:pid] && w["agent_started"] == identity[:started] }
          return name
        end
      end
      nil
    end

    def build_waiter(identity, waiter_pid, waiter_started, task)
      {
        "waiter_pid" => waiter_pid,
        "waiter_started" => waiter_started,
        "agent_pid" => identity[:pid],
        "agent_started" => identity[:started],
        "pane" => identity[:pane],
        "worktree" => identity[:worktree],
        "task" => task,
        "enqueued_at" => now_iso
      }.merge(process_fields(identity))
    end

    def build_holder(identity, task, waiter_pid: nil)
      {
        "kind" => identity[:kind] || "agent",
        "pid" => identity[:pid],
        "started" => identity[:started],
        "pane" => identity[:pane],
        "worktree" => identity[:worktree],
        "task" => task,
        "waiter_pid" => waiter_pid,
        "acquired_at" => now_iso,
        "idle_since" => nil
      }.merge(process_fields(identity))
    end

    def process_fields(identity)
      return {} unless identity[:kind] == "process"
      {"kind" => "process", "pgid" => identity[:pgid], "branch" => identity[:branch]}
    end

    # An agent holder idle for at least the grace period. A process holder
    # (the dev environment) is never idle in this sense.
    def idle_expired?(holder)
      return false if holder["kind"] == "process"
      idle_since = clamp_idle_since!(holder)
      !idle_since.nil? && @clock.call - idle_since >= @idle_grace
    end

    # An `idle_since` later than now means the wall clock stepped back after
    # it was recorded: restart the grace period from now, so the skew never
    # extends it.
    def clamp_idle_since!(holder)
      now = @clock.call
      holder["idle_since"] = now if holder["idle_since"] && holder["idle_since"] > now
      holder["idle_since"]
    end

    # Claims +entry+ for +waiter_pid+ when it was already promoted, or takes
    # it over when this waiter heads the queue and the holder has been idle
    # past the grace period. Shared by {#poll} and {#claim_or_dequeue}.
    #
    # @return [Hash, nil] {status: :acquired}, with :took_over after a
    #   takeover, or nil when the lock is not this waiter's
    def claim!(entry, waiter_pid, name = nil)
      holder = entry["holder"]
      return unless holder
      if holder["waiter_pid"] == waiter_pid
        holder.delete("unclaimed")
        holder.delete("takeover")
        return {status: :acquired}
      end
      return unless entry["queue"].first&.dig("waiter_pid") == waiter_pid && idle_expired?(holder)
      # The head waiter is the caller (the check above), so it is alive by
      # construction: this is its own poll/claim call running right now.
      # Liveness is deliberately not rechecked here.
      displace!(entry, holder, name)
      entry["holder"] = holder_from_waiter(entry["queue"].shift)
      audit(:takeover, name, from: holder_summary(holder), to: entry["holder"] && holder_summary(entry["holder"])) if name
      {status: :acquired, took_over: holder}
    end

    def displace!(entry, holder, name = nil)
      head = entry["queue"].first
      record = {
        "pid" => holder["pid"],
        "started" => holder["started"],
        "pane" => holder["pane"],
        "task" => holder["task"],
        "idle_since" => holder["idle_since"],
        "at" => @clock.call,
        "by" => {"pane" => head["pane"], "task" => head["task"], "worktree" => head["worktree"]}
      }
      records = (entry["displaced"] || []).reject { |r| r["pid"] == holder["pid"] && r["started"] == holder["started"] }
      entry["displaced"] = records << record
      @logger.debug { "lock: waiter #{head["waiter_pid"]} took over from idle pid #{holder["pid"]}" }
    end

    # Buffers one audit event, unless +name+ is nil (a caller with no lock
    # name to attribute the event to, which should not happen in practice).
    # Every caller runs inside {#with_lock} and is expected to pass already-
    # trimmed data (see {#holder_summary}/{#waiter_summary}/{#identity_summary}),
    # so this only drops nils.
    def audit(event, name, **data)
      return unless name
      @pending_events << {event: event.to_s, name: name, data: data.compact}
    end

    # Appends the events buffered during a {#with_lock} block. Runs only once
    # `locks.json` is committed (or a read-only block has returned), so the
    # audit log never records a transition that a failed block or write
    # rolled back, and still under the store flock, so lines land in the same
    # order as the writes they describe. A process killed between the commit
    # and this flush loses those events; that is accepted, since an entry for
    # a state that never committed would mislead an audit trail more than a
    # rare missing one. Lock order is always the store flock first, then
    # {LockAuditLog}'s own flock, never the reverse.
    def flush_audit_events
      @pending_events.each { |e| @audit_log.append(**e) }
    end

    def holder_summary(holder)
      return nil unless holder
      {"pid" => holder["pid"], "pane" => holder["pane"], "worktree" => holder["worktree"], "task" => holder["task"], "kind" => holder["kind"]}
    end

    def waiter_summary(waiter)
      return nil unless waiter
      {"agent_pid" => waiter["agent_pid"], "pane" => waiter["pane"], "worktree" => waiter["worktree"], "task" => waiter["task"]}
    end

    def identity_summary(identity)
      return nil unless identity
      {"pid" => identity[:pid], "pane" => identity[:pane], "worktree" => identity[:worktree]}
    end

    def within_liveness_snapshot(&block)
      @liveness.respond_to?(:within_snapshot) ? @liveness.within_snapshot(&block) : yield
    end

    # An unclaimed promotion also dies with its waiter: nobody is left to
    # tell the agent it holds the lock. A holder `lock clear` kept outlives
    # its wrapper for as long as its process group runs, unless
    # +kept_group+ is false (the `stale` annotation, which reports the
    # wrapper itself as gone).
    def holder_alive?(holder, kept_group: true)
      unless alive_or_unknown?(holder["pid"], holder["started"])
        return kept_group && !!holder["kept"] && kept_group_running?(holder)
      end
      !holder["unclaimed"] || alive_or_unknown?(holder["waiter_pid"], holder["waiter_started"])
    end

    # A group that can't be checked (no terminator, or `ps` failed) counts as
    # running: reaping its hold would let a second dev environment start beside it.
    def kept_group_running?(holder)
      return true unless @terminator
      @terminator.orphan_running?(holder)
    rescue Workspace::Error => e
      @logger.debug { "lock: kept process group #{holder["pgid"]} counts as running: #{e.message}" }
      true
    end

    def waiter_alive?(waiter)
      alive_or_unknown?(waiter["waiter_pid"], waiter["waiter_started"])
    end

    # Unknown liveness (the process table could not be read) counts as alive:
    # reaping a live holder would grant its lock twice.
    def alive_or_unknown?(pid, started)
      @liveness.alive?(pid: pid, started: started)
    rescue Workspace::Error => e
      @logger.debug { "lock: liveness unknown for pid #{pid}, not reaping: #{e.message}" }
      true
    end

    # Promotes the queue head to holder while the lock is free and the head
    # is alive, dropping dead entries in front of a live one as it goes so
    # FIFO order is preserved for whoever is still around. The new holder is
    # "unclaimed" until its waiter polls and learns of the promotion, and
    # keeps a takeover waiter's mark until then, so a promotion taken back
    # by {#keep_process_holder} requeues it as a takeover.
    # A waiter marked by a `lock clear` still running stops promotion there,
    # so it and everyone behind it keep their places until that clear ends.
    def promote!(entry, name = nil)
      while entry["holder"].nil? && !entry["queue"].empty?
        break if live_clearing_marker(entry["queue"].first)
        candidate = entry["queue"].shift
        next unless waiter_alive?(candidate)
        entry["holder"] = holder_from_waiter(candidate).merge({"unclaimed" => true}, candidate.slice("takeover"))
        audit(:acquire, name, holder: holder_summary(entry["holder"])) if name
      end
    end

    # The `clearing` marker {#clear} left on +holder+ (or a waiter), while
    # the clear that left it still runs (or its liveness can't be checked).
    def live_clearing_marker(holder)
      marker = holder["clearing"]
      return nil unless marker.is_a?(Hash) && marker["pid"]
      alive_or_unknown?(marker["pid"], marker["started"]) ? marker : nil
    end

    def waiter_marked_by?(waiter, clearer)
      marker = waiter["clearing"]
      marker.is_a?(Hash) && same_clearer?(marker, clearer)
    end

    def same_clearer?(marker, clearer)
      !clearer.nil? && marker["pid"] == clearer["pid"] && marker["started"] == clearer["started"]
    end

    def drop_clearing_marker!(holder, clearer)
      marker = holder["clearing"]
      holder.delete("clearing") if marker.is_a?(Hash) && same_clearer?(marker, clearer)
      holder
    end

    def same_process?(current, holder)
      !current.nil? && current["pid"] == holder["pid"] && current["started"] == holder["started"]
    end

    # The inverse of {#holder_from_waiter}, for a promotion taken back
    # before its waiter learned of it.
    def waiter_from_holder(holder)
      {
        "waiter_pid" => holder["waiter_pid"],
        "waiter_started" => holder["waiter_started"],
        "agent_pid" => holder["pid"],
        "agent_started" => holder["started"],
        "pane" => holder["pane"],
        "worktree" => holder["worktree"],
        "task" => holder["task"],
        "enqueued_at" => holder["acquired_at"]
      }.merge(process_fields({kind: holder["kind"], pgid: holder["pgid"], branch: holder["branch"]}), holder.slice("takeover"))
    end

    def holder_from_waiter(waiter)
      build_holder(
        {
          kind: waiter["kind"] || "agent",
          pid: waiter["agent_pid"],
          started: waiter["agent_started"],
          pane: waiter["pane"],
          worktree: waiter["worktree"],
          pgid: waiter["pgid"],
          branch: waiter["branch"]
        },
        waiter["task"],
        waiter_pid: waiter["waiter_pid"]
      ).merge("waiter_started" => waiter["waiter_started"])
    end

    def annotate_entry(entry)
      holder = entry["holder"]
      {
        "holder" => holder&.merge("stale" => !holder_alive?(holder, kept_group: false)),
        "queue" => entry["queue"].map { |w| w.merge("stale" => !waiter_alive?(w)) }
      }
    end

    def reap!(data, source: nil)
      data.each do |name, entry|
        if entry["holder"] && !holder_alive?(entry["holder"])
          audit(:reap, name, holder: holder_summary(entry["holder"]), source: source)
          entry["holder"] = nil
        end
        dead, alive = entry["queue"].partition { |w| !waiter_alive?(w) }
        dead.each { |w| audit(:reap, name, waiter: waiter_summary(w), source: source) }
        entry["queue"] = alive
        if entry["displaced"]
          entry["displaced"].select! { |r| alive_or_unknown?(r["pid"], r["started"]) }
          entry.delete("displaced") if entry["displaced"].empty?
        end
        promote!(entry, name)
      end
    end
  end
end
