# workspace focus

Bring a project's iTerm window to the front, centered, with the other windows dimmed for a few seconds.

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
| `--center` | Center the window on the visible area of its screen after focusing, keeping its size. The default [`focus.chain`](#focus-chain) already centers, so this matters when you change the chain |
| `--color COLOR` | Color for highlight (default: green). Colors: red, green, blue, yellow, orange, purple, white, cyan, magenta, random |

## Details

Finds the iTerm window for the specified project using its stored window ID and brings it to the front via `window-tool`. It then runs the steps of [`focus.chain`](#focus-chain), then `--highlight`, `--shake`, `--center` and `--pane`, in that order.

A [headless](README.launch.md#headless) project has no window, so `focus` exits 1 with a message naming its tmux session (`tmux attach -t <session>`).

`--pane` checks the pane first, before anything is focused: a malformed reference is `bad_pane`, a pane id from another session `wrong_session`, an unknown pane `no_such_pane`, and a project with no tmux session `no_session`. It then focuses the window, selects the pane's tmux window and the pane (by pane id, so a renumbered index can't pick another pane). If tmux can't select it, `focus_failed`; the window is already in front by then.

`--cycle` lists the tracked projects whose recorded window iTerm still has (see [`status`](README.status.md#window-state)), sorted by name, finds the one in front (the first of iTerm's windows, front to back, that belongs to one of them), and focuses the one after it. If none of them is in front it starts at the first (the last with `--reverse`). Bind it to a key to step through workspaces. Headless projects are skipped. With no live window it fails with `no_windows_to_cycle`.

`--center` picks the screen the window is on — the one whose full frame holds the window's center, else the one it shares the most area with — and moves the window (its size unchanged) to the middle of that screen's visible area, the part not taken by the menu bar and Dock. If the screens cannot be read it fails with `no_screen_geometry` after the window is already in front. Works with `--cycle` too, centering each window it lands on.

Auto-detects the project from the current directory if not specified, using `.workspace-project` marker files or matching active project roots.

## Focus chain

The global config key `focus.chain` lists the window-tool steps `focus` runs after the window is in front. Steps are joined by `+`. The default is:

```
focus + center + dim --opacity 0.5 --duration 3
```

So a plain `workspace focus` brings the window forward, centers it on its screen, and dims everything else at half opacity for 3 seconds. `focus` does not wait for the dim: it returns first, and the dim ends on its own.

`workspace focus` passes `id=<window>` to every step itself, so a step is written without it.

### Allowed steps

- The first step is exactly `focus`, with no arguments. `focus` has already run it.
- Later steps are `center`, `dim`, `highlight`, `flash`, `shake`, `snap` or `maximize`, with their window-tool options. `center`, `dim`, `highlight`, `flash` and `maximize` take no positional arguments.
- `dim` and `highlight` must be the last step. They run detached, and nothing can follow them.
- A step may not carry `id=`, `title=`, `--app`, `--json`, `--exact`, `--first`, `--verbose`, `--keep-going` or `--help`. `focus` sets the target itself, and these make window-tool do nothing here.
- A `--color` must be one of red, green, blue, yellow, orange, purple, white, cyan, magenta or random.

`workspace config set focus.chain` checks all of this and refuses a bad value. The key is global only, because `focus --cycle` has no workspace to read a project file from. See [`config`](README.config.md).

```sh
# Plain focus: no centering, no dim
workspace config set focus.chain focus

# Center, then highlight in red
workspace config set focus.chain "focus + center + highlight --color red"

# Back to the default
workspace config unset focus.chain
```

### Flag order

`focus` runs, in this order: the window-tool `focus`, the chain, `--highlight`, `--shake`, `--center`, then `--pane`. Because `--center` runs after the chain, a `dim` at the end of the chain starts before `--center` moves the window.

### The dim runs detached

`dim` and `highlight` block in window-tool until they end. `focus` starts them in the background with none of its pipes open, so it can return at once. It waits 0.25 seconds to catch a window-tool that refuses the command, and counts the step as started after that.

`dim --duration 0` never ends on its own. The dim holds until `window-tool undim`, the next dim, or the window closing.

### Failures are warnings

Once the window is in front the person has what they asked for, so a failed step does not fail `focus`. The chain stops at the first failed step, and `focus` prints `Warning: ...` on stderr. With `--json` the same sentences are in the document's `warnings`. The warning names the step and quotes window-tool's first line of stderr.

A bad stored `focus.chain`, or a global config that cannot be read, gives the same warning and runs the default chain.

- Foreground steps have no time limit. `flash --count 100000` or a large `shake --count` holds `focus`, and workspace-ui's button, until it ends.
- A detached step that fails after the first 0.25 seconds is not reported.
- `focus_by_id`, the call that brings a window forward, has other callers: `tile` and `run --focus`. They stay plain and ignore `focus.chain`. So does the Alfred workflow, which calls window-tool directly (see [`alfred`](README.alfred.md)).

### Side effects

A focus centers the window, so it moves. `stop` saves each window's position for the next launch, so a window that was focused and then stopped is saved at the centered spot, not where the tile layout put it. Set `focus.chain` to `focus` to avoid this.

Anything that calls `workspace focus` gets the chain, including agents and workspace-ui's focus button.

### window-tool versions

`dim` needs window-tool 0.7 or later. `center` needs 0.11 or later. An older window-tool exits with `Unknown command` for the step. The warning then says to update window-tool or change `focus.chain`. window-tool exits 1 for this in some versions and 2 in others, so `focus` reads the message, not the exit code.

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

# Center the window on its screen, keeping its size
workspace focus --center my-notes
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one `focused` row carrying `iterm_window_id`, and `pane` (the pane id) with `--pane`. A missing window or a headless project is the failure envelope. With no window recorded the `code` is `no_window` (`details.workspace`); when iTerm no longer has the recorded window it is `window_gone` (`details.workspace`, `details.iterm_window_id`); when `--center` cannot read the screens it is `no_screen_geometry`. All exit 1. Warnings from the chain are in `warnings` (see [Failures are warnings](#failures-are-warnings)), and in `details.warnings` of `no_screen_geometry` and `focus_failed`. With `--cycle` the row is the project focused, and no live window is `no_windows_to_cycle` (exit 1).
