# workspace kill

Kill a worktree project's session and remove its git worktree. The inverse of `workspace start`.

## Usage

```sh
workspace kill [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `-f`, `--force` | Skip confirmation, and skip the uncommitted/unpushed-work check |

## Details

If no project is specified, detects the current worktree project from a `.workspace-project` marker file in the working directory.

Kills the tmux session, removes the git worktree, and cleans up the tmuxinator config. Prompts for confirmation before proceeding unless `--force` is used.

Only works on worktree-based projects created by `workspace start`. For non-worktree projects, use `workspace stop` instead.

### Unsaved-work check

Before touching anything, `kill` refuses to remove a worktree that has:

- **uncommitted changes** to tracked files (staged or unstaged; untracked files never count), or
- **unpushed commits** — commits reachable from the worktree's HEAD that aren't reachable from any remote-tracking ref, or (if the repo has no remotes) from any other local branch

If git itself can't answer (an error running the check), `kill` also refuses rather than guess. The error names the worktree path, the counts, and the branch. The way out is to commit/push the work, or rerun with `--force`, which skips this check along with the confirmation prompt.

A non-worktree project has nothing to check — `kill` already refuses it for not being a worktree project (see above).

## Examples

```sh
# Kill the current worktree project (auto-detected from cwd)
workspace kill

# Kill a specific worktree project
workspace kill myproject.worktree-PROJ-123

# Force kill without confirmation or the unsaved-work check
workspace kill -f myproject.worktree-PROJ-123
```

## See also

`workspace finish` also removes a worktree, but requires the branch to be clean and fully pushed (no override), and can optionally open a PR first.
