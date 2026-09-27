require "json"
require "time"

module Workspace
  # Append-only audit log for one lock namespace, written to `locks.jsonl`
  # next to that namespace's `locks.json`.
  #
  # Every {#append} call is expected to run from inside {LockStore}'s flock
  # (either the exclusive lock a mutating op already holds, or the shared
  # lock a read-only op holds), so lines land in the same order as the
  # `locks.json` writes they describe. This class does no locking of its
  # own: it only appends one JSON line per event, which is small enough to
  # land as a single, unsplit `write(2)` call.
  #
  # Growth is bounded by simple size-based rotation: once the file would
  # exceed +rotate_bytes+, it's renamed to `locks.jsonl.1` (replacing any
  # previous one) and a fresh file is started, so at most two generations
  # ever exist on disk.
  class LockAuditLog
    DEFAULT_ROTATE_BYTES = 262_144 # 256KB

    # @param dir [String] this namespace's lock store directory
    # @param logger [Workspace::Logger] debug logger
    # @param rotate_bytes [Integer] rotate once the log would exceed this size
    def initialize(dir:, logger: Workspace::Logger.new, rotate_bytes: DEFAULT_ROTATE_BYTES)
      @path = File.join(dir, "locks.jsonl")
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
      rotate! if would_exceed?(line.bytesize)
      File.open(@path, "a", 0o600) do |f|
        f.write(line)
        f.flush
      end
    rescue SystemCallError => e
      @logger.debug { "lock: audit log write failed (#{e.class}: #{e.message})" }
    end

    private

    def would_exceed?(next_bytes)
      File.exist?(@path) && File.size(@path) + next_bytes > @rotate_bytes
    end

    def rotate!
      File.rename(@path, "#{@path}.1")
    rescue SystemCallError => e
      @logger.debug { "lock: audit log rotation failed (#{e.class}: #{e.message})" }
    end
  end
end
