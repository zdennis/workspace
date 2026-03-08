# workspace stop

Kill a worktree project's session and remove its git worktree. The inverse of `workspace start`.

## Usage

```sh
workspace stop [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `-f`, `--force` | Skip confirmation and force worktree removal |

## Details

If no project is specified, detects the current worktree project from a `.workspace-project` marker file in the working directory.

Kills the tmux session, removes the git worktree, and cleans up the tmuxinator config. Prompts for confirmation before proceeding unless `--force` is used.

Only works on worktree-based projects created by `workspace start`. For non-worktree projects, use `workspace kill` instead.

## Examples

```sh
# Stop the current worktree project (auto-detected from cwd)
workspace stop

# Stop a specific worktree project
workspace stop myproject.worktree-PROJ-123

# Force stop without confirmation
workspace stop -f myproject.worktree-PROJ-123
```
