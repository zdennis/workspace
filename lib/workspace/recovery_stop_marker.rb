require "fileutils"

module Workspace
  # A file per session that says "the daemon is about to stop this agent to recover it from an API
  # error", so the SessionEnd the stop causes does not stop the dev server the session started.
  # The `session-event` hook reads it before it knows the workspace, so it is only a file check.
  #
  # A marker older than {MAX_AGE} reads as unset, so a crash between the stop and the clear cannot
  # protect a session forever. Nothing here raises: what cannot be read is not marked.
  class RecoveryStopMarker
    # Seconds a marker counts for.
    MAX_AGE = 300

    # Session ids are written into a file name, so only plain ones are accepted.
    SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

    # @param state_dir [String] the workspace state directory (`Config#state_dir`)
    # @param clock [#now] time source
    def initialize(state_dir:, clock: Time)
      @dir = File.join(state_dir, "agent-recovery", "stopping")
      @clock = clock
    end

    # @param session_id [String] the session about to be stopped
    # @return [Boolean] whether the marker was written
    def mark(session_id)
      path = path_for(session_id) or return false
      FileUtils.mkdir_p(@dir)
      File.write(path, "")
      File.utime(@clock.now, @clock.now, path)
      true
    rescue SystemCallError
      false
    end

    # @param session_id [String]
    # @return [void]
    def clear(session_id)
      path = path_for(session_id) or return
      File.delete(path)
    rescue SystemCallError
      nil
    end

    # @param session_id [String, nil]
    # @return [Boolean] whether a marker younger than {MAX_AGE} exists
    def marked?(session_id)
      path = path_for(session_id) or return false
      @clock.now - File.stat(path).mtime < MAX_AGE
    rescue SystemCallError
      false
    end

    private

    def path_for(session_id)
      id = session_id.to_s
      File.join(@dir, id) if SAFE_ID.match?(id)
    end
  end
end
