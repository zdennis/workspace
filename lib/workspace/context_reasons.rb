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

    # scrape mode: `context.pattern` didn't match the pane's captured text.
    PATTERN_NO_MATCH = "pattern didn't match (scrape mode)"

    # scrape mode is configured but `context.pattern` isn't set.
    NO_PATTERN = "no context.pattern configured (scrape mode)"

    # No pane id was available to look the reading up with (the status-line
    # process ran without $TMUX_PANE set), and no agent pid fallback found a
    # reading either.
    NO_PANE_ID = "no pane id (status-line process lacked $TMUX_PANE)"

    # The only reading on record for this pane was recorded under a
    # different Claude session id -- the pane was reused (e.g. a `claude`
    # restart) and the old reading is no longer current.
    STALE_SESSION = "the last reading is from an earlier Claude session in this pane"

    # One line of fix instructions, printed alongside any of the reasons
    # above. Never suggests sudo.
    FIX_HINT = <<~HINT.strip
      Fix: run `workspace doctor --fix`, or set a scrape pattern with
      `workspace config set context.source scrape` and
      `workspace config set context.pattern '(\\d+)% ctx'`, or pass --context-pct N.
    HINT
  end
end
