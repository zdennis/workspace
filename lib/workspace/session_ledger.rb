require "json"
require "fileutils"
require "time"

module Workspace
  # Append-only history of coding-agent sessions: one JSON line per
  # SessionStart and SessionEnd, so `restore` can recreate the panes a reboot
  # took and resume their sessions ({#slots_for}). History can't be
  # backfilled, so every entry carries what a later reader may need.
  #
  # Written from the `session-event` hook, which must never fail, so
  # {#record} swallows every error. Lines are written under an exclusive
  # `flock` so panes ending together never interleave a line.
  class SessionLedger
    # @param path [String] path to `ledger.jsonl`
    # @param clock [#call] returns the current Time, injected for specs
    # @param logger [Workspace::Logger] debug logger
    def initialize(path:, clock: -> { Time.now }, logger: Workspace::Logger.new)
      @path = path
      @clock = clock
      @logger = logger
    end

    # Appends one entry, stamped with the time it was recorded. Nil fields are
    # left out.
    #
    # @param entry [Hash{String=>Object}] e.g. event, workspace, pane_slot,
    #   pane_id, tmux_server, layout, session_id, transcript_path, cwd
    # @return [Boolean] whether the line was written
    def record(entry)
      line = JSON.generate({"at" => @clock.call.utc.iso8601(6)}.merge(entry).compact)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write("#{line}\n")
      end
      true
    rescue => e
      @logger.debug { "session_ledger: record failed (#{e.class}: #{e.message})" }
      false
    end

    # Streams the file line by line (only the workspace's entries are kept); a line that
    # isn't a JSON object (a torn or foreign line) is skipped.
    #
    # @param workspace [String]
    # @return [Array<Hash>] the workspace's entries, oldest first; empty when
    #   there is no ledger
    # @raise [SystemCallError] if the ledger exists but can't be read
    def entries_for(workspace)
      File.foreach(@path).filter_map do |line|
        entry = parse(line)
        entry if entry && entry["workspace"] == workspace
      end
    rescue Errno::ENOENT
      []
    end

    # The session each pane slot of a workspace held last, for `restore`. The
    # file is never rotated, so it is streamed and only one record per slot is
    # kept in memory.
    #
    # * The latest SessionStart for a slot replaces any earlier one.
    # * A session counts once, in the slot of its latest SessionStart: a pane
    #   whose index changed (a sibling closed) or a session resumed elsewhere
    #   leaves its old slot.
    # * A SessionEnd closes the record holding its session id, wherever that
    #   pane sits by then; one without a session id closes its own slot.
    # * A SessionStart without a pane slot can't be placed and is skipped.
    #
    # The hook records a pane under its tmux session's name, which for a
    # worktree workspace is not the workspace's name, so several names can be given.
    #
    # @param workspaces [Array<String>] the names the workspace's entries were recorded under
    # @return [Array<Hash{String=>Object}>] one record per slot: `pane_slot`, `pane_id`, `tmux_server`, `session_id`,
    #   `transcript_path`, `cwd`, `layout`, `at`, and for a session that
    #   ended `ended_at` and `end_reason`; empty when there is no ledger
    # @raise [SystemCallError] if the ledger exists but can't be read
    def slots_for(*workspaces)
      slots = {}
      File.foreach(@path) do |line|
        entry = parse(line)
        next unless entry && workspaces.include?(entry["workspace"])

        case entry["event"]
        when "session_start" then open_slot(slots, entry)
        when "session_end" then close_slot(slots, entry)
        end
      end
      slots.values
    rescue Errno::ENOENT
      []
    end

    private

    SLOT_FIELDS = %w[pane_slot pane_id tmux_server session_id transcript_path cwd layout at].freeze
    private_constant :SLOT_FIELDS

    def parse(line)
      entry = JSON.parse(line)
      entry.is_a?(Hash) ? entry : nil
    rescue JSON::ParserError
      nil
    end

    def open_slot(slots, entry)
      slot = entry["pane_slot"]
      return unless slot.is_a?(String) && !slot.empty?

      session_id = entry["session_id"]
      slots.delete_if { |key, record| key != slot && !session_id.nil? && record["session_id"] == session_id }
      slots[slot] = entry.slice(*SLOT_FIELDS)
    end

    def close_slot(slots, entry)
      session_id = entry["session_id"]
      record = session_id.nil? ? slots[entry["pane_slot"]] : slots.each_value.find { |r| r["session_id"] == session_id }
      return unless record

      record["ended_at"] = entry["at"]
      record["end_reason"] = entry["reason"]
    end
  end
end
