# workspace reactivate

Reactivate Claude in a project's tmux pane.

## Usage

```sh
workspace reactivate [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--all` | Reactivate Claude in all active projects |

## Details

Sends `claude --continue || claude` to the Claude pane (pane 0.1), restarting Claude with session continuity when possible.

Auto-detects the project from the current directory if not specified. No-op if Claude is already running (the command text gets typed into Claude's input).

## Examples

```sh
# Reactivate Claude in a specific project
workspace reactivate my-project

# Reactivate from within the project directory
workspace reactivate

# Reactivate all active projects
workspace reactivate --all
```
