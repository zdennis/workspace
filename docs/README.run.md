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
| `--close` | Send `exit` to the pane after the command runs (closes the shell/pane) |
| `--pipe CMD` | Pipe the command output into CMD (repeatable for multi-stage pipelines) |

## Details

The command is sent to the tmux pane using `tmux send-keys` in literal mode (`-l`), so special characters are passed through unchanged.

**Pane targeting** — by default the bottommost pane is used (highest pane index at invocation time). Use `--pane N` for a specific zero-based index, or `--pane bottom` / `--bottom` to be explicit.

**Split panes** — `--split` creates a new horizontal pane below the bottommost pane, then sends the command there. `--split --vertical` splits side-by-side instead. The split uses `tmux split-window -P -F '#{pane_index}'` to capture the new pane index atomically.

**Waiting for results** — `--wait` writes two UUID-keyed files to `~/.workspace-runs/` before sending anything to tmux:

- `<uuid>.cmd` — the raw command text, written verbatim (no shell interpolation)
- `<uuid>.sh` — the wrapper script that runs the `.cmd` file with redirected I/O and then calls `workspace report-run-status`

The pane receives `. ~/.workspace-runs/<uuid>.sh` via `tmux send-keys`. The parent process polls `~/.workspace-runs/<uuid>.json` for completion, then prints the exit status, stdout, and stderr. The workspace process exits with the command's exit code.

Writing the command to a `.cmd` file instead of interpolating it inline means single quotes, backslashes, and other shell metacharacters in the command are passed through unchanged. However, `--wait` validates shell quoting early using `Shellwords.split` and raises an error with a hint if the command has unbalanced quotes:

```
Error: Command has invalid shell quoting (shell single quote is not closed).
Hint: if your argument contains single quotes (e.g. "what's"), wrap it in double quotes instead: echo "what's up"
```

Requires `workspace` to be on PATH inside the tmux pane's shell.

**`--wait` is incompatible with `--no-enter`** — the wrapper script must be executed by the shell, so Enter must be sent.

**`--close` is incompatible with `--no-enter`** — `exit` must be submitted to the shell.

**Piping commands** — `--pipe CMD` appends `| CMD` to the command before it is sent or written to the `.cmd` file. Multiple `--pipe` flags build a multi-stage pipeline in declaration order:

```sh
workspace run scooter "find . -name '*.log'" --pipe "grep ERROR" --pipe "wc -l"
# sends: find . -name '*.log' | grep ERROR | wc -l
```

Each stage is individually validated for shell quoting before the stages are joined, so an unbalanced quote in one stage cannot mask an unbalanced quote in another. `--pipe` is incompatible with `--no-enter` since the pipeline must be submitted to the shell.

**`--dry-run` with `--wait`** prints the contents of both files that would be written (`.cmd` and `.sh`) and the pane command that would be sent, using `<uuid>` as a placeholder. Nothing is written or sent.

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

# Run a command in a split pane and close the pane when done
workspace run scooter 'rake spec' --split --close

# Wait for a command and close the pane after it finishes
workspace run scooter 'rake spec' --wait --close

# Pipe output of one claude invocation into another
workspace run scooter "claude -p 'find recent Slack @-mentions'" \
  --pipe "claude -p 'summarize and notify me'" \
  --split --wait --close

# Multi-stage pipeline
workspace run scooter 'grep ERROR log/production.log' --pipe 'sort' --pipe 'uniq -c'
```
