# workspace dev

Run one dev environment per repository, guarded by the repo-wide `devenv` lock. Worktrees of one repo usually share ports and databases, so `dev` makes "whose server is running?" explicit: one worktree runs it, the others queue or take over.

## Usage

```sh
workspace dev up     [--wait] [--takeover] [--no-ready] [--max-wait DURATION]
workspace dev down   [--force]
workspace dev status
```

## Configuration

The command comes from the parent project's config (`~/.config/workspace/projects/<parent>.yml`), so every worktree of a repo shares it:

```sh
workspace config set dev.up "./start-dev"         # required
workspace config set dev.ready "port:3000"        # optional readiness probe
workspace config set dev.stop_timeout 20s         # SIGTERM → SIGKILL grace (default 20s)
```

`dev.ready` is either `port:N` (passes once `localhost:N` accepts a TCP connection) or a shell command run in the worktree (passes on exit 0).

## Options (up)

| Option | Description |
|--------|-------------|
| `--wait` | Queue FIFO behind another worktree's dev env instead of refusing |
| `--takeover` | Stop another worktree's dev env, then start this one |
| `--no-ready` | Don't wait for the `dev.ready` check |
| `--max-wait DURATION` | With `--wait`, give up after `DURATION` seconds (exit 75) |

## Options (down)

| Option | Description |
|--------|-------------|
| `--force` | Also kill a process group left behind by a wrapper that was SIGKILLed |

## Exit codes (up)

| Code | Meaning |
|------|---------|
| 0 | Running (or already running for this worktree) |
| 1 | Running for another worktree (no `--wait`/`--takeover`), or failed to start |
| 4 | The `devenv` lock was cleared while waiting |
| 6 | Ready check failed; the env is stopped and the lock released |
| 75 | Still queued after `--max-wait` |

## Details

**`up`** opens a background `devenv` window in the current tmux session and runs the hidden `workspace dev __run` wrapper there. The wrapper takes the `devenv` lock and runs `dev.up` through the shell with the worktree root as cwd. The command owns the pane's TTY: no pipes, output goes straight to the pane, and it can prompt or hit `binding.pry`. `up` returns once the wrapper holds the lock and `dev.ready` passes, printing `Dev environment running for <worktree> (<branch>) in <session>:devenv.` Running `up` again from the same worktree is a no-op.

**Another worktree holds it** — `up` exits 1 with that worktree's name and branch. `--wait` queues (the wrapper waits in its window, and `up` prints one `Trying to obtain workspace devenv lock...` line). `--takeover` stops the holder first and hands the lock straight to this worktree, ahead of anyone already queued.

**Stopping** — `down`, `--takeover` and `workspace lock clear devenv` send SIGTERM to the wrapper only. The wrapper forwards it once to its whole process group (the dev command and its children), waits for the command to exit, releases the lock, and exits. If anything in the group is still running after `dev.stop_timeout`, the group gets SIGKILL. `down` works from any worktree of the repo.

**Ctrl-C** in the `devenv` window stops the command and releases the lock.

**Crashes** — the wrapper releases the lock whenever the command exits. If the wrapper itself is SIGKILLed, its lock is reaped as a dead holder. When the dev command survives it, `down` and `status` report the orphaned process group, and `down --force` kills it. The group is only ever signalled while the wrapper's pid still matches its recorded start time, except for this explicit `--force`, and never once a live process has taken the wrapper's pid (the group id has then been reused by something unrelated; the stale lock is just removed).

**`status`** shows the holder's worktree and branch, pid/pgid, pane, uptime, whether `dev.ready` currently passes, and the queue.

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
