require "json"
require "fileutils"
require "time"

module Workspace
  # Persists the most recent context-window reading for each tmux pane
  # running `workspace statusline`, so `sessions --json` and `workspace
  # handoff check` can report it without depending on Claude's status line
  # having just rendered.
  #
  # Keyed on `$TMUX_PANE` — the same identity `workspace session-event` and
  # {Workspace::SessionMonitor} use — because pane indices shift as panes
  # split and close. A status-line process that started without `TMUX_PANE`
  # set (it happens; see the class docs on {Workspace::Commands::Statusline})
  # is recorded under its `CLAUDE_PID` instead, so a pane can still be
  # matched up via its agent process id.
  #
  # Guarded by `flock` on a sentinel file, matching {Workspace::LockStore}
  # and {Workspace::Commands::Config}: never locked on the JSON file itself,
  # since it's rewritten via tmp-file-then-rename on every write.
  class ContextStore
    # @param path [String] path to the JSON store file
    # @param logger [Workspace::Logger] debug logger
    def initialize(path:, logger: Workspace::Logger.new)
      @path = path
      @logger = logger
    end

    # Records a context-window reading.
    #
    # @param pct [Numeric, nil] used_percentage, 0..100. `nil` (Claude sent
    #   JSON null or omitted the key -- what happens right after `/clear`,
    #   with a new `session_id`) is recorded as-is, since it's the current
    #   session reporting no reading yet, not a bad reading. Anything else
    #   that isn't a 0..100 number (a string like "N/A", a negative number,
    #   or a number over 100) is dropped rather than recorded as a guess
    # @param pane_id [String, nil] tmux pane id ("%23"), when TMUX_PANE was set
    # @param pid [String, Integer, nil] CLAUDE_PID, used when pane_id is nil
    # @param started [String, nil] CLAUDE_PID's `ps` start time (`lstart`);
    #   without it a pid-keyed reading is never trusted on read, since a
    #   reused pid could otherwise report another session's percentage
    # @param session_id [String, nil] Claude Code session id
    # @param cwd [String, nil] the agent's working directory
    # @param recorded_at [Time] when the reading was taken
    # @return [void]
    def record(pct:, pane_id: nil, pid: nil, started: nil, session_id: nil, cwd: nil,
      recorded_at: Time.now)
      return if pane_id.nil? && pid.nil?
      valid_pct = pct.nil? || (pct.is_a?(Numeric) && (0..100).cover?(pct))
      return unless valid_pct

      entry = {
        "pct" => pct&.round,
        "recorded_at" => recorded_at.utc.iso8601,
        "session_id" => session_id,
        "cwd" => cwd,
        "started" => started
      }

      with_lock do
        data = read_data
        data["panes"] ||= {}
        data["by_pid"] ||= {}
        data["panes"][pane_id] = entry if pane_id
        data["by_pid"][pid.to_s] = entry if pid
        write_data(data)
      end
    rescue => e
      @logger.debug { "context_store: record failed (#{e.class}: #{e.message})" }
    end

    # @param pane_id [String] tmux pane id
    # @return [Hash, nil] {"pct"=>, "recorded_at"=>, "session_id"=>, "cwd"=>, "started"=>}, or nil
    def reading_for_pane(pane_id)
      return nil unless pane_id
      read_data.dig("panes", pane_id)
    rescue => e
      @logger.debug { "context_store: read failed (#{e.class}: #{e.message})" }
      nil
    end

    # @param pid [String, Integer] CLAUDE_PID
    # @return [Hash, nil] same shape as {#reading_for_pane}
    def reading_for_pid(pid)
      return nil unless pid
      read_data.dig("by_pid", pid.to_s)
    rescue => e
      @logger.debug { "context_store: read failed (#{e.class}: #{e.message})" }
      nil
    end

    private

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    def lock_path
      "#{@path}.lock"
    end

    def read_data
      return {} unless File.exist?(@path)
      JSON.parse(File.read(@path))
    rescue JSON::ParserError
      {}
    end

    def write_data(data)
      tmp_path = "#{@path}.tmp#{Process.pid}"
      File.write(tmp_path, JSON.generate(data))
      File.rename(tmp_path, @path)
    end
  end
end
