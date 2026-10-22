# workspace kill

Kill a worktree project's session and remove its git worktree. The inverse of `workspace start`.

## Usage

```sh
workspace kill [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WS` | The worktree workspace to kill, the same as the positional `project` (giving both with different values is a usage error) |
| `-f`, `--force` | Skip confirmation, and skip the uncommitted/unpushed-work check |

## Details

With no project (positionally or with `--name`), `kill` acts on the workspace the working directory is in: a worktree's `.workspace-project` marker, else the active workspace whose root holds the directory. Outside any workspace it refuses with `not_in_workspace` and removes nothing.

Removes the git worktree, cleans up the tmuxinator config, project settings and state entry, then kills the tmux session. Prompts for confirmation before proceeding unless `--force` is used.

### Order of steps

1. Check for unsaved work (skipped with `--force`).
2. Ask for confirmation (skipped with `--force`).
3. If this worktree holds the `devenv` lock (see [`dev`](README.dev.md)), stop its dev environment as `dev down` does. One that cannot be stopped is reported and the removal goes on.
4. Check for unsaved work again, then remove the worktree with `git worktree remove --force`, so untracked files go with it. An edit made while the prompt waited is refused here, not deleted. Once the worktree is gone, the workspace's [workflow runs](README.workflow.md) are cancelled (`cancelled_by: "kill"`), so none goes on holding a lock (a run whose file is malformed is named in a warning instead, and `kill` goes on), and its [task](README.start.md#tasks) is archived as `abandoned` (`discarded` with `--force`).
5. Run the `post_kill` hook.
6. Remove the tmuxinator config and project settings.
7. Remove the state entry, then kill the tmux session.

The session is killed last because `kill` often runs inside that session, and killing it ends the `kill` process. Everything that has to be written is done by then. For the same reason, the `post_kill` hook runs before the session is killed, not after. It still sees the project's settings, but the worktree directory is already gone, so it runs in the directory you ran `kill` from.

Only works on worktree-based projects created by `workspace start`. For non-worktree projects, use `workspace stop` instead.

### Notes inside the worktree

If the workspace's notes directory (see [`notes`](README.notes.md)) is inside the worktree and holds files, removing the worktree deletes them. `kill` says so before it asks for confirmation: `Warning: The notes directory /path holds 3 files and is inside the worktree; removing the worktree deletes them.` It does not stop: copy the notes out first if you want to keep them. A notes directory outside the worktree is untouched.

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
workspace kill --name myproject.worktree-PROJ-123

# Force kill without confirmation or the unsaved-work check
workspace kill -f myproject.worktree-PROJ-123
```

## See also

`workspace finish` also removes a worktree, but requires the branch to be clean and fully pushed (no override), and can optionally open a PR first.

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row: `killed`, or `cancelled` (status `cancelled`, exit 0) when the confirmation was declined. When the notes directory was inside the worktree and held files, the row also has `"notes_inside_worktree":{"dir":"/abs","files":3}` and `warnings` has the sentence above; the key is absent otherwise. When step 3 stopped a dev environment the row also has `"dev_stopped": true`; the key is absent otherwise. A refusal is the failure envelope with `code` `unsaved_work` and `retry.flags` `["--force"]`; outside any workspace with no project named, `code` is `not_in_workspace`. Run it from outside the session being killed, which ends last.
