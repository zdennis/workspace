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

## Completed

_None yet._
