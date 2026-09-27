require "json"
require "time"

module Workspace
  # Append-only audit log for one lock namespace, written to `locks.jsonl`
  # next to that namespace's `locks.json`.
  #
  # {LockStore} calls {#append} only once it has staged and fsynced the
  # `locks.json` write an event describes, just before renaming it into
  # place, while still holding its own flock, so lines land in the same
  # order as those writes.
  #
  # Growth is bounded by simple size-based rotation: once the file would
  # exceed +rotate_bytes+, it's renamed to `locks.jsonl.1` (replacing any
  # previous one) and a fresh file is started, so at most two generations
  # ever exist on disk. Once an append looks due to rotate, the re-check,
  # rotation, and append run under an exclusive flock on a dedicated
  # `locks.jsonl.lock`, since callers holding only a shared store flock
  # (denies) could otherwise both rotate and clobber a whole generation.
  # That lock is always taken after the store flock, never before, so the
  # two can't deadlock.
  class LockAuditLog
    DEFAULT_ROTATE_BYTES = 262_144 # 256KB

    # @param dir [String] this namespace's lock store directory
    # @param logger [Workspace::Logger] debug logger
    # @param rotate_bytes [Integer] rotate once the log would exceed this size
    def initialize(dir:, logger: Workspace::Logger.new, rotate_bytes: DEFAULT_ROTATE_BYTES)
      @path = File.join(dir, "locks.jsonl")
      @lockfile_path = "#{@path}.lock"
      @logger = logger
      @rotate_bytes = rotate_bytes
    end

    # Appends one audit event. Never raises: a failure to write the audit
    # trail must never block or fail the lock operation it's describing.
    #
    # @param event [String] "acquire", "release", "reap", "takeover", "clear", or "deny"
    # @param name [String] lock name
    # @param data [Hash] event-specific fields (holder/waiter summaries, pids, etc.)
    # @return [void]
    def append(event:, name:, data: {})
      line = JSON.generate({
        "timestamp" => Time.now.utc.iso8601(3),
        "event" => event,
        "lock" => name
      }.merge(data)) + "\n"
      if near_rotation?(line.bytesize)
        with_rotation_lock do
          rotate! if would_exceed?(line.bytesize)
          write_line(line)
        end
      else
        write_line(line)
      end
    rescue SystemCallError => e
      @logger.debug { "lock: audit log write failed (#{e.class}: #{e.message})" }
    end

    private

    # Unlocked hint: most appends are nowhere near the threshold and skip
    # the rotation lock entirely. An `O_APPEND` write is atomic, so one that
    # races a rotation still lands whole in one generation or the other.
    def near_rotation?(next_bytes)
      File.exist?(@path) && File.size(@path) + next_bytes > @rotate_bytes
    end

    # Re-checked under the rotation lock, since another appender may have
    # rotated between {#near_rotation?} and taking the lock.
    def would_exceed?(next_bytes)
      File.stat(@path).size + next_bytes > @rotate_bytes
    rescue Errno::ENOENT
      false
    end

    def with_rotation_lock
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write_line(line)
      File.open(@path, "a", 0o600) do |f|
        f.write(line)
        f.flush
      end
    end

    def rotate!
      File.rename(@path, "#{@path}.1")
    rescue SystemCallError => e
      @logger.debug { "lock: audit log rotation failed (#{e.class}: #{e.message})" }
    end
  end
end
