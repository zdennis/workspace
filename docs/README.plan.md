# workspace plan

Read, start, pause and delete a workspace's plan: the counted task list in `IMPLEMENTATION_PLAN.md` in its [notes directory](README.notes.md). workspace parses the file, counts it, and works out one `state` from the plan, the session and the pane that owns the plan, so the app, scripts and agents all show the same answer.

## Usage

```sh
workspace plan status [--name WORKSPACE | --all | --file PATH] [--json]
workspace plan path [--name WORKSPACE] [--json]
workspace plan show [--name WORKSPACE]
workspace plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]
workspace plan start [--name WORKSPACE] [--json]
workspace plan pause [--name WORKSPACE] [--json]
workspace plan delete [--name WORKSPACE] --yes [--json]
```

Without `--name`, the workspace is the one detected from the current directory. `--all`, `--file` and `--name` exclude each other, and a flag that does not belong to the subcommand is a usage error.

## Subcommands

| Subcommand | What it does |
|------------|--------------|
| `status` | Counts the plan and reports its state. A workspace with no plan is a row with `exists: false`, not an error. `--all` lists every configured workspace whose checkout exists; `--file PATH` parses any file, with `workspace: null` and a state from the file alone (no session, pane or question is read) |
| `path` | Prints the plan's absolute path alone, whether or not the file exists. Makes nothing |
| `show` | Prints the plan file as it is. Fails with `no_plan` when there is none |
| `init` | Writes a new plan into the notes directory, making the directory first. `--title` sets the title (default: the title of the workspace's task, else none). `--from FILE` imports an existing document as the plan: it gets new frontmatter unless it has its own (then `--title` is ignored). Fails with `plan_exists` when a plan is there; `--force` replaces it. The file is written whole or not at all |
| `start` | Sets `status: active`, then gets an agent working on the plan (see [Start, pause and delete](#start-pause-and-delete)) |
| `pause` | Sets `status: paused`. Interrupts nothing |
| `delete` | Renames the plan to `IMPLEMENTATION_PLAN.md.deleted-<time>`. Needs `--yes` |

## Start, pause and delete

Each verb changes one thing and is safe to repeat. A plan with no file is `no_plan`. `start` and `pause` also refuse a plan that is done (`status: done`, or no task left to do) with `plan_done`; reopen it by editing the file.

- **`start`** sets `status: active` and then does the first of these that applies:
  - The workspace has no tmux session: it is launched like `launch --play implementation-plan --prompt "Continue the plan."`, so the agent is told the play and the line, the notes pack and the other automatic packs ride along, and the pane is bound to the play. Outcome `launched`, or a `failed` row with the launch's reason (`prompt_not_sent`, `session_not_started`) when the prompt could not be sent; the status stays `active`.
  - The workspace has a session and its main agent pane (the plan's `owner_pane` when that is a live Claude Code or Codex pane, else the first such pane the agent daemon lists) is working: nothing is typed. Outcome `already_working`.
  - The pane is idle: the play and "Continue the plan." are typed into it and the pane is bound to the play (a pane bound to a workflow run or a review keeps that binding). Outcome `sent`. A pane that waits for an answer is not typed into (`pane_busy`), and a session whose agent daemon does not answer is `no_daemon`; with no Claude Code or Codex pane it is `no_agent_pane`.

  Where it knows the pane the agent is in, `start` writes it into the frontmatter as `owner_pane` (adding the line when it is missing), so a plan whose pane id went stale after a `restore` reads `working` again. An unwritable `owner_pane` is a note in `message`; the launch or send still stands.
- **`pause`** sets `status: paused` (`paused`, or `unchanged` when it already was). It interrupts nothing: the agent re-reads `status:` before each task and stops, and whoever pauses sends the agent the key if it should stop sooner. [`doctor`](README.doctor.md) warns when a paused plan's owner pane is still working.
- **`delete`** needs `--yes`, or fails with `confirmation_required` (`retry.flags` is `["--yes"]`). It renames the file to `IMPLEMENTATION_PLAN.md.deleted-<UTC time>` in the same directory (`-1`, `-2` after it when that name is taken) and touches neither the session nor the worktree. The row's `path` is the plan's path and `message` names the new file.

A status or owner write changes only that line (the frontmatter is added when the file has none), reads the whole file, goes through a temp file and a rename, and keeps the file's mode. If the file changed between the read and the rename, for instance because the agent saved an edit, the write is made again on what is there now. A second change under the retry writes nothing and fails with `plan_write_conflict`. An agent that saves between the final check and the rename can still lose its edit; that window is a few microseconds.

Every change to the file records [`plan_changed`](README.event-log.md) in the event log, which `init` does too.

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

## The implementation-plan play

`play/implementation-plan` is a built-in [play](README.library.md) (`lib/library/play/implementation-plan.md`) that teaches an agent this file: where to find it (`workspace plan path`), the task syntax, taking a task to `[~]` and then `[x]` only once it is verified, re-reading `status:` before each task, and stopping on `paused`. Send it with `--pack implementation-plan` or `--play implementation-plan`; it is not one of the packs sent automatically. It names `workspace plan status` and `workspace plan start`.

The plan is also the handoff doc: with no `--handoff-doc`, [`handoff check` and `new`](README.handoff.md#the-default-doc) use `IMPLEMENTATION_PLAN.md` when it exists, and `new` binds the pane to this play. [`doctor`](README.doctor.md) warns on a paused plan whose owner pane is working and on a `[~]` task in a workspace with no session.

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

`start`, `pause` and `delete` are [action documents](README.json.md) too (`action: "plan start"`, `"plan pause"`, `"plan delete"`) with one result, `{"workspace","outcome","reason","message","path","pane"}`:

| Verb | `outcome` | Notes |
|------|-----------|-------|
| `start` | `launched`, `sent`, `already_working`, `failed` | `pane` is the pane id the agent is in (null when a launch did not say); `failed` carries `reason` and `message` and exits 1 |
| `pause` | `paused`, `unchanged` | `pane` is null |
| `delete` | `deleted` | `message` is `Renamed to <path>.`; `pane` is null |

`plan` in [`capabilities`](README.capabilities.md) is `4` once `start`, `pause` and `delete` exist; each level is described there.

## Errors

| `code` | When |
|--------|------|
| `no_plan` | `show`, `start`, `pause` or `delete` found no plan file (`details.name`, `details.path`) |
| `plan_exists` | `init` found a plan and `--force` was not given (`details.path`) |
| `plan_done` | `start` or `pause` found a plan that is done (`details.name`, `details.path`) |
| `confirmation_required` | `delete` was run without `--yes` (`retry.flags` is `["--yes"]`) |
| `plan_write_conflict` | The plan changed twice while a verb was writing it; nothing was written. Run the verb again |
| `no_agent_pane`, `pane_busy`, `no_daemon`, `not_delivered`, `not_submitted` | `start` of a workspace with a session found no Claude Code or Codex pane, found the pane waiting for an answer, could not reach the agent daemon, or could not type into the pane. See [`agent-run send`](README.agent-run.md) |
| `notes_dir_unwritable` | `init` couldn't make the notes directory or write the file, or a verb couldn't write or rename it |
| `error` | `init --from FILE` couldn't read the file (no more specific code) |
| `unknown_workspace`, `not_in_workspace`, `notes_dir_unresolved`, `config_parse` | As for [`notes dir`](README.notes.md#errors) |

A `start` that fails after setting the status (`pane_busy`, `no_daemon`, `no_agent_pane`, a send that did not arrive, or a `failed` launch row) leaves the plan `active`; the status write is the first step, and running `start` again is safe.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).
