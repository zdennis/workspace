# workspace projects

List projects, show one in detail, or list its member workspaces: each repository's main checkout plus its
linked git worktrees, with the workspaces that belong to each.

## Usage

```sh
workspace projects [list] [--running] [--git] [--json]
workspace projects show [NAME|PATH] [--json] [--no-agents] [--no-git] [--timeout SECONDS]
workspace projects members [NAME|PATH] [--path] [--all] [--json]
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
| `--timeout SECONDS` | `show` only: how long to wait for each agent daemon (default 1) and for all the git reads, the worktree listing included (default 5). A small value turns slow checkouts `unknown` |
| `--path` | `members` only: print each checkout's path instead of its workspace name. Not with `--json` |
| `--all` | `members` only: also list worktrees that have no workspace config (runs one bounded `git worktree list`) |
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
- Configs that share a directory but aren't in git are one project each: with no
  git dir to key on, every config is its own project, so the same path can list
  twice (both flagged `(same name)` only if their names match).
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

Errors under `--json` print `{"schema_version":1,"error":"..."}` on stdout and
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
| `AGENTS` | Panes by state, waiting first, from the workspace's agent daemon. `-` when the workspace isn't running, `none` when its daemon reports no panes, `no daemon`, `timed out` or `bad reply` when the daemon couldn't be read. Absent with `--no-agents` |
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
             "counts":{"working":0,"idle":0,"waiting":1}},
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
| `members[].agents` | `{"available":true,"panes":[...],"counts":{"working","idle","waiting"}}` from the daemon. `{"available":false,"reason":...}` when it can't be read: `not_running` (never asked), `no_daemon`, `timeout` or `error` (bad reply, with the message in `detail`). This is never an `errors` entry and never changes the exit code. `null` with `--no-agents` |
| `members[].git` | `{"available","branch","changed_files","ahead","upstream","unpushed_commits","unsaved"}`. `unsaved` is always present: `"no"`, `"yes"`, `"unknown"` (git couldn't answer, with `available: false` and `reason` `timeout` or `error`; `detail` carries an error message) or `"missing"` (checkout gone). `branch` is `null` when detached; `ahead` and `upstream` are `null` without an upstream. `null` with `--no-git` (the key is always present) and for every member of a project with no git repository |
| `members[].open_asks`, `pipeline` | `null` for a missing checkout, or when the file can't be read. `pipeline` is `{"entries": N}` |
| `locks` | Lock name to `holder` (or `null`) and `queue`. `{}` when nothing is locked or every checkout is gone. `null` if the store can't be read |
| `dev` | Same facts as `workspace dev status --json`, for the project. `holder_workspace` is set only while running. `null` if every checkout is gone or the store can't be read |
| `errors` | Present only when `locks` or `dev` couldn't be read, or listing worktrees timed out: `{"locks": "...", "dev": "...", "worktrees": "..."}` |
| `summary` | Totals across the workspaces. `waiting_agents` counts panes waiting on a person. `agents_unavailable` counts running workspaces whose daemon couldn't be read (`no_daemon`, `timeout`, `error`), so `waiting_agents: 0` with `agents_unavailable: 0` means none waiting, while a nonzero `agents_unavailable` means the count may be low. Both are `null` with `--no-agents`. `workspaces` counts configured workspaces only. `unsaved_members` counts members whose `git.unsaved` is `"yes"` or `"unknown"` (a missing checkout isn't counted); `null` with `--no-git` or for a project with no git repository |

Exit code 0 means the project was found, even if every session is down. An
unknown or ambiguous NAME, or a directory in no project, exits 1; under
`--json` that is `{"schema_version":1,"error":"..."}` on stdout.

## members

`workspace projects members [NAME|PATH]` prints the project's workspaces for
scripts: one workspace name per line, main checkout first, then the worktrees
by name. NAME works as for `show` (a project name, a member workspace name or a
path; a name shared by two clones is a usage error listing their paths; no NAME
means the project containing the current directory). Output is only the names, so
it fits a loop:

```sh
for ws in $(workspace projects members); do workspace stop "$ws"; done
workspace launch $(workspace projects members app)
```

- `--path` prints each member's checkout path instead of its name, in the same order.
- Without `--all` it reads only the tmuxinator configs and `.git` files and runs
  no git command. A workspace whose checkout is gone is still listed.
- `--all` also lists worktrees that have no workspace config, after the configured
  members, which costs one `git worktree list` (stopped after 5 seconds, then an
  error). They have no name, so they print as their path, with or without `--path`;
  a name is never blank.
  Paths start with `/`, which workspace names never do, so a script can tell them apart.
- A repository with no workspaces prints nothing and exits 0.

Errors (an unknown or ambiguous NAME, a directory in no project) exit 1, as for `show`.

### members JSON

```json
{"schema_version":1,
 "project":{"name":"app","id":"/Users/z/src/app/.git","path":"/Users/z/src/app"},
 "members":[
   {"workspace":"app","path":"/Users/z/src/app","kind":"main","configured":true,"exists":true},
   {"workspace":"app.worktree-login","path":"/Users/z/src/app/.worktrees/login","kind":"worktree","configured":true,"exists":true},
   {"workspace":null,"path":"/Users/z/src/app/.worktrees/spike","kind":"worktree","configured":false,"exists":true}
 ]}
```

`kind` is `main` or `worktree`. The `workspace: null` member (`configured: false`)
appears only with `--all`; `exists: false` marks a checkout that is gone. Errors under
`--json` print `{"schema_version":1,"error":"..."}` on stdout and exit 1, as for `list`.

## Examples

```sh
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
