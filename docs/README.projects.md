# workspace projects

List projects, or show one in detail: each repository's main checkout plus its
linked git worktrees, with the workspaces that belong to each.

## Usage

```sh
workspace projects [list] [--running] [--json]
workspace projects show [NAME|PATH] [--json] [--no-agents] [--timeout SECONDS]
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
| `--json` | Print schema-versioned JSON (below) |

## Details

`list` prints one row per project: its name, how many workspaces belong to it,
how many have a running tmux session, and the path of its main checkout.
A NOTE column after the path flags `(no git)`, `(broken checkout)`,
`(checkout missing)`, and `(same name)` when two projects share a name.

It is cheap: it reads the tmuxinator configs, a few `.git` files, and makes one
`tmux list-sessions` call. It runs no git commands, opens no sockets and uses
no network. With no tmux server, every project shows 0 running.

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

Worktrees that have no workspace config are not listed.

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
workspace, one read from its agent daemon's socket (see "Agents" below). The dev status comes from `Dev#status_payload`, which runs
`git rev-parse` and, if the project sets `dev.ready`, that command in the main
checkout (not in the holder's worktree). Reading the lock store creates its
directory and `locks.json` if they are missing. Git facts are not shown yet.

```
Project  app   ~/src/app   (git)

WORKSPACE           KIND      RUN             AGENTS            ASKS  PIPE  NOTE
app                 main      yes             1 idle            0     2
app.worktree-login  worktree  yes (headless)  1 waiting, 1 working  1     0
app.worktree-old    worktree  -               -                 -     -     MISSING (checkout gone)

Locks (repo-wide)
  devenv   held by app.worktree-login (pid 4121)   queue: 1
  deploy   STALE holder app (pid 999)
Dev env   running in app.worktree-login, ready
```

| Column | Meaning |
|--------|---------|
| `RUN` | The workspace's tmux session is running (`yes (headless)` when launched headless). `-` for a missing checkout |
| `AGENTS` | Panes by state, waiting first, from the workspace's agent daemon. `-` when the workspace isn't running, `none` when its daemon reports no panes, `no daemon`, `timed out` or `bad reply` when the daemon couldn't be read. Absent with `--no-agents` |
| `ASKS` | Open `workspace ask` questions. `?` if the store can't be read |
| `PIPE` | Work items in flight in the workspace's pipeline. `?` if the file can't be read |
| `NOTE` | `MISSING (checkout gone)`: the config's `root:` no longer exists. Its run, agent, ask and pipeline facts are not read |

### Agents

By default `show` asks each running workspace's agent daemon for its pane states,
the same snapshot `workspace sessions` reads. Each read is bounded: a daemon that
is down, or doesn't answer within the timeout, is reported as unavailable and the
command still exits 0. A hung daemon therefore costs at most the timeout per
running workspace. Workspaces that aren't running are never asked.

| Option | Meaning |
|--------|---------|
| `--no-agents` | Skip every daemon: opens no sockets, drops the `AGENTS` column, and `agents` is `null` in JSON |
| `--timeout SECONDS` | How long to wait for each daemon (default 1, must be greater than 0) |

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
    "open_asks":1,"pipeline":{"entries":0}}
 ],
 "locks":{"devenv":{"holder":{"workspace":"app.worktree-login","path":"...","pid":4121,"stale":false},
                    "queue":[{"workspace":"app","path":"...","pid":4150,"stale":false}]}},
 "dev":{"running":true,"ready":true,"holder_workspace":"app.worktree-login"},
 "summary":{"workspaces":3,"running":2,"open_asks":1,"pipeline_entries":2,"waiting_agents":1}}
```

| Key | Meaning |
|-----|---------|
| `members[].running` | The workspace has a running tmux session and its checkout exists |
| `members[].headless` | Launched headless, from the session state |
| `members[].agents` | `{"available":true,"panes":[...],"counts":{"working","idle","waiting"}}` from the daemon. `{"available":false,"reason":...}` when it can't be read: `not_running` (never asked), `no_daemon`, `timeout` or `error` (bad reply). This is never an `errors` entry and never changes the exit code. `null` with `--no-agents` |
| `members[].open_asks`, `pipeline` | `null` for a missing checkout, or when the file can't be read. `pipeline` is `{"entries": N}` |
| `locks` | Lock name to `holder` (or `null`) and `queue`. `{}` when nothing is locked or every checkout is gone. `null` if the store can't be read |
| `dev` | Same facts as `workspace dev status --json`, for the project. `holder_workspace` is set only while running. `null` if every checkout is gone or the store can't be read |
| `errors` | Present only when `locks` or `dev` couldn't be read: `{"locks": "...", "dev": "..."}` |
| `summary` | Totals across the workspaces. `waiting_agents` counts panes waiting on a person; it is absent with `--no-agents` |

Exit code 0 means the project was found, even if every session is down. An
unknown or ambiguous NAME, or a directory in no project, exits 1; under
`--json` that is `{"schema_version":1,"error":"..."}` on stdout.

## Examples

```sh
$ workspace projects show
$ workspace projects show app --json
$ workspace projects show ~/src/app   # a path picks between same-named clones

$ workspace projects
PROJECT      WORKSPACES  RUNNING  PATH           NOTE
app          3           2        ~/src/app
app          1           0        ~/other/app    (same name)
notes        1           1        ~/notes        (no git)

$ workspace projects --running --json
{"schema_version":1,"projects":[{"name":"app","id":"/Users/z/src/app/.git",...,"workspaces":3,"running":2}]}
```
