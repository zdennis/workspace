require "json"
require "fileutils"
require "time"

module Workspace
  # Reads and mutates one namespace's `locks.json`, guarded by `flock` so
  # concurrent CLI invocations serialize their read-modify-write cycles.
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
  # `--takeover` and `lock clear` can signal its whole process group.
  class LockStore
    # @param dir [String] this namespace's lock store directory
    # @param liveness [Workspace::LockHolder] checks whether a recorded pid is still alive
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, liveness:, logger: Workspace::Logger.new)
      @dir = dir
      @liveness = liveness
      @logger = logger
      @lockfile_path = File.join(dir, "locks.lock")
      @data_path = File.join(dir, "locks.json")
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
    # @return [Hash] :status is one of :acquired, :already_held, :held, :queued, :deadlock
    def acquire(name, identity:, waiter_pid:, waiter_started:, task: nil, wait: false)
      with_lock do |data|
        reap!(data)
        entry = data[name] ||= empty_entry
        holder = entry["holder"]

        if same_agent?(holder, identity)
          holder.delete("unclaimed")
          next {status: :already_held}
        end

        if (other = other_hold_or_wait(data, name, identity))
          next {status: :deadlock, other: other}
        end

        if holder.nil? && entry["queue"].empty?
          entry["holder"] = build_holder(identity, task, waiter_pid: waiter_pid)
          next {status: :acquired}
        end

        next {status: :held, holder: holder} unless wait

        existing_index = entry["queue"].index { |w| w["agent_pid"] == identity[:pid] && w["agent_started"] == identity[:started] }
        if existing_index
          entry["queue"][existing_index]["waiter_pid"] = waiter_pid
          entry["queue"][existing_index]["waiter_started"] = waiter_started
          position = existing_index + 1
        else
          entry["queue"] << build_waiter(identity, waiter_pid, waiter_started, task)
          position = entry["queue"].size
        end
        total = position + (holder ? 1 : 0)
        {status: :queued, position: position, total: total, holder: holder}
      end
    end

    # Checks progress for a queued `acquire --wait`, called once per poll.
    #
    # @param name [String] lock name
    # @param waiter_pid [Integer] the waiting process's own pid
    # @return [Hash] :status is one of :acquired, :queued, :cleared
    def poll(name, waiter_pid)
      with_lock do |data|
        reap!(data)
        entry = data[name]
        next {status: :cleared} unless entry

        holder = entry["holder"]
        if holder && holder["waiter_pid"] == waiter_pid
          holder.delete("unclaimed")
          next {status: :acquired}
        end

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
        promote!(entry)
        true
      end
    end

    # Releases every lock +pid+ holds and removes it from every queue it is
    # waiting in.
    #
    # @param pid [Integer]
    # @return [Array<String>] names of locks actually released
    def release_all(pid)
      with_lock do |data|
        reap!(data)
        released = []
        data.each do |name, entry|
          holder = entry["holder"]
          if holder && holder["pid"] == pid
            entry["holder"] = nil
            promote!(entry)
            released << name
          end
          entry["queue"].reject! { |w| w["waiter_pid"] == pid }
        end
        released
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
          promote!(entry)
          next :released
        end
        removed = entry["queue"].reject! { |w| w["waiter_pid"] == waiter_pid }
        removed ? :dequeued : :absent
      end
    end

    # Ends a timed-out wait in one step: claims the lock if it was promoted
    # to this waiter since its last poll, otherwise leaves the queue.
    #
    # @param name [String] lock name
    # @param waiter_pid [Integer]
    # @return [Symbol] :acquired or :dequeued
    def claim_or_dequeue(name, waiter_pid)
      with_lock do |data|
        entry = data[name]
        holder = entry && entry["holder"]
        if holder && holder["waiter_pid"] == waiter_pid
          holder.delete("unclaimed")
          next :acquired
        end
        entry["queue"].reject! { |w| w["waiter_pid"] == waiter_pid } if entry
        :dequeued
      end
    end

    # Removes a lock's holder and queue unconditionally, with no liveness
    # check. Yields the holder record first (if any), so a caller can run a
    # kind-specific side effect — a `kind: "process"` holder's caller is
    # expected to terminate its recorded pgid before the record disappears.
    #
    # @param name [String] lock name
    # @param cleared_by [String, nil] identity recorded for logging
    # @yieldparam holder [Hash, nil] the holder being cleared
    # @return [Hash, nil] the removed {holder:, queue:}, or nil if the lock had no entry
    def clear(name, cleared_by: nil)
      with_lock(lenient: true) do |data|
        entry = data[name]
        next nil unless entry
        holder = entry["holder"]
        yield holder if block_given?
        data.delete(name)
        @logger.debug { "lock: cleared #{name}#{" by #{cleared_by}" if cleared_by}" }
        {holder: holder, queue: entry["queue"]}
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
    def with_lock(lenient: false, readonly: false)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      result = nil
      lock_mode = readonly ? File::RDONLY : (File::RDWR | File::CREAT)
      File.open(@lockfile_path, lock_mode | File::CREAT, 0o600) do |f|
        f.flock(readonly ? File::LOCK_SH : File::LOCK_EX)
        data = lenient ? read_data_lenient : read_data
        result = within_liveness_snapshot { yield data }
        write_data(data) unless readonly
      end
      result
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
      {"holder" => normalize_holder(entry["holder"]), "queue" => normalize_queue(entry["queue"])}
    end

    # Drops a holder record missing the fields liveness checks require,
    # rather than letting it crash reap!/status downstream.
    def normalize_holder(holder)
      return nil unless holder.is_a?(Hash) && holder["pid"] && holder["started"]
      holder
    end

    # Drops queue entries missing the fields liveness/promotion require.
    def normalize_queue(queue)
      return [] unless queue.is_a?(Array)
      queue.select { |w| w.is_a?(Hash) && w["waiter_pid"] && w["waiter_started"] }
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

    def same_agent?(holder, identity)
      !!holder && holder["pid"] == identity[:pid] && holder["started"] == identity[:started]
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
      }
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
      {"pgid" => identity[:pgid], "branch" => identity[:branch]}
    end

    def within_liveness_snapshot(&block)
      @liveness.respond_to?(:within_snapshot) ? @liveness.within_snapshot(&block) : yield
    end

    # An unclaimed promotion also dies with its waiter: nobody is left to
    # tell the agent it holds the lock.
    def holder_alive?(holder)
      return false unless alive_or_unknown?(holder["pid"], holder["started"])
      !holder["unclaimed"] || alive_or_unknown?(holder["waiter_pid"], holder["waiter_started"])
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
    # "unclaimed" until its waiter polls and learns of the promotion.
    def promote!(entry)
      while entry["holder"].nil? && !entry["queue"].empty?
        candidate = entry["queue"].shift
        next unless waiter_alive?(candidate)
        entry["holder"] = build_holder(
          {
            kind: "agent",
            pid: candidate["agent_pid"],
            started: candidate["agent_started"],
            pane: candidate["pane"],
            worktree: candidate["worktree"]
          },
          candidate["task"],
          waiter_pid: candidate["waiter_pid"]
        ).merge("waiter_started" => candidate["waiter_started"], "unclaimed" => true)
      end
    end

    def annotate_entry(entry)
      holder = entry["holder"]
      {
        "holder" => holder&.merge("stale" => !holder_alive?(holder)),
        "queue" => entry["queue"].map { |w| w.merge("stale" => !waiter_alive?(w)) }
      }
    end

    def reap!(data)
      data.each_value do |entry|
        entry["holder"] = nil if entry["holder"] && !holder_alive?(entry["holder"])
        entry["queue"].select! { |w| waiter_alive?(w) }
        promote!(entry)
      end
    end
  end
end
