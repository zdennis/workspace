require "json"
require "time"

module Workspace
  # The rules for reading a coding agent's token usage that every reader shares: which session a pane's
  # attempt belongs to ({.session_entry}), whether a transcript path may be opened ({.transcript_path?}),
  # how a Claude Code transcript's lines count ({Scan}), and how counted usages add up ({.total}).
  # It reads only what it is given (a ledger, lines) and never raises on bad data.
  class TranscriptUsage
    # The last bytes of the session ledger read to find an attempt's session; a ledger is never rotated.
    MAX_LEDGER_BYTES = 1024 * 1024

    SESSION_ID = /\A[A-Za-z0-9._-]{1,128}\z/
    TRANSCRIPT_PATH = %r{\A/[^\x00-\x1f\x7f]{1,4095}\.jsonl\z}
    VERSION = /\A[A-Za-z0-9._+-]{1,50}\z/
    MODEL = /\A[A-Za-z0-9._:\/\[\]-]{1,100}\z/
    USAGE_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze

    # One message of a transcript: the time of its first line (which decides whether it is in the
    # window), and the usage and model its lines last gave.
    Message = Struct.new(:first, :usage, :model)

    # What one transcript line says, by the per-line rules every usage reader shares: its time (nil when
    # unreadable), whether it is a sub-agent (`isSidechain`) line, whether it is an assistant message, that
    # message's `id` (nil when not a String), usage (nil unless a Hash), model and version (nil unless
    # valid), and `unreadable` when it carries usage that can't be counted (no readable time, or not a Hash).
    Line = Struct.new(:at, :sidechain, :message, :id, :usage, :model, :version, :unreadable)

    # The per-line pass over a transcript, fed lines in file order, once or in pieces: feeding the lines
    # in two halves leaves the same state as feeding them all at once. A message written on several lines
    # is one message, keyed by its `message.id` (a line with none is its own message, keyed by its index among
    # the lines this scan was fed). It applies {TranscriptUsage.read_line} to each line.
    class Scan
      # @return [Hash{Object => Message}] the messages seen so far, in first-seen order
      attr_reader :messages
      # @return [String, nil] the last valid `version` on a line inside the window
      attr_reader :version

      # @param from [Time] the window's start
      # @param to [Time] the window's end
      # @param floor [Time] a line at or before this time shows the lines reach back far enough
      # @param sidechain [Boolean] true for a sub-agent's own transcript, whose sidechain lines all count
      def initialize(from:, to:, floor:, sidechain: false)
        @from = from
        @to = to
        @floor = floor
        @sidechain = sidechain
        @messages = {}
        @version = nil
        @reached = @unreadable = @seen = false
        @lines = 0
      end

      # Applies lines in file order. Sub-agent (`isSidechain`) lines are left out unless the scan is a sidechain one.
      #
      # @param lines [Enumerable<String>] transcript lines, without their newlines
      # @return [self]
      def feed(lines)
        lines.each do |line|
          index = @lines
          @lines += 1
          read = TranscriptUsage.read_line(line) or next
          next if read.sidechain && !@sidechain
          @unreadable = true if read.unreadable
          next unless read.at
          @reached = true if read.at <= @floor
          inside = read.at.between?(@from, @to)
          @seen = true if inside
          @version = read.version if inside && read.version
          next unless read.message
          record = (@messages[read.id || index] ||= Message.new(read.at))
          record.usage = read.usage if read.usage
          record.model = read.model if read.model
        end
        self
      end

      # @return [Boolean] whether a line at or before the floor was fed
      def reached? = @reached

      # @return [Boolean] whether a usage line had no readable time or a usage that is not a Hash
      def unreadable? = @unreadable

      # @return [Boolean] whether any line fell inside the window
      def seen? = @seen

      # @return [Array<Message>] the messages whose first line is inside the window and that carry usage
      def counted
        @messages.values.select { |record| record.usage && record.first >= @from && record.first <= @to }
      end
    end

    # @param path [Object] a ledger entry's `transcript_path`
    # @return [Boolean] whether it is an absolute `.jsonl` path with no control characters
    def self.transcript_path?(path)
      path.is_a?(String) && TRANSCRIPT_PATH.match?(path)
    end

    # The latest SessionStart for the pane (one of the given workspace names, on the given tmux server when
    # both are known) at or before `ended`, unless a SessionEnd for it at or after its start came before `started`.
    #
    # @param ledger [Workspace::SessionLedger, nil] nil finds none
    # @param names [Array<String>] the workspace names the session hook may have recorded the pane under
    # @param pane [String] the tmux pane id
    # @param started [Time] the attempt's start
    # @param ended [Time] the attempt's end (or now)
    # @param server [Object, nil] the pane's tmux server pid, or nil when unknown
    # @return [Array(Hash, Boolean), nil] the chosen SessionStart entry and whether a SessionEnd for it was seen
    def self.session_entry(ledger:, names:, pane:, started:, ended:, server:)
      return nil unless ledger && pane.is_a?(String) && !pane.empty?
      names = Array(names).select { |name| name.is_a?(String) && !name.empty? }
      entries = ledger.recent_entries(max_bytes: MAX_LEDGER_BYTES, matching: pane)
      start = entries.reverse_each.find do |entry|
        entry["event"] == "session_start" && entry["pane_id"] == pane && names.include?(entry["workspace"]) &&
          (server.nil? || entry["tmux_server"].nil? || entry["tmux_server"].to_s == server.to_s) &&
          entry["session_id"].is_a?(String) && SESSION_ID.match?(entry["session_id"]) && (at = time(entry["at"])) && at <= ended
      end
      return nil unless start
      # Only an end at or after this start closes it: a session resumed under the same id starts again.
      start_at = time(start["at"])
      end_at = entries.find do |entry|
        entry["event"] == "session_end" && entry["session_id"] == start["session_id"] && (stop = time(entry["at"])) && stop >= start_at
      end&.fetch("at", nil)
      return nil if end_at && time(end_at) < started
      [start, !end_at.nil?]
    end

    # @param usages [Array<Hash>] usage hashes
    # @return [Hash, nil] the sum of each {USAGE_KEYS} key (zero cache keys dropped); nil for none, or
    #   when a count is not a whole number at least 0
    def self.total(usages)
      return nil if usages.empty?
      return nil unless usages.all? { |usage| USAGE_KEYS.all? { |key| !usage.key?(key) || (usage[key].is_a?(Integer) && usage[key] >= 0) } }
      sums = USAGE_KEYS.to_h { |key| [key, usages.sum { |usage| usage[key] || 0 }] }
      sums.reject { |key, value| value.zero? && key.start_with?("cache_") }
    end

    # @param value [Object]
    # @return [Time, nil] the ISO 8601 time, or nil when it is not one
    def self.time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # @param line [String] one transcript line, without its newline
    # @return [Line, nil] what the line says, or nil when it is not a JSON object
    def self.read_line(line)
      entry = parse_line(line) or return nil
      message = (entry["type"] == "assistant" && entry["message"].is_a?(Hash)) ? entry["message"] : nil
      at = time(entry["timestamp"])
      usage = message && message["usage"]
      model = message && message["model"]
      version = entry["version"]
      Line.new(
        at,
        entry["isSidechain"] == true,
        !message.nil?,
        (message && message["id"].is_a?(String)) ? message["id"] : nil,
        usage.is_a?(Hash) ? usage : nil,
        (model.is_a?(String) && MODEL.match?(model) && model != "<synthetic>") ? model : nil,
        (version.is_a?(String) && VERSION.match?(version)) ? version : nil,
        !!message&.key?("usage") && (at.nil? || !usage.is_a?(Hash))
      )
    end

    # @param line [String]
    # @return [Hash, nil] the line's JSON object, or nil when it is not one
    def self.parse_line(line)
      entry = JSON.parse(line)
      entry.is_a?(Hash) ? entry : nil
    rescue JSON::ParserError
      nil
    end
  end
end
