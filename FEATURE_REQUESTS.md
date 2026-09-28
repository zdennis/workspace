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


### Create launcher panes individually instead of in a single AppleScript

The current approach builds all panes in one AppleScript that concatenates uid/project output. If the output is truncated with many panes, some projects silently fail to register. Creating panes one at a time (or in smaller batches) would be more reliable, though slower. Consider a hybrid approach: batch creation with per-pane verification and retry.

### `agent-run`/`send_keys` doesn't reliably submit multi-line text into Claude Code

`Tmux#send_keys` (`lib/workspace/tmux.rb:49`) only sends a second Enter when
the pasted text exceeds 1000 bytes (the `large_paste` heuristic), on the
assumption that only large pastes collapse into Claude Code's
`pasted_content` widget. In practice, a multi-line body well under 1000
bytes can still collapse into that widget, and the single Enter then just
dismisses the widget instead of submitting — the text is left sitting,
unsubmitted, at the prompt. Repeated `workspace agent-run command` calls in
that state each append another pasted block instead of one being submitted,
compounding the problem.

Reproduced via `workspace agent-run command --work-item <ref> --body "<3-4
line sentence, ~300 bytes>"`: the text appeared at the prompt but never
submitted until a manual `tmux send-keys -t <target> Enter` was sent
outside of workspace.

Ideas:
- Detect multi-line text (not just byte size) and always send the
  dismiss-then-submit double Enter for it.
- Expose a CLI primitive for sending a bare Enter/newline to a pane (there
  currently isn't one — recovering the stuck pane required raw `tmux
  send-keys ... Enter`, bypassing `workspace` entirely).
- Consider clearing any stray unsubmitted input before pasting a new
  command, so a missed submission doesn't silently concatenate with the
  next one.

Related: `Tmux#send_keys`/`#tmux_load_buffer` (`lib/workspace/tmux.rb:49,103`)
don't guard against an empty `text`. `workspace agent-run command --body ""`
(sent as a bare-Enter nudge, to work around the above) writes zero bytes to
`tmux load-buffer`'s stdin, which never creates the named buffer even though
the load command itself reports success. The following `paste-buffer` and
the `ensure`'s `delete-buffer` then both fail against a nonexistent buffer,
logging `no buffer ws_send_<id>` / `unknown buffer: ws_send_<id>` to the
`workspace agent` daemon's own stderr. Fix: either short-circuit `send_keys`
for empty text (skip straight to sending Enter), or have callers pass a
single space instead of `""`.

### `wait-until-content --since-start` reflow limitation

If a pane is reflowed mid-wait (e.g. a rewrapping resize), the content anchor
can be lost and the surviving==0 fallback treats pre-start content as
post-start, allowing a possible false match. Content alone cannot distinguish
reflow from full history eviction, and full eviction must treat everything as
post-start — so fixing this needs an out-of-band signal (e.g. a pane resize
event, capture-time pane dimensions, or a marker-based baseline). See
`docs/README.wait-until-content.md` and
`lib/workspace/commands/wait_until_content.rb`.

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
