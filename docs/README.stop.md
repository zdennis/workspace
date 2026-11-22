# workspace stop

Stop workspace projects and their tmux sessions.

## Usage

```sh
workspace stop [--name WS | --all] [--json] [project1] [project2] ...
```

## Details

Stops the specified projects' tmux sessions and closes the iTerm2 window that comes back for each. With no project (positionally or with `--name`), it stops the workspace the working directory is in: a worktree's `.workspace-project` marker, else the active workspace whose root holds the directory. `--all` stops every active workspace project. Outside any workspace, with no name and no `--all`, it refuses with `not_in_workspace` and stops nothing.

### The window iTerm2 brings back

When a workspace's tmux session ends, iTerm2 brings back the hidden `tmux -CC` gateway window for it: tmux's Command Menu, then `Detached` and an idle prompt. `stop` closes that window. It looks after the kill, because iTerm2 does not list the buried gateway session while tmux is attached.

First `stop` looks for the session recorded for the workspace (`unique_id` in the state file). It waits up to 2 seconds for that session to come back, then closes its window, and prints `Closing launcher window W`. It closes the window only when every session in it belongs to a workspace being stopped. A launcher window shared with a workspace that keeps running, or holding any session nothing tracks, stays open.

Otherwise it falls back to finding the window by its screen. A window matches when it holds exactly one session, that session's screen shows this workspace's own launch command (`tmux -CC attach -t ...` or `tmuxinator start NAME --attach`) typed at a shell prompt, then tmux's Command Menu, then `Detached`, then the same prompt with nothing typed after it, and only a login shell runs on its tty. A window whose session another tracked workspace owns is never picked. If two windows match, neither is closed. `stop` prints `Closing gateway window W`. The fallback exists because it is not known whether the gateway keeps its recorded id when it comes back.

Headless workspaces are skipped, and so is a workspace with no recorded id when launch mode resolves to headless. No AppleScript runs for them.

A `stop` or `kill` run from a pane inside the session it ends dies with that session, so the window stays open. Close it by hand.

Projects can be restarted with `workspace launch`.

Every AppleScript call goes through the osascript runner with a time limit. A failure never changes the exit code. `stop` still removes the entries from the state file and kills the tmux sessions, prints one of these warnings to stderr, and leaves the window open (close it by hand):

- `Warning: iTerm did not answer in 5s; the window for P was left open.`
- `Warning: iTerm did not close the window W for P; it was left open.`
- `Warning: More than one detached gateway window matched P; none was closed.`
- `Warning: Could not close the launcher window for P: <error>; it was left open.` (`gateway window` when the fallback found it)

tmux turns `.` and `:` in a session name into `_`, so a config with `name: foo.js` runs as session `foo_js`; `stop` and `kill` look the session up, and name it in their messages, by that stored name.

A project whose tmuxinator config selects a custom tmux socket (`-L` or `-S` in `tmux_options`) has its session killed on that socket, including through `kill`, `finish` and `prune`, which read the socket before they remove the config.

## Examples

```sh
# Stop the workspace you are in
workspace stop

# Stop every active project
workspace stop --all

# Stop one project by name, from anywhere (`--name` adds to any projects named positionally)
workspace stop --name my-notes

# Stop a specific project
workspace stop my-notes

# Stop multiple specific projects
workspace stop my-notes billing
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project: `stopped`, or `not_running` for a named project that wasn't active (no stderr warning). The text goes to stderr. When closing a window failed, `warnings` holds the sentences above (one per project that had a window) and the rows and exit code are unchanged. Outside any workspace with no name and no `--all`, the document is the error envelope with `code` `not_in_workspace` (exit 1).
