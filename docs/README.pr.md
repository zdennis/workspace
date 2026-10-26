# workspace pr

Open a pull request for a workspace's branch without finishing the workspace. [`finish --pr`](README.finish.md) also opens one, but it then removes the worktree; `pr create` leaves everything where it is.

## Usage

```sh
workspace pr create [--name WORKSPACE] [--draft] [--json]
```

Run it inside a workspace, or name one with `--name`.

## Options

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | The workspace (default: the one the current directory is in) |
| `--draft` | Open the pull request as a draft. Ignored when the branch already has a pull request |
| `--json` | Print one JSON document |

## Details

In order:

1. If the branch already has a pull request (`gh pr view`, any state), it is returned with outcome `existing`, and nothing is pushed or created.
2. If the branch has no commits ahead of its base, `pr create` stops with `nothing_to_push`. The base is `origin/HEAD`, else the first of `origin/main`, `main`, `origin/master`, `master` that exists; with none of them, this check is skipped.
3. If the branch has no upstream, it is pushed with `git push -u origin <branch>` (within 120 seconds).
4. `gh pr create --fill` runs (within 60 seconds) with outcome `created`.

If the push works and `gh pr create` then fails, the branch stays pushed; running `pr create` again is safe, because it looks for the pull request first. An existing pull request can be open, closed or merged; the document does not say which. If the look-up itself fails for a reason other than a missing login, `pr create` goes on to push and create, and `gh` refuses if the pull request exists after all.

A branch that already has an upstream is not pushed: commits made since the last push are not on the remote, so push them first. A detached HEAD is refused. `gh` and `git` are told not to ask questions, so a missing login is an error, not a prompt.

Plain output is `Created pull request: URL` or `Pull request already exists: URL`, preceded by `Pushed BRANCH to origin.` when it pushed. Under `--json` that line is not printed, so stdout holds the one document.

`workspace` adds nothing to the pull request: the title and body come from `gh pr create --fill`.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).

## Errors

| Code | When |
|------|------|
| `gh_unavailable` | `gh` is not installed (`details.reason` `missing`) or is not logged in (`not_logged_in`, with `details.detail`, the first line `gh` printed) |
| `nothing_to_push` | The branch has no commits ahead of its base. `details.branch`, `details.base` |
| `not_in_workspace` | No `--name` and the current directory is in no workspace |
| `unknown_workspace` | `--name` names no workspace |
| `no_remote`, `push_auth_failed`, `protected_branch`, `push_rejected`, `push_network`, `push_timeout`, `push_failed` | The push `git` refused or did not finish; `push_network` is temporary (run the same command again), `push_timeout` may have landed. `details.permanent` says which. See [README.json.md](README.json.md) |
| `error` | A detached HEAD, or a `gh pr create` that failed or did not answer in time. The message has the tool's first line |

## JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","outcome":"created","url":"https://github.com/o/r/pull/41","number":41}
```

| Field | Meaning |
|-------|---------|
| `workspace` | The workspace the branch belongs to |
| `outcome` | `created` or `existing` |
| `url` | The pull request's URL |
| `number` | Its number, or `null` when the URL does not end in `/pull/N` |

Capability: `pr_create` 1 in [`capabilities`](README.capabilities.md). `finish --json` also gains `pr_url`.

## Examples

```sh
workspace pr create
workspace pr create --draft --json
workspace pr create --name api.worktree-PROJ-123
```
