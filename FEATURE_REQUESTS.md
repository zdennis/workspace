# Workspace Feature Requests

Feature requests and ideas for the workspace CLI.

## Open

### Investigate state loss during individual sequential launches

The merge-on-save fix handles concurrent writes, but there may still be
a scenario where launching projects one at a time loses previous entries.
Needs reproduction and debugging with `WORKSPACE_DEBUG=1`.

### `workspace focus --cycle`

Cycle through workspace windows with repeated invocations, similar to
Cmd+Tab behavior. Each call focuses the next project in the list.

### `workspace layout save/restore` across sessions

Persist window positions so relaunching projects restores them to their
previous screen locations automatically.

### `workspace remove` subcommand

Remove a workspace project entirely — delete its tmuxinator config and
project settings files. Unlike `kill` (which stops a running session),
`remove` would clean up the on-disk configuration so the project no
longer appears in `workspace list --all`.

**Note:** Before implementing, consult the agent team to evaluate whether
this overlaps too much with `kill` or is distinct enough to warrant a
separate command. Key question: should `kill` gain a `--remove` flag
instead, or is the destructive nature of removing configs better served
by a dedicated subcommand with its own confirmation prompt?


### Structured JSON envelope for --json output

Wrap all --json output in a standard envelope object (e.g. {"data": ..., "warnings": [...]}) so metadata like event log size warnings can be included without polluting the data. Currently warnings go to stderr which works but loses the info in non-interactive/piped contexts.


### Claude MCP servers config setting

Add a claude.mcp_servers setting in global and project config that specifies MCP servers passed to claude via --mcp-servers flag when workspace launches or reactivates a project. Project settings override global. Affects the claude command template used by launch (pane 0.1) and reactivate.

## Completed

### `workspace deactivate` / `workspace reactivate`

Deactivate the Claude pane in a project by sending Ctrl-C multiple times
to kill the running Claude process. Reactivate it later with
`claude --continue || claude`. This saves memory and CPU for idle
sessions that aren't actively being used.

- `workspace deactivate <project>` — send Ctrl-C to the Claude pane
  (pane 0.1) several times to ensure the process exits
- `workspace reactivate <project>` — send `claude --continue || claude`
  to the Claude pane to restart it
- Both should auto-detect the project from the current directory if not
  specified
- Consider `--all` flags to deactivate/reactivate all active projects
  at once


