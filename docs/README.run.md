# workspace run

Send a shell command to a specific pane in a running project's tmux session. Defaults to the bottommost pane and auto-detects the project from the current directory when the project name is omitted.

## Usage

```sh
workspace run [project] <command> [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--pane N` | Target pane by zero-based index, or `bottom` for the last pane |
| `--bottom` | Target the bottommost pane (default behavior, useful for explicit scripts) |
| `--split` | Create a new pane below the bottommost and run the command there |
| `--vertical` | With `--split`, split side-by-side (vertical divider) instead of below |
| `--no-enter` | Send command text without pressing Enter |
| `--focus` | Bring the project's iTerm window to the front after sending |
| `--dry-run` | Print the tmux command without executing it |
| `--wait` | Wait for the command to finish and report exit status, stdout, and stderr |
| `--timeout N` | Seconds to wait before giving up (default: 300, requires `--wait`) |

## Details

The command is sent to the tmux pane using `tmux send-keys` in literal mode (`-l`), so special characters are passed through unchanged.

**Pane targeting** — by default the bottommost pane is used (highest pane index at invocation time). Use `--pane N` for a specific zero-based index, or `--pane bottom` / `--bottom` to be explicit.

**Split panes** — `--split` creates a new horizontal pane below the bottommost pane, then sends the command there. `--split --vertical` splits side-by-side instead. The split uses `tmux split-window -P -F '#{pane_index}'` to capture the new pane index atomically.

**Waiting for results** — `--wait` wraps the command in a UUID-keyed shell callback before sending it to tmux:
```sh
(<command>) > ~/.workspace-runs/<uuid>.stdout 2>~/.workspace-runs/<uuid>.stderr
workspace report-run-status <uuid> $?
```
The parent process polls `~/.workspace-runs/<uuid>.json` for completion, then prints the exit status, stdout, and stderr. The workspace process exits with the command's exit code. Requires `workspace` to be on PATH inside the tmux pane's shell.

**`--wait` is incompatible with `--no-enter`** — the wrapper must be executed by the shell, so Enter must be sent.

**`--dry-run` with `--wait`** prints the wrapper form (showing the UUID placeholder), not the bare command.

Result files in `~/.workspace-runs/` accumulate and are not automatically cleaned up.

## Examples

```sh
# Send to bottommost pane (project auto-detected from cwd)
workspace run 'rake spec'

# Explicit project and pane
workspace run scooter 'rake spec' --pane 1

# Split a new pane and tail a log
workspace run scooter 'tail -f log/development.log' --split

# Pre-fill a command without pressing Enter
workspace run scooter 'bundle exec rails console' --no-enter

# Run and wait for the result
workspace run scooter 'rake spec' --wait

# Wait with a shorter timeout
workspace run scooter 'rake spec' --wait --timeout 60
```
