# workspace capture

Read a tmux pane's scrollback buffer and print it to stdout. Auto-detects the project from the current directory when the project name is omitted.

## Usage

```sh
workspace capture [project] [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--pane N` | Target pane by zero-based index, or `bottom` for the last pane (default) |
| `--lines N` | Number of lines from the bottom to capture (default: 100, must be positive) |
| `--all` | Capture the full pane history up to tmux's `history-limit` (mutually exclusive with `--lines`) |

## Details

Output is printed to stdout, making it composable with pipes and other tools.

**Pane targeting** — defaults to the bottommost pane (highest index at invocation time). Use `--pane N` for a specific zero-based index, or `--pane bottom` to be explicit.

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
