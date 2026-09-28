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
  end
end
