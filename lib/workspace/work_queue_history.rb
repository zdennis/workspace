require "json"
require "time"

module Workspace
  # The finished items of one workspace's work queue: `work-queue-history.jsonl`,
  # one JSON line per item, oldest first, beside the queue file. Every read and
  # write holds the exclusive lock of a sidecar `<path>.lock` and first drops the
  # lines older than the retention, so a prune rewrite can't lose an append and
  # pruning happens whether or not the agent daemon runs. A line whose
  # `finished_at` can't be read is kept, never guessed at. A line that is not a
  # JSON object is kept in the file and skipped by reads. The file is written
  # whole through {AtomicFile}, mode 0600.
  #
  # Times are ISO 8601 UTC with milliseconds.
  class WorkQueueHistory
    # How long a finished item stays, in seconds (365 days).
    RETENTION = 365 * 24 * 60 * 60

    # @param path [String] the workspace's `work-queue-history.jsonl`
    # @param clock [#now] time source
    # @param retention [Numeric] seconds a line is kept after its `finished_at`
    def initialize(path:, clock: Time, retention: RETENTION)
      @path = path
      @clock = clock
      @retention = retention
      @lock = FileLock.new("#{path}.lock")
    end

    # Adds one finished item, after pruning. `finished_at` is stamped with the
    # clock's time when the entry has none.
    #
    # @param entry [Hash] the item, string keys
    # @return [Hash] the entry as written
    def append(entry)
      append_locked(entry)
    end

    # The same as {#append}, for a caller that already holds the queue store's
    # lock: the lock order is the store's, then this one.
    #
    # @param entry [Hash] the item, string keys
    # @return [Hash] the entry as written
    def append_locked(entry)
      written = {"finished_at" => stamp(@clock.now)}.merge(entry)
      @lock.hold do
        lines = pruned(read_lines).first
        write(lines + [JSON.generate(written)])
      end
      written
    end

    # @param since [Time, nil] only entries finished at or after this
    # @param before [Time, nil] only entries finished before this
    # @param state [String, nil] only entries with this `outcome`
    # @return [Array<Hash>] the entries, oldest first; none when there is no file
    def entries(since: nil, before: nil, state: nil)
      return [] unless File.exist?(@path)
      @lock.hold do
        lines = settle(read_lines)
        parsed(lines).select { |entry| matches?(entry, since, before, state) }
      end
    end

    # @param prefix [String] the start of an item id
    # @return [Hash] the one entry whose `id` starts with it
    # @raise [Workspace::Error] `unknown_queue_item` for none, `ambiguous_queue_item` for several
    def find(prefix)
      found = prefix.to_s.empty? ? [] : entries.select { |e| e["id"].to_s.start_with?(prefix) }
      exact = found.select { |e| e["id"] == prefix }
      found = exact if exact.size == 1
      if found.empty?
        raise Workspace::Error.new("No finished item has an id starting with #{prefix.inspect}.",
          code: "unknown_queue_item", details: {id: prefix})
      end
      if found.size > 1
        raise Workspace::Error.new("#{prefix.inspect} starts more than one finished item; give more of the id.",
          code: "ambiguous_queue_item", details: {id: prefix, matches: found.map { |e| e["id"] }})
      end
      found.first
    end

    # Removes entries: those finished before a time, or all of them.
    #
    # @param before [Time, nil] drop entries finished before this
    # @param all [Boolean] drop every entry
    # @return [Integer] how many entries were removed
    # @raise [ArgumentError] unless exactly one of `before` and `all` is given
    def clear(before: nil, all: false)
      raise ArgumentError, "give exactly one of before: and all:" unless before.nil? == all
      return 0 unless File.exist?(@path)
      @lock.hold do
        lines = settle(read_lines)
        kept = all ? lines.reject { |l| entry_of(l) } : lines.reject { |l| older?(entry_of(l), before) }
        write(kept) if kept != lines
        parsed(lines).size - parsed(kept).size
      end
    end

    # Drops the lines older than the retention.
    #
    # @return [Integer] how many lines were dropped
    def prune
      return 0 unless File.exist?(@path)
      @lock.hold do
        lines = read_lines
        kept, count = pruned(lines)
        write(kept) if count > 0
        count
      end
    end

    private

    def settle(lines)
      kept, count = pruned(lines)
      write(kept) if count > 0
      kept
    end

    def pruned(lines)
      cutoff = @clock.now - @retention
      kept = lines.reject { |line| older?(entry_of(line), cutoff) }
      [kept, lines.size - kept.size]
    end

    def older?(entry, cutoff)
      return false unless entry
      Time.iso8601(entry["finished_at"].to_s) < cutoff
    rescue ArgumentError
      false
    end

    def matches?(entry, since, before, state)
      return false if state && entry["outcome"] != state
      return true unless since || before
      finished = Time.iso8601(entry["finished_at"].to_s)
      (since.nil? || finished >= since) && (before.nil? || finished < before)
    rescue ArgumentError
      false
    end

    def entry_of(line)
      parsed = JSON.parse(line)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def parsed(lines)
      lines.filter_map { |line| entry_of(line) }
    end

    def read_lines
      return [] unless File.exist?(@path)
      File.read(@path).lines.map(&:chomp).reject(&:empty?)
    end

    def write(lines)
      AtomicFile.write(@path, lines.map { |l| "#{l}\n" }.join, perm: 0o600, tag: Thread.current.object_id)
    end

    def stamp(time)
      time.utc.iso8601(3)
    end
  end
end
