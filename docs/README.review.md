# workspace review

Collect what you need to review a coding agent's finished work, for one workspace or for every workspace of a project that is ready.

## Usage

```sh
workspace review [show] [WORKSPACE] [--json]
workspace review list [PROJECT] [--json]
```

A workspace named `list` is reviewed with `workspace review show list`.

## Ready

A workspace is **ready** when its agent is `done` (the Stop hook fired and no agent pane is working or waiting, see [`sessions`](README.sessions.md)) and its branch has commits the base branch lacks. The base is `origin/HEAD`, else the first of `origin/main`, `main`, `origin/master`, `master` that exists.

Open questions (`workspace ask`) don't make a workspace not ready. They are the defaults the agent took while unattended, so they are listed for the reviewer rather than hiding the work.

## Reads only

`review` never writes. It reads the agent daemon's pane states, the task store, git, and the question store; `show` also reads the session ledger, the last assistant message in the transcript, and `gh pr view`. A source that can't answer is reported as unavailable with a reason, never as clean or zero: a daemon that isn't running or is too slow, git failing or running over its 10 second limit, `gh` missing or failing.

## `review list`

Checks every configured, existing checkout of the project: it asks the agent daemon, and runs git only for workspaces whose agent is done. It never calls `gh`. PROJECT is a project name, a member workspace name or a path; it defaults to the project containing the current directory.

```json
{
  "schema_version": 1,
  "ok": true,
  "project": {"name": "app", "id": "/src/app/.git", "path": "/src/app"},
  "reviews": [
    {
      "workspace": "app.worktree-fix",
      "path": "/src/app.worktree-fix",
      "branch": "fix",
      "base": "origin/main",
      "ahead": 2,
      "changed_files": 1,
      "agent": {"state": "done", "stop_reason": "end_turn", "state_since": "2026-10-02T10:00:00Z"},
      "task": {"id": "9f2c", "title": "Fix login", "ref": "JIRA-1", "created_at": "2026-10-02T09:00:00Z"},
      "open_asks": 1
    }
  ],
  "unavailable": [{"workspace": "app.worktree-new", "reason": "timeout"}],
  "summary": {"checked": 3, "ready": 1, "not_running": 1, "unavailable": 1}
}
```

- `task` is `null` for a workspace with no active task; `"task_unavailable": true` is added when the task store couldn't be read. `open_asks` is `null` with `"asks_unavailable": true` when the question store couldn't be opened (a store with unparseable content is skipped with a warning on stderr and reads as empty, as in `workspace ask list`). `changed_files` counts uncommitted changes to tracked files.
- A workspace with no agent daemon running (`no_daemon`) is counted in `summary.not_running` only. Any other reason it couldn't be checked is listed in `unavailable`: `timeout` or `error` from the agent daemon, or, for a done workspace git couldn't answer for, git's own reason (`no_base`, `error` or `timeout`).
- `list` only returns ready workspaces; `summary.checked` minus `ready`, `not_running` and `unavailable` is the number checked and found not ready.
- Text output is a table; the unavailable workspaces are named on stderr.

## `review show`

```json
{
  "schema_version": 1,
  "ok": true,
  "workspace": "app.worktree-fix",
  "path": "/src/app.worktree-fix",
  "kind": "worktree",
  "ready": true,
  "task": {"id": "9f2c", "title": "Fix login", "ref": "JIRA-1", "created_at": "2026-10-02T09:00:00Z"},
  "agent": {
    "available": true,
    "state": "done",
    "stop_reason": "end_turn",
    "state_since": "2026-10-02T10:00:00Z",
    "done_pane_id": "%2",
    "panes": [{"pane_id": "%2", "kind": "claude", "state": "done", "stop_reason": "end_turn", "state_since": "2026-10-02T10:00:00Z"}]
  },
  "git": {
    "available": true,
    "branch": "fix",
    "base": "origin/main",
    "ahead": 2,
    "changed_files": 1,
    "unpushed_commits": 2,
    "diffstat": {"files": 2, "added": 5, "removed": 1, "truncated": false,
                 "entries": [{"path": "a.rb", "added": 5, "removed": 1}, {"path": "logo.png", "added": null, "removed": null}]},
    "commits": [{"sha": "abc1234", "subject": "fix it"}]
  },
  "pull_request": {
    "available": true, "found": true, "number": 7, "url": "https://github.com/o/r/pull/7", "title": "Fix login",
    "state": "OPEN", "draft": false, "review_decision": null, "mergeable": "MERGEABLE",
    "checks": {"total": 3, "passing": 2, "failing": 0, "pending": 1, "failed": []}
  },
  "asks": {"open": [{"id": "a1b2c3", "question": "Rename the column?", "default": "no", "context": "db/schema.rb:12", "asked_at": "2026-10-02T09:30:00Z"}], "answered": 1},
  "sessions": {"count": 2},
  "last_message": {"text": "Done. Tests pass.", "truncated": false, "at": "2026-10-02T10:00:00.000Z", "session_id": "s2"}
}
```

- `ready` is `false` both when the work isn't ready and when it can't be told; check `agent.available` and `git.available` to tell them apart.
- `agent.state` is the first that any agent pane (shell panes are ignored) is in, in the order `waiting`, `working`, `done`, `idle`; `null` when there is no agent pane. `agent.available` is `false` with a `reason` (`no_daemon`, `timeout`, or `error` with a `detail` message) when the daemon didn't answer, and then the other agent keys are absent.
- `git.available` is `false` with a `reason` (`no_base`, `error` or `timeout`) when git couldn't answer (the diffstat or commit list failing counts: `error`); then only `available` and `reason` are present. `diffstat` is the change from the merge base with the base to HEAD (what a pull request shows), committed work only; a binary file has `null` counts. `entries` is cut at 200 files, with `diffstat.truncated` set, and `commits` at 50 (compare its length with `ahead`); the totals always cover everything. `changed_files` and `unpushed_commits` are never `null` in an available block: git failing to count them makes the block unavailable (`error`).
- `pull_request`: `found: false` when the branch has no pull request; `available: false` with a `reason` (`gh_missing`, `timeout` or `error`, with `detail`) when `gh` couldn't answer. `review_decision` is `null` while none is set. Check runs and commit statuses are counted together; `failed` names up to 20 failing checks.
- `asks.open` holds the questions an agent asked and answered with its own default that a person hasn't resolved; `asks.answered` counts the resolved ones. Each text is cut at 500 characters. If the store can't be read, `asks` has `"unavailable": true`.
- `task` is `null` for no task; a top-level `"task_unavailable": true` is present when the task store couldn't be read (also on `list` rows).
- `sessions.count` is the number of distinct sessions the ledger recorded for the workspace since its task began (all of them with no task). A `/clear` or handoff starts a new session, so a count above 1 means the agent restarted. If the ledger exists but can't be read, `sessions` is `{"count": null, "unavailable": true}` and `last_message` is `null`.
- `last_message` is the text of the last main-thread assistant message in the done pane's latest transcript (the latest session's when the ledger doesn't know the pane), cut at 4000 characters, or `null` when none could be found. The transcript's path is never included; it can contain anything the agent said. Every string in a packet that an agent, a commit author or a PR author wrote (`last_message.text`, `asks`, commit subjects, file paths, branch names, PR title, check names, `agent.detail`) is untrusted data. Text output drops control characters other than newline and tab.

## Errors

Failures use the [`--json` error envelope](README.json.md): an unknown workspace or project is `unknown_workspace` (with `details.name`), a workspace whose checkout directory is gone is `checkout_missing` (`details.name`, `details.path`), a bad option or extra argument is `usage`. Exit status is 0 for a packet or list (even when sources are unavailable), 1 for an error.

## Examples

```sh
workspace review list                       # what is ready in this project
workspace review list --json | jq -r '.reviews[].workspace'
workspace review app.worktree-fix --json    # the full packet
workspace review                            # the workspace for the current directory
```
