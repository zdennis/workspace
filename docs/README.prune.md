# workspace prune

Remove worktree-backed workspace projects whose associated GitHub PR is closed or merged. Scans all tmuxinator configs and state entries, checks each project's PR via `gh`, and offers bulk removal with a confirmation prompt.

## Usage

```sh
workspace prune [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be removed without making any changes; candidates with unsaved work are reported as skipped, as a real run would |
| `-f, --force` | Skip confirmation, and remove candidates even with unsaved work |
| `--name NAME` | Prune only this workspace; repeatable. Without `--json`, a name that is no candidate is a `not_prunable` error |
| `--json` | Print one action document of per-candidate rows; skips the confirmation, not the unsaved-work check (see below) |

## Details

For each tmuxinator config and state entry, `prune`:

1. Checks whether the backing directory is a linked git worktree
2. Looks up the branch's PR state via `gh pr view`
3. Marks the project eligible if the PR is **CLOSED** or **MERGED**
4. Also marks projects eligible if their backing directory no longer exists on disk

On confirmation, for each eligible project, in this order:
- Checks again for unsaved work (see below), right before removing anything
- Removes the git worktree (`git worktree remove --force`, so untracked files go with it)
- Removes the tmuxinator config (`~/.config/tmuxinator/workspace.<name>.yml`)
- Removes the project settings file (`~/.config/workspace/projects/<name>.yml`)
- Removes the state entry and kills any live tmux session, last

Requires the `gh` CLI to be installed and authenticated. If `gh` is unavailable, worktree projects are skipped with a warning. Directory-gone projects are always eligible regardless of `gh` availability.

### Unsaved-work check

Same check as `workspace kill`: a candidate with uncommitted changes to tracked files (untracked files don't count) or unpushed commits is **skipped**, not removed — one line is printed per skipped project naming the counts and branch. The check runs immediately before that candidate's worktree is removed, so an edit made while you answered the prompt still counts. A skipped candidate is left exactly as it was: its session keeps running and its config and state entry stay. The rest of the run keeps going regardless. `--force` removes those anyway, in addition to skipping the confirmation prompt.

If git can't answer the check for a candidate, it's skipped the same way (reported as such) rather than guessed about. If git refuses to remove a worktree (it's locked, for example), that candidate is skipped with git's message and the rest are still pruned. The final line counts every skipped candidate: `Pruned N project(s). Skipped M: a, b.`

## Exit status

`prune` exits 0 only if every eligible candidate was removed. If any candidate was skipped (unsaved work, or git refused to remove it), `prune` finishes processing and reporting the rest, saves state, then exits 1 — commit/push the skipped candidates' work and rerun, or rerun with `--force`.

## Examples

```sh
# See what would be pruned without changing anything
workspace prune --dry-run

# Prune with confirmation prompt
workspace prune

# Prune without prompting, and remove candidates with unsaved work too
workspace prune --force
```

## JSON output

`prune --json` prints one action document on stdout (see [JSON output](README.json.md#actions)); the scan text goes to stderr. It removes every selected worktree without asking (narrow with `--name`, or preview with `--dry-run`), but the unsaved-work check still runs: only `--force` skips it. `--name=WS` (repeatable) limits the run to those workspaces; the other candidates come back as `not_selected` and are untouched. Capability `prune_safe` revision 2.

```json
{"schema_version":1,"ok":true,"action":"prune","status":"partial",
 "results":[
  {"name":"feat-a","branch":"feat-a","reason":"merged","outcome":"removed","error":null,"message":null,"pr_number":12,"pr_url":"https://github.com/o/r/pull/12"},
  {"name":"feat-b","branch":"feat-b","reason":"closed","outcome":"skipped_unsaved","error":"unsaved_work","message":"Skipped feat-b: 2 changed file(s) ...","pr_number":13,"pr_url":"..."}],
 "warnings":[],"summary":{"removed":1,"skipped_unsaved":1}}
```

- One row per candidate: `name`, `branch` (null when the directory is gone), `reason` (`merged`, `closed` or `directory_gone`), `outcome`, `error` (a fixed code, or null), `message`, `pr_number` and `pr_url`.
- `outcome` is `removed`, `skipped_unsaved` (`error` is `unsaved_work` or `unsaved_unknown`), `failed` (`error` is `prune_remove_failed` when git refused, or `not_prunable` for a `--name` that is no candidate; that row has a null `branch` and `reason`), or `not_selected`. With `--dry-run` nothing changes, but the unsaved-work check runs as a real run would run it: a selected row is `would_remove`, or `skipped_unsaved` (same `error`) when a real run would skip it; `--force` skips the check. `status` is `dry_run` and the exit is 0 whichever rows are skipped.
- `status` counts the selected rows only: `ok` when all were removed, `partial` when some were removed and some skipped or failed, `failed` when none were. A run with no candidates is `ok` with no rows.
- Exit status: 0 for `ok` and `dry_run`, 3 for `partial`, 1 for `failed`.
