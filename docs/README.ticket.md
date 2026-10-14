# workspace ticket

Look up a ticket the way [`start`](README.start.md) reads its argument, without starting anything. A person or an app can show the title and body first, and see whether a workspace for the ticket already exists.

## Usage

```sh
workspace ticket show REF [--name WORKSPACE] [--json]
```

`REF` is anything `start` takes: a JIRA key (`PROJ-123`) or URL, a pull request URL or ref (`#41`, `owner/repo#41`), a GitHub issue URL, or a branch name. Run it in a project's checkout, or name one with `--name`.

## Options

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | Look in this workspace's project instead of the one detected from the current directory. A linked worktree's workspace names its parent project |
| `--json` | Print one JSON document |

## Details

The command reads and writes nothing in the repository: no worktree, branch, config file or task, and no `git fetch`. The title and body come from one tool:

| Kind | Tool | Command |
|------|------|---------|
| `github_pr` | `gh` | `gh pr view N [--repo OWNER/REPO] --json title,body,url` |
| `github_issue` | `gh` | `gh issue view N [--repo OWNER/REPO] --json title,body,url` |
| `jira` | `jira` ([jira-cli](https://github.com/ankitpokhrel/jira-cli)) | `jira issue view KEY --raw` |
| `branch` | none | Nothing runs; `title`, `body` and `url` are `null` |

With no repository in the ref, `gh` uses the repository of the checkout. Each tool answers within 10 seconds, and keeps its own sign-in; `workspace` never reads, stores or prints a credential. The body is cut to 64 KB. A JIRA description in Atlassian's rich-text form is turned into plain text.

`branch` is the branch `start` would work on: the JIRA key, `pr-41` for a pull request, `issue-42` for an issue, or the branch name. `workspace` is the workspace `start` would reuse, found the way `start` finds it: a worktree at `.worktrees/<branch>`, else a worktree that holds the branch anywhere. It is `null` when there is none, and when the branch is only checked out in the main checkout.

Plain output is the key and title, the URL, a `Workspace: ... (already exists)` line when there is one, and the body.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`). Without `--json`, nothing is printed on stdout when it fails; with `--json` the envelope is the only stdout.

## Errors

| Code | When |
|------|------|
| `ticket_not_found` | The tool says no ticket has that key, number or URL. `details.source` (`gh` or `jira`), `details.ref` |
| `ticket_source_unavailable` | The tool is not installed, did not answer in time, or failed (for example, it is not signed in). `details.source`, `details.reason` (`missing`, `timeout` or `error`), and for `error`, `details.detail`, the tool's first line. A branch never raises it |
| `unknown_workspace` | `--name` names no workspace |

## JSON output

```json
{"schema_version":1,"ok":true,"ref":"PROJ-123","kind":"jira","key":"PROJ-123","title":"Fix the login redirect","body":"After signing in ...","url":"https://acme.atlassian.net/browse/PROJ-123","branch":"PROJ-123","workspace":"api.worktree-PROJ-123"}
```

| Field | Meaning |
|-------|---------|
| `ref` | The argument as given |
| `kind` | `jira`, `github_issue`, `github_pr` or `branch` |
| `key` | The ticket's own name: the JIRA key, `owner/repo#41` (`#41` when the ref names no repository), or the branch |
| `title`, `body`, `url` | From the tool; `null` for a branch, and when the tool has none. `body` is at most 64 KB |
| `branch` | The branch `start` works on |
| `workspace` | The workspace that already exists for `branch`, or `null` |

Capability: `ticket` 1 in [`capabilities`](README.capabilities.md).

## Examples

```sh
workspace ticket show PROJ-123
workspace ticket show https://github.com/acme/api/pull/41 --json
workspace ticket show feature/login --name api
```
