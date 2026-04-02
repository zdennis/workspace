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

## Details

When you kill workspace projects externally (closing iTerm windows directly, killing tmux sessions manually, or system crashes), the state file can contain entries for sessions that no longer exist. These are "zombie" sessions.

The cleanup command:

1. **Detects zombies** by checking each state entry against live tmux sessions and iTerm windows
2. **Lists all zombies** with their status (tmux session alive/DEAD, iTerm window alive/DEAD)
3. **Asks for confirmation** before removing (unless `--force` is used)
4. **Removes zombie entries** from state

A session is considered a zombie if either its tmux session or iTerm window (or both) no longer exists.

## Examples

```sh
# List zombie sessions and ask for confirmation before removing
workspace cleanup

# Remove all zombie sessions immediately without confirmation
workspace cleanup --force
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
