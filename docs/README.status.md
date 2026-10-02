# workspace status

Show detailed state of tracked launcher sessions.

## Usage

```sh
workspace status [options]
```

## Options

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON |

## Details

Shows the state of all tracked workspace sessions, including their iTerm window IDs and whether they are still alive. A [headless](README.launch.md#headless) project shows `headless` instead of a window ID, and has `"headless": true` in the JSON. With `--json`, every entry gains `"alive"`: `true`, `false`, or `null` for unknown. The key is added to the output only and is not stored in the state file.

Each session is checked against tmux and marked `[alive]` (its tmux session exists), `[dead]` (the state file still lists it but the tmux session is gone), or `[unknown]` (tmux didn't answer, or the project's `tmux_options` select a custom socket the check can't see). `status` only reads the state file; it never prunes. Use `workspace cleanup` or `workspace prune` to remove dead entries. The iTerm window isn't checked.

Useful for debugging when sessions get out of sync, or for scripting with `--json` to get window IDs and session data.

## Examples

```sh
$ workspace status
  my-notes  window_id=1200  [alive]
  billing  window_id=1192  [dead]
  ci-runner  headless  [alive]

$ workspace status --json
{
  "my-notes": {
    "unique_id": "8A3F2B1C-...",
    "iterm_window_id": 1200,
    "alive": true
  },
  "billing": {
    "unique_id": "7D4E6A9F-...",
    "iterm_window_id": 1192,
    "alive": false
  }
}

# Get a specific project's window ID
$ workspace status --json | jq -r '.["my-notes"].iterm_window_id'
1200
```
