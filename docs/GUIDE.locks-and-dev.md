# Getting started: locks and the dev environment

This walkthrough takes you from a fresh `workspace` install to running a
shared dev environment and coordinating file edits between agents with
locks. By the end you'll have a project launched, a worktree started from
it, a dev command configured, and a feel for how `workspace lock` and
`workspace dev` keep two worktrees from stepping on each other.

## 1. Prerequisites and install

You need macOS, iTerm2, tmux, and tmuxinator, plus `window-tool` on your
`PATH`. See the [main README](../README.md#requirements) for the full list
and install links.

Clone the repo and add `bin/` to your `PATH`, then run:

```sh
workspace init
```

This installs tmuxinator templates into `~/.config/tmuxinator/`, creates
`~/.config/workspace/` and `~/.config/workspace/projects/`, and writes a
default `~/.config/workspace/config.yml`. It's safe to run more than once.

`init` also offers to install agent session hooks for any coding agent it
detects (Claude Code, for example). These hooks are what make the `edit`
lock enforced instead of just advisory, and what power idle takeover (both
covered in [section 6](#6-locks-directly)). Choose **[i]nstall** when
asked, or pass `--install-hooks` to skip the prompt.

Now check your setup:

```sh
workspace doctor
```

You should see a checkmark for each required tool:

```
  ✓  ruby (3+)
  ✓  tmux (3+)
  ✓  tmuxinator (3+)
  ✓  iTerm2
  ✓  window-tool
  ✓  git (2+)
  ✓  gh (2+)
  ✓  ascii-banner
  ✓  templates installed
  ✓  state: no duplicate window IDs
```

Anything without a checkmark names the missing tool and how to install it.
Run `workspace doctor` again from inside a project directory later (after
[section 3](#3-initialize-launch-and-start-a-worktree)) and it also reports
whether session hooks and the session-monitor daemon are set up for that
project — that's what makes lock enforcement and idle takeover work.

## 2. Initialize a project

`workspace init` (above) sets up workspace itself, once, on a machine. To
bring an existing repo under workspace, run `workspace add .` from inside
it, or just `workspace start` (next section) to create a worktree directly.
If you already have a tmuxinator config for a project, `workspace launch
<project>` will use it as-is.

## 3. Launch, and start a worktree

Launch a project by name or directory path:

```sh
workspace launch my-project
```

This opens an iTerm2 window running the project's tmuxinator session, and
starts a background session-monitor daemon for it (used by `workspace
sessions`, and by lock idle takeover).

From inside that project, create a worktree for a piece of work:

```sh
workspace start PROJ-123
```

`workspace start` accepts a JIRA key, JIRA URL, GitHub PR or issue URL, or
a plain branch name. It creates a git worktree under `.worktrees/` in the
project root, generates a tmuxinator config for it, and launches it in its
own window — all in one step.

**Project vs. worktree vs. parent** — a *project* is anything workspace
launches (a plain checkout or a worktree). A *worktree* is a project
created by `workspace start` from another project's repo. The project it
was created from is its *parent*. Run this from inside the worktree to
confirm the relationship:

```sh
workspace parent
```

This prints the parent project's name. Add `--path` for its root directory,
or `--json` for the full picture:

```sh
$ workspace parent --json
{"name":"app","path":"/Users/z/src/app","git_common_dir":"/Users/z/src/app/.git","is_worktree":true,"worktree":"app.worktree-login"}
```

Locks and the dev environment are both scoped to the *repository*, not the
individual worktree — every worktree of `app` shares one lock namespace and
one `devenv` lock, because they're usually sharing one database and one set
of ports.

## 4. Configure the dev environment

Dev environment settings live on the **parent project**, so every worktree
of a repo shares them. Set the command that starts your dev server — this
is required, there's no default:

```sh
workspace config set dev.up "./start-dev"
```

If you try `workspace dev up` before setting this, you'll get:

```
No dev command configured. Set one with: workspace config set dev.up "<command>"
```

Optionally, add a readiness probe — either `port:N` (waits for a TCP
connection on `localhost:N`) or a shell command that passes on exit 0:

```sh
workspace config set dev.ready "port:3000"
```

Other settings, all optional with defaults:

```sh
workspace config set dev.stop_timeout 20s       # SIGTERM -> SIGKILL grace (default 20s)
workspace config set dev.startup_timeout 30s    # wait for the wrapper to take a free lock (default 30s)
workspace config set dev.ready_timeout 2m       # wait for dev.ready to pass (default 120s)
workspace config set dev.kill_grace 5s          # wait after SIGKILL before giving up (default 2s, max 60s)
```

Read a value back, or remove it:

```sh
workspace config get dev.up
workspace config unset dev.ready
```

`workspace config` (no subcommand) shows the whole project config as YAML;
add `--global` to see `~/.config/workspace/config.yml` instead.

## 5. Try `dev up`, `dev status`, `dev down`

From your worktree:

```sh
workspace dev up
```

This opens a `devenv` tmux window in the current session and runs your
`dev.up` command there, holding the repo-wide `devenv` lock while it runs.
`up` returns once the wrapper holds the lock and, if configured, `dev.ready`
passes:

```
Dev environment running for app.worktree-login (feat/login) in myproject:devenv.
```

Running `up` again from the same worktree is a no-op. Check on it:

```sh
workspace dev status
```

This shows the holder's worktree and branch, pid/pgid, pane, uptime,
whether `dev.ready` currently passes, and the queue. Stop it:

```sh
workspace dev down
```

### Contention: a second worktree wants the dev environment

Start a second worktree of the same repo (`workspace start` again, from the
parent), start the dev environment from the first one, then try it from the
second:

```sh
workspace dev up
```

Because another worktree already holds the `devenv` lock, this is refused:

```
$ workspace dev up
Dev environment is running for app.worktree-login (feat/login). Use --wait to queue or --takeover to switch.
```

(exit 1). You have two ways past that:

```sh
workspace dev up --wait              # queue and wait your turn
workspace dev up --takeover          # stop the other worktree's env, then start yours
```

`--wait` queues FIFO behind whoever's running; `--takeover` stops the
current holder's dev environment first and hands the lock straight to you,
ahead of anyone already waiting. Add `--max-wait DURATION` with `--wait` to
give up after a while instead of waiting forever (exit 75).

## 6. Locks directly

Locks are a general-purpose coordination primitive; `devenv` (used by `dev
up`/`down`) is just one lock name. The most common one for agents is
`edit`, used to make sure only one agent is editing files at a time.

```sh
workspace lock acquire edit --task "PROJ-12 fix login"
workspace lock status
workspace lock release edit
```

Acquiring a lock someone else holds fails immediately unless you pass
`--wait` (queue and poll). Add `--max-wait DURATION` to give up after a
while instead of waiting forever (exit 75). An agent can hold or wait for
only one lock at a time — trying to acquire a second while already holding
or waiting for one exits 5 and names the other lock.

**Enforcement** — once the session hooks from `workspace init` (or
`workspace start`, which installs them automatically for new worktrees) are
in place, the `edit` lock isn't just a convention: a coding agent's Edit,
Write, MultiEdit, or NotebookEdit tool call is denied unless the calling
agent currently holds `edit`. `workspace doctor` warns if a worktree is
missing these hooks (for example, one created by hand with `git worktree
add` instead of `workspace start`) — run `workspace init` there to add
them. Bash-based edits (`sed`, `git apply`, codegen) aren't covered by the
hook and stay advisory.

**Idle takeover** — if the agent holding a lock stops working (its turn
ends) and stays idle for `locks.idle_grace` (default 5 minutes), the next
agent waiting in the queue takes the lock over automatically on its next
poll. Configure it per project:

```sh
workspace config set locks.idle_grace 10m
```

The agent that gets displaced is told about it the next time it runs
`acquire` or `release` for that lock. Idle takeover never applies to
`devenv`.

**Prompting an agent to use the lock** — print the exact instructions to
paste into an agent's prompt:

```sh
workspace lock instructions
```

```
Before editing files, run `workspace lock acquire edit --wait --task "<your task>"` using Bash with run_in_background. Do not edit anything until it reports "Acquired". When your edits are complete, run `workspace lock release edit`. Never run `workspace lock clear`.
```

## 7. Observing what's going on

`workspace sessions` shows every pane in a project along with a LOCK
column — which locks that pane holds or is queued for (`edit ✓`, or
`devenv #2` for the second waiter):

```sh
workspace sessions
```

For scripting, `workspace lock status --json` gives you the same
information as the table, structured:

```sh
workspace lock status --json
```

Every lock op is also recorded in an append-only audit log, one JSON line
per event, next to each namespace's `locks.json`:

```sh
${XDG_STATE_HOME:-~/.local/state}/workspace/locks/<namespace>/locks.jsonl
```

Read it directly — `tail -f`, `jq`, whatever you like. It logs `acquire`,
`release`, `reap`, `takeover`, `clear`, and `deny` events (a `deny` is
logged whenever enforcement actually blocks an edit).

## 8. Recovery

**A stale holder** — every lock operation reaps dead holders and waiters
automatically (checking that the recorded pid is still running with a
matching start time), so most of the time you don't need to do anything.
`workspace lock status` marks anything about to be reaped as `STALE`.

**Force-clearing a stuck lock:**

```sh
workspace lock clear edit
```

`clear` removes a lock's holder and queue unconditionally, no liveness
check needed. It's idempotent — clearing a name with nothing held just
reports that:

```
Cleared edit: was free, 0 waiter(s) removed.
```

Clearing `devenv` is different, because it also has to stop the running
dev environment first. Four outcomes are possible:

- **Cleared** — the environment was stopped and the lock removed.
- **Kept** — the process group couldn't be stopped (see below), or someone
  else grabbed the lock while it was being stopped. Exits 1.
- **Already being cleared** — another `clear` (or `dev down`, or `dev up
  --takeover`) is already stopping it. Exits 1; check
  `workspace lock status devenv` for progress.
- **Not held** — nothing to do.

**A process group owned by another user** — if the dev environment's
process group has live processes you're not permitted to signal (for
example, someone else started it, or it's running under another account),
`clear`/`dev down` print who owns it and refuse to touch it:

```
Could not stop process group N (pid P): ...
Kept devenv lock: ...
```

Don't use sudo. Ask that process's owner to stop it themselves — the
message names the pgid, so they can run `kill -TERM -N` (using the pgid
workspace printed). The lock frees itself as soon as the group is empty.

## 9. Config reference

All of these are set with `workspace config set <key> <value>` on the
**parent project** and read with `workspace config get <key>`.

| Key | Description | Default | Valid range |
|-----|-------------|---------|-------------|
| `dev.up` | Command that starts the dev environment | none — required | any shell command |
| `dev.ready` | Readiness probe: `port:N` or a shell command | none — optional | — |
| `dev.stop_timeout` | SIGTERM -> SIGKILL grace when stopping the dev env | 20s | any positive duration |
| `dev.startup_timeout` | How long `dev up` waits for the wrapper to take a free lock | 30s | any positive duration |
| `dev.ready_timeout` | How long `dev up` waits for `dev.ready` to pass | 120s (2m) | any positive duration |
| `dev.kill_grace` | How long `lock clear devenv`/`dev down`/`dev up --takeover` wait after SIGKILL before keeping the lock | 2s | any positive duration, capped at 60s |
| `locks.idle_grace` | How long an idle agent keeps a lock before the head waiter may take it over | 5m (300s) | any positive duration |
| `locks.ps_timeout` | How long to wait for `ps` when checking process liveness | 5s | 1s–60s |
| `locks.reap_interval` | How often the session-monitor daemon sweeps for stale lock holders/waiters | 30s | any positive duration; takes effect only the next time the daemon starts |

Durations are a plain number of seconds, or a number with an `s`, `m`, or
`h` suffix (`20`, `20s`, `5m`, `1h`).

## 10. Troubleshooting

- **"No dev command configured"** — you haven't set `dev.up` yet on the
  parent project. See [section 4](#4-configure-the-dev-environment).
- **`dev up` or `lock acquire` refuses immediately** — someone else holds
  it. Use `--wait` to queue, `--takeover` (dev only) to preempt, or check
  `workspace lock status` / `workspace dev status` to see who.
- **Edits are being denied unexpectedly** — you don't currently hold the
  `edit` lock. Run `workspace lock acquire edit --wait --task "..."` first,
  or check `workspace lock status edit` to see who does.
- **A worktree's edits aren't enforced at all** — its session hooks aren't
  installed. Run `workspace doctor` there, then `workspace init` to add
  them.
- **A lock or dev environment seems stuck** — see
  [section 8](#8-recovery).

For the full details behind everything above, see:

- [`docs/README.lock.md`](README.lock.md)
- [`docs/README.dev.md`](README.dev.md)
- [`docs/README.config.md`](README.config.md)
