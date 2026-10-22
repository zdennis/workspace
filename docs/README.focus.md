# workspace focus

Bring a project's iTerm window to the front.

## Usage

```sh
workspace focus [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WS` | The project, as an option; same as the positional `[project]`. Giving both with different names is a usage error |
| `--shake` | Shake the window after focusing to draw attention |
| `--highlight` | Highlight the window after focusing |
| `--pane PANE` | After the window is in front, select this pane: a pane id (`%19`) or `window.pane` (`0.1`). It must belong to the project's tmux session |
| `--cycle` | Focus the next tracked project that has a live window, in name order, after the one in front (wrapping around). Takes no project and no `--pane` |
| `--reverse` | With `--cycle`, go to the previous one |
| `--color COLOR` | Color for highlight (default: green). Colors: red, green, blue, yellow, orange, purple, white, cyan, magenta, random |

## Details

Finds the iTerm window for the specified project using its stored window ID and brings it to the front via `window-tool`.

A [headless](README.launch.md#headless) project has no window, so `focus` exits 1 with a message naming its tmux session (`tmux attach -t <session>`).

`--pane` checks the pane first, before anything is focused: a malformed reference is `bad_pane`, a pane id from another session `wrong_session`, an unknown pane `no_such_pane`, and a project with no tmux session `no_session`. It then focuses the window, selects the pane's tmux window and the pane (by pane id, so a renumbered index can't pick another pane). If tmux can't select it, `focus_failed`; the window is already in front by then.

`--cycle` lists the tracked projects whose recorded window iTerm still has (see [`status`](README.status.md#window-state)), sorted by name, finds the one in front (the first of iTerm's windows, front to back, that belongs to one of them), and focuses the one after it. If none of them is in front it starts at the first (the last with `--reverse`). Bind it to a key to step through workspaces. Headless projects are skipped. With no live window it fails with `no_windows_to_cycle`.

Auto-detects the project from the current directory if not specified, using `.workspace-project` marker files or matching active project roots.

## Examples

```sh
# Focus a project window
workspace focus my-notes

# Focus the current directory's project
workspace focus

# Focus and shake the window
workspace focus --shake my-notes

# Focus and highlight the window in green
workspace focus --highlight my-notes

# Focus the window and select pane %19
workspace focus my-notes --pane %19

# Focus the next workspace window, or the previous one
workspace focus --cycle
workspace focus --cycle --reverse

# Focus and highlight in a specific color
workspace focus --highlight --color blue my-notes
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one `focused` row carrying `iterm_window_id`, and `pane` (the pane id) with `--pane`. A missing window or a headless project is the failure envelope. With no window recorded the `code` is `no_window` (`details.workspace`); when iTerm no longer has the recorded window it is `window_gone` (`details.workspace`, `details.iterm_window_id`). Both exit 1. With `--cycle` the row is the project focused, and no live window is `no_windows_to_cycle` (exit 1).
