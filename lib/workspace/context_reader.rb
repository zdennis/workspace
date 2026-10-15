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
  # A pane whose agent kind is given is read by that kind first: the pattern
  # in the global `context.patterns` for the kind (its one capture group is the
  # percent used), else the provider's own ({AgentProvider#context_pattern},
  # which Codex has because it has no status line to route), is scraped from
  # the pane whatever `context.source` says. The last match on the screen
  # counts, since an agent's footer is its lowest line. A kind with neither is
  # read as described next.
  #
  # * `scrape` — reads the pane's own visible text and applies
  #   `context.pattern` (a regex with one capture group).
  class ContextReader
    # How long a successfully scraped reading stays fresh enough to serve
    # while every scan slot is busy, so a `sessions` request under load still
    # answers with something true rather than an error.
    SCRAPE_CACHE_TTL = 30

    # @param context_store [Workspace::ContextStore]
    # @param project_settings [Workspace::ProjectSettings] reads the global config
    # @param tmux [Workspace::Tmux, nil] required for scrape mode
    # @param logger [Workspace::Logger] debug logger
    # @param lock_holder [Workspace::LockHolder] checks a pid-keyed reading's
    #   pid and start time against the process table
    # @param scan_slots [Workspace::ScanSlotLimiter, nil] bounds how many
    #   scrapes run at once, machine-wide; nil scrapes ungated
    # @param clock [#call] returns the current time, which stamps scraped
    #   readings and clocks the scrape cache's freshness window
    def initialize(context_store:, project_settings:, tmux: nil, logger: Workspace::Logger.new,
      lock_holder: Workspace::LockHolder.new, scan_slots: nil,
      clock: -> { Time.now.utc })
      @context_store = context_store
      @lock_holder = lock_holder
      @project_settings = project_settings
      @tmux = tmux
      @logger = logger
      @scan_slots = scan_slots
      @clock = clock
      # Last successful scrape per pane id: {reading:, recorded_at:}. Held in
      # memory only — the daemon keeps one reader for its lifetime.
      @scrape_cache = {}
    end

    # @param pane_id [String, nil] tmux pane id
    # @param agent_pid [String, Integer, nil] the pane's coding-agent pid,
    #   used as a fallback lookup when no reading was recorded for pane_id
    # @param current_session_id [String, nil] the pane's current Claude
    #   session id; when given and it doesn't match the stored reading's
    #   session_id, the reading is treated as stale rather than current
    # @param kind [String, nil] the pane's agent kind ("claude", "codex", ...); see the class comment
    # @return [Hash] pct: [Integer, nil], error: [String, nil],
    #   updated_at: [String, nil] (ISO8601, whole seconds), and for a result
    #   taken from a stored or scraped reading, recorded_at: [Time, nil]
    #   (full precision, for ordering against another moment) and
    #   session_id: [String, nil]. A reading from a session that hasn't
    #   reported usage yet keeps its updated_at and session_id, with pct nil.
    def read(pane_id:, agent_pid: nil, current_session_id: nil, kind: nil)
      global = safe_load_global
      pattern, remaining = kind_pattern(kind, global)
      return read_kind_scrape(pane_id, pattern, remaining) if pattern
      source = global.dig("context", "source") || "statusline"
      (source == "scrape") ? read_scrape(pane_id, global) : read_statusline(pane_id, agent_pid, current_session_id)
    end

    private

    # @return [Array(String, Boolean), nil] the pattern for the kind and whether its capture is
    #   the percent left; a configured pattern captures the percent used
    def kind_pattern(kind, global)
      patterns = global.dig("context", "patterns")
      configured = patterns[kind] if kind && patterns.is_a?(Hash)
      return [configured, false] if configured.is_a?(String) && !configured.empty?

      provider = kind && AgentProvider.find(kind)
      [provider.context_pattern, provider.context_remaining?] if provider&.context_pattern
    end

    def read_kind_scrape(pane_id, pattern, remaining)
      return absent(ContextReasons::PATTERN_NO_MATCH) unless @tmux

      scraped = scrape_pane(pane_id)
      return scraped if scraped.is_a?(Hash)
      return absent(ContextReasons::PATTERN_NO_MATCH) unless scraped

      captured = last_capture(scraped, Regexp.new(pattern))
      return cache_scrape(pane_id, absent(ContextReasons::PATTERN_NO_MATCH)) unless captured

      used = remaining ? 100 - captured.to_i : captured.to_i
      scraped_reading(pane_id, used.clamp(0, 100))
    rescue RegexpError => e
      @logger.debug { "context_reader: invalid context pattern for #{pane_id} (#{e.message})" }
      absent(ContextReasons::PATTERN_NO_MATCH)
    end

    # @return [String, nil] the first capture group of the last match in +text+; nil for no match or no group
    def last_capture(text, regexp)
      last = nil
      text.scan(regexp) { last = Regexp.last_match }
      last && last[1]
    end

    def scraped_reading(pane_id, pct)
      now = @clock.call
      reading = {pct: pct, error: nil, updated_at: now.utc.iso8601, recorded_at: now, session_id: nil}
      cache_scrape(pane_id, reading)
    end

    # Records a reading taken from a pane the reader just scraped — matched
    # or not — in the scrape cache, so a later busy read for a pane that never
    # matches still answers from the cache instead of undetermined. Returns
    # the reading as given; the cache write is all this adds.
    def cache_scrape(pane_id, reading)
      if @scan_slots
        @scrape_cache[pane_id] = {reading: reading, recorded_at: reading[:recorded_at] || @clock.call}
      end
      reading
    end

    def read_statusline(pane_id, agent_pid, current_session_id)
      reading = pane_id && @context_store.reading_for_pane(pane_id)
      return present(reading, current_session_id) if reading

      reading = agent_pid && @context_store.reading_for_pid(agent_pid)
      if reading
        return absent(ContextReasons::PID_UNVERIFIED) unless same_process?(agent_pid, reading)
        return present(reading, current_session_id)
      end
      absent(pane_id.nil? ? ContextReasons::NO_PANE_ID : ContextReasons::NO_READING)
    end

    # A reading stored without a start time can't be tied to this process,
    # and a process table we can't read leaves liveness unknown: either way
    # the reading isn't trusted.
    def same_process?(pid, reading)
      started = reading["started"]
      return false if started.nil? || started.empty?
      @lock_holder.alive?(pid: pid, started: started)
    rescue Workspace::Error => e
      @logger.debug { "context_reader: could not verify pid #{pid} (#{e.message})" }
      false
    end

    def read_scrape(pane_id, global)
      pattern = global.dig("context", "pattern")
      return absent(ContextReasons::NO_PATTERN) if pattern.nil? || pattern.empty?
      return absent(ContextReasons::PATTERN_NO_MATCH) unless @tmux

      scraped = scrape_pane(pane_id)
      # Every slot busy already answered with a result of its own.
      return scraped if scraped.is_a?(Hash)
      return absent(ContextReasons::PATTERN_NO_MATCH) unless scraped

      match = Regexp.new(pattern).match(scraped)
      return cache_scrape(pane_id, absent(ContextReasons::PATTERN_NO_MATCH)) unless match && match[1]

      scraped_reading(pane_id, match[1].to_i)
    rescue RegexpError => e
      @logger.debug { "context_reader: invalid context.pattern (#{e.message})" }
      absent(ContextReasons::PATTERN_NO_MATCH)
    end

    # Captures the pane's text, through one of the machine-wide scan slots
    # when a limiter is injected; without one it is a plain capture, as
    # before. One non-blocking slot attempt — a request never waits out
    # another's capture.
    #
    # @param pane_id [String] tmux pane id
    # @return [String, nil, Hash] the captured text (nil when the pane
    #   couldn't be captured), or, when every slot was busy, the busy result:
    #   the pane's last successful reading when it is still fresh, absent
    #   with {ContextReasons::SCAN_BUSY} otherwise
    def scrape_pane(pane_id)
      return @tmux.capture_screen(pane_id) unless @scan_slots

      # Wrapped in an array: a busy read of every slot reads as nil, apart
      # from a capture that itself returned no text.
      captured = @scan_slots.with_scan_slot { [@tmux.capture_screen(pane_id)] }
      return busy_result(pane_id) unless captured

      captured.first
    end

    # Answers a busy read from the pane's cached last successful scrape,
    # while that reading is no older than {SCRAPE_CACHE_TTL}; past that, or
    # with nothing cached, the reading is undetermined rather than guessed.
    #
    # @param pane_id [String] tmux pane id
    # @return [Hash] the cached reading, or absent with
    #   {ContextReasons::SCAN_BUSY}
    def busy_result(pane_id)
      cached = @scrape_cache[pane_id]
      return absent(ContextReasons::SCAN_BUSY) unless cached

      now = @clock.call
      return absent(ContextReasons::SCAN_BUSY) if now - cached[:recorded_at] > SCRAPE_CACHE_TTL

      cached[:reading]
    end

    def present(reading, current_session_id = nil)
      stored_session_id = reading["session_id"]
      if current_session_id && stored_session_id && stored_session_id != current_session_id
        return absent(ContextReasons::STALE_SESSION)
      end
      recorded_at = parse_time(reading["recorded_at"])
      {
        pct: reading["pct"],
        error: reading["pct"].nil? ? ContextReasons::NO_READING_YET : nil,
        updated_at: recorded_at&.utc&.iso8601 || reading["recorded_at"],
        recorded_at: recorded_at,
        session_id: stored_session_id
      }
    end

    # Readings recorded before sub-second stamps were added carry whole
    # seconds; both forms parse.
    def parse_time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
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
