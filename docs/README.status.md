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

Shows the state of all tracked workspace sessions, including their iTerm window IDs and whether they are still alive.

Dead sessions are automatically pruned before display, so only live sessions are shown.

Useful for debugging when sessions get out of sync, or for scripting with `--json` to get window IDs and session data.

## Examples

```sh
$ workspace status
  my-notes  window_id=1200  [alive]
  billing  window_id=1192  [alive]

$ workspace status --json
{
  "my-notes": {
    "unique_id": "8A3F2B1C-...",
    "iterm_window_id": 1200
  },
  "billing": {
    "unique_id": "7D4E6A9F-...",
    "iterm_window_id": 1192
  }
}

# Get a specific project's window ID
$ workspace status --json | jq -r '.["my-notes"].iterm_window_id'
1200
```
