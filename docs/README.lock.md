# workspace lock

Coordinate agents sharing a resource through one flock-guarded lock store per repository. Locks are shared across every worktree of a repository — the namespace is keyed on the realpath of `git rev-parse --git-common-dir`, so acquiring a lock from any worktree is visible to every other worktree of the same repo.

## Usage

```sh
workspace lock acquire <name> [options]
workspace lock release [<name>|--all]
workspace lock status  [<name>]
workspace lock clear   [<name>|--all]
workspace lock instructions [<name>]
```

## Options (acquire)

| Option | Description |
|--------|-------------|
| `--task TEXT` | Free-text description shown to other waiters (e.g. `"PROJ-12 fix login"`) |
| `--wait` | Enqueue and poll instead of refusing immediately when the lock is busy |
| `--poll DURATION` | Time between polls while waiting: `30s`, `5m`, `1h`, or a plain number of seconds (default: 5) |
| `--max-wait DURATION` | Give up after `DURATION`: `30s`, `5m`, `1h`, or a plain number of seconds (exit 75); re-run to keep waiting |

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

## Exit codes (release)

| Code | Meaning |
|------|---------|
| 0 | Released (or idempotently, nothing to release) |
| 3 | This agent's hold was taken over idle; applies only to `release`, not `acquire` — a displaced agent's `acquire` prints a notice and carries on as usual (see Idle takeover below) |

## Details

**Lock names** — letters, digits, `.`, `_` and `-`, starting with a letter or digit (for example `edit`, `devenv`, `db-migrate`). Every subcommand rejects any other name with a usage error, because names are pasted into the commands `instructions` tells an agent to run.

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

**`--max-wait` is when to stop waiting, not a hard deadline** — it bounds how long `acquire --wait` polls, not how long the lock stays reserved for this waiter. If the queue promotes this waiter to holder, or its idle takeover comes due, at the instant the deadline fires, `acquire` claims the lock and exits 0 holding it rather than discarding a promotion it just won. A caller that treats exit 75 as "definitely still queued" and exit 0 as "definitely got it early" is therefore always correct; there is no window where the process exits nonzero while secretly holding the lock. Because of this, agents are expected to run `workspace lock acquire --wait` in the background and treat the process's exit — not the printed message — as the signal for whether the lock was obtained: check the exit code (or poll `workspace lock status`) rather than racing the wait loop's own timing.

**SIGINT/SIGTERM** — interrupting a queued `acquire --wait` removes its queue entry and exits 130 (SIGINT) or 143 (SIGTERM). If the poll that notices the signal also acquires the lock, by promotion or idle takeover, `acquire` keeps it and exits 0, like `--max-wait`.

**Idle takeover** — a lock held by an agent that has stopped working doesn't block everyone else forever. The `workspace session-event` hook (installed by [`workspace init`](README.init.md)) marks the agent's hold idle when its turn ends (`Stop`), recording `idle_since`, and marks it active again on its next prompt (`UserPromptSubmit`) or tool use (`PreToolUse`), or when it re-runs `acquire` for the lock it holds. Only the calling agent's own hold is touched, matched by pid and start time. Once a hold has been idle for `locks.idle_grace` (default `5m`), the waiter at the head of the queue takes it over on its next poll; waiters further back never do, and a hold whose agent has resumed is never taken. If the wall clock steps backward past `idle_since`, the grace period restarts from the corrected time. The new holder's `acquire` prints `Took over edit lock from %12 ... idle since <time>.` on stderr before its usual `Acquired` line. `status` shows an idle hold as `IDLE since <time>`. A hold acquired outside tmux (no pane to attach the hook to) is never marked idle, so it can't be taken over by idle release; only holds acquired from inside a tmux pane are eligible.

The displaced agent is told once, the next time it runs `acquire` or `release` for that lock (or `release --all`): stderr gets `Your edit lock was taken over by %13 "PROJ-13 ..." in <worktree> at <time>, after this agent had been idle for 312s.` An `acquire` then carries on as usual: it takes the lock if it is free, or with `--wait` queues for it, and exits with its normal code (0 once acquired). A `release` has nothing left to release, so it exits 3. Idle takeover never applies to the dev environment (`devenv`, a `kind: "process"` holder).

**Enforcement** — once [`workspace session-event`](README.session-event.md) hooks are installed (by `workspace init`, `workspace start`, or an upgraded `workspace doctor`), the `edit` lock is enforced, not just advisory: a `PreToolUse` for `Edit`, `Write`, `MultiEdit` or `NotebookEdit` is denied (hook exit 2, with a message on stderr) unless the calling agent is the `edit` lock's current holder. A Bash-based edit (`sed`, `git apply`, codegen) isn't a gated tool, so it stays advisory — the hook only sees named tool calls. The check costs a `git` subprocess only when some namespace actually holds the `edit` lock; otherwise it's a plain file read, same as idle tracking. If this agent was itself displaced by an idle takeover, its next denied edit also carries the one-time takeover notice, exactly as `acquire`/`release` do.

A worktree created before this feature shipped, or with plain `git worktree add` rather than `workspace start`, has no hooks installed until `workspace init` is run there — worktrees created by `workspace start` get them automatically. `workspace doctor` lists which worktrees are missing hooks.

The `edit` lock (and every other lock this agent holds) is released automatically: on `SessionEnd`, and on a `SessionStart` whose `source` is `clear` (i.e. `/clear`). Neither depends on the agent calling `workspace lock release` itself.

Set the grace period per project, in seconds or with an `s`, `m` or `h` suffix:

```sh
workspace config set locks.idle_grace 10m
```

An invalid stored value (for example one hand-edited to `0`) falls back to the default with a warning instead of failing the lock command.

**`instructions`** — prints the prompt block that tells a coding agent how to use a lock, versioned with the CLI so it always matches these commands. `<name>` defaults to `edit` and is substituted into every command:

```
Before editing files, run `workspace lock acquire edit --wait --task "<your task>"` using Bash with run_in_background. Do not edit anything until it reports "Acquired". When your edits are complete, run `workspace lock release edit`. Never run `workspace lock clear`.
```

**`release`/`clear` are idempotent** — both exit 0 even when there was nothing to release or clear, except that `release` exits 3 when it reports an idle takeover (releasing a lock this agent doesn't hold, or clearing a name with no entry), and say so in their output rather than treating it as an error. A future `--json` flag (planned) will let a caller distinguish "nothing to do" from "released/cleared something" without parsing prose.

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

# Print the agent prompt block for the edit lock
workspace lock instructions
```
