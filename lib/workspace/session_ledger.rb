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

    # The coding-agent session now running in a pane: the latest SessionStart recorded for the
    # pane id under that tmux server, unless a SessionEnd for the same session came after it.
    # A `/clear` ends one session and starts the next in the same pane, so the answer follows it.
    #
    # @param pane_id [String] a tmux pane id (e.g. "%23")
    # @param tmux_server [String, nil] the pane's tmux server pid; entries from another server don't count
    # @return [String, nil] the session id, or nil when none is open, none is recorded, or the ledger can't be read
    def open_session_for(pane_id:, tmux_server:)
      open_record_for(pane_id: pane_id, tmux_server: tmux_server)&.fetch("session_id")
    end

    # The whole SessionStart entry of the session {#open_session_for} names, so a caller can read
    # the directory the session started in rather than one a hook reported later.
    #
    # @param pane_id [String] a tmux pane id (e.g. "%23")
    # @param tmux_server [String, nil] the pane's tmux server pid; entries from another server don't count
    # @return [Hash{String=>Object}, nil] the entry, or nil when no session is open, none is recorded,
    #   or the ledger can't be read
    def open_record_for(pane_id:, tmux_server:)
      read_open_record(pane_id: pane_id, tmux_server: tmux_server)
    rescue SystemCallError
      nil
    end

    # {#open_record_for} for a caller that must tell "no session is open" from "the ledger
    # can't be read". No ledger yet means no session is open.
    #
    # @param pane_id [String] a tmux pane id (e.g. "%23")
    # @param tmux_server [String, nil] the pane's tmux server pid; entries from another server don't count
    # @return [Hash{String=>Object}, nil] the entry, or nil when no session is open or none is recorded
    # @raise [SystemCallError] if the ledger exists but can't be read
    def read_open_record(pane_id:, tmux_server:)
      return nil if pane_id.to_s.empty? || tmux_server.to_s.empty?

      current = nil
      File.foreach(@path) do |line|
        entry = parse(line)
        next unless entry
        case entry["event"]
        when "session_start"
          current = entry if entry["pane_id"] == pane_id && entry["tmux_server"] == tmux_server
        when "session_end"
          current = nil if current && entry["session_id"] == current["session_id"]
        end
      end
      id = current && current["session_id"]
      (id.is_a?(String) && !id.empty?) ? current : nil
    rescue Errno::ENOENT
      nil
    end

    # The entries in the last +max_bytes+ of the ledger, any workspace, oldest first, for a caller that
    # must stay quick on a ledger that is never rotated. The first line is skipped when the read starts
    # inside one. Never raises.
    #
    # @param max_bytes [Integer]
    # @param matching [String, nil] a value a line must hold as a JSON string, checked before the line is parsed
    # @return [Array<Hash>] empty when there is no ledger or it can't be read
    def recent_entries(max_bytes:, matching: nil)
      File.open(@path, File::RDONLY | File::NONBLOCK) do |file|
        return [] unless file.stat.file?
        start = [file.size - max_bytes, 0].max
        file.seek(start)
        lines = file.read.to_s.force_encoding(Encoding::UTF_8).scrub.split("\n")
        lines.shift if start > 0
        needle = matching && %("#{matching}")
        lines.filter_map { |line| parse(line) if needle.nil? || line.include?(needle) }
      end
    rescue SystemCallError
      []
    end

    # @param session_id [String]
    # @return [String, nil] the `at` of the session's latest SessionStart, in any pane; nil when none is recorded
    # @raise [SystemCallError] if the ledger exists but can't be read
    def last_start_at(session_id)
      latest = nil
      File.foreach(@path) do |line|
        entry = parse(line)
        latest = entry["at"] if entry && entry["event"] == "session_start" && entry["session_id"] == session_id
      end
      latest
    rescue Errno::ENOENT
      nil
    end

    # Copies a stopped workspace's sessions to its new name for `rename`, so `restore NEW` resumes
    # them. For each slot of {#slots_for} under the old workspace and tmux session names it appends a
    # SessionStart (and, when the session had ended, a SessionEnd with the same reason) under the new
    # names, with the new directory. `transcript_path`, `session_id`, `pane_id`, `tmux_server`,
    # `layout`, `kind` and the original times are kept; the pane slot swaps its session prefix.
    # Claude Code's transcripts are not touched.
    #
    # Safe to run again. A session already carried to the same slot is not written twice, and a start
    # a failed run left without its end gets only the end. Once the new rows are written, each old slot
    # gets a SessionEnd with reason `renamed` (not resumable, and later than any end it had), so
    # `restore OLD` does not resume the session `restore NEW` does; an old slot already ended
    # `renamed` is skipped. A slot of another tmux session name is left. One whose new slot is held by a
    # different session is not carried, but is still ended, so one transcript has only one resume.
    # A new slot that itself ended `renamed` holds nothing, so a rename back to an old name writes anew.
    #
    # @param from [String] the old workspace name
    # @param to [String] the new workspace name
    # @param cwd [String] the checkout's new path
    # @param from_session [String] the old tmux session name
    # @param to_session [String] the new tmux session name
    # @return [Array<Hash{String=>Object}>] the slots carried or finished by this call
    # @raise [SystemCallError] if the ledger exists but can't be read
    def carry(from:, to:, cwd:, from_session: from, to_session: to)
      carried = existing_slots(to, to_session)
      slots_for(from, from_session).filter_map do |slot|
        next if slot["end_reason"] == RENAMED
        match = /\A#{Regexp.escape(from_session)}:(.+)\z/.match(slot["pane_slot"].to_s)
        next unless match

        new_slot = "#{to_session}:#{match[1]}"
        have = carried[new_slot]
        have = nil if have && have["end_reason"] == RENAMED
        same = have && have["session_id"] == slot["session_id"]
        taken = have && !same

        unless same || taken
          record(slot.slice(*SLOT_FIELDS).merge("event" => "session_start", "workspace" => to, "pane_slot" => new_slot, "cwd" => cwd))
        end
        if slot["ended_at"] && !taken && !(same && have["ended_at"])
          record({"event" => "session_end", "at" => slot["ended_at"], "workspace" => to, "pane_slot" => new_slot,
                  "session_id" => slot["session_id"], "reason" => slot["end_reason"]})
        end
        record({"event" => "session_end", "workspace" => from, "pane_slot" => slot["pane_slot"],
                "session_id" => slot["session_id"], "reason" => RENAMED})
        slot.merge("pane_slot" => new_slot, "cwd" => cwd) unless taken
      end
    end

    private

    RENAMED = "renamed"
    SLOT_FIELDS = %w[pane_slot pane_id tmux_server session_id transcript_path cwd layout at kind].freeze
    private_constant :SLOT_FIELDS

    def existing_slots(workspace, session)
      slots_for(workspace, session).to_h { |slot| [slot["pane_slot"], slot] }
    end

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
