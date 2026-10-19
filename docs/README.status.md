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
| `--json-envelope` | Output as JSON in the standard envelope (implies `--json`): `{"schema_version":1,"ok":true,"status":{...},"warnings":[]}`, where `status` is the object `--json` prints. See [`--json` output](README.json.md#success-output-without-the-envelope) |

## Details

Shows the state of all tracked workspace sessions, including their iTerm window IDs and whether they are still alive. A [headless](README.launch.md#headless) project shows `headless` instead of a window ID, and has `"headless": true` in the JSON. With `--json`, every entry gains `"alive"` (the tmux session) and `"window_alive"` (the iTerm window), each `true`, `false`, or `null` for unknown. Both keys are added to the output only and are not stored in the state file.

Each session is checked against tmux and marked `[alive]` (its tmux session exists), `[dead]` (the state file still lists it but the tmux session is gone), or `[unknown]` (tmux didn't answer, or the project's `tmux_options` select a custom socket the check can't see). `status` only reads the state file; it never prunes. Use `workspace cleanup` or `workspace prune` to remove dead entries. The plain output marks the tmux session only; the window is reported in `--json`.

### Window state

`window_alive` is `true` when the recorded `iterm_window_id` is among iTerm's windows, and `false` when it is not or none is recorded: the workspace's tmux session may be running with its window closed. It is `null` for a [headless](README.launch.md#headless) entry (no window to have), and for every windowed entry when the window list could not be read (`window-tool` missing, failing, or printing something that is not a window list), so a `null` never means the window is gone. All windows are listed in one `window-tool` call, skipped when every entry is headless. `window_state` in [`capabilities`](README.capabilities.md) is `1` when this field exists.

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
    "alive": true,
    "window_alive": true
  },
  "billing": {
    "unique_id": "7D4E6A9F-...",
    "iterm_window_id": 1192,
    "alive": false,
    "window_alive": false
  }
}

# Get a specific project's window ID
$ workspace status --json | jq -r '.["my-notes"].iterm_window_id'
1200
```
