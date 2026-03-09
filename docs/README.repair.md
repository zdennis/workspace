# workspace repair

Rebuild state from live iTerm windows, or manually set a project's window ID.

## Usage

```sh
workspace repair [project] [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--window-id WID` | Manually set the window ID for a project (requires project name) |

## Details

Without arguments, scans all iTerm windows for titles matching `workspace-{name}` and reconstructs the state file from what's actually running. Matches window titles to iTerm session unique IDs so that focus, tile, and other commands work correctly.

Existing state entries for projects not found in the scan are preserved.

With `--window-id`, sets a specific project's window ID without scanning. Useful when you know the window ID (e.g., from `window-tool list --json`) and want to fix a single entry.

## Examples

```sh
# Auto-rebuild state from all live workspace windows
workspace repair

# Manually set a project's window ID
workspace repair homebrew-bin --window-id 1196
```
