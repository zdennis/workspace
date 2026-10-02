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

Removes the git worktree, cleans up the tmuxinator config, project settings and state entry, then kills the tmux session. Prompts for confirmation before proceeding unless `--force` is used.

### Order of steps

1. Check for unsaved work (skipped with `--force`).
2. Ask for confirmation (skipped with `--force`).
3. Check for unsaved work again, then remove the worktree with `git worktree remove --force`, so untracked files go with it. An edit made while the prompt waited is refused here, not deleted.
4. Run the `post_kill` hook.
5. Remove the tmuxinator config and project settings.
6. Remove the state entry, then kill the tmux session.

The session is killed last because `kill` often runs inside that session, and killing it ends the `kill` process. Everything that has to be written is done by then. For the same reason, the `post_kill` hook runs before the session is killed, not after. It still sees the project's settings, but the worktree directory is already gone, so it runs in the directory you ran `kill` from.

Only works on worktree-based projects created by `workspace start`. For non-worktree projects, use `workspace stop` instead.

### Unsaved-work check

Before touching anything, `kill` refuses to remove a worktree that has:

- **uncommitted changes** to tracked files (staged or unstaged; untracked files never count), or
- **unpushed commits** — commits reachable from the worktree's HEAD that aren't reachable from any remote-tracking ref, or (if the repo has no remotes) from any other local branch

If git itself can't answer (an error running the check), `kill` also refuses rather than guess. The error names the worktree path, the counts, and the branch. The check runs before the prompt and again right before the removal; if the second check refuses, nothing has been removed. The way out is to commit/push the work, or rerun with `--force`, which skips this check along with the confirmation prompt.

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

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row: `killed`, or `cancelled` (status `cancelled`, exit 0) when the confirmation was declined. A refusal is the failure envelope with `code` `unsaved_work` and `retry.flags` `["--force"]`. Run it from outside the session being killed, which ends last.
