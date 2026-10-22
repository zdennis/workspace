# workspace capture

Read a tmux pane's scrollback buffer and print it to stdout. Auto-detects the project from the current directory when the project name is omitted.

## Usage

```sh
workspace capture [project] [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WS` | The project, as an option; same as the positional `[project]`. Giving both with different names is a usage error |
| `--pane N` | Target pane by zero-based index, `window.pane` (e.g. `0.1`), a tmux pane id (e.g. `%19`, from `workspace sessions --json`), `bottom` for the last pane, or a title substring (e.g. `Claude Code`), matched against the raw pane title then the agent label shown in `workspace sessions` TITLE; the first matching pane wins, so use `window.pane` or a `%id` to be exact (default: `bottom`) |
| `--lines N` | Number of lines from the bottom to capture (default: 100, must be positive) |
| `--all` | Capture the full pane history up to tmux's `history-limit` (mutually exclusive with `--lines`) |

## Details

Output is printed to stdout, making it composable with pipes and other tools.

**Pane targeting** — defaults to the bottommost pane (highest index at invocation time). Use `--pane N` for a specific zero-based index, `--pane 0.1` for `window.pane` (from `workspace sessions`), `--pane %19` for a tmux pane id (from `workspace sessions --json`), `--pane "Claude Code"` for a title substring, or `--pane bottom` to be explicit. A title is matched against the raw pane title, then the agent label shown in `workspace sessions` TITLE (e.g. `Claude Code`); the first matching pane wins, so use `window.pane` or a `%id` to be exact.

**Line range** — by default captures the last 100 lines of the scrollback buffer using `tmux capture-pane -S -100`. Use `--lines N` for a different count. Use `--all` to capture everything up to tmux's `history-limit` setting (equivalent to `tmux capture-pane -S -`).

**`--all` and `--lines` are mutually exclusive** — specifying both raises an error.

**Output format** — plain text with no ANSI escape sequences. Programs that use the alternate screen (vim, less, htop) will show their current visible screen state, not scrollback history.

**Auto-detection** — when no project is given, the project is detected from the current working directory the same way `workspace run` and `workspace focus` do.

## Examples

```sh
# Last 100 lines of the bottommost pane (project auto-detected from cwd)
workspace capture

# Explicit project
workspace capture scooter

# Last 200 lines
workspace capture scooter --lines 200

# Full history
workspace capture scooter --all

# Specific pane by index
workspace capture scooter --pane 1

# Composable — pipe to other tools
workspace capture scooter | grep ERROR
workspace capture scooter | tail -20
workspace capture scooter | claude -p 'summarize the errors'

# Save scrollback to a file
workspace capture scooter --all > /tmp/scooter-history.txt
```
