# workspace finish

Verify a worktree project is clean and fully pushed, then remove it the same way `workspace kill` does. A local counterpart to a merge-and-cleanup workflow, for agents that shouldn't depend on `gh` being configured.

## Usage

```sh
workspace finish [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WS` | The worktree workspace to finish, the same as the positional `project` (giving both with different values is a usage error) |
| `--pr` | Open a PR with `gh pr create --fill` (or reuse an existing one) before cleanup |
| `--json` | Emit the JSON schema below instead of plain text |

There is no `--force`/override for the clean-and-pushed check — see "Details".

## Details

With no project (positionally or with `--name`), `finish` acts on the workspace the working directory is in: a worktree's `.workspace-project` marker, else the active workspace whose root holds the directory, the same way `kill` does. Outside any workspace it refuses with `not_in_workspace` and removes nothing.

Before touching anything, `finish` checks:

1. **Clean** — no uncommitted changes to tracked files (`git status --porcelain --untracked-files=no`); untracked files never block it.
2. **On a branch, with an upstream** — the worktree must have a branch checked out (a detached HEAD is refused, with a hint to check out a branch first), and the branch must be tracking a remote branch. Without one, `finish` refuses with a hint: `git push -u origin <branch>`.
3. **Not ahead of its upstream** — if HEAD has commits the upstream doesn't, `finish` refuses with a hint: `git push`.

If git can't answer one of these checks, `finish` refuses rather than guess. There's no flag to skip this — if you want to discard work, use `workspace kill --force` instead.

`finish` checks against the upstream branch as it was last fetched; it doesn't fetch first. If a teammate pushed to the same branch since your last fetch, run `git fetch` before `finish` to get an accurate check.

`finish` removes the worktree through `kill` and archives the workspace's [task](README.start.md#tasks) with outcome `merged` only when the branch's commits are already on the default branch, else `pushed`. This is the same check `goal show` uses, read from local refs only (`finish` does no fetch for it). With an `origin` remote, the default branch is `origin/HEAD`, else `origin/main`, else `origin/master`; with no `origin` remote, it is local `main` or `master`. `merged` means the commits are on that branch, so a squash or rebase merge, which leaves them off it, reads `pushed`. A few edge cases follow from this:

- A branch with no commits of its own reads `merged`.
- A repo whose default branch is neither `main` nor `master` and has no `origin/HEAD`, or whose origin's default branch was never fetched, reads `pushed`.
- A repo with no `origin` remote reads `merged` when the branch is on local `main` or `master` (earlier versions always read `pushed` there). `finish` requires an upstream, so the only ways to reach this case are an upstream on another remote or a local branch.

The same outcome goes in the `worktree_finished` event and the `--json` document. A PR found or created by `--pr` does not change it; the URL is `pr_url`.

With `--pr`, `finish` looks for an existing PR for the branch (`gh pr view`) and prints its URL if found, or opens one (`gh pr create --fill`) otherwise. This is the same step [`pr create`](README.pr.md) runs, without its push or its check for commits: `finish` has already required the branch to be pushed. If `gh` isn't installed, this step is skipped with a one-line note and `finish` keeps going. If `gh` fails (not authenticated, no fill-able commits, etc.), `finish` reports the error and stops — the worktree is *not* removed.

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
{"schema_version": 1, "ok": true, "project": "myproject.worktree-PROJ-123", "outcome": "pushed", "pr_url": null}
```

Error (nothing was removed):

```json
{"schema_version": 1, "ok": false, "error": "'myproject.worktree-PROJ-123' has 2 changed file(s) at /path/to/worktree.\nCommit or stash them before finishing.", "code": "unsaved_work"}
```

- `outcome` is `merged` (the branch's commits are on the default branch) or `pushed` (clean and pushed, not known to be merged).
- `schema_version` is bumped only on a breaking change to this shape.
- `notes_inside_worktree` and `warnings` are present only when the workspace's notes directory was inside the worktree and held files, which finishing deleted: `{"schema_version": 1, "ok": true, "project": "…", "notes_inside_worktree": {"dir": "/abs/tmp/workspace-notes", "files": 3}, "warnings": ["The notes directory /abs/tmp/workspace-notes holds 3 files and is inside the worktree; removing the worktree deletes them."]}`. `warnings` is a list of sentences. In plain-text mode `finish` prints the same sentence, prefixed `Warning:`, before it removes anything.
- `pr_url` is always present: the URL of the pull request `--pr` found or opened, or `null` without `--pr`, when `gh` is not installed, or when no URL came back.
- `dev_stopped: true` is present only when the worktree held the `devenv` lock and `finish` stopped that dev environment before removing the worktree (as [`kill`](README.kill.md) does); the key is absent otherwise.
- Usage/validation errors (an unknown flag, extra arguments) get the same treatment when `--json` is present: `{"schema_version": 1, "ok": false, "error": "<message>", "code": "<code>"}` on stdout, exit 1 — never plain text on stderr.
- Exit codes: `0` on success, `1` on any error (see above).

## Examples

```sh
# Remove the worktree workspace you are in (session, worktree, config), once it is clean and pushed; the branch is kept
workspace finish

# Open (or reuse) a PR for the branch first, then remove the workspace
workspace finish --pr

# Finish a named worktree workspace, from anywhere
workspace finish --name myproject.worktree-PROJ-123

# The same, scripted
workspace finish myproject.worktree-PROJ-123 --json
```

## See also

[`workspace pr create`](README.pr.md) opens a pull request and keeps the workspace. `workspace kill` removes a worktree unconditionally (with an unsaved-work check that `--force` can skip); `finish` never skips its clean/pushed check.
