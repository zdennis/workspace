# workspace plan

Read a workspace's plan: the counted task list in `IMPLEMENTATION_PLAN.md` in its [notes directory](README.notes.md). workspace parses the file, counts it, and works out one `state` from the plan, the session and the pane that owns the plan, so the app, scripts and agents all show the same answer.

## Usage

```sh
workspace plan status [--name WORKSPACE | --all | --file PATH] [--json]
workspace plan path [--name WORKSPACE] [--json]
workspace plan show [--name WORKSPACE]
workspace plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]
```

Without `--name`, the workspace is the one detected from the current directory. `--all`, `--file` and `--name` exclude each other, and a flag that does not belong to the subcommand is a usage error.

## Subcommands

| Subcommand | What it does |
|------------|--------------|
| `status` | Counts the plan and reports its state. A workspace with no plan is a row with `exists: false`, not an error. `--all` lists every configured workspace whose checkout exists; `--file PATH` parses any file, with `workspace: null` and a state from the file alone (no session, pane or question is read) |
| `path` | Prints the plan's absolute path alone, whether or not the file exists. Makes nothing |
| `show` | Prints the plan file as it is. Fails with `no_plan` when there is none |
| `init` | Writes a new plan into the notes directory, making the directory first. `--title` sets the title (default: the title of the workspace's task, else none). `--from FILE` imports an existing document as the plan: it gets new frontmatter unless it has its own (then `--title` is ignored). Fails with `plan_exists` when a plan is there; `--force` replaces it. The file is written whole or not at all |

## The plan file

```markdown
---
plan: 1
title: Auth rewrite
status: active
owner_pane: "%19"
---

# Auth rewrite

## Tasks

### Phase 1
- [x] T1 Add the user table
- [-] T2 Rename the column -- the old name stays
### Phase 2
- [~] T3 Add the token store
- [ ] T4 Wire the login form
- [!] T5 Rotate the signing key -- waiting on ops

## Task details
Anything here is free text and is not counted.
```

- **Frontmatter** is optional: `plan: 1`, `title`, `status` (`active`, `paused` or `done`; `active` when absent) and `owner_pane` (a tmux pane id such as `%19`). It is read line by line as `key: value`, so a stray colon never makes the file unreadable. A double-quoted value is read as JSON would read it.
- **A task** is a line at column 0, `- [S] ID Title`, under a `## Tasks` heading. `S` is a space (to do), `~` (in progress), `x` or `X` (done), `-` (skipped) or `!` (blocked). Skipped and blocked tasks end ` -- reason`.
- **An id** is the first word, and it must contain a digit (`T1`, `CLI-D18`, `1.2`). A trailing colon is allowed. A first word with a digit is always read as the id (`404 page` has the id `404`), so start a task with its id.
- **Not counted:** indented checkboxes, fenced code, HTML comments, and everything under a later `#` or `##` heading such as `## Task details`.
- **Phase:** the nearest heading above the task that is not `Tasks` (`###` and deeper headings under `## Tasks`).
- Counts: `left = todo + in_progress + blocked`; `percent = (done + skipped) / total`, rounded. `current` is the first in-progress task, else the first to do.

The parser never fails. It reads at most 1 MB, and it returns `warnings` for what it could not read cleanly. A task line is still counted when it has a problem, so the counts never hide work.

| Warning `code` | Meaning |
|----------------|---------|
| `no_id` | A task line has no id (counted, with a null `id`) |
| `bad_state` | A box character is not one of the six states (counted as to do), or `status:` is not `active`, `paused` or `done` (read as `active`) |
| `duplicate_id` | An id is used on an earlier line (both are counted) |
| `missing_reason` | A skipped or blocked task has no ` -- reason` (counted) |
| `owner_pane_unknown` | `owner_pane` is not a pane of the workspace's session; only said when the agent daemon answered and the session runs |
| `truncated` | The file is longer than 1 MB; only the start was read |
| `unreadable` | The file exists but can't be read; reported as an empty plan |

## State

`state` is the first of these that holds:

| State | When |
|-------|------|
| `empty` | No tasks (or no plan file) |
| `done` | Nothing is left (`left` is 0), or `status: done` |
| `paused` | `status: paused` |
| `stopped` | The workspace has no live tmux session |
| `waiting` | The owner pane waits on a person, or a `workspace ask` question is open |
| `working` | The owner pane works |
| `blocked` | Every task left is blocked |
| `stalled` | The owner pane has been idle longer than the [`plan.stall_seconds`](README.config.md) key (project scope, default `5m`) |
| `idle` | None of the above |

A fact that can't be read never decides a state. A tmux that can't be asked, or a workspace on a socket of its own, is not `stopped`; a plan with no `owner_pane`, or a daemon that does not answer, leaves `pane_state` null, so the plan reads `idle` (or `blocked`) rather than `working`. Plans with no tasks skip every read.

## JSON output

```json
{"schema_version":1,"ok":true,"plans":[{"workspace":"api.worktree-x","project":"api","path":"/abs/IMPLEMENTATION_PLAN.md","exists":true,"title":"Auth rewrite","status":"active","state":"working","owner_pane":"%19","pane_state":"working","updated_at":"2026-10-12T14:03:11Z","signature":"1791850994123456789:8841","counts":{"total":20,"done":7,"in_progress":1,"skipped":1,"blocked":0,"todo":11,"left":12},"percent":40,"current":{"id":"T9","title":"Add the token store","phase":"Phase 2"},"tasks":[{"id":"T1","title":"Add the user table","state":"done","reason":null,"phase":"Phase 1","line":14}],"open_asks":0,"warnings":[{"code":"no_id","line":31,"message":"No task id: start the task with an id such as T1."}]}]}
```

| Field | Meaning |
|-------|---------|
| `workspace`, `project` | The workspace and its project (the workspace itself unless it is a worktree); null for `--file` |
| `path`, `exists` | The plan file and whether it is there. With `--all`, a workspace whose notes directory can't be worked out has a null `path` and a warning carrying that error's code |
| `title`, `status` | From the frontmatter (`status` defaults to `active`); null when there is no file |
| `state` | See above |
| `owner_pane`, `pane_state` | The frontmatter's pane, and its state (`working`, `idle`, `waiting`, ...) from the agent daemon; null when unknown |
| `updated_at`, `signature` | The file's modification time (UTC, to the second) and `mtime_ns:size`. The signature changes when the file does, so a reader can skip a re-read when it is the same |
| `counts`, `percent`, `current` | See above; `current` is null when nothing is left |
| `tasks` | Every counted task: `id`, `title`, `state` (`todo`, `in_progress`, `done`, `skipped`, `blocked`), `reason`, `phase`, `line` |
| `open_asks` | Open `workspace ask` questions in the workspace |
| `warnings` | `{code, line, message}`; `line` is null for a warning about the whole file |

`plan path --json`: `{"schema_version":1,"ok":true,"path":"/abs/IMPLEMENTATION_PLAN.md","exists":true,"notes_dir":"/abs"}`.

`plan init --json` is an [action document](README.json.md) (`action: "plan init"`) with one result, `{"workspace","outcome":"created","reason":null,"message":null,"path"}`; `message` says so when an imported document has no tasks to count.

`plan` in [`capabilities`](README.capabilities.md) is `1` when these commands exist.

## Errors

| `code` | When |
|--------|------|
| `no_plan` | `show` found no plan file (`details.name`, `details.path`) |
| `plan_exists` | `init` found a plan and `--force` was not given (`details.path`) |
| `notes_dir_unwritable` | `init` couldn't make the notes directory or write the file |
| `error` | `init --from FILE` couldn't read the file (no more specific code) |
| `unknown_workspace`, `not_in_workspace`, `notes_dir_unresolved`, `config_parse` | As for [`notes dir`](README.notes.md#errors) |

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).
