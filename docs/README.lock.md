# workspace lock

Coordinate agents sharing a resource through one flock-guarded lock store per repository. Locks are shared across every worktree of a repository — the namespace is keyed on the realpath of `git rev-parse --git-common-dir`, so acquiring a lock from any worktree is visible to every other worktree of the same repo.

## Usage

```sh
workspace lock acquire <name> [options]
workspace lock release [<name>|--all]
workspace lock status  [<name>]
workspace lock clear   [<name>|--all]
```

## Options (acquire)

| Option | Description |
|--------|-------------|
| `--task TEXT` | Free-text description shown to other waiters (e.g. `"PROJ-12 fix login"`) |
| `--wait` | Enqueue and poll instead of refusing immediately when the lock is busy |
| `--poll SECS` | Seconds between polls while waiting (default: 5) |
| `--max-wait DURATION` | Give up after `DURATION` seconds (exit 75); re-run to keep waiting |

## Options (release / clear)

| Option | Description |
|--------|-------------|
| `--all` | `release`: release every lock this agent holds. `clear`: clear every lock in this namespace |

## Exit codes (acquire)

| Code | Meaning |
|------|---------|
| 0 | Acquired |
| 1 | Held by someone else (no `--wait`) |
| 4 | Cleared by someone else while waiting |
| 5 | This agent already holds or waits for a different lock (the deadlock rule) |
| 75 | Still queued after `--max-wait`; re-run to keep waiting |

## Details

**Identity** — a holder is the calling agent's process pid plus its `ps` start time, never a heartbeat. Inside tmux, the agent is found by walking down from the pane's own process (`$TMUX_PANE`); outside tmux, the nearest matching ancestor of the running process is used instead. The start time guards against PID reuse: a dead pid reused by an unrelated process is correctly treated as a different, absent holder.

**Re-entrant** — acquiring a lock this agent already holds succeeds immediately (idempotent); sub-agents launched from the same pane inherit the parent agent's hold.

**One lock at a time** — an agent may hold or wait for only one lock at a time. Trying to acquire a second lock while holding or waiting for another exits 5 and names the other lock.

**FIFO queueing** — `--wait` enqueues behind the current holder and any earlier waiters. Only the queue head may take the lock once it frees up. Waiters are tracked by their own process pid and start time (not the agent's), so a killed `acquire --wait` process is dropped from the queue on the next reap.

**Reaping** — every operation (`acquire`, `release`, `status`, `clear`) first drops any holder or waiter whose pid is no longer running, or whose start time no longer matches (pid reuse), promoting the next live waiter in FIFO order.

**Two-line `--wait` output** — printed once when queued, then again on success, with no progress output in between:

```
Trying to obtain workspace edit lock (position 2 of 3, held by %12 "PROJ-12 fix login" in app.worktree-login)...
Acquired edit lock. Release with: workspace lock release edit
```

**SIGINT/SIGTERM** — interrupting a queued `acquire --wait` removes its queue entry before exiting.

**`clear`** — removes a lock's holder and queue unconditionally, with no liveness check and no confirmation prompt. Use it to recover from a stuck lock. Clearing `devenv` also stops the dev environment: SIGTERM to its wrapper, then SIGKILL to its process group after `dev.stop_timeout` — but only while the wrapper's pid still matches its recorded start time, so a reused process group is never signalled (see [`workspace dev`](README.dev.md)).

## Examples

```sh
# Try to acquire without waiting
workspace lock acquire edit --task "PROJ-12 fix login"

# Queue and wait, polling every 5s, giving up after 9 minutes
workspace lock acquire edit --wait --task "PROJ-12 fix login" --max-wait 540

# Release what you hold
workspace lock release edit
workspace lock release --all

# Inspect
workspace lock status
workspace lock status edit

# Force-clear a stuck lock
workspace lock clear edit
```
