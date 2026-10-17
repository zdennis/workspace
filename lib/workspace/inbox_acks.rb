require "json"
require "fileutils"
require "time"

module Workspace
  # The derived inbox rows a person has acknowledged or snoozed, in one JSON
  # file (`.inbox/acks.json`). An entry is `{id, fingerprint, acked_at}` plus
  # `until` for a snooze. A derived row stays out of `list` while an entry has
  # its id and its current fingerprint (and, for a snooze, `until` is ahead);
  # a new episode has a new fingerprint and shows again. Written the way
  # {Workspace::InboxStore} is: an exclusive `flock`, a temp file with
  # `fsync`, then `rename`. Reads take no lock and never write: the rename is
  # whole, so a reader sees the file before or after a write. Every write drops
  # acks older than {RETENTION} seconds and snoozes past their `until`.
  class InboxAcks
    # Seconds an ack is kept (30 days).
    RETENTION = 30 * 24 * 60 * 60

    # @param path [String] the acks file
    # @param clock [#call] returns the current Time
    def initialize(path:, clock: -> { Time.now })
      @path = path
      @clock = clock
      @lockfile_path = "#{path}.lock"
    end

    # Leaves out the rows an entry hides now.
    #
    # @param rows [Array<Hash>] derived rows (`id`, `fingerprint`)
    # @return [Hash] `rows:` the rows still showing and `warnings:` (`{"code", "message"}`), one
    #   `inbox_store_unreadable` when the file can't be read, in which case every row shows
    def filter(rows)
      entries = read_entries
      now = @clock.call
      hiding = records(entries).select { |entry| hides_now?(entry, now) }.to_h { |entry| [entry["id"], entry["fingerprint"]] }
      {rows: rows.reject { |row| hiding.key?(row["id"]) && hiding[row["id"]] == row["fingerprint"] }, warnings: []}
    rescue Workspace::Error => e
      {rows: rows, warnings: [{"code" => e.code, "message" => e.message}]}
    end

    # Hides a derived row until its fingerprint changes.
    #
    # @param id [String] the derived id
    # @param fingerprint [String] the row's fingerprint now
    # @return [Boolean] false when this ack was already stored
    # @raise [Workspace::Error] `inbox_store_unreadable`
    def ack(id, fingerprint)
      store(id, fingerprint, nil)
    end

    # Hides a derived row until a time, or until its fingerprint changes.
    #
    # @param id [String] the derived id
    # @param fingerprint [String] the row's fingerprint now
    # @param until_time [String] an ISO 8601 UTC time
    # @return [Boolean] false when this snooze was already stored
    # @raise [Workspace::Error] `inbox_store_unreadable`
    def snooze(id, fingerprint, until_time)
      store(id, fingerprint, until_time)
    end

    private

    def store(id, fingerprint, until_time)
      with_lock do |data|
        same = records(data).any? do |entry|
          entry["id"] == id && entry["fingerprint"] == fingerprint && entry["until"] == until_time
        end
        next false if same
        data.reject! { |entry| entry.is_a?(Hash) && entry["id"] == id }
        entry = {"id" => id, "fingerprint" => fingerprint, "acked_at" => @clock.call.utc.iso8601}
        entry["until"] = until_time if until_time
        data << entry
        prune(data)
        true
      end
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        data = read_entries
        changed = yield data
        write(data) if changed
        changed
      end
    rescue SystemCallError => e
      raise Workspace::Error.new("Could not access inbox acks at #{@path} (#{e.class}: errno #{e.errno})",
        code: "inbox_store_unreadable", details: {"scope" => "acks"})
    end

    def read_entries
      return [] unless File.exist?(@path)
      content = File.read(@path, encoding: Encoding::UTF_8)
      return [] if content.strip.empty?
      parsed = JSON.parse(content)
      return parsed if parsed.is_a?(Array)
      unreadable("it is not a JSON list")
    rescue JSON::ParserError
      unreadable("it is not valid JSON")
    rescue SystemCallError => e
      unreadable("errno #{e.errno}")
    end

    def unreadable(reason)
      raise Workspace::Error.new(
        "Inbox acks #{@path} can't be read (#{reason}); nothing was recorded and the file " \
        "was left unchanged. Fix or move it aside and retry.",
        code: "inbox_store_unreadable", details: {"scope" => "acks"}
      )
    end

    def records(data)
      data.grep(Hash)
    end

    def hides_now?(entry, now)
      return true unless entry["until"]
      wake = parse_time(entry["until"])
      !wake.nil? && wake > now
    end

    # Drops acks older than {RETENTION} and snoozes past their time or with a time that can't be read; an ack whose time can't be read stays.
    def prune(data)
      now = @clock.call
      data.reject! do |entry|
        next false unless entry.is_a?(Hash)
        if entry["until"]
          wake = parse_time(entry["until"])
          wake.nil? || wake <= now
        else
          at = parse_time(entry["acked_at"])
          at && now - at > RETENTION
        end
      end
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def write(data)
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @path)
    end
  end
end
