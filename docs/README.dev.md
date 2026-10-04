# workspace dev

Run one dev environment per repository, guarded by the repo-wide `devenv` lock. Worktrees of one repo usually share ports and databases, so `dev` makes "whose server is running?" explicit: one worktree runs it, the others queue or take over.

## Usage

```sh
workspace dev up     [--wait] [--force] [--no-ready] [--max-wait DURATION]
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

## Options (every subcommand)

| Option | Description |
|--------|-------------|
| `--name WS` | Act on workspace `WS` instead of the one detected from cwd |

## Options (up)

| Option | Description |
|--------|-------------|
| `--wait` | Queue FIFO behind another worktree's dev env instead of refusing |
| `--force` | Stop another worktree's dev env, then start this one |
| `--no-ready` | Don't wait for the `dev.ready` check |
| `--max-wait DURATION` | Give up after `DURATION`: `30s`, `9m`, `1h`, or a plain number of seconds (exit 75); implies `--wait`. With `--force`, it limits the whole switch |

`--takeover` is the deprecated alias for `--force` and still works; `down --force` (below) is a separate flag.

## Options (down)
| Option | Description |
|--------|-------------|
| `--force` | Also kill a process group left behind by a wrapper that was SIGKILLed |

## Exit codes (up)

| Code | Meaning |
|------|---------|
| 0 | Running (or already running for this worktree) |
| 1 | Running for another worktree (no `--wait`/`--force`), or failed to start; also a `--force` whose target is already being stopped by another `lock clear`, `dev down`, or `dev up --force` |
| 4 | The `devenv` lock was cleared while waiting |
| 6 | Ready check failed; the env is stopped and the lock released |
| 75 | Still queued after `--max-wait` |

## Exit codes (down)

| Code | Meaning |
|------|---------|
| 0 | Stopped (or nothing was running) |
| 1 | Could not stop the process group, or it's already being stopped by another `lock clear`, `dev down`, or `dev up --force` |

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
- While a workflow run holds the `devenv` lock, `holder` is the run (`"kind": "run"`, `run_id`, `step`, `workflow`, `workspace`, `worktree`, and no `pid`). `running` is `true` exactly while that holder has a live `delegate` (the dev wrapper, with `pid`, `pgid`, `branch`, `pane`, `worktree`, `since` and `stale`), even when the run itself has ended (`holder.stale` is then `true`); read the environment's pid, branch and worktree from `holder.delegate`. A run holding the lock with no environment under it is `running: false` with a non-null `holder`. `ready` is `null` whenever `running` is `false`. A delegate with `"kept": true` and `"stale": true` is a process group that could not be stopped and whose wrapper is gone: `running` is `false`, and no new environment can start under that run until the group is gone.
- A corrupt `locks.json` becomes `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1.
- Usage/validation errors (an unknown flag, extra arguments) get the same treatment when `--json` is present: `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1 — never plain text on stderr.
- Exit codes: `0` on success (including no environment running), `1` for a store error or a usage/validation error.

## Details

**`up`** opens a background `devenv` window in the current tmux session and runs the hidden `workspace dev __run` wrapper there. The wrapper takes the `devenv` lock and runs `dev.up` through the shell with the worktree root as cwd. The command owns the pane's TTY: no pipes, output goes straight to the pane, and it can prompt or hit `binding.pry`. `up` returns once the wrapper holds the lock and `dev.ready` passes, printing `Dev environment running for <worktree> (<branch>) in <session>:devenv.` Running `up` again from the same worktree is a no-op.

**Another worktree holds it** — `up` exits 1 with that worktree's name and branch. `--wait` queues (the wrapper waits in its window, and `up` prints one `Trying to obtain workspace devenv lock...` line). `--force` stops the holder first and hands the lock straight to this worktree, ahead of anyone already queued.

**Stopping** — `down`, `--force` and `workspace lock clear devenv` send SIGTERM to the wrapper only. The wrapper forwards it once to its whole process group (the dev command and its children), waits for the command to exit, releases the lock, and exits. If anything in the group is still running after `dev.stop_timeout`, the group gets SIGKILL. `down` works from any worktree of the repo. If the group can't be stopped — processes this user isn't permitted to signal (a server under `sudo`), something still running `dev.kill_grace` (default `2s`, capped at `60s`) after SIGKILL, or a wrapper already gone while its group runs on — `down` and `--force` keep the `devenv` lock exactly as `workspace lock clear devenv` does: `Could not stop process group N (pid P): ...` and `Kept devenv lock: ...` (with a `kill -TERM -N` hint for the group's owner) on stderr, exit 1, and the lock is not reaped while that group still runs. `--force`'s own wrapper stays queued first and starts once the lock frees.

**One stop at a time** — while `down`, `--force` or `lock clear devenv` is stopping the group, the holder carries `"clearing": {"pid", "started"}` naming that process. Any of the three run meanwhile signals nothing, prints `devenv lock is already being cleared by pid N ...` on stderr, and exits 1 (a `--force` that finds one keeps its own wrapper queued first, so it still starts once that group is stopped). The marker is dropped when that stop finishes, and ignored once the process that set it is no longer running.

**Ctrl-C** in the `devenv` window stops the command and releases the lock.

**Leftover processes** — the wrapper releases the lock only once nothing else is left in its process group: when the command exits but something it started is still running (a background job, or a server running as another user under `sudo`), the window prints `Command exited; waiting for N process(es) left in process group P to exit before releasing the devenv lock.` and the lock stays held until they exit. A SIGTERM that arrives meanwhile is still forwarded to the group once.

**Crashes** — the wrapper releases the lock whenever the command and everything left in its group have exited. If the wrapper itself is SIGKILLed, its lock is reaped as a dead holder. When the dev command survives it, `down` and `status` report the orphaned process group, and `down --force` kills it. The group is only ever signalled while the wrapper's pid still matches its recorded start time, except for this explicit `--force`, and never once a live process has taken the wrapper's pid (the group id has then been reused by something unrelated; the stale lock is just removed).

**The `devenv` window is set `remain-on-exit`**, so it stays open after the wrapper exits and crash output stays readable. `down` and `--force` close the dead pane once the env is actually stopped; a ready-check timeout, giving up on `--max-wait`/startup, or `lock clear devenv` leave the window open — close it by hand with `tmux kill-window`.

**No tmux server running** — `up` fails fast: `tmux server not running; start the workspace with 'workspace launch', then run 'workspace dev up' again.`

**A foreign pgid** — when a stale (wrapper-gone) holder's recorded process group has live processes this user isn't permitted to signal (its id was likely reused by another user), `down` (with or without `--force`) and `up --force` refuse and leave the lock in place, printing a `ps -axo pid,pgid,user,stat,command | awk '$2 == N'` inspection hint; `status` shows the same note. `workspace lock clear devenv` keeps the lock too and exits 1, without signalling the group, while that group still runs and the wrapper's pid has not been taken by another process. Likewise a group `lock clear devenv` can't stop while the wrapper is still alive (another user's processes, or still running after SIGKILL) keeps its lock and exits 1, and that lock is not reaped when the wrapper goes away while the group still runs; see [`workspace lock`](README.lock.md).

**`--force` jumps the queue** — it stops the current holder and hands the lock straight to this worktree, ahead of anyone already waiting with `--wait`. A `workspace lock clear devenv` run at the same time still removes those `--wait` waiters once the holder is stopped (they exit 4; if it can't be stopped they stay queued), but keeps the takeover's queued wrapper, which starts once the holder is stopped.

**`--force --max-wait DURATION`** gives up if this worktree's dev env isn't running by then: `up` stops its queued wrapper, which leaves the queue, and exits 75, the same as `--wait --max-wait`. If the time runs out before the current holder is stopped, the holder keeps running. `DURATION` doesn't cut short a stop already under way; `up` checks it again once that stop finishes.

**Under a workflow run** — a run can hold the `devenv` lock for a step (`uses: [devenv]`, or `dev-env`), in the same FIFO queue as `up --wait`. The lock then says who may start the environment, not that one is running:

- `up` from the pane bound to that run (see [`binding`](README.binding.md)) starts the wrapper at once as the run's delegate: it is recorded on the run's hold instead of queueing behind its own run. `up` again is a no-op while it runs. When the command exits, the lock stays with the run.
- `up` from any other pane exits 1 and names the run on stderr, with `If that run is no longer going, free the lock with: workspace lock clear devenv`. `--wait` queues behind the run. `--force` is refused: it does not take a lock from a run. That holds when the run takes the lock back from its own environment (see below) just as a `--force` starts: the `--force` exits 1, its queued wrapper is stopped, and the environment is left running.
- `down` stops the run's environment and leaves the lock with the run. With nothing running it prints `No dev environment is running; the devenv lock is held by <worktree> (run <id>, step <name>).` and exits 0. An environment that can't be stopped (another user's processes, or still running after SIGKILL) stays recorded on the lock, marked `kept`, even after its wrapper is gone, and `down` exits 1; `up` from the run's pane is then refused until that process group is gone, and `down` drops the record once it is. With the wrapper gone and the group still running, `down --force` kills the group and drops the record, as it does for any orphaned group; the lock stays with the run. The `kept` mark stays with the environment if the run gives the lock up or takes it back while `down` is failing to stop it, and a record another lock command dropped in the meantime (the wrapper was dead and not yet marked) is put back on the run's hold. Once the wrapper is gone, `down`'s message and `up`'s refusal from the run's pane name `workspace dev down --force` first, and `kill -TERM` by the owner for another user's processes. If the lock went to someone else for good during the failed stop, `down` says `The devenv lock no longer names it` instead, and still exits 1.
- `status` prints `Dev environment: running for <worktree> (<branch>) under run <id>`, or `Dev environment: not running; the devenv lock is held by <worktree> (run <id>, step <name>)`. For a `kept` environment whose wrapper is gone it prints `Dev environment: STALE for <worktree> (<branch>) under run <id> (wrapper pid N is gone; its process group N is still running — stop it with ...); the devenv lock is held by ...`, naming `workspace dev down --force`, where `--json` has `running: false` and the delegate with `kept` and `stale`.
- If the run gives the lock up (its next step doesn't use `devenv`, the step has to wait for a lock that sorts before `devenv`, or the run ends) while the environment still runs, the lock passes to the wrapper, which then holds it like any `dev up`: stop it with `down`. `workspace lock clear devenv` stops it too. When the same run next takes `devenv` it gets the lock back with that environment under it, ahead of anyone queued; until then anyone queued for `devenv` waits for the environment to stop.
- A delegate whose wrapper is SIGKILLed, with no `down` having failed to stop it, is dropped from the lock at the next lock or dev command, even if its dev command lives on; the run still holds the lock, and `up` from the run's pane would start a second one. Stop the leftover process by hand.
- `up` and `down` first take a run that has ended off the lock (a write to the lock store): the lock is freed, or passes to the environment still running under it. `status` only reports it.
- The wrapper learns its run from `WORKSPACE_DEV_RUN`, which `up` sets in the `devenv` window; it is not meant to be set by hand.

**`status`** shows the holder's worktree and branch, pid/pgid, pane, uptime, whether `dev.ready` currently passes, and the queue.

## Known limitations

- The dev timeouts are configurable with `workspace config set`: `dev.startup_timeout` (default 30s), `dev.ready_timeout` (default 120s), `dev.stop_timeout` (default 20s), and `dev.kill_grace` (max 60s). See [config guide](README.config.md) for details.
- Only one dev service is supported per project, guarded by the single `devenv` lock.

## Examples

```sh
# Start this worktree's dev env
workspace dev up

# An agent queueing in the background, giving up after 10 minutes
workspace dev up --wait --max-wait 10m

# Switch the running env to this worktree
workspace dev up --force

# Switch, but give up if it isn't running within 2 minutes
workspace dev up --force --max-wait 2m

# Inspect and stop
workspace dev status
workspace dev down

# Clean up after a SIGKILLed wrapper
workspace dev down --force
```

## JSON output

`dev up --json` and `dev down --json` print an action document (see [README.json.md](README.json.md#actions); the actions are `dev up` and `dev down`) with one row: `started` or `stopped`, or `failed` with `reason` `exit_code` and the command's `exit_code` (the explanation is on stderr). The exit code is the command's own. `dev status --json` is described above.
