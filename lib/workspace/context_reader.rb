require "time"

module Workspace
  # Resolves a coding-agent pane's context-window usage for `sessions --json`
  # (and, later, `workspace handoff check`): a percentage, or a reason it
  # can't be determined right now — never a guess.
  #
  # Two sources, chosen by the global `context.source` config (default
  # `"statusline"`):
  #
  # * `statusline` — the most recent reading `workspace statusline` recorded
  #   in {Workspace::ContextStore}, keyed by pane id, falling back to the
  #   agent's pid when the status-line process ran without `TMUX_PANE` set.
  # * `scrape` — reads the pane's own visible text and applies
  #   `context.pattern` (a regex with one capture group).
  class ContextReader
    # @param context_store [Workspace::ContextStore]
    # @param project_settings [Workspace::ProjectSettings] reads the global config
    # @param tmux [Workspace::Tmux, nil] required for scrape mode
    # @param logger [Workspace::Logger] debug logger
    def initialize(context_store:, project_settings:, tmux: nil, logger: Workspace::Logger.new)
      @context_store = context_store
      @project_settings = project_settings
      @tmux = tmux
      @logger = logger
    end

    # @param pane_id [String, nil] tmux pane id
    # @param agent_pid [String, Integer, nil] the pane's coding-agent pid,
    #   used as a fallback lookup when no reading was recorded for pane_id
    # @param current_session_id [String, nil] the pane's current Claude
    #   session id; when given and it doesn't match the stored reading's
    #   session_id, the reading is treated as stale rather than current
    # @return [Hash] pct: [Integer, nil], error: [String, nil],
    #   updated_at: [String, nil] (ISO8601)
    def read(pane_id:, agent_pid: nil, current_session_id: nil)
      global = safe_load_global
      source = global.dig("context", "source") || "statusline"
      (source == "scrape") ? read_scrape(pane_id, global) : read_statusline(pane_id, agent_pid, current_session_id)
    end

    private

    def read_statusline(pane_id, agent_pid, current_session_id)
      if pane_id.nil?
        reading = agent_pid && @context_store.reading_for_pid(agent_pid)
        return present(reading, current_session_id) if reading
        return absent(ContextReasons::NO_PANE_ID)
      end

      reading = @context_store.reading_for_pane(pane_id)
      reading ||= @context_store.reading_for_pid(agent_pid) if agent_pid
      return present(reading, current_session_id) if reading
      absent(ContextReasons::NO_READING)
    end

    def read_scrape(pane_id, global)
      pattern = global.dig("context", "pattern")
      return absent(ContextReasons::NO_PATTERN) if pattern.nil? || pattern.empty?
      return absent(ContextReasons::PATTERN_NO_MATCH) unless @tmux

      text = @tmux.capture_screen(pane_id)
      match = text && Regexp.new(pattern).match(text)
      return absent(ContextReasons::PATTERN_NO_MATCH) unless match && match[1]

      {pct: match[1].to_i, error: nil, updated_at: Time.now.utc.iso8601}
    rescue RegexpError => e
      @logger.debug { "context_reader: invalid context.pattern (#{e.message})" }
      absent(ContextReasons::PATTERN_NO_MATCH)
    end

    def present(reading, current_session_id = nil)
      stored_session_id = reading["session_id"]
      if current_session_id && stored_session_id && stored_session_id != current_session_id
        return absent(ContextReasons::STALE_SESSION)
      end
      {pct: reading["pct"], error: nil, updated_at: reading["recorded_at"]}
    end

    def absent(reason)
      {pct: nil, error: reason, updated_at: nil}
    end

    def safe_load_global
      @project_settings.load_global
    rescue => e
      @logger.debug { "context_reader: could not read global config (#{e.message})" }
      {}
    end
  end
end
