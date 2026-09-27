# workspace dev

Run one dev environment per repository, guarded by the repo-wide `devenv` lock. Worktrees of one repo usually share ports and databases, so `dev` makes "whose server is running?" explicit: one worktree runs it, the others queue or take over.

## Usage

```sh
workspace dev up     [--wait] [--takeover] [--no-ready] [--max-wait DURATION]
workspace dev down   [--force]
workspace dev status [--json]
```

## Configuration

The command comes from the parent project's config (`~/.config/workspace/projects/<parent>.yml`), so every worktree of a repo shares it:

```sh
workspace config set dev.up "./start-dev"         # required
workspace config set dev.ready "port:3000"        # optional readiness probe
workspace config set dev.stop_timeout 20s         # SIGTERM → SIGKILL grace (default 20s)
workspace config set dev.startup_timeout 30s      # wait for the wrapper to take a free lock (default 30s)
workspace config set dev.ready_timeout 2m         # wait for the dev.ready check to pass (default 120s)
```

`dev.ready` is either `port:N` (passes once `localhost:N` accepts a TCP connection) or a shell command run in the worktree (passes on exit 0).

## Options (up)

| Option | Description |
|--------|-------------|
| `--wait` | Queue FIFO behind another worktree's dev env instead of refusing |
| `--takeover` | Stop another worktree's dev env, then start this one |
| `--no-ready` | Don't wait for the `dev.ready` check |
| `--max-wait DURATION` | Give up after `DURATION` seconds (exit 75); implies `--wait` |

## Options (down)

| Option | Description |
|--------|-------------|
| `--force` | Also kill a process group left behind by a wrapper that was SIGKILLed |

## Exit codes (up)

| Code | Meaning |
|------|---------|
| 0 | Running (or already running for this worktree) |
| 1 | Running for another worktree (no `--wait`/`--takeover`), or failed to start; also a `--takeover` whose target is already being stopped by another `lock clear`, `dev down`, or `dev up --takeover` |
| 4 | The `devenv` lock was cleared while waiting |
| 6 | Ready check failed; the env is stopped and the lock released |
| 75 | Still queued after `--max-wait` |

## Exit codes (down)

| Code | Meaning |
|------|---------|
| 0 | Stopped (or nothing was running) |
| 1 | Could not stop the process group, or it's already being stopped by another `lock clear`, `dev down`, or `dev up --takeover` |

## `--json`

`workspace dev status --json` emits one JSON object on stdout instead of the table:

```json
{
  "schema_version": 1,
  "running": true,
  "holder": {
    "kind": "process", "pid": 5211, "pgid": 5211, "branch": "feat/login",
    "pane": "%9", "worktree": "/Users/z/src/app.worktree-login",
    "acquired_at": "2026-09-26T09:12:00Z", "stale": false
  },
  "ready": true,
  "queue": []
}
```

- `schema_version` is bumped only on a breaking change to this shape.
- No environment running: `{"schema_version": 1, "running": false, "holder": null, "ready": null, "queue": []}` — never an error.
- `ready` is `true`/`false` when `dev.ready` is configured and the environment is running (not stale), otherwise `null` (not configured, or nothing to check).
- `holder`'s `stale` marks a wrapper whose pid is gone (an orphaned process group may still be running — see "Crashes" below); `running` is `false` for a stale holder.
- A corrupt `locks.json` becomes `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1.
- Usage/validation errors (an unknown flag, extra arguments) get the same treatment when `--json` is present: `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1 — never plain text on stderr.
- Exit codes: `0` on success (including no environment running), `1` for a store error or a usage/validation error.

## Details

**`up`** opens a background `devenv` window in the current tmux session and runs the hidden `workspace dev __run` wrapper there. The wrapper takes the `devenv` lock and runs `dev.up` through the shell with the worktree root as cwd. The command owns the pane's TTY: no pipes, output goes straight to the pane, and it can prompt or hit `binding.pry`. `up` returns once the wrapper holds the lock and `dev.ready` passes, printing `Dev environment running for <worktree> (<branch>) in <session>:devenv.` Running `up` again from the same worktree is a no-op.

**Another worktree holds it** — `up` exits 1 with that worktree's name and branch. `--wait` queues (the wrapper waits in its window, and `up` prints one `Trying to obtain workspace devenv lock...` line). `--takeover` stops the holder first and hands the lock straight to this worktree, ahead of anyone already queued.

**Stopping** — `down`, `--takeover` and `workspace lock clear devenv` send SIGTERM to the wrapper only. The wrapper forwards it once to its whole process group (the dev command and its children), waits for the command to exit, releases the lock, and exits. If anything in the group is still running after `dev.stop_timeout`, the group gets SIGKILL. `down` works from any worktree of the repo. If the group can't be stopped — processes this user isn't permitted to signal (a server under `sudo`), something still running `dev.kill_grace` (default `2s`, capped at `60s`) after SIGKILL, or a wrapper already gone while its group runs on — `down` and `--takeover` keep the `devenv` lock exactly as `workspace lock clear devenv` does: `Could not stop process group N (pid P): ...` and `Kept devenv lock: ...` (with a `kill -TERM -N` hint for the group's owner) on stderr, exit 1, and the lock is not reaped while that group still runs. `--takeover`'s own wrapper stays queued first and starts once the lock frees.

**One stop at a time** — while `down`, `--takeover` or `lock clear devenv` is stopping the group, the holder carries `"clearing": {"pid", "started"}` naming that process. Any of the three run meanwhile signals nothing, prints `devenv lock is already being cleared by pid N ...` on stderr, and exits 1 (a `--takeover` that finds one keeps its own wrapper queued first, so it still starts once that group is stopped). The marker is dropped when that stop finishes, and ignored once the process that set it is no longer running.

**Ctrl-C** in the `devenv` window stops the command and releases the lock.

**Leftover processes** — the wrapper releases the lock only once nothing else is left in its process group: when the command exits but something it started is still running (a background job, or a server running as another user under `sudo`), the window prints `Command exited; waiting for N process(es) left in process group P to exit before releasing the devenv lock.` and the lock stays held until they exit. A SIGTERM that arrives meanwhile is still forwarded to the group once.

**Crashes** — the wrapper releases the lock whenever the command and everything left in its group have exited. If the wrapper itself is SIGKILLed, its lock is reaped as a dead holder. When the dev command survives it, `down` and `status` report the orphaned process group, and `down --force` kills it. The group is only ever signalled while the wrapper's pid still matches its recorded start time, except for this explicit `--force`, and never once a live process has taken the wrapper's pid (the group id has then been reused by something unrelated; the stale lock is just removed).

**The `devenv` window is set `remain-on-exit`**, so it stays open after the wrapper exits and crash output stays readable. `down` and `--takeover` close the dead pane once the env is actually stopped; a ready-check timeout, giving up on `--max-wait`/startup, or `lock clear devenv` leave the window open — close it by hand with `tmux kill-window`.

**No tmux server running** — `up` fails fast: `tmux server not running; start the workspace with 'workspace launch', then run 'workspace dev up' again.`

**A foreign pgid** — when a stale (wrapper-gone) holder's recorded process group has live processes this user isn't permitted to signal (its id was likely reused by another user), `down` (with or without `--force`) and `up --takeover` refuse and leave the lock in place, printing a `ps -axo pid,pgid,user,stat,command | awk '$2 == N'` inspection hint; `status` shows the same note. `workspace lock clear devenv` keeps the lock too and exits 1, without signalling the group, while that group still runs and the wrapper's pid has not been taken by another process. Likewise a group `lock clear devenv` can't stop while the wrapper is still alive (another user's processes, or still running after SIGKILL) keeps its lock and exits 1, and that lock is not reaped when the wrapper goes away while the group still runs; see [`workspace lock`](README.lock.md).

**`--takeover` jumps the queue** — it stops the current holder and hands the lock straight to this worktree, ahead of anyone already waiting with `--wait`. A `workspace lock clear devenv` run at the same time still removes those `--wait` waiters once the holder is stopped (they exit 4; if it can't be stopped they stay queued), but keeps the takeover's queued wrapper, which starts once the holder is stopped.

**`status`** shows the holder's worktree and branch, pid/pgid, pane, uptime, whether `dev.ready` currently passes, and the queue.

## Known limitations

- The 120s ready timeout and the 30s wrapper startup timeout are fixed and not yet configurable.
- Only one dev service is supported per project, guarded by the single `devenv` lock.

## Examples

```sh
# Start this worktree's dev env
workspace dev up

# An agent queueing in the background, giving up after 10 minutes
workspace dev up --wait --max-wait 600

# Switch the running env to this worktree
workspace dev up --takeover

# Inspect and stop
workspace dev status
workspace dev down

# Clean up after a SIGKILLed wrapper
workspace dev down --force
```
