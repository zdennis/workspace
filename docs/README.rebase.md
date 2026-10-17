# workspace rebase and workspace push

`rebase` puts a workspace's branch on top of the repository's default branch. `push` sends the branch to origin afterwards, forcing only when the rebase is what made the push need it. Both work on one workspace and leave every other checkout alone, except that `rebase --onto update` can move the default branch (see below).

## Usage

```sh
workspace rebase --onto local|update|remote|upstream [--name WORKSPACE] [--json]
workspace push [--name WORKSPACE] [--json]
```

Run them inside a workspace, or name one with `--name`. A detached HEAD is refused.

## rebase

| Option | Description |
|--------|-------------|
| `--onto TARGET` | Required. `local`, `update`, `remote` or `upstream` |
| `--name WORKSPACE` | The workspace (default: the one the current directory is in) |
| `--json` | Print one JSON document |

The default branch is what `origin/HEAD` points at, else `main`, else `master`. A workspace that is on the default branch is refused.

| `--onto` | What happens |
|----------|--------------|
| `local` | Rebases onto the local default branch. Nothing is fetched |
| `update` | Fetches origin, then moves the local default branch up to `origin/<default>`, then rebases onto it. If the checkout that has the default branch checked out has changes to tracked files, they are stashed first and restored after (untracked files are never touched). A default branch that is not checked out anywhere is moved directly |
| `remote` | Fetches origin and rebases onto `origin/<default>`; the local default branch is not touched |
| `upstream` | Fetches the branch's own upstream (usually `origin/<branch>`) and rebases onto it. Allowed on the default branch (main onto `origin/main`), which the other targets refuse. Refused with `no_upstream` when the branch has no upstream and `upstream_gone` when its upstream was deleted on the remote |

Before anything else, `rebase` refuses a workspace that has a rebase already stopped in it (`rebase_in_progress`) and a workspace with staged or unstaged changes to tracked files (`dirty_worktree`). It never stashes the workspace's own changes. Untracked files do not count.

If the branch already contains the target, the outcome is `up_to_date` and nothing changes. If the rebase stops on a conflict, `rebase` lists the conflicted files, runs `git rebase --abort`, and reports `conflict` with `aborted: true`: the workspace is back as it was. If git runs past its time limit during the rebase, the rebase is aborted too and the error (code `error`) says so, with `details.aborted: true`: the branch is unchanged. If that abort fails, the error is `rebase_in_progress` with `details.aborted: false` and `details.path`, and its message says to run `git rebase --abort` there. If the abort of a conflicted rebase fails, `aborted` is `false` and the rebase is still stopped. In `update`, when the local default branch and origin's each have commits the other lacks, or the stash does not apply back, nothing is rebased and the outcome is `default_not_updated` (`reason` `diverged` or `stash_pop`; with `stash_pop` the default branch was moved and the changes stay in the stash).

Exit 0 for every outcome, `conflict` and `default_not_updated` included: read `outcome`. Exit 1 with an error for the cases under Errors. Plain output is one sentence, plus the conflicted files, one per line.

### JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","branch":"feature/x","onto":"local","outcome":"rebased","reason":null,"aborted":null,"conflicted":[],"detail":null}
```

| Field | Meaning |
|-------|---------|
| `outcome` | `rebased`, `up_to_date`, `conflict` or `default_not_updated` |
| `reason` | `conflict` (with `conflict`), `diverged` or `stash_pop` (with `default_not_updated`), else `null` |
| `aborted` | `true` when a conflicted rebase was aborted, `false` when the abort failed, else `null` |
| `conflicted` | The conflicted paths; empty unless `conflict` |
| `detail` | The first line git printed, or the explanation of a `default_not_updated`; else `null` |

## push

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | The workspace (default: the one the current directory is in) |
| `--json` | Print one JSON document |

In order:

1. A branch with no upstream is pushed with `git push -u origin <branch>`.
2. Otherwise origin is fetched, and the branch is compared with its upstream. Same commit: `up_to_date`, nothing pushed. Only the branch has new commits: a plain push.
3. If the upstream has commits the branch lacks, `push` looks at the branch's reflog. When every one of those commits was once on the branch (a rebase replaced them), the push is `--force-with-lease`, and `forced` is `true`. When one of them was never on the branch (someone else pushed it), nothing is pushed and the error is `push_rejected`.

A branch whose upstream is not `origin/<branch>` is refused (`push_rejected`). A branch that is only behind its upstream (no commits of its own) is never forced, since that would delete the upstream's commits. Pushes go to `origin`, with the branch's own name; each git call has a time limit and never prompts. If origin refuses a push, the error is `push_rejected`; any other push failure is an uncoded `error`. A branch whose reflog has expired is treated as having commits it never had, so it is refused rather than forced.

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","branch":"feature/x","outcome":"pushed","forced":false}
```

| Field | Meaning |
|-------|---------|
| `outcome` | `pushed` or `up_to_date` |
| `forced` | `true` when the push used `--force-with-lease` |

`pr create` pushes through the same code, with `-u`.

## Errors

| Code | When |
|------|------|
| `dirty_worktree` | `rebase`: tracked files have changes. `details.path`, `details.files` |
| `rebase_in_progress` | `rebase`: a rebase is already stopped in the workspace, or git ran past its time limit mid-rebase and the abort failed (`details.aborted` `false`). `details.path` |
| `no_upstream` | `rebase --onto upstream`: the branch has no upstream configured. `details.branch` |
| `upstream_gone` | `rebase --onto upstream`: the upstream no longer exists on the remote. `details.branch`, `details.upstream` |
| `fetch_failed` | `rebase --onto update\|remote\|upstream` or `push`: `git fetch origin` failed. `details.remote`, `details.detail` |
| `push_rejected` | `push`: refused. `details.branch`, `details.upstream`, `details.detail`, `details.reason`: `origin_refused` (origin said no), `would_delete_commits` (the branch is only behind its upstream, so pushing would delete commits), `upstream_has_other_commits` (the upstream has commits the branch never had, or its reflog no longer shows them) or `upstream_mismatch` (the upstream is not `origin/<branch>`). |
| `not_in_workspace` | No `--name` and the current directory is in no workspace |
| `unknown_workspace` | `--name` names no workspace |
| `usage` | `--onto` is missing or not `local`, `update`, `remote` or `upstream` |
| `error` | A detached HEAD, no default branch, a rebase that failed without stopping, `git` missing, or a git call past its time limit (during a rebase, `details.aborted` is `true`) |

Capability: `rebase` 2 (1 had `local`, `update` and `remote`; 2 adds `upstream`) in [`capabilities`](README.capabilities.md) (covers both commands).

## Examples

```sh
workspace rebase --onto update
workspace push
workspace rebase --onto remote --name api.worktree-PROJ-123 --json
```
