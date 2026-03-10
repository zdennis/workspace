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

## Completed

_None yet._
