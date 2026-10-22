# workspace ticket

Look up a ticket the way [`start`](README.start.md) reads its argument, without starting anything, or list the tickets worth starting. A person or an app can show the title and body first, and see whether a workspace for the ticket already exists.

## Usage

```sh
workspace ticket show REF [--name WORKSPACE] [--json]
workspace ticket list [--assigned | --recent] [--source gh|jira] [--limit N] [--name WORKSPACE] [--json]
```

`REF` is anything `start` takes: a JIRA key (`PROJ-123`) or URL, a pull request URL or ref (`#41`, `owner/repo#41`), a GitHub issue URL, or a branch name. Run it in a project's checkout, or name one with `--name`. With no `--name`, the workspace detected from the current directory (its marker, or a running workspace's checkout) picks the project; outside any workspace, the git repository the current directory is in does.

## Options

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | Look in this workspace's project instead of the one detected from the current directory. A linked worktree's workspace names its parent project |
| `--json` | Print one JSON document |
| `--assigned` | `list` only: open tickets assigned to you. The default |
| `--recent` | `list` only: open tickets changed lately, whoever they are assigned to |
| `--source SOURCE` | `list` only: ask only `gh` or `jira`; repeatable. Default both |
| `--limit N` | `list` only: at most `N` tickets, 1 to 100. Default 20 |

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

Capability: `ticket` 1 in [`capabilities`](README.capabilities.md) is `ticket show`; revision 2 adds `ticket list` and `start --title-from-ticket` and `--slug`.

## ticket list

`list` offers tickets to pick from, newest change first. It reads and writes nothing, like `show`. Three reads run at the same time, each as `show` runs its tool (10 seconds, no prompt, the tool's own sign-in):

| Source | `--assigned` | `--recent` |
|--------|--------------|------------|
| `gh` issues | `gh issue list --state open --assignee @me` | `gh issue list --state open --search sort:updated-desc` |
| `gh` pull requests | `gh pr list --state open --assignee @me` | `gh pr list --state open --search sort:updated-desc` |
| `jira` | `jira issue list -q "assignee = currentUser() AND resolution = Unresolved" --order-by updated --raw` | `jira issue list -q "updated >= -14d" --order-by updated --raw` |

Each is asked for `--limit` rows; the merged rows are sorted by `updated_at`, newest first, and cut to `--limit`. The cut is across all sources, so one busy source can fill the list; use `--source` to ask one. `gh` uses the repository of the checkout, so a project with no GitHub remote, or a repository with issues turned off, gets a `gh` warning (the pull request half still answers). `jira` runs the query in jira-cli's configured project; with none configured, it is a `jira` warning.

A tool that is not installed, did not answer in time or failed (for example, it is not signed in) is a warning in `warnings`, never an error: the other sources still answer, and the exit status is 0. With no `--json`, a warning goes to stderr as `Warning: ...`, and stdout lists `KEY  state  title` (`(pull request)` after a pull request's key), with `[workspace: NAME]` when one exists.

```json
{"schema_version":1,"ok":true,"filter":"assigned","limit":20,"tickets":[{"ref":"PROJ-123","kind":"jira","key":"PROJ-123","title":"Fix the login redirect","url":"https://acme.atlassian.net/browse/PROJ-123","source":"jira","state":"In Progress","updated_at":"2026-10-17T09:12:00.000+0000","branch":"PROJ-123","slug_branch":"PROJ-123-fix-the-login-redirect","workspace":"api.worktree-proj-123"}],"warnings":[{"source":"gh","code":"ticket_source_unavailable","reason":"missing","message":"`gh` is not installed."}]}
```

| Field | Meaning |
|-------|---------|
| `filter`, `limit` | What was asked |
| `tickets[]` | A row per ticket; the same fields as `show` without `body`, plus `source`, `state`, `updated_at` and `slug_branch` |
| `ref` | Pass it to `start` or `show`: a JIRA key, or the URL of a GitHub issue or pull request |
| `kind`, `key`, `title`, `url`, `branch` | As in `show`. `title` is one line of plain text, `null` if the tool gave none |
| `source` | The tool that answered: `gh` or `jira` |
| `state` | `gh`: `open` (lowercase). `jira`: the status name as JIRA spells it |
| `updated_at` | When the tool says the ticket last changed, in its own format (`gh` UTC, `jira` with an offset); `null` if it says nothing |
| `slug_branch` | The branch `start --slug` would make from the title; equal to `branch` for a pull request |
| `workspace` | The workspace that already exists for the ticket, found by `slug_branch`, `branch`, or any worktree branch that starts `<branch>-`; else `null` |
| `warnings[]` | One per source that failed: `source`, `code` (`ticket_source_unavailable`), `reason` (`missing`, `timeout` or `error`), `detail` (for `error`), `message`. An empty array when every source answered |

Usage errors (exit 1, a `usage` code under `--json`): `--limit` outside 1 to 100, an unknown `--source`, or a list option given to `show`. `unknown_workspace` for a bad `--name`.

## Examples

```sh
workspace ticket show PROJ-123
workspace ticket show https://github.com/acme/api/pull/41 --json
workspace ticket show feature/login --name api
workspace ticket list --json
workspace ticket list --recent --source=gh --limit=10
```
