# workspace finish

Verify a worktree project is clean and fully pushed, then remove it the same way `workspace kill` does. A local counterpart to a merge-and-cleanup workflow, for agents that shouldn't depend on `gh` being configured.

## Usage

```sh
workspace finish [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--pr` | Open a PR with `gh pr create --fill` (or reuse an existing one) before cleanup |
| `--json` | Emit the JSON schema below instead of plain text |

There is no `--force`/override for the clean-and-pushed check — see "Details".

## Details

If no project is specified, detects the current worktree project from a `.workspace-project` marker file in the working directory, the same way `kill` does.

Before touching anything, `finish` checks:

1. **Clean** — no uncommitted changes to tracked files (`git status --porcelain --untracked-files=no`); untracked files never block it.
2. **On a branch, with an upstream** — the worktree must have a branch checked out (a detached HEAD is refused, with a hint to check out a branch first), and the branch must be tracking a remote branch. Without one, `finish` refuses with a hint: `git push -u origin <branch>`.
3. **Not ahead of its upstream** — if HEAD has commits the upstream doesn't, `finish` refuses with a hint: `git push`.

If git can't answer one of these checks, `finish` refuses rather than guess. There's no flag to skip this — if you want to discard work, use `workspace kill --force` instead.

`finish` checks against the upstream branch as it was last fetched; it doesn't fetch first. If a teammate pushed to the same branch since your last fetch, run `git fetch` before `finish` to get an accurate check.

`finish` removes the worktree through `kill` and archives the workspace's [task](README.start.md#tasks) with outcome `merged`: it has verified the work is clean and pushed, not that it merged.

With `--pr`, `finish` looks for an existing PR for the branch (`gh pr view`) and prints its URL if found, or opens one (`gh pr create --fill`) otherwise. If `gh` isn't installed, this step is skipped with a one-line note and `finish` keeps going. If `gh` fails (not authenticated, no fill-able commits, etc.), `finish` reports the error and stops — the worktree is *not* removed.

Once the checks (and optional PR step) pass, `finish` removes the project the same way `workspace kill` does, without the confirmation prompt but *with* its unsaved-work check (`finish` never uses `--force`). That check runs again right before the worktree is removed, so work committed or edited after the checks above (while the PR step ran, say) is refused rather than deleted. The worktree is then removed with `git worktree remove --force`, so untracked files go with it.

### Running `finish` from inside the session it kills

An agent typically runs `workspace finish` from inside the tmux pane that command is about to tear down. Killing that tmux session can terminate the very process running `finish` (SIGHUP), so order matters: the worktree, tmuxinator config, project settings and state entry are all removed, and the `post_kill` hook runs, *before* the tmux session is killed. Killing the session is the last step, so if it cuts the process off, nothing is left half-done. See "Order of steps" in [README.kill.md](README.kill.md).

Under `--json`, the `post_kill` hook doesn't run, so stdout carries only the JSON line.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Finished (removed) |
| 1 | Not clean/pushed, no config found, `gh` failed, or another error — nothing was removed |

## `--json`

`workspace finish --json` emits one JSON object on stdout instead of plain text.

Success:

```json
{"schema_version": 1, "project": "myproject.worktree-PROJ-123"}
```

Error (nothing was removed):

```json
{"schema_version": 1, "error": "'myproject.worktree-PROJ-123' has 2 changed file(s) at /path/to/worktree.\nCommit or stash them before finishing."}
```

- `schema_version` is bumped only on a breaking change to this shape.
- Usage/validation errors (an unknown flag, extra arguments) get the same treatment when `--json` is present: `{"schema_version": 1, "error": "<message>"}` on stdout, exit 1 — never plain text on stderr.
- Exit codes: `0` on success, `1` on any error (see above).

## Examples

```sh
# Finish the current worktree project (auto-detected from cwd)
workspace finish

# Finish and open a PR first
workspace finish --pr

# Finish a specific project, scripted
workspace finish myproject.worktree-PROJ-123 --json
```

## See also

`workspace kill` removes a worktree unconditionally (with an unsaved-work check that `--force` can skip); `finish` never skips its clean/pushed check.
