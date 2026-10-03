# workspace projects

Group workspaces by repository: each project is a repository's main checkout plus its linked git worktrees.
List projects, show one, list its member workspaces, stop all of its running workspaces at once,
or remove all of its worktrees.

## Usage

```sh
workspace projects [list] [--running] [--git] [--json]
workspace projects show [NAME|PATH] [--json] [--no-agents] [--no-git] [--timeout SECONDS]
workspace projects members [NAME|PATH] [--path] [--all] [--timeout SECONDS] [--json]
workspace projects stop [NAME] [--dry-run] [--json]
workspace projects kill NAME [--dry-run] [--yes] [--force] [--discard-unsaved] [--timeout DURATION] [--json]
```

A bare `workspace projects` runs `list`.

## Terminology

| Term | Meaning | JSON key |
|------|---------|----------|
| project | The main checkout of one repository plus all of its linked worktrees. Identified by the realpath of the git common dir. | `name`, `id`, `path` |
| workspace | One tmuxinator config (`~/.config/tmuxinator/workspace.<name>.yml`). A project member that has a config. | `workspaces` (count) |
| member | A checkout in the project: the main checkout or one worktree. | |

Every other `[project]` argument in the CLI (`launch`, `stop`, `sessions`,
`pipeline`...) and `list-projects` operate on single workspaces, not on this
grouping. `~/.config/workspace/projects/<name>.yml` holds per-workspace
settings, despite the directory name.

## Options

| Option | Description |
|--------|-------------|
| `--running` | `list` only: projects with at least one running workspace |
| `--git` | `list` only: add an `UNSAVED` column and count worktrees that have no workspace config. Runs git in every checkout |
| `--no-git` | `show` only: skip git (see "Git" below) |
| `--no-agents` | `show` only: skip every agent daemon (see "Agents" below) |
| `--timeout SECONDS` | `show`: how long to wait for each agent daemon (default 1) and for all the git reads, the worktree listing included (default 5). A small value turns slow checkouts `unknown`. `members --all`: how long to wait for the worktree listing (default 5) |
| `--path` | `members` only: print each checkout's path instead of its workspace name. Not with `--json` |
| `--all` | `members` only: also list worktrees that have no workspace config (runs one bounded `git worktree list`); they show only with `--path` or `--json` |
| `--dry-run` | `stop`, `kill`: show what would happen and change nothing |
| `--yes` | `kill` only: don't ask for confirmation. Every check still runs. Required with `--json` or when stdin is not a terminal |
| `--force` | `kill` only: let worktrees whose checkout is gone (`missing`) or that git can't check (`unknown`) past preflight; a `missing` one is then removed, an `unknown` one still fails if git can't check it at removal time |
| `--discard-unsaved` | `kill` only: also remove worktrees that have unsaved work, losing it |
| `--timeout DURATION` | `kill` only: how long all the unsaved-work checks may take together, e.g. `10`, `30s` or `1m` (default 5s). A worktree git doesn't answer for in time is `unknown` |
| `--json` | Print schema-versioned JSON (below) |

## Details

`list` prints one row per project: its name, how many workspaces belong to it,
how many have a running tmux session, and the path of its main checkout.
A NOTE column after the path flags `(no git)`, `(broken checkout)`,
`(checkout missing)`, and `(same name)` when two projects share a name.

It is cheap: it reads the tmuxinator configs, a few `.git` files, and makes one
`tmux list-sessions` call. Without `--git` it runs no git commands, opens no
sockets and uses no network. With no tmux server, every project shows 0 running.

With `--git`, an `UNSAVED` column shows how many of the project's checkouts have
unsaved work: `2 of 3`, `2 of 3 (1 unknown)` when git couldn't answer for one of
them, `unknown` when it couldn't answer for any, or `-` for a project with no git
repository. A checkout that is gone is left out of the total and named instead,
`2 of 3 (1 missing)`, so it never reads as clean; `missing` alone means every
checkout is gone. A checkout counts as unsaved when it has changed tracked files or
commits that aren't pushed anywhere; `unknown` counts as unsaved and `missing` does not.
The total includes worktrees that have no workspace config (the NOTE column says
how many, e.g. `(1 unconfigured worktree)`), though `WORKSPACES` still counts only
configured ones. It runs about five git commands per checkout, all checkouts of a
project in parallel, so it is slower than a plain `list`. All projects share one
5-second budget, `git worktree list` included: whatever is still running when it
runs out is stopped and shows `unknown`. If the worktree listing is what ran out,
the unconfigured worktrees are not known: the UNSAVED cell gains `worktrees not
listed` (so a `0 of 2` is not a clean bill) and the NOTE says `unconfigured
worktrees unknown`.

### How a workspace joins a project

A workspace belongs to the project that owns the git directory its `root:`
points into: the realpath of that checkout's git common dir, the same key
`workspace lock` uses. The common dir is read from `.git` files, so a worktree
joins its main checkout wherever it lives and whatever its config is called.

- Root in a git repo: grouped by git common dir. The project is named after the
  workspace configured at the main checkout, else after the checkout's directory.
- Root not in git: its own single-member project (`vcs: "none"`), keyed by the
  root's realpath.
- Root has a `.git` file whose git dir is gone (a worktree whose main repository
  was moved or deleted): its own single-member project (`vcs: "broken"`).
- Root directory gone: matched by config name (`<project>.worktree-<branch>` joins
  the project named `<project>`), else its own project (`vcs: "unknown"`). The
  member has `exists: false`.
- Submodules are their own projects. A bare repository is named after its
  directory minus `.git`.
- Two clones of one repository are two projects, because their git dirs differ.
  Both show `(same name)` and their own paths. A command that takes a project
  name gives a usage error listing the candidate paths, and accepts a path to
  pick one.
- Configs that share a directory but aren't in git are one project, not one
  each: with no git dir to key on, the project is keyed by the config's path,
  so two configs with the same root list once, as one project with two members.
- Configs whose roots are gone are matched by name. When several projects share
  the matched name, the config joins one only if its old root was inside that
  project's main checkout; otherwise it stands alone.
- A config rooted in a subdirectory of a repository (a monorepo package) joins
  that repository's project; the project is named after the config at the
  repository root, else after the repository's directory, not the subdirectory.

Worktrees that have no workspace config are not members. `list --git` and `show` find them with `git worktree list`; plain `list` doesn't.

Paths are realpaths, so a symlinked root shows its target. The walk up to the
first `.git` matches what `workspace lock` does: a directory inside some outer
repository (for example a dotfiles repo at `~/.git`) belongs to that repository.
A worktree whose main repository has been moved or deleted is reported as a
broken checkout.

## JSON

```json
{"schema_version":1,"projects":[
  {"name":"workspace","id":"/Users/z/src/workspace/.git","path":"/Users/z/src/workspace",
   "vcs":"git","workspaces":3,"running":2}
]}
```

With `--git` each project also has `"unsaved":{"members":2,"unknown":1,"missing":0,"total":3,"incomplete":false}` (`null` for a project with no git repository; `members` counts `yes` and `unknown`, and `total` leaves out the `missing` ones) and `"unconfigured_worktrees":1`. When the worktree listing ran out of time, `incomplete` is `true` (the counts cover only the configured checkouts) and `unconfigured_worktrees` is `null`.

| Key | Meaning |
|-----|---------|
| `name` | Display name. Not unique across clones |
| `id` | Stable identifier: realpath of the shared git dir (the checkout's realpath for a non-git project). `workspace:<name>` for a project whose checkout is gone and whose config has no usable path of its own (no `root:`, or one already taken by another config) |
| `path` | The main checkout (the git dir itself for a bare repo). `""` for a config with no `root:` |
| `vcs` | `git`, `none` (checkout exists, not in git), `broken` (`.git` file points at a missing git dir) or `unknown` (checkout gone) |
| `workspaces` | Number of workspaces in the project |
| `running` | How many of them have a running tmux session |

Errors under `--json` print `{"schema_version":1,"ok":false,"error":"..."}` on stdout and
exit 1, whatever the order of the flags.

## show

`workspace projects show [NAME|PATH]` prints everything the local files and
processes say about one project. NAME is a project name, a member workspace
name or a path. With no argument it uses the project containing the current
directory, including a repository that has no workspace config yet (shown with
no workspaces). If two projects share a name, `show` is a usage error listing
each candidate's path; pass a path to pick one.

It reads local files, makes one `tmux list-sessions` call and, for each running
workspace, one read from its agent daemon's socket (see "Agents" below). The
dev status comes from `Dev#status_payload`, which runs `git rev-parse` and, if
the project sets `dev.ready`, that command in the main checkout (not in the
holder's worktree). Reading the lock store creates its
directory and `locks.json` if they are missing.
Git facts and unconfigured worktrees are on by default (see "Git" below); `--no-git` skips them.

```
Project  app   ~/src/app   (git)

WORKSPACE           KIND      BRANCH  RUN             AGENTS                ASKS  PIPE  GIT                           NOTE
app                 main      main    yes             1 idle                0     2     clean
app.worktree-login  worktree  login   yes (headless)  1 waiting, 1 working  1     0     3 changed, 2 unpushed
app.worktree-old    worktree  -       -               -                     -     -     -                             MISSING (checkout gone)
(no config)         worktree  spike   -               -                     -     -     unknown (treated as unsaved)

Locks (repo-wide)
  devenv   held by app.worktree-login (pid 4121)   queue: 1
  deploy   STALE holder app (pid 999)
Dev env   running in app.worktree-login, ready
```

| Column | Meaning |
|--------|---------|
| `RUN` | The workspace's tmux session is running (`yes (headless)` when launched headless). `-` for a missing checkout |
| `AGENTS` | Panes by state, waiting first and done last, from the workspace's agent daemon. `-` when the workspace isn't running, `none` when its daemon reports no panes, `no daemon`, `timed out` or `bad reply` when the daemon couldn't be read. Absent with `--no-agents` |
| `BRANCH` | The checked-out branch, `-` when detached or unknown. Absent with `--no-git` |
| `ASKS` | Open `workspace ask` questions. `?` if the store can't be read |
| `PIPE` | Work items in flight in the workspace's pipeline. `?` if the file can't be read |
| `GIT` | `clean`, or `N changed` and `N unpushed`; `unknown (treated as unsaved)` or `timed out (treated as unsaved)` when git couldn't answer; `-` for a missing checkout. Absent with `--no-git` |
| `NOTE` | `MISSING (checkout gone)`: the config's `root:` no longer exists. Its run, agent, ask and pipeline facts are not read |

### Git

By default `show` also reads each existing checkout's branch, upstream, changed
files and unsaved-work state, and lists worktrees that have no workspace config
(`(no config)` in text, `configured: false` and `workspace: null` in JSON; the
main checkout too if it has no config). That is about five git commands per
checkout, all checkouts in parallel. Unsaved work is changed tracked files
(untracked files never count) or commits not pushed anywhere, the same test
`kill` and `prune` use. `--no-git` runs none of it.

The whole git step, `git worktree list` included, is bounded by `--timeout` (default 5
seconds when not given; an explicit value also bounds each agent daemon, and a small
one turns checkouts `unknown`). A checkout that doesn't answer
in time, or that git fails on, doesn't fail the command: its `git.unsaved` is
`"unknown"` with `available: false` and a `reason` (`timeout` or `error`), and
`summary.unsaved_members` counts it as unsaved. A timed-out git command is
stopped: its process group gets SIGTERM, then SIGKILL after a second. If listing the
worktrees runs out of time, the unconfigured worktrees are left out and `errors.worktrees` says so. `unknown` counts as unsaved in `summary.unsaved_members`; `missing` (a checkout whose
directory is gone, never clean) does not. `unpushed_commits` counts commits not on any
remote, while `ahead` counts commits not on the upstream branch. Scripts and
preflights must read `git.unsaved` (or `summary.unsaved_members`), not the exit code:
`show` exits 0 whatever it finds. These are kept apart from `errors`, which is
only for unreadable local state.

### Agents

By default `show` asks each running workspace's agent daemon for its pane states,
the same snapshot `workspace sessions` reads. Each read is bounded: a daemon that
is down, or doesn't answer within the timeout, is reported as unavailable and the
command still exits 0. A hung daemon therefore costs at most the timeout per
running workspace. Timeouts apply per running workspace, so they add up: three
hung daemons at the default 1 second cost about 3 seconds. Workspaces that
aren't running are never asked. The bound covers the wait for the reply; opening
the socket and writing the request are not timed, though both are local and
return at once unless the daemon's accept queue or socket buffer is full.

Two kinds of degradation, kept apart on purpose: local state `show` can't read
(asks, pipeline, locks, dev) is `null` in its field, with a top-level `errors`
entry for locks and dev; the optional agent daemon not answering is
`agents.available: false` plus a `reason`, with no `errors` entry.

| Option | Meaning |
|--------|---------|
| `--no-agents` | Skip every daemon: opens no sockets, drops the `AGENTS` column, and `agents` is `null` in JSON |
| `--timeout SECONDS` | How long to wait for each running workspace's daemon (default 1) and for all the git reads (default 5); a finite number greater than 0. Ignored for agents with `--no-agents` and for git with `--no-git` |

Locks and the dev environment are repo-wide, so they are read once from the
project's main checkout. Each holder or waiter is mapped to the workspace whose
checkout contains its worktree (the deepest one wins); a worktree with no
workspace config shows as `null` in JSON and by its directory name in text. A
stale holder is shown as `STALE`. If the lock store is unreadable, `show` still
succeeds and says so in place of the locks and dev lines.

### show JSON

```json
{"schema_version":1,
 "project":{"name":"app","id":"/Users/z/src/app/.git","path":"/Users/z/src/app","vcs":"git"},
 "members":[
   {"workspace":"app.worktree-login","path":"/Users/z/src/app/.worktrees/login","kind":"worktree",
    "configured":true,"exists":true,"running":true,"headless":true,
    "agents":{"available":true,
             "panes":[{"pane_id":"%3","kind":"claude","state":"waiting","idle_seconds":120,
                      "agents":[{"name":"eval","state":"running"}]}],
             "counts":{"working":0,"idle":0,"waiting":1,"done":0}},
    "open_asks":1,"pipeline":{"entries":0},
    "git":{"available":true,"branch":"login","changed_files":3,"ahead":2,"upstream":"origin/login",
          "unpushed_commits":2,"unsaved":"yes"}},
   {"workspace":null,"path":"/Users/z/src/app/.worktrees/spike","kind":"worktree","configured":false,"exists":true,
    "running":false,"headless":false,"agents":{"available":false,"reason":"not_running"},"open_asks":null,"pipeline":null,
    "git":{"available":true,"branch":"spike","changed_files":0,"ahead":null,"upstream":null,"unpushed_commits":0,"unsaved":"no"}}
 ],
 "locks":{"devenv":{"holder":{"workspace":"app.worktree-login","path":"...","pid":4121,"stale":false},
                    "queue":[{"workspace":"app","path":"...","pid":4150,"stale":false}]}},
 "dev":{"running":true,"ready":true,"holder_workspace":"app.worktree-login"},
 "summary":{"workspaces":3,"running":2,"open_asks":1,"pipeline_entries":2,"unsaved_members":1,"waiting_agents":1,"agents_unavailable":1}}
```

| Key | Meaning |
|-----|---------|
| `members[]` for an unconfigured worktree | `workspace: null`, `configured: false`, `running: false`, `open_asks` and `pipeline` `null`. Present unless `--no-git` |
| `members[].running` | The workspace has a running tmux session and its checkout exists |
| `members[].headless` | Launched headless, from the session state |
| `members[].agents` | `{"available":true,"panes":[...],"counts":{"working","idle","waiting","done"}}` from the daemon. `{"available":false,"reason":...}` when it can't be read: `not_running` (never asked), `no_daemon`, `timeout` or `error` (bad reply, with the message in `detail`). This is never an `errors` entry and never changes the exit code. `null` with `--no-agents` |
| `members[].git` | `{"available","branch","changed_files","ahead","upstream","unpushed_commits","unsaved"}`. `unsaved` is always present: `"no"`, `"yes"`, `"unknown"` (git couldn't answer, with `available: false` and `reason` `timeout` or `error`; `detail` carries an error message) or `"missing"` (checkout gone). `branch` is `null` when detached; `ahead` and `upstream` are `null` without an upstream. `null` with `--no-git` (the key is always present) and for every member of a project with no git repository |
| `members[].open_asks`, `pipeline` | `null` for a missing checkout, or when the file can't be read. `pipeline` is `{"entries": N}` |
| `locks` | Lock name to `holder` (or `null`) and `queue`. `{}` when nothing is locked or every checkout is gone. `null` if the store can't be read |
| `dev` | Same facts as `workspace dev status --json`, for the project. `holder_workspace` is set only while running. `null` if every checkout is gone or the store can't be read |
| `errors` | Present only when `locks` or `dev` couldn't be read, or listing worktrees timed out: `{"locks": "...", "dev": "...", "worktrees": "..."}` |
| `summary` | Totals across the workspaces. `waiting_agents` counts panes waiting on a person. `agents_unavailable` counts running workspaces whose daemon couldn't be read (`no_daemon`, `timeout`, `error`), so `waiting_agents: 0` with `agents_unavailable: 0` means none waiting, while a nonzero `agents_unavailable` means the count may be low. Both are `null` with `--no-agents`. `workspaces` counts configured workspaces only. `unsaved_members` counts members whose `git.unsaved` is `"yes"` or `"unknown"` (a missing checkout isn't counted); `null` with `--no-git` or for a project with no git repository |

Exit code 0 means the project was found, even if every session is down. An
unknown or ambiguous NAME, or a directory in no project, exits 1; under
`--json` that is `{"schema_version":1,"ok":false,"error":"..."}` on stdout.

## members

`workspace projects members [NAME|PATH]` prints the project's workspaces for
scripts: one workspace name per line, main checkout first, then the worktrees
by name. NAME works as for `show` (a project name, a member workspace name or a
path; a name shared by two clones is a usage error listing their paths; no NAME
means the project containing the current directory). Output is only the names, so
it fits a loop:

```sh
workspace projects members | while read -r ws; do workspace stop "$ws"; done
```

Use `while read -r` (or `--json`) rather than word splitting, so a path with
spaces stays in one piece. Do not pass the output unquoted to a command that acts on
every workspace when given no argument: with an empty result,
`workspace stop $(workspace projects members)` becomes a bare `workspace stop`,
which stops every active workspace.

- `--path` prints each member's checkout path instead of its name, in the same order.
- Without `--all` it reads only the tmuxinator configs and `.git` files and runs
  no git command. A workspace whose checkout is gone is still listed.
- `--all` also lists worktrees that have no workspace config, after the configured
  members, which costs one `git worktree list` (stopped after 5 seconds, or after
  `--timeout SECONDS`, then an error). They have no name, so name mode (no `--path`,
  no `--json`) omits them and prints one note to stderr, such as
  `1 unconfigured worktree(s) omitted; use --path or --json to include them`.
  `--path` and `--json` include them. Name mode never prints a path.
- A project with no workspaces prints nothing on stdout, a note on stderr
  (`no workspaces in project NAME`), and exits 0.

Errors (an unknown or ambiguous NAME, a directory in no project) exit 1, as for `show`; under `--json` they print `{"schema_version":1,"ok":false,"error":"..."}` on stdout.

### members JSON

```json
{"schema_version":1,
 "project":{"name":"app","id":"/Users/z/src/app/.git","path":"/Users/z/src/app","vcs":"git"},
 "members":[
   {"workspace":"app","path":"/Users/z/src/app","kind":"main","configured":true,"exists":true},
   {"workspace":"app.worktree-login","path":"/Users/z/src/app/.worktrees/login","kind":"worktree","configured":true,"exists":true},
   {"workspace":null,"path":"/Users/z/src/app/.worktrees/spike","kind":"worktree","configured":false,"exists":true}
 ]}
```

`kind` is `main` or `worktree`. The `workspace: null` member (`configured: false`)
appears only with `--all`; `exists: false` marks a checkout that is gone. `project` has the same
fields as in `show`.

## stop

`workspace projects stop [NAME|PATH]` stops every running workspace of the
project, the main checkout and the worktrees alike, in one step: at the end of
the day, or before switching repos. NAME works as for `show`.

- Targets are the members that are active in the state file, the same notion of
  "active" `workspace stop` uses. The rest report `not_running`. A workspace
  whose checkout is gone but whose session is still live is stopped like any other.
- There is no prompt and no unsaved-work check: `stop` removes nothing that
  `launch` can't recreate, and `workspace stop` doesn't prompt either.
- It runs the same code as `workspace stop`, once for all the targets, so a
  launcher window closes only when every tracked project in it is stopping. Each
  stopped workspace's `post_stop` hook runs (in `--json` mode its output goes to
  stderr). Afterwards one `tmux list-sessions` flags any session that is still
  alive as `failed`. A failed workspace's `post_stop` does not run. If tmux itself
  can't be listed, the outcomes stay as `stop` reported them, `warnings` gets
  `could not verify sessions stopped: <detail>`, and the same line goes to stderr.
- A failed stop has already removed the workspace from the state file, so running
  `projects stop` again reports `Nothing running` and can't retry it. Kill the
  leftover session yourself with `tmux kill-session -t <session>` (or
  `workspace kill <workspace>`).
- If you run it from inside one of the project's sessions, that workspace is
  stopped last, after the result is printed; its `post_stop` hook does not run,
  and its outcome reads `stopped`.
- A failed stop has already removed the workspace's state, so running `projects stop`
  again will not retry it (it reports `not_running`). Kill the leftover tmux session
  yourself (`tmux kill-session -t <session>`, the name is in the `message`) or run
  `workspace kill <workspace>`.
- If the post-stop `tmux list-sessions` itself errors, the Stop outcomes stand and a
  `warnings` entry and a stderr line say "could not verify sessions stopped".
- Agent daemons, locks and each workspace's pipeline and asks files are left
  alone, as with `workspace stop`.
- `--dry-run` prints what would be stopped and exits 0.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every target stopped, nothing was running (`Nothing running in project 'x'.`), or a `--dry-run` |
| 1 | Nothing stopped: a usage error, an unknown or ambiguous NAME, or every target failed (`status` is `failed`) |
| 3 | Some workspaces stopped and some failed |

### stop JSON

```json
{"schema_version":1,"action":"stop","dry_run":false,"status":"partial",
 "project":{"name":"app","id":"/Users/z/src/app/.git","path":"/Users/z/src/app"},
 "results":[
   {"workspace":"app","path":"/Users/z/src/app","kind":"main","outcome":"stopped","reason":null},
   {"workspace":"app.worktree-login","path":"...","kind":"worktree","outcome":"failed","reason":"error",
    "message":"tmux session 'app-worktree-login' is still running after stop"},
   {"workspace":"app.worktree-old","path":"...","kind":"worktree","outcome":"not_running","reason":null}
 ],
 "warnings":[],
 "summary":{"stopped":1,"would_stop":0,"not_running":1,"failed":1}}
```

`status` is `ok` (exit 0), `dry_run` (0), `partial` (3) or `failed` (1, every
target failed). `outcome` is `stopped`, `would_stop` (dry run), `not_running` or
`failed`. `results` lists the workspaces in member order, with the caller's own
last. `summary` always has a count for all four outcomes, zero included. Usage errors and an unknown or
ambiguous NAME print `{"schema_version":1,"ok":false,"error":"..."}` instead and exit 1.

## kill

`workspace projects kill NAME` removes every worktree workspace of the project
in one step, once their work has landed. Each goes the way `workspace kill`
does: its tmux session, git worktree, tmuxinator config, project settings and
state entry. NAME is required (a project name, a member workspace name or a
path), so a group removal never depends on the current directory.

- The main checkout is never removed. It reports `kept`, and its session keeps
  running; run `projects stop` afterwards for a full shutdown.
- Worktrees with no workspace config are not touched or listed; use
  `git worktree remove` for those.
- In a bare repository every configured member is a worktree.

**Checks first.** Every worktree is checked before anything is removed:

| Check | `reason` | Overridden by |
|-------|----------|---------------|
| Unsaved work: changed tracked files or commits not pushed anywhere (`unsaved: "yes"`) | `unsaved` | `--discard-unsaved` |
| Git couldn't answer, or took longer than `--timeout` (default 5s) for all worktrees together (`unsaved: "unknown"`) | `unknown` | `--force`, or retry with a longer `--timeout` |
| The checkout directory is gone (`unsaved: "missing"`) | `missing` | `--force` |
| The worktree runs the dev environment (it holds the `devenv` lock) | `dev_env` | nothing: run `workspace dev down` first |
| The repository's lock store can't be read, so a running dev env can't be ruled out | `lock_store` | nothing: remove worktrees one at a time with `workspace kill NAME` |

If any worktree has a check that isn't overridden, nothing is removed: those
worktrees report `refused` with every reason listed, the rest `not_attempted`,
and the command exits 1. Other locks a worktree holds are listed under
`warnings` but don't refuse; their holders end with the session.

The dev environment is checked only here, before the prompt. A `workspace dev
up` started in a worktree while the prompt waits is not caught.

**Overrides.** `--force` covers only `missing` and `unknown`. A missing
checkout's config, settings, state entry and session are still removed; git's
own record of the gone directory is left for `git worktree prune`. Unsaved work
needs `--discard-unsaved`, and only those worktrees are removed with
`workspace kill --force` semantics. Every other worktree keeps `workspace
kill`'s last-moment unsaved-work re-check, so an edit made after the check, or a
worktree git still can't answer for, fails that worktree (`failed`, reason
`unsaved` or `unknown`) while the rest carry on. Overridden worktrees carry
`"forced": true` and `"overridden_reason"` in JSON on `removed`, `failed` and
`would_remove` rows (not on `refused` or `not_attempted`, where nothing was
acted on).

**Confirmation.** On a terminal it prints the plan (each worktree with its path
and branch, and the main checkout that stays) and asks `Remove N worktree(s) of
'x' and kill their sessions? [y/N]`. Unlike `workspace kill -f`, `--force` does
not skip the prompt; `--yes` does. With `--json`, or when stdin is not a
terminal, pass `--yes` (or `--dry-run`); otherwise it is a usage error and
nothing is read from stdin. Answering no prints `Cancelled.` and exits 0.

- `--dry-run` runs the checks and prints the plan, or the refusal, without
  prompting. It exits 0 if the run would go ahead and 1 if it would be refused.
- Each removed worktree's `post_kill` hook runs (in `--json` mode its output goes
  to stderr).
- If you run it from inside one of the worktrees, that worktree is removed last,
  and the result is printed once its worktree is gone and before its session
  ends.
- Agent daemons and each workspace's pipeline and asks files are left alone, as
  with `workspace kill`.

### kill exit codes

| Code | Meaning |
|------|---------|
| 0 | Every worktree removed, no worktrees (`No worktrees in project 'x'.`), cancelled at the prompt, or a `--dry-run` that would go ahead |
| 1 | Nothing removed: a usage error, an unknown or ambiguous NAME, a refusal (`status` is `refused`), or every worktree failed (`failed`) |
| 3 | Some worktrees removed and some failed |

### kill JSON

```json
{"schema_version":1,"action":"kill","dry_run":false,"status":"refused",
 "project":{"name":"app","id":"/Users/z/src/app/.git","path":"/Users/z/src/app"},
 "results":[
   {"workspace":"app","path":"/Users/z/src/app","kind":"main","outcome":"kept","reason":null},
   {"workspace":"app.worktree-login","path":"...","kind":"worktree","outcome":"not_attempted","reason":null,
    "unsaved":"no","branch":"login","dev_env":false,"locks":["deploy"]},
   {"workspace":"app.worktree-wip","path":"...","kind":"worktree","outcome":"refused","reason":"unsaved",
    "message":"has unsaved work: 2 changed file(s) and 1 unpushed commit(s) on wip; the dev environment is running in it; run 'workspace dev down' first",
    "unsaved":"yes","branch":"wip","dev_env":true,"changed_files":2,"unpushed_commits":1,
    "blockers":[{"reason":"unsaved","message":"has unsaved work: ..."},{"reason":"dev_env","message":"the dev environment is running in it; ..."}]},
   {"workspace":"app.worktree-old","path":"...","kind":"worktree","outcome":"not_attempted","reason":null,
    "unsaved":"missing","branch":null,"dev_env":false}
 ],
 "warnings":["app.worktree-login holds lock 'deploy'; it is released when its session ends"],
 "summary":{"removed":0,"would_remove":0,"refused":1,"not_attempted":2,"failed":0,"kept":1}}
```

`status` is `ok` (exit 0), `dry_run` (0), `refused` (1), `partial` (3) or
`failed` (1). `--json` never prompts, so it never reports `cancelled`.
`outcome` is `removed`, `would_remove` (dry run), `refused`, `not_attempted`,
`failed` or `kept` (the main checkout). On `refused`, `reason` is the first
check that wasn't overridden and `blockers` lists them all; on `failed` it is
`unsaved`, `unknown` or `error` (any other failure removing it), with the detail
in `message`. A `failed` row whose failure came after its worktree was already
removed (its `post_kill` hook or config removal failed) also has
`"worktree_removed": true`; the config, settings or session may be left behind,
so finish with `workspace kill NAME` or by hand. Every worktree row
carries `unsaved` (`yes`, `no`, `unknown` or `missing`), `branch` and `dev_env`,
plus `changed_files` and `unpushed_commits` when `unsaved` is `yes` and `locks`
when it holds other locks. `summary` always has a count for all six outcomes.
Programs should key off `reason` and `blockers[].reason`, not `message`: the
messages are for people and their wording can change.
Usage errors (including `--json` without `--yes` or `--dry-run`) and an unknown
or ambiguous NAME print `{"schema_version":1,"ok":false,"error":"..."}` instead and exit 1.

## Examples

```sh
$ workspace projects kill app --dry-run
$ workspace projects kill app                    # asks first
$ workspace projects kill app --yes --json
$ workspace projects kill app --force --yes      # also clear out worktrees whose checkout is gone

$ workspace projects stop app --dry-run
$ workspace projects stop            # the project for the current directory
$ workspace projects stop app --json

$ workspace projects show
$ workspace projects show app --json
$ workspace projects show ~/src/app   # a path picks between same-named clones
$ workspace projects show --no-git    # skip git: no branch, unsaved work or unconfigured worktrees

$ workspace projects members
app
app.worktree-login
$ workspace projects members app --path
/Users/z/src/app
/Users/z/src/app/.worktrees/login
$ workspace projects members --all --json
{"schema_version":1,"project":{"name":"app",...},"members":[{"workspace":"app",...},...]}

$ workspace projects
PROJECT      WORKSPACES  RUNNING  PATH           NOTE
app          3           2        ~/src/app
app          1           0        ~/other/app    (same name)
notes        1           1        ~/notes        (no git)

$ workspace projects --git
PROJECT  WORKSPACES  RUNNING  UNSAVED  PATH         NOTE
app      3           2        2 of 4   ~/src/app    (1 unconfigured worktree)
notes    1           1        -        ~/notes      (no git)

$ workspace projects --running --json
{"schema_version":1,"projects":[{"name":"app","id":"/Users/z/src/app/.git",...,"workspaces":3,"running":2}]}
```
