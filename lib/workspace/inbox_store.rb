require "json"
require "fileutils"
require "securerandom"
require "time"

module Workspace
  # The items of one inbox scope (a workspace, a project or the global list),
  # durable in one JSON file and guarded by `flock` so concurrent CLI
  # invocations never clobber each other's writes. Written the way
  # {Workspace::AskStore} is: an exclusive lock to write, a shared one to read,
  # a temp file with `fsync`, then `rename`. Records are patched by id, never
  # by index.
  #
  # The store keeps text as data and checks none of it; the command that
  # builds a record checks its fields (string keys, valid ISO 8601 times)
  # before it gets here. Every write stores a passed snooze (the item is
  # open again) and a passed expiry (the item is dismissed by expiry) on every
  # item it finds, and reports each expiry to {#on_expired}; reads compute both
  # and never write. Retention: a write that would make the {LIVE_LIMIT}+1st
  # live item raises `inbox_full`, and every write drops the resolved items
  # past the newest {RESOLVED_LIMIT} (by `resolved_at`).
  class InboxStore
    # The states {#transition} moves an item to.
    STATES = %w[open snoozed done dismissed].freeze

    # The most items one scope holds in `open` or `snoozed`; a write that would add another is `inbox_full`.
    LIVE_LIMIT = 500

    # The newest resolved (`done` or `dismissed`) items a scope keeps; older ones are dropped on write.
    RESOLVED_LIMIT = 200

    # What {#transition} did.
    # @!attribute record [Hash] the item after the call
    # @!attribute changed [Boolean] false when it was already in the state
    Transition = Struct.new(:record, :changed)

    # Called with each item an earlier-set expiry dismissed during a write, after
    # the write is done and the lock released (the caller logs `expired`).
    # @return [#call, nil]
    attr_accessor :on_expired

    # @param path [String] path to this scope's JSON file
    # @param scope [String] how this scope is named in errors (`workspace:api`)
    # @param clock [#call] returns the current Time
    # @param error_output [IO] where a read that skips an unreadable file warns
    def initialize(path:, scope: nil, clock: -> { Time.now }, error_output: $stderr)
      @path = path
      @scope = scope || File.basename(path, ".json")
      @clock = clock
      @error_output = error_output
      @lockfile_path = "#{path}.lock"
      @warned = false
    end

    # Appends a new open item. The store sets `id`, `state`, the timestamps
    # and the resolution fields; everything else in `record` is kept as given.
    #
    # @param record [Hash] the writable fields (`type`, `scope`, `title`, ...)
    # @return [Hash] the stored record
    def add(record)
      with_lock do |data|
        ensure_room(data)
        build_item(record, data).tap { |item| data << item }
      end
    end

    # What {#upsert} did.
    # @!attribute record [Hash] the item after the call
    # @!attribute outcome [String] `created`, `updated`, `suppressed` or `reopened`
    Upsert = Struct.new(:record, :outcome)

    # Adds the record, or updates the one item already holding its
    # `dedupe_key`, in one lock so two writers never leave two items. An open
    # or snoozed item takes the new `title`, `body`, `source`, `links` and
    # `expires_at` and keeps its `id`, `state` and `snooze_until` (`updated`).
    # A done, dismissed or expired one is left alone (`suppressed`) unless
    # +reopen+ is set, which opens it with the new fields (`reopened`).
    #
    # @param record [Hash] as {#add}, with a non-nil `dedupe_key`
    # @param reopen [Boolean] reopen a resolved item instead of suppressing
    # @return [Upsert]
    def upsert(record, reopen: false)
      key = record["dedupe_key"]
      raise ArgumentError, "upsert needs a dedupe_key" if key.nil?
      with_lock do |data|
        now = @clock.call
        existing = records_in(data).find { |r| r["dedupe_key"] == key }
        unless existing
          ensure_room(data)
          next Upsert.new(build_item(record, data).tap { |item| data << item }, "created")
        end
        settled = settle(existing, now)
        live = %w[open snoozed].include?(settled["state"])
        next Upsert.new(settled, "suppressed") unless live || reopen
        ensure_room(data) unless live
        existing.replace(settled)
        UPSERT_FIELDS.each { |field| existing[field] = record[field] }
        existing["updated_at"] = now_iso
        unless live
          existing.merge!("state" => "open", "resolved_at" => nil, "resolved_by" => nil, "snooze_until" => nil)
        end
        Upsert.new(existing, live ? "updated" : "reopened")
      end
    end

    # Never creates the store: nothing recorded yet reads as empty. An
    # unreadable file also reads as empty, with one warning, since nothing is
    # written back. A snooze whose time has passed reads `open`, an item
    # whose expiry has passed reads `dismissed`; neither is written.
    #
    # @return [Array<Hash>] items, oldest first
    def list
      return [] unless File.exist?(@path)
      now = @clock.call
      with_lock(readonly: true) { |data| records_in(data).map { |r| settle(r, now) } }
    end

    # @param id [String]
    # @return [Hash, nil] the item, or nil when this scope has none with the id
    def find(id)
      list.find { |r| r["id"] == id }
    end

    # Changes a record's fields: yields the stored record (a passed snooze or
    # expiry already applied) under the exclusive lock and stamps `updated_at`
    # after the block, unless the block left the record as it was. State changes go through {#transition}.
    #
    # @param id [String]
    # @yieldparam record [Hash] the record to change in place
    # @return [Hash, nil] the changed record, or nil when there is no such id
    def update(id)
      with_lock do |data|
        record = records_in(data).find { |r| r["id"] == id }
        next nil unless record
        record.replace(settle(record, @clock.call))
        before = record.dup
        yield record
        record["updated_at"] = now_iso unless record == before
        record
      end
    end

    # Moves an item to a state. `done` and `dismissed` stamp `resolved_at` and
    # `resolved_by`; `open` and `snoozed` clear them. `snoozed` needs the time to
    # wake at, and `open` drops an expiry already past, so a reopened item stays
    # open. An item already in the state is left untouched.
    #
    # @param id [String]
    # @param to [String] one of {STATES}
    # @param by [Hash, nil] who resolved it (`{"kind" => "user", "pane" => "%3"}`)
    # @param snooze_until [String, nil] ISO 8601 time to wake at; required for `snoozed`
    # @return [Transition, nil] nil when there is no such id
    # @raise [Workspace::Error] `invalid_inbox_item` when snoozing a done or dismissed item
    def transition(id, to:, by: nil, snooze_until: nil)
      transition_where(to, by, snooze_until) { |r| r["id"] == id }
    end

    # {#transition} for the item holding a `dedupe_key`, found and changed under one lock.
    # An unreadable store raises `inbox_store_unreadable` rather than reading as no match.
    #
    # @param key [String]
    # @return [Transition, nil] nil when no item holds the key
    def transition_by_key(key, to:, by: nil, snooze_until: nil)
      transition_where(to, by, snooze_until) { |r| r["dedupe_key"] == key }
    end

    private

    def transition_where(to, by, snooze_until)
      raise ArgumentError, "unknown inbox state #{to.inspect}" unless STATES.include?(to)
      raise ArgumentError, "snoozing needs snooze_until" if to == "snoozed" && snooze_until.nil?
      with_lock do |data|
        now = @clock.call
        record = records_in(data).find { |r| yield r }
        next nil unless record
        settled = settle(record, now)
        if to == "snoozed" && %w[done dismissed].include?(settled["state"])
          raise Workspace::Error.new("Invalid inbox item: state is #{settled["state"]}; reopen it before snoozing.",
            code: "invalid_inbox_item", details: {"field" => "state", "reason" => "is #{settled["state"]}; reopen it before snoozing"})
        end
        next Transition.new(settled, false) if settled["state"] == to && (to != "snoozed" || settled["snooze_until"] == snooze_until)
        ensure_room(data) if to == "open" && %w[done dismissed].include?(settled["state"])
        record.replace(settled)
        apply_transition(record, to, by, now, snooze_until)
        Transition.new(record, true)
      end
    end

    # The fields an upsert refreshes on an item that already holds the key.
    UPSERT_FIELDS = %w[title body source links expires_at note].freeze
    private_constant :UPSERT_FIELDS

    def ensure_room(data)
      return if records_in(data).count { |r| %w[open snoozed].include?(r["state"]) } < LIVE_LIMIT
      raise Workspace::Error.new(
        "Inbox is full: #{@scope} holds #{LIVE_LIMIT} open or snoozed items. Mark some done or dismissed first.",
        code: "inbox_full", details: {"scope" => @scope, "limit" => LIVE_LIMIT}
      )
    end

    # Drops the resolved items past the newest {RESOLVED_LIMIT} by `resolved_at`.
    def trim_resolved(data)
      resolved = data.each_with_index.select { |r, _| r.is_a?(Hash) && %w[done dismissed].include?(r["state"]) }
      return if resolved.size <= RESOLVED_LIMIT
      oldest = resolved.sort_by { |r, i| [parse_time(r["resolved_at"]) || Time.at(0), i] }.first(resolved.size - RESOLVED_LIMIT)
      drop = oldest.map(&:last)
      data.reject!.with_index { |_, i| drop.include?(i) }
    end

    def build_item(record, data)
      now = now_iso
      record.merge(
        "id" => unused_id(data),
        "state" => "open",
        "snooze_until" => nil,
        "created_at" => now,
        "updated_at" => now,
        "resolved_at" => nil,
        "resolved_by" => nil
      )
    end

    def apply_transition(record, to, by, now, snooze_until)
      stamp = now.utc.iso8601
      record["state"] = to
      record["updated_at"] = stamp
      if %w[done dismissed].include?(to)
        record["resolved_at"] = stamp
        record["resolved_by"] = by
        record["snooze_until"] = nil
      else
        record["resolved_at"] = nil
        record["resolved_by"] = nil
        record["snooze_until"] = (to == "snoozed") ? snooze_until : nil
        record["expires_at"] = nil if to == "open" && (parse_time(record["expires_at"]) || now) <= now
      end
    end

    # @return [Hash] a copy with a passed snooze or expiry applied
    def settle(record, now)
      state = record["state"]
      return record unless %w[open snoozed].include?(state)
      expires = parse_time(record["expires_at"])
      if expires && expires <= now
        return record.merge(
          "state" => "dismissed",
          "snooze_until" => nil,
          "resolved_at" => expires.utc.iso8601,
          "resolved_by" => {"kind" => "expiry"}
        )
      end
      wake = parse_time(record["snooze_until"])
      return record unless state == "snoozed" && wake && wake <= now
      record.merge("state" => "open", "snooze_until" => nil)
    end

    # The write is done by now, so a failing callback only warns.
    def report_expired(record)
      @on_expired&.call(record)
    rescue => e
      @error_output.puts "workspace: could not report the expiry of inbox item #{record["id"]} (#{e.class})"
    end

    # Applies every passed snooze and expiry to the stored records in place.
    # @return [Array<Hash>] the records that expired
    def settle_stored(data)
      now = @clock.call
      records_in(data).filter_map do |record|
        settled = settle(record, now)
        next if settled.equal?(record)
        record.replace(settled)
        record if settled["resolved_by"] == {"kind" => "expiry"}
      end
    end

    def parse_time(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end

    # @param readonly [Boolean] shared lock, and never rewrites the file. A
    #   write raises rather than replace a file it couldn't read, since that
    #   would drop every item in it.
    def with_lock(readonly: false)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      result = nil
      expired = []
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(readonly ? File::LOCK_SH : File::LOCK_EX)
        data = read_data(readonly: readonly)
        expired = settle_stored(data) unless readonly
        result = yield data
        unless readonly
          trim_resolved(data)
          write_data(data)
        end
      end
      expired.each { |record| report_expired(record) }
      result
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access inbox store at #{@path} (#{e.class}: errno #{e.errno})"
    end

    def read_data(readonly:)
      return [] unless File.exist?(@path)
      # Written as UTF-8 JSON; read as that whatever the locale of the process.
      content = File.read(@path, encoding: Encoding::UTF_8)
      return [] if content.strip.empty?
      parsed = JSON.parse(content)
      return parsed if parsed.is_a?(Array)
      unreadable("it is not a JSON list", readonly)
    rescue JSON::ParserError
      unreadable("it is not valid JSON", readonly)
    end

    def unreadable(reason, readonly)
      unless readonly
        raise Workspace::Error.new(
          "Inbox store #{@path} can't be read (#{reason}); nothing was recorded and the file " \
          "was left unchanged. Fix or move it aside and retry.",
          code: "inbox_store_unreadable", details: {"scope" => @scope}
        )
      end
      unless @warned
        @warned = true
        @error_output.puts "workspace: ignoring inbox store #{@path} (#{reason})"
      end
      []
    end

    # Entries that aren't JSON objects are kept on disk but never matched or listed.
    def records_in(data)
      data.grep(Hash)
    end

    def unused_id(data)
      taken = records_in(data).map { |r| r["id"] }
      loop do
        id = SecureRandom.hex(5)
        return id unless taken.include?(id)
      end
    end

    def write_data(data)
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @path)
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
