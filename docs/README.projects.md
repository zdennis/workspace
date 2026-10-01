# workspace projects

List projects: each repository's main checkout plus its linked git worktrees,
with the workspaces that belong to each.

## Usage

```sh
workspace projects [list] [--running] [--json]
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
| `--running` | Only projects with at least one running workspace |
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
| `id` | Stable identifier: realpath of the shared git dir (the checkout's realpath for a non-git project) |
| `path` | The main checkout (the git dir itself for a bare repo) |
| `vcs` | `git`, `none` (checkout exists, not in git), `broken` (`.git` file points at a missing git dir) or `unknown` (checkout gone) |
| `workspaces` | Number of workspaces in the project |
| `running` | How many of them have a running tmux session |

Errors under `--json` print `{"schema_version":1,"error":"..."}` on stdout and
exit 1, whatever the order of the flags.

## Examples

```sh
$ workspace projects
PROJECT      WORKSPACES  RUNNING  PATH           NOTE
app          3           2        ~/src/app
app          1           0        ~/other/app    (same name)
notes        1           1        ~/notes        (no git)

$ workspace projects --running --json
{"schema_version":1,"projects":[{"name":"app","id":"/Users/z/src/app/.git",...,"workspaces":3,"running":2}]}
```
