module Workspace
  # Shared reason strings and fix hint for a coding-agent pane whose context
  # usage percentage can't be determined right now. `sessions --json` and
  # `workspace handoff check` both surface these, so they live in one place
  # rather than being duplicated (and drifting) between the two.
  module ContextReasons
    # No reading has ever reached the store for this pane: the status line
    # isn't routed through `workspace statusline`, or Claude hasn't rendered
    # the status line yet this session.
    NO_READING = "no reading recorded (status line not routed through workspace, or not rendered yet)"

    # A reading was recorded for this session, but Claude hasn't yet reported
    # a real percentage in it -- the JSON null `used_percentage` Claude sends
    # on its very first render after start or `/clear`, before it has
    # anything to report.
    NO_READING_YET = "Claude hasn't reported context usage for this session yet (it was just started or cleared)"

    # scrape mode: `context.pattern` didn't match the pane's captured text.
    PATTERN_NO_MATCH = "pattern didn't match (scrape mode)"

    # scrape mode is configured but `context.pattern` isn't set.
    NO_PATTERN = "no context.pattern configured (scrape mode)"

    # scrape mode: every machine-wide scan slot was held, so the pane wasn't
    # captured this time, and no reading from it fresh enough to serve
    # (within the scrape cache window) was left to fall back on.
    SCAN_BUSY = "couldn't scrape the pane (every scan slot busy) and no fresh reading is cached"

    # No pane id was available to look the reading up with (the status-line
    # process ran without $TMUX_PANE set), and no agent pid fallback found a
    # reading either.
    NO_PANE_ID = "no pane id (status-line process lacked $TMUX_PANE)"

    # The only reading on record for this pane was recorded under a
    # different Claude session id -- the pane was reused (e.g. a `claude`
    # restart) and the old reading is no longer current.
    STALE_SESSION = "the last reading is from an earlier Claude session in this pane"

    # A pid-keyed reading's pid/start time couldn't be confirmed against the
    # process table -- the process table couldn't be read, no start time was
    # recorded, or the pid no longer matches -- so it may belong to an
    # unrelated, reused pid rather than the current agent.
    PID_UNVERIFIED = "couldn't confirm the Claude process that recorded this reading is still running"

    # One line of fix instructions, printed alongside any of the reasons
    # above. Never suggests sudo.
    FIX_HINT = <<~HINT.strip
      Fix: run `workspace doctor --fix` to route Claude's status line through
      workspace, or add manually to ~/.claude/settings.json (or a project's
      .claude/settings.json):
      "statusLine": {"type": "command", "command": "workspace statusline"},
      or set a scrape pattern with `workspace config set context.source scrape` and
      `workspace config set context.pattern '(\\d+)% ctx'`, or pass --context-pct N.
    HINT

    # The fix hint for a kind whose context workspace reads by scraping the
    # pane itself (Codex): it has no status line workspace could route, and
    # `context.pattern` is not consulted for a kind-detected pane
    # (ContextReader#kind_pattern short-circuits it), so only
    # `context.patterns.<kind>` in the global config file can replace the
    # built-in pattern.
    SCRAPED_KIND_FIX_HINT = <<~HINT.strip
      Fix: this agent has no status line workspace can route; its context usage
      is read by scraping its own status footer. If your version prints a
      different line, set a pattern by hand in ~/.config/workspace/config.yml:
      context:
        patterns:
          codex: 'Context\\s+(\\d{1,3})% used'
      (`context.pattern` is not consulted for a detected pane of this kind;
      only the `context.patterns` mapping above is), or pass --context-pct N.
    HINT

    # The fix hint for a pane whose agent kind is known. A kind workspace
    # reads by scraping its own pane (one whose provider carries a context
    # pattern, Codex today) gets the hint that takes effect for it; any other
    # kind -- Claude Code, an unknown kind, or no kind at all -- gets the
    # statusLine routing hint.
    #
    # @param kind [String, nil] the pane's agent kind ("claude", "codex", ...)
    # @return [String] one fix hint
    def self.fix_hint(kind = nil)
      provider = kind && AgentProvider.find(kind)
      return SCRAPED_KIND_FIX_HINT if provider&.context_pattern
      FIX_HINT
    end
  end
end
