# workspace lock

Coordinate agents sharing a resource through one flock-guarded lock store per repository. Locks are shared across every worktree of a repository — the namespace is keyed on the realpath of `git rev-parse --git-common-dir`, so acquiring a lock from any worktree is visible to every other worktree of the same repo.

## Usage

```sh
workspace lock acquire <name> [options]
workspace lock release [<name>|--all]
workspace lock status  [<name>] [--json]
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

## Exit codes (clear)

| Code | Meaning |
|------|---------|
| 0 | Cleared (or idempotently, nothing to clear) |
| 1 | A `devenv` lock was kept because its dev environment's process group could not be stopped, or someone else took it while the group was being stopped — see `clear` below. With `--all`, every other lock was still cleared, but the command as a whole still exits 1 if any lock was kept |

## Details

**Lock names** — letters, digits, `.`, `_` and `-`, starting with a letter or digit (for example `edit`, `devenv`, `db-migrate`). Every subcommand rejects any other name with a usage error, because names are pasted into the commands `instructions` tells an agent to run.

**Identity** — a holder is the calling agent's process pid plus its `ps` start time, never a heartbeat. Any registered agent CLI counts as an agent, not only Claude. The nearest matching agent ancestor of the calling process is tried first, since that is the one that actually ran the command; only when no ancestor matches does it fall back to walking down from the pane's own process (`$TMUX_PANE`). The start time guards against PID reuse: a dead pid reused by an unrelated process is correctly treated as a different, absent holder.

**Re-entrant** — acquiring a lock this agent already holds succeeds immediately (idempotent); sub-agents launched from the same pane inherit the parent agent's hold.

**One lock at a time** — an agent may hold or wait for only one lock at a time. Trying to acquire a second lock while holding or waiting for another exits 5 and names the other lock.

**FIFO queueing** — `--wait` enqueues behind the current holder and any earlier waiters. Only the queue head may take the lock once it frees up. Waiters are tracked by their own process pid and start time (not the agent's), so a killed `acquire --wait` process is dropped from the queue on the next reap.

**Reaping** — every operation (`acquire`, `release`, `status`, `clear`) first drops any holder or waiter whose pid is no longer running, or whose start time no longer matches (pid reuse), promoting the next live waiter in FIFO order. The exception is a `devenv` holder `clear` had to keep (below): it is not reaped while its process group is still running, even once its wrapper is gone.

A running session-monitor daemon (started by `workspace launch` or `workspace agent`) also reaps in the background, every 30s, for the lock namespace of each of its panes' current directories, so `lock status` and `sessions` stop showing a dead agent's hold even with no lock op to reap it. It runs the same reap pass an op starts with, so it never drops a holder an op would keep: a namespace with no `locks.json` yet is left untouched, and a kept `devenv` holder stays until its process group is empty. It never waits on the store: a namespace another process is mid-op in is skipped and retried on the next pass, and a pass with nothing to reap leaves `locks.json` untouched. Its reaps are logged to `locks.jsonl` like any other, with an extra `"source": "daemon"` field so they can be told apart from a reap an op ran. A namespace the daemon fails to reap 3 times in a row (an unreadable or corrupt `locks.json`, say) gets one `Warning: lock reaper ...` line in the daemon's log (`workspace-<name>.log` beside its socket, or its stderr when run in the foreground); it warns again only if the namespace recovers and then fails another 3 times. Reaping only happens while a daemon runs for that workspace; otherwise a namespace goes back to being reaped only by the next lock op.

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

**`release`/`clear` are idempotent** — both exit 0 even when there was nothing to release or clear, except that `release` exits 3 when it reports an idle takeover and `clear` exits 1 when it keeps a `devenv` lock it could not stop (releasing a lock this agent doesn't hold, or clearing a name with no entry), and say so in their output rather than treating it as an error.

### `--json`

`workspace lock status --json` emits one JSON object on stdout instead of the table, for scripts:

```json
{
  "schema_version": 1,
  "locks": {
    "edit": {
      "holder": {
        "kind": "agent", "pid": 4411, "started": "Sat Sep 26 09:12:03 2026",
        "pane": "%12", "worktree": "app.worktree-login", "task": "PROJ-12 fix login",
        "acquired_at": "2026-09-26T09:30:00Z", "idle_since": null, "stale": false
      },
      "queue": [
        {"waiter_pid": 5120, "waiter_started": "...", "agent_pid": 4502, "pane": "%13",
         "worktree": "app.worktree-search", "task": "PROJ-14", "enqueued_at": "...", "stale": false}
      ]
    }
  }
}
```

- `schema_version` is bumped only on a breaking change to this shape; new optional fields may be added without bumping it.
- An empty store is `{"schema_version": 1, "locks": {}}` — never an error.
- `holder` is `null` when the lock is free; `queue` is `[]` when no one is waiting.
- `stale` marks a holder or waiter that the next mutating op (`acquire`, `release`, `clear`) would reap as dead — the same annotation the table's `STALE` marker comes from. A kept `devenv` holder (`"kept": true`, see `clear`) is marked stale once its wrapper is gone, but is not reaped while its process group still runs.
- A corrupt `locks.json` becomes `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1 — the JSON error stays on the same stream as a successful payload, so a caller only ever needs to read stdout and check for an `"error"` key, never stderr, to tell the two apart.
- Usage/validation errors (a bad lock name, an unknown flag, extra arguments) get the same treatment: `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1 — never plain text on stderr — as long as `--json` was present on the command line. A caller that always passes `--json` and always reads stdout never needs to special-case argument mistakes.
- Exit codes: `0` on success (including an empty store or a free lock), `1` for a store error or a usage/validation error.

**`clear`** — removes a lock's holder and queue unconditionally, with no liveness check and no confirmation prompt. Use it to recover from a stuck lock. Clearing `devenv` also stops the dev environment first: SIGTERM to its wrapper, then SIGKILL to its process group after `dev.stop_timeout` — but only while the wrapper's pid still matches its recorded start time, so a reused process group is never signalled (see [`workspace dev`](README.dev.md)). The lock keeps naming the dev environment until its process group is gone, so no second dev environment can start beside one that is still running. If the group can't be stopped — it has live processes this user isn't permitted to signal (for example a dev server started under `sudo` or by another user), or it is still running 2s after SIGKILL — `clear` keeps the `devenv` lock, prints `Could not stop process group N (pid P): ...` (naming the owning user when `ps` shows one) and `Kept devenv lock: ...` on stderr, and exits 1. Its waiters are removed either way. The kept holder is marked `"kept": true`, and is restored if its wrapper released the lock meanwhile (a waiter promoted by that release goes back to the head of the queue). It is not reaped when its wrapper exits or is killed: it stays until its process group is gone. Have its owner run `kill -TERM -N`; the lock frees on its own once the group is empty. With `--all`, every other lock is still cleared. If someone else already holds the lock by the time the group is stopped (or can't be), `clear` names them on stderr, prints no `Cleared` line, and exits 1. A wrapper that is already gone is never signalled, but its lock is kept the same way (exit 1) while its process group still has running members, including another user's, unless a live process has since taken the wrapper's pid (the group id was then reused by something unrelated). Otherwise the lock is cleared; if the id was reused, `clear` says so on stderr (`the id now belongs to an unrelated process`) and signals nothing.

**Manual recovery when `ps` is unavailable** — a kept `devenv` lock is treated as still running whenever the process group's liveness can't be checked (`ps` missing, or failing for any reason), so `clear` keeps refusing it forever and no CLI command can free it. To recover by hand: confirm yourself whether the process group named in the kept holder (`pgid`) is actually still running (`ps -o pid,pgid,command -g <pgid>`, or equivalent), stop it if it is, then edit the lock's `locks.json` directly and remove that lock's entry. The file lives at `${XDG_STATE_HOME:-~/.local/state}/workspace/locks/<namespace>/locks.json` (`workspace lock status --json` prints the same holder record, which names the namespace's project). Removing the entry is equivalent to a successful `clear`; nothing else needs updating.

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

## Audit log

Every namespace directory (alongside `locks.json`) also holds an append-only `locks.jsonl`: one JSON line per `acquire`, `release`, `reap`, `takeover` and `clear` event, plus a `deny` event whenever enforcement (above) actually denies an edit. Each line has a `timestamp`, `event`, `lock` (the lock name), and event-specific fields (trimmed holder/waiter summaries, not the full stored record); a `reap` the session-monitor daemon ran also carries `"source": "daemon"`. A `clear` of a `devenv` holder is logged when it starts, with `"holder_kept": true`; the holder's removal once its process group is stopped is a separate `release` carrying `cleared_by`:

```json
{"timestamp":"2026-09-26T09:30:00.123Z","event":"acquire","lock":"edit","holder":{"pid":4411,"pane":"%12","worktree":"app.worktree-login","task":"PROJ-12 fix login","kind":"agent"}}
{"timestamp":"2026-09-26T09:31:12.004Z","event":"deny","lock":"edit","agent":{"pid":5200,"pane":"%13","worktree":"app.worktree-search"},"holder":{"pid":4411,"pane":"%12","worktree":"app.worktree-login","task":"PROJ-12 fix login","kind":"agent"}}
```

- **Ordering matches `locks.json`** — every line is written while the store's own flock is held (the same lock a mutating op takes to rewrite `locks.json`), so the audit trail's order can be trusted against the data file's.
- **The edit fast path never touches it** — `workspace session-event`'s `PreToolUse` check reads `locks.json` directly (no flock) when it's about to allow an edit; only a genuinely *denied* edit takes the flock to append a `deny` line. A busy repo doing nothing but allowed edits writes nothing to `locks.jsonl`.
- **Bounded growth** — once the next line would push `locks.jsonl` past 256KB, it's rotated to `locks.jsonl.1` (replacing any previous one) and a fresh file started, so at most two generations ever exist. There's no `workspace lock log` reader yet; read it directly (`tail -f`, `jq`, etc.).
