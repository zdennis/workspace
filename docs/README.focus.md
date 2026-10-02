# workspace focus

Bring a project's iTerm window to the front.

## Usage

```sh
workspace focus [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--shake` | Shake the window after focusing to draw attention |
| `--highlight` | Highlight the window after focusing |
| `--pane PANE` | After the window is in front, select this pane: a pane id (`%19`) or `window.pane` (`0.1`). It must belong to the project's tmux session |
| `--color COLOR` | Color for highlight (default: green). Colors: red, green, blue, yellow, orange, purple, white, cyan, magenta, random |

## Details

Finds the iTerm window for the specified project using its stored window ID and brings it to the front via `window-tool`.

A [headless](README.launch.md#headless) project has no window, so `focus` exits 1 with a message naming its tmux session (`tmux attach -t <session>`).

`--pane` checks the pane first, before anything is focused: a malformed reference is `bad_pane`, a pane id from another session `wrong_session`, an unknown pane `no_such_pane`, and a project with no tmux session `no_session`. It then focuses the window, selects the pane's tmux window and the pane (by pane id, so a renumbered index can't pick another pane). If tmux can't select it, `focus_failed`; the window is already in front by then.

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

# Focus and highlight in a specific color
workspace focus --highlight --color blue my-notes
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one `focused` row carrying `iterm_window_id`, and `pane` (the pane id) with `--pane`. A missing window or a headless project is the failure envelope.
