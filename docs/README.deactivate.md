# workspace deactivate

Deactivate Claude in a project's tmux pane by sending Ctrl-C.

## Usage

```sh
workspace deactivate [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--all` | Deactivate Claude in all active projects |

## Details

Sends Ctrl-C to the Claude pane (pane 0.1) three times with short delays between sends. This kills the running Claude process, freeing memory and CPU for idle sessions.

Auto-detects the project from the current directory if not specified.

## Examples

```sh
# Deactivate Claude in a specific project
workspace deactivate my-project

# Deactivate from within the project directory
workspace deactivate

# Deactivate all active projects
workspace deactivate --all
```
