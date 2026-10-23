# workspace plan

Read, start, pause and delete a workspace's plan: the counted task list in `IMPLEMENTATION_PLAN.md` in its [notes directory](README.notes.md). workspace parses the file, counts it, and works out one `state` from the plan, the session and the pane that owns the plan, so the app, scripts and agents all show the same answer.

## Usage

```sh
workspace plan status [--name WORKSPACE | --all | --file PATH | --group GROUP] [--json]
workspace plan path [--name WORKSPACE] [--json]
workspace plan show [--name WORKSPACE]
workspace plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]
workspace plan start [--name WORKSPACE] [--task ID [--pane PANE | --spawn KIND]] [--json]
workspace plan pause [--name WORKSPACE] [--interrupt] [--json]
workspace plan delete [--name WORKSPACE] --yes [--json]
workspace plan task add --title TEXT [--id ID] [--state STATE] [--reason TEXT] [--phase NAME | --after ID] [--if-revision REV] [--name WORKSPACE] [--json]
workspace plan task set-state --task ID --state STATE [--reason TEXT] [--if-revision REV] [--name WORKSPACE] [--json]
workspace plan task set-title --task ID --title TEXT [--if-revision REV] [--name WORKSPACE] [--json]
workspace plan task move --task ID (--after ID | --before ID | --phase NAME) [--if-revision REV] [--name WORKSPACE] [--json]
```

Without `--name`, the workspace is the one detected from the current directory. `--all`, `--file`, `--group` and `--name` exclude each other, and a flag that does not belong to the subcommand is a usage error. So are `--pane` with `--spawn`, either of them without `--task`, and a `--spawn` kind that is not `claude`, `codex`, `opencode` or `pi`. Every flag also takes the `--flag=value` form.

## Subcommands

| Subcommand | What it does |
|------------|--------------|
| `status` | Counts the plan and reports its state. A workspace with no plan is a row with `exists: false`, not an error. `--all` lists every configured workspace whose checkout exists; `--file PATH` parses any file, with `workspace: null` and a state from the file alone (no session, pane or question is read); `--group GROUP` is the [merged view of a group](#a-groups-plans) |
| `path` | Prints the plan's absolute path alone, whether or not the file exists. Makes nothing |
| `show` | Prints the plan file as it is. Fails with `no_plan` when there is none |
| `init` | Writes a new plan into the notes directory, making the directory first. `--title` sets the title (default: the title of the workspace's task, else none). `--from FILE` imports an existing document as the plan: it gets new frontmatter unless it has its own (then `--title` is ignored). Fails with `plan_exists` when a plan is there; `--force` replaces it. The file is written whole or not at all |
| `start` | Sets `status: active`, then gets an agent working on the plan (see [Start, pause and delete](#start-pause-and-delete)). With `--task`, sends that one task to one pane (see [One task](#one-task)) |
| `pause` | Sets `status: paused`. Interrupts nothing unless `--interrupt` is given |
| `delete` | Renames the plan to `IMPLEMENTATION_PLAN.md.deleted-<time>`. Needs `--yes` |
| `task` | `add`, `set-state`, `set-title` or `move` changes one task line (see [Task verbs](#task-verbs)) |

## Start, pause and delete

Each verb changes one thing and is safe to repeat. A plan with no file is `no_plan`. `start` and `pause` also refuse a plan that is done (`status: done`, or no task left to do) with `plan_done`; reopen it by editing the file.

- **`start`** sets `status: active` and then does the first of these that applies:
  - The workspace has no tmux session: it is launched like `launch --play implementation-plan --prompt "Continue the plan."`, so the agent is told the play and the line, the notes pack and the other automatic packs ride along, and the pane is bound to the play. Outcome `launched`, or a `failed` row with the launch's reason (`prompt_not_sent`, `session_not_started`) when the prompt could not be sent; the status stays `active`.
  - A plan with no tasks (a new one from `plan init`, or `start --plan`) is not refused: the line is "The plan has no tasks yet. Draft them as the play's \"Draft the tasks\" section says, then end your turn. Do not start any task." in place of "Continue the plan.", in both of the cases above and below, and the outcome is `drafting` in place of `launched` or `sent`. The agent writes the task lines and `## Start here`, runs `plan status`, and stops for you to read the plan; run `plan start` again to have it work the tasks. A plan with tasks keeps the behavior described here.
  - The workspace has a session and its main agent pane (the plan's `owner_pane` when that is a live Claude Code or Codex pane, else the first such pane the agent daemon lists) is working: nothing is typed. Outcome `already_working`.
  - The pane is idle: the play and "Continue the plan." are typed into it and the pane is bound to the play (a pane bound to a workflow run or a review keeps that binding). Outcome `sent`. A pane that waits for an answer is not typed into (`pane_busy`), and a session whose agent daemon does not answer is `no_daemon`; with no Claude Code or Codex pane it is `no_agent_pane`.

  Where it knows the pane the agent is in, `start` writes it into the frontmatter as `owner_pane` (adding the line when it is missing), so a plan whose pane id went stale after a `restore` reads `working` again. An unwritable `owner_pane` is a note in `message`; the launch or send still stands.
- **`pause`** sets `status: paused` (`paused`, or `unchanged` when it already was). On its own it interrupts nothing: the agent re-reads `status:` before each task and stops. [`doctor`](README.doctor.md) warns when a paused plan's owner pane is still working.

  With `--interrupt`, once the status is written, each owner pane (the plan's `owner_pane` and the owners of the tasks still left) that the agent daemon lists as `working` gets its agent's interrupt key: `Escape` for Claude Code and Codex. OpenCode and Pi have no key listed yet, so their panes are left to stop before their next task. A pane that is idle or waiting gets nothing, since `Escape` there would start Claude Code's rewind or answer a permission prompt. The row's `interrupts` lists each owner pane as `{pane, kind, outcome, message}`, where `outcome` is `sent`, `not_working`, `unsupported` (no key for its kind), `gone` (the daemon does not list it) or `failed` (`message` says why). A daemon that does not answer leaves `interrupts` empty and adds a `no_daemon` entry to the document's `warnings`; the pause still stands and the exit code is 0.
- **`delete`** needs `--yes`, or fails with `confirmation_required` (`retry.flags` is `["--yes"]`). It renames the file to `IMPLEMENTATION_PLAN.md.deleted-<UTC time>` in the same directory (`-1`, `-2` after it when that name is taken) and touches neither the session nor the worktree. The row's `path` is the plan's path and `message` names the new file.

### One task

`plan start --task=ID [--pane=PANE | --spawn=KIND]` sends one task to one pane, so several agents can work tasks side by side and each can be steered.

- It refuses an id no task has (`unknown_task`), a task that is done or skipped (`task_done`), and a plan that is done (`plan_done`). Once nothing below refuses the task either, it sets `status: active`, before anything is typed, so the agent never reads `paused`. A refused task leaves the plan as it was.
- The pane is the first of these:
  1. `--pane`: a pane id (`%19`) or `window.pane` (`0.1`) of the workspace's own session, checked as for [`agent-run send`](README.agent-run.md). The agent daemon must list it as a coding-agent pane, or the result is `no_agent_pane`.
  2. `--spawn=KIND`: a new pane split below the bottom one, starting a fresh `claude`, `codex`, `opencode` or `pi` agent with the command the workspace's own pane runs for that kind (minus any part that resumes a conversation, so a Claude Code pane started `claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions` gives `claude --dangerously-skip-permissions`), else the command `start --agent-kind` writes for it, else the bare executable. The task is typed once that agent's screen settles (and, for Claude Code, shows its prompt), within 60 seconds. An agent that is not ready is a `failed` row with reason `prompt_not_sent`, and the new pane is closed again, since nothing was typed into it; the row's `details` has `pane_id` and `pane_closed` (`false` when tmux could not close it, and the message then leaves out "the pane was closed"). A Codex agent at a sign-in, folder-trust or approval screen is the exception: its pane is kept open (`pane_closed: false`, `details.waiting` `sign_in`, `trust` or `approval`) and the message tells you to finish that screen there, then start the task again. `details.waiting` is absent when no such screen was seen, and a workspace on a custom tmux socket keeps its pane without `waiting`. Only the pane `--spawn` split is ever closed, never one named with `--pane`; a workspace on a custom tmux socket keeps its pane (`pane_closed: false`). A failure after the agent was ready (typing the task) leaves the pane open and raises the error with `details.pane_id` and `details.pane_closed: false`. Capability feature `spawn_cleanup`.
  3. The task's owner, when the daemon lists it as a coding-agent pane.
  4. The main agent pane, chosen as plain `start` chooses it.
- A workspace with no session is launched as plain `start` launches it, with the task's line as the prompt (outcome `launched`). With `--pane` or `--spawn` it is `no_session` instead.
- The same refusals as plain `start` apply to the chosen pane: one that waits for an answer is `pane_busy`. One that is working is `pane_busy` too, unless it already owns this task (outcome `already_working`, nothing typed). A task whose owner pane is working is `task_owned` when a different pane, or `--spawn`, was asked for, so one task never gets two agents.
- What is typed is the play and `Work on plan task ID only. Do not take other tasks; end your turn when it is done or blocked.` The task's title is not typed; the agent reads it from the file. The pane is bound to the play with `focus: "plan task ID"`, which the SessionStart hook repeats after a `/clear`. A pane bound to a workflow run or a review keeps that binding.
- Once the text is typed, the pane is written onto the task line as its owner (`<!-- owner: %19 -->`, replacing an older owner), and a `[ ]` task becomes `[~]`; other boxes stay as they are. A line that can't be written is a note in `message`, and the send still stands.

A status or owner write changes only that line (the frontmatter is added when the file has none), reads the whole file, goes through a temp file and a rename, and keeps the file's mode. If the file changed between the read and the rename, for instance because the agent saved an edit, the write is made again on what is there now. A second change under the retry writes nothing and fails with `plan_write_conflict`. An agent that saves between the final check and the rename can still lose its edit; that window is a few microseconds.

Every change to the file records [`plan_changed`](README.event-log.md) in the event log, which `init` does too. A change to the checklist, however it was made, also records [`plan_progress`](README.event-log.md) (counts, current task, changed task ids) while the workspace's agent daemon runs.

## Task verbs

`plan task add|set-state|set-title|move` change a task without editing the Markdown by hand. Each is an [action document](README.json.md) (`action: "plan task add"`, `"plan task set-state"`, `"plan task set-title"`, `"plan task move"`) and goes through the one writer of the plan file (a temp file and a rename, with one re-read and retry), so it changes only the line it must: owner comments stay, nothing is renumbered, and an id is never reused.

| Verb | What it does |
|------|--------------|
| `add --title TEXT` | Adds a task line. `--id` names it (default: the next number after the highest id with the prefix of the plan's last task, so `T9` after `T8`). `--state` is `todo` by default. The line goes after `--after ID`, or after the last task of `--phase NAME` (after the heading when it has none), or after the plan's last task (at the end of `## Tasks` when there is none). An id that is already used is `task_exists` |
| `set-state --task ID --state STATE` | Changes the box. A blocked or skipped task ends with ` -- reason`, so those states need `--reason` (`reason_required`) unless the line already has one; a reason for any other state is `invalid_task`. Leaving blocked or skipped takes the reason away. The owner comment stays |
| `set-title --task ID --title TEXT` | Replaces the title text. The id, box, ` -- reason`, owner comment and place stay. The title follows the `add` rules (one line of 1 to 500 characters, no HTML comment, no ` -- `); one that breaks them is `invalid_task` with `details.field` `title`. The same title is `unchanged` |
| `move --task ID` | Moves the whole line (owner comment included) `--after ID`, `--before ID`, or to the end of `--phase NAME`. Exactly one place is given. A task is never moved relative to itself |

States are `todo`, `in_progress`, `done`, `skipped` and `blocked`. A title or reason is one line of 1 to 500 characters with no HTML comment and no ` -- `. An id is a letter or digit first with at least one digit (`T9`, `PROJ-123`). Any of these that cannot be written is `invalid_task` (`details.field`). An unknown task id, in `--task`, `--after` or `--before`, is `unknown_task`; an unknown `--phase` is `unknown_phase`; a plan with no `## Tasks` section is `no_task_section`. A plan that is `done` can still be edited.

### Refusing a stale edit

`plan status --json` gives each plan a `revision`: the first 8 hex digits of the SHA-256 of the file's bytes. Pass it back as `--if-revision=REV` and a verb whose file has since changed (any byte, even one that keeps the size) writes nothing and fails with `stale_revision`, with `details.revision` the current one. The check and the write happen on the same read, so an edit that lands in between is caught too. Every verb's result carries the new `revision`; use it for the next edit.

### Result

One result, `{"workspace","outcome","reason","message","path","pane","task","state","title","line","phase","revision","counts","percent"}` (`pane` is null; `counts` and `percent` are the plan's after the edit; `set-state` also has `previous_state`):

| Verb | `outcome` |
|------|-----------|
| `add` | `added` |
| `set-state` | `changed`, or `unchanged` when the task already reads that way |
| `set-title` | `changed`, or `unchanged` when the task already has that title |
| `move` | `moved`, or `unchanged` when the task is already in that place |

```json
{"schema_version":1,"ok":true,"action":"plan task set-state","status":"ok","results":[{"workspace":"api","outcome":"changed","reason":null,"message":null,"path":"/abs/IMPLEMENTATION_PLAN.md","pane":null,"task":"T3","state":"blocked","line":14,"phase":"Phase 1","revision":"4e1f0c2a","counts":{"total":9,"done":4,"in_progress":1,"skipped":0,"blocked":1,"todo":3,"left":5},"percent":44,"previous_state":"in_progress"}],"warnings":[],"summary":{"changed":1}}
```

Each change that writes records `plan_changed` in the event log, and the agent daemon's plan watcher reports the new counts as a `plan_progress` line. `plan_tasks` in [`capabilities`](README.capabilities.md) is `2` once these verbs and the `revision` exist, and `3` once `set-title` exists.

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
- [~] T3 Add the token store <!-- owner: %19 -->
- [ ] T4 Wire the login form
- [!] T5 Rotate the signing key -- waiting on ops

## Task details
Anything here is free text and is not counted.
```

- **Frontmatter** is optional: `plan: 1`, `title`, `status` (`active`, `paused` or `done`; `active` when absent) and `owner_pane` (a tmux pane id such as `%19`). It is read line by line as `key: value`, so a stray colon never makes the file unreadable. A double-quoted value is read as JSON would read it.
- **A task** is a line at column 0, `- [S] ID Title`, under a `## Tasks` heading. `S` is a space (to do), `~` (in progress), `x` or `X` (done), `-` (skipped) or `!` (blocked). Skipped and blocked tasks end ` -- reason`.
- **An id** is the first word, and it must contain a digit (`T1`, `CLI-D18`, `1.2`). A trailing colon is allowed. A first word with a digit is always read as the id (`404 page` has the id `404`), so start a task with its id.
- **An owner** is an HTML comment at the end of a task line, `<!-- owner: %19 -->`: the tmux pane working that task, which [`start --task`](#one-task) writes. Only a pane id is read; no comment means no owner. Older CLIs strip the comment like any other, so the line still reads as the same plain task, and a plan without owners reads as before. The frontmatter `owner_pane` is the pane working the plan as a whole.
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
| `bad_owner` | An owner comment holds something that is not a tmux pane id (the task has no owner) |
| `owner_pane_unknown` | `owner_pane` is not a pane of the workspace's session; only said when the agent daemon answered and the session runs |
| `task_owner_unknown` | The owner of a task still left (to do, in progress or blocked) is not a pane of the workspace's session (the warning names the task line); only said when the agent daemon answered and the session runs |
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

`play/implementation-plan` is a built-in [play](README.library.md) (`lib/library/play/implementation-plan.md`) that teaches an agent this file: where to find it (`workspace plan path`), the task syntax, taking a task to `[~]` and then `[x]` only once it is verified (for a spine stage with a `check:` line, claiming the stage `completed` and leaving the verdict to a separate checker), re-reading `status:` before each task, and stopping on `paused`. Send it with `--pack implementation-plan` or `--play implementation-plan`; it is not one of the packs sent automatically. It names `workspace plan status` and `workspace plan start`.

The `rpiv` workflow's plan and implement steps compose this play, and its plan step writes the run's tasks into this file, so `plan status` shows a run's progress. The run's `plan.md` under `.workflow/` is only the note for the approval gate.

The plan is also the handoff doc: with no `--handoff-doc`, [`handoff check` and `new`](README.handoff.md#the-default-doc) use `IMPLEMENTATION_PLAN.md` when it exists, and `new` binds the pane to this play. [`doctor`](README.doctor.md) warns on a paused plan whose owner pane is working and on a `[~]` task in a workspace with no session.

## A group's plans

`plan status --group GROUP` shows the plans of a [group of repositories](README.projects.md) (`GROUP`, like `group:billing`, `billing` or `Billing`, is its `group:<slug>` id, its slug or its name, ignoring case, as for `projects group add`): the rows `plan status` gives for every configured workspace, with an existing checkout, of every repository in the group. It is read-only. There is no group plan file; each workspace keeps its own `IMPLEMENTATION_PLAN.md`, and `plan start`, `pause` and the task verbs still act on one workspace. `--group` excludes `--name`, `--all` and `--file`, and only `status` takes it. A group no file matches fails with `unknown_group`.

```
Billing (group:billing)
api  /src/api
  api  working  7/20 (40%)  T9 Add the token store
  api.worktree-x  no plan
web  /src/web
  no workspaces
```

A line at the left margin is a repository (name and main checkout; `(checkout missing)` when the directory is gone) and the indented lines are its workspaces.

With `--json` the document is the `plan status --json` one with a top-level `group` (`{"id":"group:billing","name":"Billing"}`), a `repositories` list (`{id, name, path, exists}` for every repository in the group, so one with no rows or a missing checkout can be told apart), and each row has one more field, `repository`: the id (the realpath of the git common dir) of the repository the workspace belongs to, the same `id` that `projects list` gives. `plans` lists the repositories in the order the group's file does. A repository with no configured workspaces has no row. An empty group is `"plans":[]`.

## JSON output

```json
{"schema_version":1,"ok":true,"plans":[{"workspace":"api.worktree-x","project":"api","path":"/abs/IMPLEMENTATION_PLAN.md","exists":true,"title":"Auth rewrite","status":"active","state":"working","owner_pane":"%19","pane_state":"working","updated_at":"2026-10-12T14:03:11Z","signature":"1791850994123456789:8841","counts":{"total":20,"done":7,"in_progress":1,"skipped":1,"blocked":0,"todo":11,"left":12},"percent":40,"current":{"id":"T9","title":"Add the token store","phase":"Phase 2"},"tasks":[{"id":"T1","title":"Add the user table","state":"done","reason":null,"phase":"Phase 1","line":14,"owner":null,"owner_state":null}],"open_asks":0,"warnings":[{"code":"no_id","line":31,"message":"No task id: start the task with an id such as T1."}]}]}
```

| Field | Meaning |
|-------|---------|
| `workspace`, `project` | The workspace and its project (the workspace itself unless it is a worktree); null for `--file` |
| `path`, `exists` | The plan file and whether it is there. With `--all`, a workspace whose notes directory can't be worked out has a null `path` and a warning carrying that error's code |
| `title`, `status` | From the frontmatter (`status` defaults to `active`); null when there is no file |
| `state` | See above |
| `owner_pane`, `pane_state` | The frontmatter's pane, and its state (`working`, `idle`, `waiting`, ...) from the agent daemon; null when unknown |
| `updated_at`, `signature` | The file's modification time (UTC, to the second) and `mtime_ns:size`. The signature changes when the file does, so a reader can skip a re-read when it is the same |
| `revision` | The first 8 hex digits of the SHA-256 of the file's bytes (null without a file). Pass it as `--if-revision` to a [task verb](#task-verbs) to refuse an edit made on an old view |
| `counts`, `percent`, `current` | See above; `current` is null when nothing is left |
| `tasks` | Every counted task: `id`, `title`, `state` (`todo`, `in_progress`, `done`, `skipped`, `blocked`), `reason`, `phase`, `line`, `owner` (the pane id in its owner comment, or null) and `owner_state` (that pane's state from the agent daemon, null when unknown or without an owner). The daemon is asked when the plan or any task has an owner |
| `open_asks` | Open `workspace ask` questions in the workspace |
| `warnings` | `{code, line, message}`; `line` is null for a warning about the whole file |

`plan path --json`: `{"schema_version":1,"ok":true,"path":"/abs/IMPLEMENTATION_PLAN.md","exists":true,"notes_dir":"/abs"}`.

`plan init --json` is an [action document](README.json.md) (`action: "plan init"`) with one result, `{"workspace","outcome":"created","reason":null,"message":null,"path"}`; `message` says so when an imported document has no tasks to count.

`start`, `pause` and `delete` are [action documents](README.json.md) too (`action: "plan start"`, `"plan pause"`, `"plan delete"`) with one result, `{"workspace","outcome","reason","message","path","pane"}`:

| Verb | `outcome` | Notes |
|------|-----------|-------|
| `start` | `launched`, `sent`, `drafting` (the plan had no tasks), `already_working`, `failed` | `pane` is the pane id the agent is in (null when a launch did not say); `failed` carries `reason` and `message` and exits 1 |
| `start --task` | `launched`, `sent`, `spawned`, `already_working`, `failed` | The result also has `task` (the id). `pane` is the pane the task went to; for `spawned`, and for a `failed` spawn, it is the new pane |
| `pause` | `paused`, `unchanged` | `pane` is null. With `--interrupt`, the result also has `interrupts` (see [`pause`](#start-pause-and-delete)) |
| `delete` | `deleted` | `message` is `Renamed to <path>.`; `pane` is null |

```json
{"schema_version":1,"ok":true,"action":"plan start","status":"ok","results":[{"workspace":"api","outcome":"spawned","reason":null,"message":null,"path":"/abs/IMPLEMENTATION_PLAN.md","pane":"%23","task":"T5"}],"warnings":[],"summary":{"spawned":1}}
{"schema_version":1,"ok":true,"action":"plan pause","status":"ok","results":[{"workspace":"api","outcome":"paused","reason":null,"message":null,"path":"/abs/IMPLEMENTATION_PLAN.md","pane":null,"interrupts":[{"pane":"%19","kind":"claude","outcome":"sent","message":null},{"pane":"%23","kind":"claude","outcome":"not_working","message":null}]}],"warnings":[],"summary":{"paused":1}}
```

`plan` in [`capabilities`](README.capabilities.md) is `4` once `start`, `pause` and `delete` exist; each level is described there. `plan_tasks` is `1` once tasks have owners, `start --task` and `pause --interrupt` exist.

## Errors

| `code` | When |
|--------|------|
| `no_plan` | `show`, `start`, `pause` or `delete` found no plan file (`details.name`, `details.path`) |
| `plan_exists` | `init` found a plan and `--force` was not given (`details.path`) |
| `plan_done` | `start` or `pause` found a plan that is done (`details.name`, `details.path`) |
| `confirmation_required` | `delete` was run without `--yes` (`retry.flags` is `["--yes"]`) |
| `plan_write_conflict` | The plan changed twice while a verb was writing it; nothing was written. Run the verb again |
| `no_agent_pane`, `pane_busy`, `no_daemon`, `not_delivered`, `not_submitted` | `start` of a workspace with a session found no Claude Code or Codex pane, found the pane waiting for an answer, could not reach the agent daemon, or could not type into the pane. See [`agent-run send`](README.agent-run.md). With `--task`: a `--pane` that runs no coding agent is `no_agent_pane`, and a pane working on something else is `pane_busy` with `details.state` `working` |
| `stale_revision`, `task_exists`, `invalid_task`, `reason_required`, `unknown_phase`, `no_task_section` | `task add`, `set-state`, `set-title` or `move`: the file changed since `--if-revision` (`details.revision` is the current one), the id is used, the id, title, reason or place cannot be written, a blocked or skipped task has no reason, the phase is not under `## Tasks`, or there is no `## Tasks` section. See [Task verbs](#task-verbs) |
| `unknown_task`, `task_done`, `task_owned` | `start --task` named an id no task has, a task that is done or skipped, or a task whose owner pane is working on it while another pane (or `--spawn`) was asked for (`details.task`, and `details.owner` for `task_owned`) |
| `no_session`, `bad_pane`, `wrong_session`, `no_such_pane` | `start --task` with `--pane` or `--spawn` on a workspace with no session, or a `--pane` that is not a pane of its session |
| `notes_dir_unwritable` | `init` couldn't make the notes directory or write the file, or a verb couldn't write or rename it |
| `error` | `init --from FILE` couldn't read the file (no more specific code) |
| `unknown_workspace`, `not_in_workspace`, `notes_dir_unresolved`, `config_parse` | As for [`notes dir`](README.notes.md#errors) |

A plain `start` that fails after setting the status (`pane_busy`, `no_daemon`, `no_agent_pane`, a send that did not arrive, or a `failed` launch row) leaves the plan `active`; the status write is the first step, and running `start` again is safe.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).
