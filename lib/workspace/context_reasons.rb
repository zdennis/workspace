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

    # One line of fix instructions, printed alongside any of the reasons
    # above. Never suggests sudo.
    FIX_HINT = <<~HINT.strip
      Fix: run `workspace doctor --fix`, or set a scrape pattern with
      `workspace config set context.source scrape` and
      `workspace config set context.pattern '(\\d+)% ctx'`, or pass --context-pct N.
    HINT
  end
end
