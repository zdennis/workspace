require "json"
require "fileutils"
require "securerandom"
require "time"

module Workspace
  # The prompts `agent-run send --when-idle` left for a pane to take once its
  # turn ends: one `prompt-queue.json` per workspace, beside `asks.json`,
  # guarded by `flock` on `<path>.lock` and written through a temp file and
  # rename. The agent daemon adds and delivers entries ({PromptQueueDesk});
  # the file survives the daemon, so entries wait for the next one.
  #
  # An entry is `queued` until a delivery claims it (`delivering`, with the
  # daemon's pid, `claimed_at` and the readiness time it was claimed on),
  # then marked `paste_started_at` right before its text is pasted. Text
  # that never reached the pane goes back to `queued`; text that did, or may
  # have, is never typed again. Per pane the file keeps `last_delivered_at`,
  # so one entry goes per turn end even across a daemon restart.
  #
  # Times are ISO 8601 UTC with milliseconds.
  class PromptQueueStore
    # Most entries one pane may hold.
    MAX_PER_PANE = 8

    # Longest text, in bytes.
    MAX_BYTES = 32 * 1024

    # Seconds after which a `delivering` entry is taken as abandoned.
    STALE_CLAIM = 60

    # What a claim writes into an entry, removed when it goes back to `queued`.
    CLAIM_KEYS = %w[claim_id daemon_pid claimed_at claimed_fresh_since paste_started_at].freeze

    # @param path [String] the workspace's `prompt-queue.json`
    # @param clock [#now] time source
    # @param id_generator [#call] returns a new entry id
    # @param pid_alive [#call] given a pid, whether that process is running
    def initialize(path:, clock: Time, id_generator: -> { SecureRandom.hex(8) },
      pid_alive: ->(pid) { PromptQueueStore.pid_alive?(pid) })
      @path = path
      @lockfile_path = "#{path}.lock"
      @clock = clock
      @id_generator = id_generator
      @pid_alive = pid_alive
    end

    # @param pid [Integer]
    # @return [Boolean] whether a process with that pid is running
    def self.pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # @param time [Time, nil]
    # @return [String, nil] the time as the file stores it
    def self.stamp(time)
      time&.utc&.iso8601(3)
    end

    # Queues a prompt at the end of the pane's entries.
    #
    # @param pane_id [String] tmux pane id
    # @param text [String] the prompt
    # @param identity [Hash] what the pane must still be at delivery:
    #   "server_pid", "pane_pid", "agent_pid", "session_id" (nil until known)
    # @param clear_first [Boolean]
    # @return [Array(Symbol, Hash)] `:added` and the entry with its
    #   "position" (from 1), or `:queue_full` and nil
    def add(pane_id:, text:, identity:, clear_first: false)
      with_lock do |data|
        mine = data["entries"].count { |e| e["pane_id"] == pane_id }
        next [:queue_full, nil] if mine >= MAX_PER_PANE

        entry = {"id" => unused_id(data), "pane_id" => pane_id, "state" => "queued", "text" => text,
                 "clear_first" => clear_first, "queued_at" => now,
                 "server_pid" => identity["server_pid"], "pane_pid" => identity["pane_pid"],
                 "agent_pid" => identity["agent_pid"], "session_id" => identity["session_id"]}
        data["entries"] << entry
        [:added, entry.merge("position" => mine + 1)]
      end
    end

    # @param pane_id [String, nil] only this pane's entries
    # @return [Array<Hash>] entries in queue order; none when the file is missing
    def entries(pane_id: nil)
      return [] unless File.exist?(@path)
      list = with_lock(readonly: true) { |data| data["entries"] }
      pane_id ? list.select { |e| e["pane_id"] == pane_id } : list
    end

    # @return [Array<String>] the panes that have entries
    def pane_ids
      entries.map { |e| e["pane_id"] }.uniq
    end

    # Marks an entry as reported queued, so its end is reported too.
    #
    # @param id [String]
    # @return [Hash, nil] the entry with its "position", or nil when it is gone
    def announce(id)
      with_lock do |data|
        entry = data["entries"].find { |e| e["id"] == id }
        next nil unless entry
        entry["announced"] = true
        entry.merge("position" => data["entries"].select { |e| e["pane_id"] == entry["pane_id"] }.index(entry) + 1)
      end
    end

    # Writes the first session id seen for a pane into its entries queued
    # before any was known.
    #
    # @param pane_id [String]
    # @param session_id [String]
    # @return [Integer] how many entries took it
    def bind_session(pane_id, session_id)
      return 0 unless session_id && File.exist?(@path)
      with_lock do |data|
        unbound = data["entries"].select { |e| e["pane_id"] == pane_id && e["session_id"].nil? }
        unbound.each { |e| e["session_id"] = session_id }
        unbound.size
      end
    end

    # Removes the pane's `queued` entries the block names a reason for.
    #
    # @param pane_id [String]
    # @yieldparam entry [Hash]
    # @yieldreturn [String, nil] the reason to drop it, or nil to keep it
    # @return [Array<Array(Hash, String)>] each entry dropped and its reason
    def drop_queued(pane_id)
      return [] unless File.exist?(@path)
      with_lock do |data|
        dropped = data["entries"].filter_map do |entry|
          next unless entry["pane_id"] == pane_id && entry["state"] == "queued"
          reason = yield(entry)
          reason && [entry, reason]
        end
        data["entries"] -= dropped.map(&:first)
        dropped
      end
    end

    # Reaps abandoned deliveries, then claims the pane's head entry when it
    # is `queued`, no other entry of the pane is `delivering`, and the block
    # says the pane is ready later than its last delivery.
    #
    # A `delivering` entry is abandoned when its daemon is gone or its claim
    # is older than {STALE_CLAIM}: one whose paste may have started is
    # dropped `interrupted`, any other goes back to `queued`.
    #
    # @param pane_id [String]
    # @param daemon_pid [Integer] the claiming daemon
    # @yieldreturn [Time, nil] when the pane's current done or idle began,
    #   or nil when it isn't ready
    # @return [Array(Hash, Array)] the claimed entry (nil when none) and the
    #   entries dropped as `interrupted`
    def claim(pane_id, daemon_pid:)
      with_lock do |data|
        reaped = reap(data)
        mine = data["entries"].select { |e| e["pane_id"] == pane_id }
        head = mine.first
        claimable = head && head["state"] == "queued" && mine.none? { |e| e["state"] == "delivering" }
        next [nil, reaped] unless claimable

        fresh = self.class.stamp(yield)
        last = parse_time(data.dig("panes", pane_id, "last_delivered_at"))
        newer = fresh && (last.nil? || Time.iso8601(fresh) > last)
        next [nil, reaped] unless newer

        head.merge!("state" => "delivering", "claim_id" => @id_generator.call, "daemon_pid" => daemon_pid,
          "claimed_at" => now, "claimed_fresh_since" => fresh)
        [head.dup, reaped]
      end
    end

    # Says whether a claim may go on to type its clear command: the claim
    # is still current and no cancel was asked for. A cancelled entry is
    # removed. Unlike {#start_paste} it marks nothing, so the entry can
    # still be cancelled while the clear is confirmed.
    #
    # @param claim [Hash] the entry {#claim} returned
    # @return [Symbol] `:ok`, `:cancelled` or `:missing`
    def proceed(claim)
      with_lock do |data|
        entry = claimed(data, claim)
        next :missing unless entry && !entry["paste_started_at"]
        next :ok unless entry["cancel_requested"]
        data["entries"].delete(entry)
        :cancelled
      end
    end

    # Moves a pane's entries from one conversation to the next, after a
    # clear the queue typed itself: the entries queued behind a
    # `clear_first` entry were meant for the conversation it starts.
    #
    # @param pane_id [String]
    # @param from [String, nil] the conversation that was cleared; nil changes nothing
    # @param to [String] the new conversation's session id
    # @return [Integer] how many entries took it
    def rebind_session(pane_id, from:, to:)
      return 0 unless from && to
      with_lock do |data|
        moved = data["entries"].select { |e| e["pane_id"] == pane_id && e["session_id"] == from }
        moved.each { |e| e["session_id"] = to }
        moved.size
      end
    end

    # Marks the paste as starting, unless a cancel was asked for meanwhile:
    # then the entry is removed and nothing should be typed. Only the claim
    # that is current may start it, once: a claim that was reaped and taken
    # again finds the entry `:missing`. Its `claimed_at` becomes the paste
    # time.
    #
    # @param claim [Hash] the entry {#claim} returned
    # @return [Symbol] `:started`, `:cancelled` or `:missing`
    def start_paste(claim)
      with_lock do |data|
        entry = claimed(data, claim)
        next :missing unless entry && !entry["paste_started_at"]
        if entry["cancel_requested"]
          data["entries"].delete(entry)
          next :cancelled
        end
        # The paste restarts the claim's clock, so time spent waiting for the
        # delivery lock never gets a claim mid-paste reaped.
        entry["paste_started_at"] = entry["claimed_at"] = now
        :started
      end
    end

    # Ends a claimed entry's delivery.
    #
    # @param claim [Hash] the entry {#claim} returned; a claim that is no
    #   longer current changes nothing
    # @param outcome [Symbol] `:delivered` (removed; the pane's
    #   `last_delivered_at` becomes the paste time), `:requeue` (back to
    #   `queued` where it was, claim fields cleared) or `:drop` (removed)
    # @return [Hash, nil] the entry as it was, or nil when it is gone
    def finish(claim, outcome)
      with_lock do |data|
        entry = claimed(data, claim)
        next nil unless entry
        before = entry.dup
        case outcome
        when :delivered
          data["entries"].delete(entry)
          (data["panes"][entry["pane_id"]] ||= {})["last_delivered_at"] = entry["paste_started_at"] || now
        when :requeue
          entry["state"] = "queued"
          CLAIM_KEYS.each { |key| entry.delete(key) }
        when :drop then data["entries"].delete(entry)
        else raise ArgumentError, "unknown outcome #{outcome.inspect}"
        end
        before
      end
    end

    # Cancels an entry.
    #
    # @param id [String]
    # @return [Array(Symbol, Hash)] `:cancelled` (a queued entry, removed),
    #   `:cancel_requested` (a claimed entry not yet pasting; the delivery
    #   removes it and types nothing), `:pasting` (its text may be in the
    #   pane; nothing changed) or `:unknown` (nil)
    def cancel(id)
      with_lock do |data|
        entry = data["entries"].find { |e| e["id"] == id }
        next [:unknown, nil] unless entry
        next [:pasting, entry] if entry["paste_started_at"]
        if entry["state"] == "delivering"
          entry["cancel_requested"] = true
          next [:cancel_requested, entry]
        end
        data["entries"].delete(entry)
        [:cancelled, entry]
      end
    end

    private

    def reap(data)
      stale = data["entries"].select { |e| e["state"] == "delivering" && abandoned?(e) }
      stale.filter_map do |entry|
        if entry["paste_started_at"]
          data["entries"].delete(entry)
          entry
        else
          entry["state"] = "queued"
          CLAIM_KEYS.each { |key| entry.delete(key) }
          nil
        end
      end
    end

    def claimed(data, claim)
      data["entries"].find { |e| e["id"] == claim["id"] && e["state"] == "delivering" && e["claim_id"] == claim["claim_id"] }
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def abandoned?(entry)
      claimed = Time.iso8601(entry["claimed_at"].to_s)
      !entry["daemon_pid"].is_a?(Integer) || !@pid_alive.call(entry["daemon_pid"]) || @clock.now - claimed > STALE_CLAIM
    rescue ArgumentError
      true
    end

    def now
      self.class.stamp(@clock.now)
    end

    def unused_id(data)
      taken = data["entries"].map { |e| e["id"] }
      loop do
        id = @id_generator.call
        return id unless taken.include?(id)
      end
    end

    # A write raises rather than replace a file it couldn't read, since that
    # would drop every entry in it.
    def with_lock(readonly: false)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      result = nil
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(readonly ? File::LOCK_SH : File::LOCK_EX)
        data = read_data
        before = JSON.generate(data)
        result = yield data
        write_data(data) unless readonly || JSON.generate(data) == before
      end
      result
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access the prompt queue at #{@path} (#{e.class}: errno #{e.errno})"
    end

    def read_data
      return empty unless File.exist?(@path)
      content = File.read(@path, encoding: Encoding::UTF_8)
      return empty if content.strip.empty?
      parsed = JSON.parse(content)
      entries = parsed.is_a?(Hash) && parsed["entries"]
      panes = parsed.is_a?(Hash) && parsed.fetch("panes", {})
      unless entries.is_a?(Array) && entries.all?(Hash) && panes.is_a?(Hash) && panes.values.all?(Hash)
        unreadable("it is not a prompt queue document")
      end
      {"entries" => entries, "panes" => panes}
    rescue JSON::ParserError
      unreadable("it is not valid JSON")
    end

    def empty
      {"entries" => [], "panes" => {}}
    end

    def unreadable(reason)
      raise Workspace::Error, "The prompt queue #{@path} can't be read (#{reason}); " \
        "nothing was changed. Fix or move it aside and retry."
    end

    def write_data(data)
      tmp = "#{@path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @path)
    end
  end
end
