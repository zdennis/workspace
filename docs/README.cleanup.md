# workspace cleanup

Detect and remove zombie sessions from state. A zombie session is one where the state file has an entry but the corresponding tmux session or iTerm window no longer exists.

## Usage

```sh
workspace cleanup [options]
```

## Options

| Option | Description |
|--------|-------------|
| `-f`, `--force` | Skip confirmation and remove zombies immediately |
| `--dry-run` | List what would be removed. No prompt, nothing changes, exit 0 (`--force` is ignored) |
| `--tmux-dead-only` | Count only entries whose tmux session is gone; a closed window alone does not make an entry a zombie |
| `--json` | Print one action document instead of text (see [JSON output](#json-output)) |

## Details

When you kill workspace projects externally (closing iTerm windows directly, killing tmux sessions manually, or system crashes), the state file can contain entries for sessions that no longer exist. These are "zombie" sessions.

The cleanup command:

1. **Detects zombies** by checking each state entry against live tmux sessions and iTerm windows
2. **Lists all zombies** with their status (tmux session alive/DEAD, iTerm window alive/DEAD)
3. **Asks for confirmation** before removing (unless `--force` is used)
4. **Removes zombie entries** from state

A session is considered a zombie if either its tmux session or iTerm window (or both) no longer exists. With `--tmux-dead-only` only a missing tmux session counts, so an entry whose session is running and whose window was closed is kept.

If iTerm's windows cannot be listed (`window-tool` missing, failing, or printing something that is not a window list), the window is shown as `unknown`, never `DEAD`, and it never makes an entry a zombie: an entry with a running tmux session is kept, and only an entry with no tmux session is removed. A [headless](README.launch.md#headless) project has no window, so only its tmux session is checked, and it's listed with `iTerm window: none (headless)`.

## Examples

```sh
# List zombie sessions and ask for confirmation before removing
workspace cleanup

# Remove all zombie sessions immediately without confirmation
workspace cleanup --force

# See what would be removed, changing nothing
workspace cleanup --dry-run --json

# Remove only entries whose tmux session is gone
workspace cleanup --tmux-dead-only --force
```

### Example output

```
Found 2 zombie session(s):

  old-project
    tmux session: DEAD
    iTerm window: DEAD (51515)
  stale-worktree
    tmux session: alive
    iTerm window: DEAD (54427)

Remove these 2 zombie session(s) from state? [y/N]
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with a `cleaned` row per zombie removed. Without `--force` the prompt still asks, on stderr. Declining, or having nothing to clean, prints no rows (status `ok`).

Every row carries `tmux_alive` (boolean) and `window_alive` (`true`, `false`, or `null` for a headless entry or when iTerm's windows could not be listed; `null` never means the window is gone) and `headless` (boolean), which tells those two `null`s apart:

```json
{"schema_version":1,"ok":true,"action":"cleanup","status":"dry_run","results":[
  {"workspace":"api","outcome":"would_remove","reason":null,"message":null,"tmux_alive":false,"window_alive":null,"headless":false}],
 "warnings":[],"summary":{"would_remove":1}}
```

With `--dry-run` the status is `dry_run` and the rows' outcome is `would_remove`; it never prompts and exits 0. `cleanup_dry_run` in [`capabilities`](README.capabilities.md) is `1` when `--dry-run`, `--tmux-dead-only` and the row fields exist.
