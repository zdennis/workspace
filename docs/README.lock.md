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
| `--max-wait DURATION` | Stop waiting after `DURATION` seconds (exit 75); re-run to keep waiting |

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
| 5 | This agent already holds or waits for a different lock (the deadlock rule) — release it first |
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

(`%12` is a tmux pane id, identifying which pane holds or is waiting for the lock.)

**`--max-wait` is when to stop waiting, not a hard deadline** — it bounds how long `acquire --wait` polls, not how long the lock stays reserved for this waiter. If the queue promotes this waiter to holder at the instant the deadline fires, `acquire` claims the lock and exits 0 holding it rather than discarding a promotion it just won. A caller that treats exit 75 as "definitely still queued" and exit 0 as "definitely got it early" is therefore always correct; there is no window where the process exits nonzero while secretly holding the lock. Because of this, agents are expected to run `workspace lock acquire --wait` in the background and treat the process's exit — not the printed message — as the signal for whether the lock was obtained: check the exit code (or poll `workspace lock status`) rather than racing the wait loop's own timing.

**SIGINT/SIGTERM** — interrupting a queued `acquire --wait` removes its queue entry before exiting.

**`release`/`clear` are idempotent** — both exit 0 even when there was nothing to release or clear (releasing a lock this agent doesn't hold, or clearing a name with no entry), and say so in their output rather than treating it as an error. A future `--json` flag (planned) will let a caller distinguish "nothing to do" from "released/cleared something" without parsing prose.

**`clear`** — removes a lock's holder and queue unconditionally, with no liveness check and no confirmation prompt. Use it to recover from a stuck lock. Clearing `devenv` also stops the dev environment: SIGTERM to its wrapper, then SIGKILL to its process group after `dev.stop_timeout` — but only while the wrapper's pid still matches its recorded start time, so a reused process group is never signalled (see [`workspace dev`](README.dev.md)). The lock is cleared either way; if the process group has live processes this user isn't permitted to signal (its id was likely reused by another user), `clear` prints `Could not stop process group N (pid P): ... not permitted ...` instead of stopping it.

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
