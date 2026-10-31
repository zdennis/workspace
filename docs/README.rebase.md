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
3. If the upstream has commits the branch lacks, `push` looks at the branch's reflog. When every one of those commits was once on the branch (a rebase replaced them), the push is `--force-with-lease=refs/heads/<branch>:<sha>`, naming the upstream commit it compared, so a fetch in between can't widen the lease; `forced` is `true`. When one of them was never on the branch (someone else pushed it), nothing is pushed and the error is `push_rejected`.

A branch whose upstream is not `origin/<branch>` is refused (`push_rejected`), except a pull request checkout (below). A branch that is only behind its upstream (no commits of its own) is never forced, since that would delete the upstream's commits. Pushes go to `origin`, with the branch's own name (a pull request checkout's go to its head branch); each git call has a time limit and never prompts. If the remote says non-fast-forward, the error is `push_rejected`; other failures are `no_remote`, `push_auth_failed`, `protected_branch`, `push_network` (temporary, with a `retry`), `push_timeout` (the push ran past 120 seconds and may have landed; no `retry`) or `push_failed` (see [README.json.md](README.json.md)). Every push error has `details.permanent`. `git push` runs with `LC_ALL=C` so its messages can be classified. A branch whose reflog has expired is treated as having commits it never had, so it is refused rather than forced.

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","branch":"feature/x","remote_branch":"feature/x","outcome":"pushed","forced":false}
```

| Field | Meaning |
|-------|---------|
| `remote_branch` | The branch on origin: `branch`, or a pull request checkout's head branch |
| `outcome` | `pushed` or `up_to_date` |
| `forced` | `true` when the push used `--force-with-lease` |

The text output names the head branch for a pull request checkout: `Pushed pr-123 to origin/fix/thing (pull request #123).`

`pr create` pushes through the same code, with `-u`.

### Pull request checkouts

`start '#123'` checks a pull request out as the local branch `pr-123`, tracking `origin/<head>`, the pull request's own branch. `push` sends such a branch to `<head>` (`git push origin pr-123:refs/heads/<head>`) only when the local branch is named `pr-<number>`, its upstream is `<head>` on `origin`, and every check below passes, before anything is pushed:

1. `<head>` is not the default branch (what `origin/HEAD` points at, else `main` or `master`).
2. origin's fetch URL and every push URL name the same repository (`HOST/OWNER/NAME`, in https, `ssh://` or `git@host:` form).
3. `gh pr view <number> --repo HOST/OWNER/NAME` says the pull request is open, is not from a fork, has `<head>` as its head branch, and has origin's owner and name as its head repository.
4. After the fetch, `origin/<head>` is the head commit `gh` reported.

Then the usual rules apply: a plain push when only the branch has new commits, and after a rebase a push with `--force-with-lease=refs/heads/<head>:<sha>` on the head commit `gh` reported. Any other branch with a mismatched upstream is refused as before, with no `gh` call.

A refusal is `push_rejected` with `details.reason` `upstream_mismatch` and `details.pr_check`, one of:

| `pr_check` | Why |
|------------|-----|
| `gh_missing` | `gh` is not installed |
| `not_logged_in` | `gh` is not logged in; `details.detail` is gh's first line |
| `gh_failed` | `gh` failed, ran past 10 seconds (`details.timed_out` `true`, with a `retry`: run the same command again), or gave no usable head commit; `details.detail` is gh's first line |
| `pr_closed` | The pull request is closed or merged |
| `cross_repository` | The pull request comes from a fork |
| `head_mismatch` | Its head branch is not the branch the checkout tracks |
| `repo_mismatch` | Its head repository is not origin, or origin's URLs don't all name one repository `push` can read |
| `sha_mismatch` | `origin/<head>` after the fetch is not the head commit `gh` reported |
| `default_branch` | The tracked branch is the default branch |

`gh_missing`, `not_logged_in` and `gh_failed` have `details.permanent` `false`: install or log in to `gh`, or try again. The others are `true`. `details.timed_out` is present only with `gh_failed`.

origin's URL must be `https://HOST/OWNER/NAME`, `ssh://[user@]HOST/OWNER/NAME` or `[user@]HOST:OWNER/NAME` (`.git` optional), because `HOST` is passed to `gh` as the pull request's host. An SSH host alias from `~/.ssh/config` (`git@github-work:acme/api.git`) or a URL with a port (`ssh://git@ssh.github.com:443/acme/api.git`) doesn't name a host `gh` knows, so it is refused as `repo_mismatch`; push the branch by hand with `git push origin pr-123:<head>`.

The default branch is what `origin/HEAD` points at, else `main` or `master`. In a clone whose `origin/HEAD` is not set and whose default branch has another name (`develop`), a pull request whose head is that branch is not caught by `default_branch`; run `git remote set-head origin --auto` to set it.

Pull requests from forks are left out: `start` drops their upstream, so `push` sends `pr-123` with `-u` to a new `origin/pr-123`, as for any branch with no upstream, without asking `gh`. The same goes for any `pr-N` branch with no upstream. A clone whose origin is your own fork is out of scope too: the pull request lives on the upstream repository, not origin, so `push` can't confirm it through origin. Push such a branch by hand with `git push origin pr-123:<head>`.

Every push names the local branch in full (`refs/heads/<branch>:refs/heads/<dest>`), so a branch named like `+x` is never read as a forced refspec, and a tag with the branch's name is never sent.

## Errors

| Code | When |
|------|------|
| `dirty_worktree` | `rebase`: tracked files have changes. `details.path`, `details.files` |
| `rebase_in_progress` | `rebase`: a rebase is already stopped in the workspace, or git ran past its time limit mid-rebase and the abort failed (`details.aborted` `false`). `details.path` |
| `no_upstream` | `rebase --onto upstream`: the branch has no upstream configured. `details.branch` |
| `upstream_gone` | `rebase --onto upstream`: the upstream no longer exists on the remote. `details.branch`, `details.upstream` |
| `fetch_failed` | `rebase --onto update\|remote\|upstream` or `push`: `git fetch origin` failed. `details.remote`, `details.detail` |
| `push_rejected` | `push`: refused. A non-fast-forward from the remote, or the branch is not safe to force. Permanent. Branch protection is `protected_branch`, not this. `details.branch`, `details.upstream`, `details.detail`, `details.permanent`, `details.reason`: `origin_refused` (the remote said non-fast-forward), `would_delete_commits` (the branch is only behind its upstream, so pushing would delete commits), `upstream_has_other_commits` (the upstream has commits the branch never had, or its reflog no longer shows them) or `upstream_mismatch` (the upstream is not `origin/<branch>`, or a pull request checkout did not pass its checks; then `details.pr_check` says which, see [Pull request checkouts](#pull-request-checkouts)). |
| `not_in_workspace` | No `--name` and the current directory is in no workspace |
| `unknown_workspace` | `--name` names no workspace |
| `usage` | `--onto` is missing or not `local`, `update`, `remote` or `upstream` |
| `error` | A detached HEAD, no default branch, a rebase that failed without stopping, `git` missing, or a git call past its time limit (during a rebase, `details.aborted` is `true`) |

Capability: `rebase` 4 (1 had `local`, `update` and `remote`; 2 adds `upstream`; 3 adds the push error codes `no_remote`, `push_auth_failed`, `protected_branch`, `push_network`, `push_timeout`, `push_failed`, `details.permanent` and `retry` on `push_network`; 4: `push` pushes a gh pull request checkout to the pull request's head branch after checking it with gh, leases name the commit they compared, `remote_branch`, `details.pr_check`) in [`capabilities`](README.capabilities.md) (covers both commands).

## Examples

```sh
workspace rebase --onto update                 # catch up with origin's default branch; rewrites the branch's commits
workspace rebase --onto local                  # onto the local default branch, nothing fetched
workspace rebase --onto remote --name api.worktree-PROJ-123 --json   # another workspace, for a script; a conflict still exits 0
workspace rebase --onto upstream               # pick up commits pushed to this branch itself
workspace push                                 # publish the branch to origin, setting its upstream the first time
workspace push --name api.worktree-PROJ-123    # another workspace's branch, without changing directory
workspace push --json                          # after a rebase, for a script: read outcome and forced
```
