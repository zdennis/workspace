require "json"
require "fileutils"
require "time"

module Workspace
  # Append-only history of coding-agent sessions: one JSON line per
  # SessionStart and SessionEnd, so a later `restore` can recreate the panes a
  # reboot took and resume their sessions. History can't be backfilled, so the
  # write path ships before anything reads it.
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
    #   pane_id, session_id, transcript_path, cwd
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
  end
end
