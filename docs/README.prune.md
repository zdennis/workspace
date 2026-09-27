# workspace prune

Remove worktree-backed workspace projects whose associated GitHub PR is closed or merged. Scans all tmuxinator configs and state entries, checks each project's PR via `gh`, and offers bulk removal with a confirmation prompt.

## Usage

```sh
workspace prune [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be removed without making any changes |
| `-f, --force` | Skip confirmation, and remove candidates even with unsaved work |

## Details

For each tmuxinator config and state entry, `prune`:

1. Checks whether the backing directory is a linked git worktree
2. Looks up the branch's PR state via `gh pr view`
3. Marks the project eligible if the PR is **CLOSED** or **MERGED**
4. Also marks projects eligible if their backing directory no longer exists on disk

On confirmation, for each eligible project:
- Kills any live iTerm/tmux session
- Removes the git worktree (`git worktree remove --force`)
- Removes the tmuxinator config (`~/.config/tmuxinator/workspace.<name>.yml`)
- Removes the project settings file (`~/.config/workspace/projects/<name>.yml`)
- Removes the state entry

Requires the `gh` CLI to be installed and authenticated. If `gh` is unavailable, worktree projects are skipped with a warning. Directory-gone projects are always eligible regardless of `gh` availability.

### Unsaved-work check

Same check as `workspace kill`: a candidate with uncommitted changes to tracked files (untracked files don't count) or unpushed commits is **skipped**, not removed — one line is printed per skipped project naming the counts and branch. The rest of the run keeps going, and `prune` still exits 0. `--force` removes those anyway, in addition to skipping the confirmation prompt.

If git can't answer the check for a candidate, it's skipped the same way (reported as such) rather than guessed about.

## Examples

```sh
# See what would be pruned without changing anything
workspace prune --dry-run

# Prune with confirmation prompt
workspace prune

# Prune without prompting, and remove candidates with unsaved work too
workspace prune --force
```
