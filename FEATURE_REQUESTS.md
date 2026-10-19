# Workspace Feature Requests

Feature requests and ideas for the workspace CLI.

## Open

### `workspace layout save/restore` across sessions

Persist window positions so relaunching projects restores them to their
previous screen locations automatically.

**In progress:** saving on stop is FR6a, restoring on launch is FR6b.

## Completed

### Claude MCP servers config setting

Add a claude.mcp_servers setting in global and project config that specifies MCP servers passed to claude via --mcp-servers flag when workspace launches or reactivates a project. Project settings override global. Affects the claude command template used by launch (pane 0.1) and reactivate.

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

### `agent-run`/`send_keys` doesn't reliably submit multi-line text into Claude Code

Originally, `Tmux#send_keys` sent a second Enter only for pastes over
1000 bytes (the `large_paste` heuristic), so a multi-line body under that
size could collapse into Claude Code's `pasted_content` widget and sit
unsubmitted at the prompt. The heuristic is gone from `lib/`.
`Tmux#deliver` (`lib/workspace/tmux.rb:184-218`) now reads the pane back
and, in `#submit` (`tmux.rb:313-321`), presses Enter a second time when the
screen is unchanged. Empty text is short-circuited (`tmux.rb:187-188`), so
a bare-Enter nudge no longer writes an empty paste buffer.

For a bare Enter, use `workspace agent-run send --name WS --pane P --keys Enter`
(documented in `docs/README.agent-run.md:75,101`).

Still open (low value, not implemented): clear any stray unsubmitted input
before pasting a new command, so a missed submission doesn't silently
concatenate with the next one.

### Investigate state loss during individual sequential launches

Done in main `6bf064d`: `State#save` now locked.

### `workspace focus --cycle`

Done in main `46742c7`: `focus --cycle [--reverse]`.

### `workspace remove` subcommand

Done in main `f2b639c`: `workspace remove`.

### Structured JSON envelope for --json output

Done in main `924e50a`: `--json-envelope`.

### Create launcher panes individually instead of in a single AppleScript

Done in main `0a59d77`: panes verified, one retry, `launcher_pane_missing` warning.

### `wait-until-content --since-start` reflow limitation

Done in main `1066bc3`: re-baselines on reflow; remaining limits documented.
