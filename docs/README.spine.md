# workspace spine

Read a workspace's stages (`workspace spine`), set a stage's status, and start an agent on a stage. The stages are the step level of a workspace's plan (research, plan, implement, verify, ...): one Markdown file per stage in a `spine/` folder of the workspace's notes directory. The task level is [`IMPLEMENTATION_PLAN.md`](README.plan.md), which the stages link to and does not replace.

## Usage

```sh
workspace spine show [WORKSPACE] [--name WORKSPACE] [--stage STAGE-PATH] [--body] [--evaluate] [--json]
workspace spine check [WORKSPACE] STAGE-PATH --item N [--item N ...] (--done | --undone) [--if-revision REV] [--json]
workspace spine verify [WORKSPACE] STAGE-PATH (--pass | --fail) --note TEXT [--by LABEL] [--if-revision REV] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `WORKSPACE`, `--name WORKSPACE` | The workspace to read. Default: the one detected from the current directory. Give it once; two different names are a usage error |
| `--stage STAGE-PATH` | Only that stage, with its sub-stages (`verify`, `implement/api`, as `path` reports). Its own flag because the one positional is the workspace. A path no stage has is `unknown_stage` with the paths there are, the one place `show` errors on content |
| `--body` | Add the text after the frontmatter: to the stage with `--stage`, else to `goal` (stage bodies are never added to the whole tree). At most 16 KB (16384 bytes), cut on a character boundary; read without following links |
| `--evaluate` | Judge every stage against the evidence and add `state`, `gate_results`, `disputes` and more (see [Evaluating the stages](#evaluating-the-stages)). Reads `gh` and the agent daemon; works with `--stage` and `--body` |
| `--json` | Print one JSON document |

`show` only reads. It creates no folder and writes no file, never follows a link, and never fails because of what a file holds: a problem is a `warnings` entry, and the exit status stays 0. The only errors are `unknown_workspace`, `notes_dir_unresolved` and `config_parse` (the notes directory can't be worked out), and `not_in_workspace`. A workspace with no `spine/` answers `exists: false`.

Plain output is a short summary: one line per stage with its status, owner, `Done when` counts and the codes of its warnings.

`spine` in [`capabilities`](README.capabilities.md) is `2` when this command has the roll-up described below, `--stage` and `--body`; `spine_eval` is `1` when it has `--evaluate`, `2` when `--evaluate` infers stages for a workspace with no `spine/`, and `3` when it judges a stage's [check](#checking-a-stage-apart-from-its-claim) (`checking`, `check_failed`, `checker`, `checker_state`).

## Evaluating the stages

`--evaluate` is opt-in; plain `show` stays a file read that starts no process. A stage's `status` is the file's claim. `--evaluate` checks it against the evidence (the gates the stage declares, its `## Done when` list and its sub-stages) and reports the verdict beside it. It is the same verdict as the app's (`src/core/spine/model.ts`, `facts.ts`).

Each source is read at most once, whatever the number of stages: the plan file; the checkout's upstream and ahead count (and the branch's upstream config, to tell "never pushed" from "remote branch deleted"); one `gh pr view` (limit 5 s), only when `gh` is on the PATH and a stage declares `pr`, `ci`, `merged` or `review` (or `pushed` while git can't pass it); one agent-daemon snapshot (limit 1 s), which gives owner liveness and the review agent's state; and the open questions. `gh` and the daemon are read in parallel, so the worst case is about 5 s plus the local git calls. A source that can't answer leaves its gates `unchecked` and is named in `sources`; it never fails the command.

`--stage PATH --evaluate` evaluates the whole tree (a verdict depends on siblings and children) and prints the one stage. `--body` works as above. A workspace with no `spine/` gets [inferred stages](#inferred-stages).

Added to each stage (children too), beside the keys above, which keep their meaning:

```json
{
  "path": "verify", "status": "completed", "state": "disputed", "from_sub_stages": false, "looks_completed": false,
  "gate_results": [
    {"gate": "checklist", "result": "pass", "reason": "all_ticked", "message": "3 of 3 ticked"},
    {"gate": "ci", "result": "fail", "reason": "checks_failing", "message": "1 of 6 checks failing"}
  ],
  "disputes": [{"kind": "gate", "gate": "ci", "message": "Marked completed, but CI is failing"}],
  "waits_on": [], "owner_state": "idle", "owner_since": null, "dimmed": false, "current": null
}
```

At the top level (and in the `--stage` document): `"evaluated": true`, `"evaluated_at"` (UTC), `"current"` (a path or `null`) and `"sources": {"plan", "git", "gh", "review", "panes"}`, each `ok`, `unavailable` or `not_needed`, so a reader can say why a gate reads unchecked.

| Field | Meaning |
|-------|---------|
| `state` | The file's claim, or `disputed` when evidence holds a `completed` claim back. A `completed` claim on a stage that has opted in to a check reads `checking` while the check is `required` or `pending`, and `check_failed` when it is `failed`; `passed` reads `completed`. A dispute outranks both (the evidence against the claim is shown first, and `check` still tells the check's value). A stage with no status of its own (`unknown`) and sub-stages takes its roll-up's status, with `from_sub_stages: true` |
| `looks_completed` | A `not_started` or `in_progress` stage with some evidence (a gate, a non-empty Done when, or completed sub-stages), every gate `pass`, nothing unticked and nothing open. It never moves the stage |
| `gate_results` | One entry per declared gate: `gate`, `result` (`pass`, `fail`, `pending`, `unchecked`), `reason` (a stable code) and `message` (words). `pending` and `unchecked` never dispute |
| `disputes` | Why a `completed` claim is held back. `kind` is `gate` (with `gate`), `done_when` (`done`, `total`) or `sub_stages` (`open`, `total`), each with a `message`. Unticked criteria are named once, as `done_when`, not again as a failing `checklist` gate |
| `waits_on` | The sibling ids in `depends_on` that are not `completed` or `skipped` by evaluated state, so a dependency that is `checking` or `check_failed` is listed |
| `current` (document) | The first top-level stage whose evaluated state is not `completed` or `skipped` (`disputed`, `checking`, `check_failed` and `unknown` count as not done) |
| `current` (stage) | The same for the stage's children: a child path or `null` |
| `owner_state` | Set when `owner` is a pane id: `working`, `waiting` (waiting, or has an open question), `idle` (an agent at rest, or a shell pane), `gone` (the daemon answered and the pane is not among its panes) or `unknown` (it didn't answer). `null` when the owner is `you`, a label or empty |
| `checker` | The pane that gave the verdict: the `%N` in `checked_by` (`claude %27` is `%27`), else `checked_by` as written (`person`); `null` without `checked_by`. There is none while a check is `required` or `pending`, since `spine set` clears `checked_by` and the verdict has not been written yet |
| `checker_state` | As `owner_state`, for the `checker` pane, from the same daemon read; `null` when `checker` is not a pane id |
| `owner_since` | When the owner pane started working, when `owner_state` is `working` |
| `dimmed` | `true` under a skipped parent |
| `rollup` | Over the children's evaluated states, so `counts.disputed`, `counts.checking` and `counts.check_failed` can be above 0. A `checking` or `check_failed` child is not done: it counts in `total`, not in `done`, and keeps the roll-up `in_progress` |

Gate facts: `pushed` passes for a merged pull request; a deleted remote branch or an ahead count git could not give is `unchecked`; no upstream is a fail. `pr` reads "no pull request" (a fail) for a branch never pushed, and `unchecked` when the remote is gone and no merged pull request is on record, or when `gh` can't say. `review` is `unchecked` when the agent's state can't be read or the branch is 0 commits ahead; it passes when the agent is `done` and the review decision is not `CHANGES_REQUESTED`. `ci` is `unchecked` with no pull request or no checks. `checklist`, once declared, fails on an empty list.

Plain output adds `Current:` and one line per stage with its `state` (and `(file says X)` when disputed), `looks completed`, the owner and its state, the checker and its state, `waits on`, each dispute and each gate that is not a pass, and `Not read:` for a source that was unavailable.

Gates move with git and CI, not with files, so a reader that keeps the evaluation on screen should run it again on a timer.

### Inferred stages

With no `spine/`, `--evaluate` guesses the stages, by the same rules as the app (`src/core/spine/inferred.ts`), so both show the same ones. Plain `show` does not: it stays a file read and answers `exists: false` with no `inferred`. The document is plain `show`'s (`exists: false`, `stages: []`) plus the evaluated top-level keys and `inferred`: Research, Plan, Implement, Verify, Review, and Ship for a linked worktree only (the project's own checkout has no Ship). Each is a stage in the evaluated shape above, with `file: null`, `path` and `id` equal to its `kind`, numbers 10 to 60, `inferred: true` and `source`, what decided its status: `plan`, `workflow`, `review` or `pr`. `current` is the first inferred stage not `completed` or `skipped`. `--stage` still answers `unknown_stage`, since there is no stage file to find.

```json
{"exists": false, "stages": [], "evaluated": true, "current": "implement",
 "inferred": [{"path": "research", "kind": "research", "status": "skipped", "state": "skipped", "inferred": true, "source": "plan", "...": "..."}]}
```

| Stage | Status |
|-------|--------|
| Research | `unknown` when the plan file could not be read, `skipped` when it exists, else `not_started` |
| Plan | `not_started` with no plan file; `in_progress` while it has no tasks or none started, done, skipped or blocked (waiting for approval); else `completed` |
| Implement | From the plan's tasks: `not_started` with no plan or no tasks, `completed` when none are left (or the plan is done), `blocked` when a task is, `in_progress` once a task is started or the plan's owner pane works or waits. Its `owner` is the plan's `owner_pane` |
| Verify | From the pull request's checks: `blocked` when failing, `in_progress` while running, `completed` when they pass and Implement is completed; else `not_started` |
| Review | `in_progress` when the review agent is `done` and the branch is ahead of its base, else `not_started` |
| Ship | `in_progress` while the pull request is open, else `not_started`; it declares the gates `pushed`, `pr`, `ci` and `merged` |

The first workflow run still going in the workspace that has a step named `research`, `plan`, `implement` or `verify` outranks the plan for those stages (`source: "workflow"`): a step that is `pending` reads `not_started`; `waiting`, `running` or `checking`, `in_progress`; `passed`, `completed`; `failed`, `blocked`. The run's pane owns the stage of its current step. A merged pull request makes Review and Ship `completed` and every stage not `completed` `skipped` (`source: "pr"`).

What it reads is what `--evaluate` reads (the plan file, git, the daemon snapshot, the open questions), plus the run files and the pane bindings, and always the one `gh pr view`, whatever the gates, when `gh` is on the PATH and the branch has an upstream: Verify, Ship and the merged rule read the pull request. That costs up to the 5 s `gh` limit on each call. Without `gh` (or with no answer) those stages read as they do with no pull request. The plan's own state is derived as `plan status` does, with the session taken as live when the daemon answers and unknown when it does not.

## Setting a status, note or owner

```sh
workspace spine set [WORKSPACE] STAGE-PATH [--status VALUE] [--note TEXT] [--owner VALUE] [--if-revision REV] [--recursive] [--by LABEL] [--json]
```

At least one of `--status`, `--note` and `--owner` is required (a usage error otherwise). `STAGE-PATH` is the stage's ids joined with `/` (`verify`, `implement/api`), as `show` reports `path`. With `--name WORKSPACE` the one argument is the path.

| Option | Description |
|--------|-------------|
| `--status VALUE` | A status or an alias (see Status), written as the canonical value. `unknown` is refused (`invalid_status`) |
| `--note TEXT` | One line of at most 300 characters, written as `note:`. Alone it changes only the note and keeps the status. With a status change and no `--note` the note is cleared; when the status stays, the note is kept. An empty `--note ""` clears it |
| `--owner VALUE` | Who works the stage: a pane id such as `%6`, `you`, or an agent label such as `claude %6`; one line of at most 64 characters, written as `owner:`. Alone it changes only the owner. An empty `--owner ""` removes the line. A usage error with `--recursive`, since an owner belongs to one stage |
| `--if-revision REV` | Refuse with `stale_revision` unless the stage file's current `revision` is `REV`. With `--recursive` it checks the named stage's file only |
| `--recursive` | Also set every sub-stage, at any depth, that is neither `completed` nor `skipped`, parents first, each file written whole. A sub-stage that is a folder with no file is left out |
| `--by LABEL` | The `updated_by` label (at most 100 characters). Default: `<agent> <pane>` (such as `claude %6`) when `$TMUX_PANE` is a pane the workspace's agent daemon has logged as a coding agent, else `person` |

Every write sets `updated` (now, UTC) and `updated_by`. Beyond those, only the `status`, `note` and `owner` lines that the call changes are touched (a `status` that already reads as asked keeps its text, even an alias), and the other bytes stay as they were: the other lines, the body, line endings (LF or CRLF), a byte order mark, comments, unknown keys and lists stay as they were. A key that is missing is added at the end of the frontmatter block; a note being cleared is removed. A note or label that is not plain words is written as a double-quoted string. Nothing is written when the stage already reads the status, the note and the owner as asked; the stage is in `unchanged`.

The file is read as bytes, opened without following a link, written to a temp file in the same folder (a dot name, so it is never read as a stage), fsynced and renamed over the original. If the file changes between the read and the rename, the write starts over once, then is refused (`changed_while_writing`). Writers of one workspace take turns through a lock file in the CLI's state folder (`$XDG_STATE_HOME/workspace/.spine/`, never the notes folder), waited for up to 10 seconds, so two calls that overlap both land, the second one on top of the first. An editor holding an unsaved buffer is not covered by the lock.

Each file written appends one [`spine_changed`](README.event-log.md) line to the event log, carrying the new `revision` and the `owner` after; a write that changed only the owner has `change: "owner"`.

A stage changed some other way, by hand in an editor or by an agent's edit tool, is logged too while the workspace's agent daemon runs (`spine_events` in [`capabilities`](README.capabilities.md)): see [`event-log`](README.event-log.md). The daemon recognises a `spine set` or `spine verify` write by its revision, so one write is one line.

### Owner finished

When the agent that owns a started stage finishes, the daemon writes one `spine_changed` line with `change: "owner_finished"` (`spine_report` in [`capabilities`](README.capabilities.md)): `path`, `owner` (the pane id, as `spine start` wrote it) and `state`. Two things trigger it: the pane's turn ends (the Stop hook; for Codex also an interrupt) while it owns a stage that is `in_progress`, or a stage with an owner moves to `completed` (written by `spine set` or by hand). `state` is `completed`, `checking` (completed, check still pending) or `in_progress`. An `in_progress` line means the turn ended with the work not claimed done, and is written at every turn end; a completed stage is reported once, when it is set, and the Stop that follows adds nothing. A pane that owns no stage, and a sub-agent's stop, write nothing. The daemon must be running; a turn that ended while it was down is not reported.

```json
{
  "schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh",
  "written": [
    {"path": "verify", "file": "40-verify.md", "status": "completed", "previous": "in_progress", "revision": "0c1d2e3f",
     "updated": "2026-10-17T22:01:00Z", "updated_by": "person", "note": null, "owner": null}
  ],
  "unchanged": [{"path": "review", "file": "50-review.md", "status": "completed", "owner": null, "revision": "5a6b7c8d"}]
}
```

`written` and `unchanged` are in tree order. For a stage that has opted in to a check, a `written` row also has `check` (the value after), and the event has `check` and, when it moved, `previous_check`. Plain output is one line per stage.

A refusal is the standard error document. With `--recursive` the run stops at the first refusal of a stage file and `details.written` lists the stages already written (rows as above); a refusal before any write (`invalid_status`, `no_spine`, `unknown_stage`, `lock_busy`) has no `written`. A stage already written reads the status on a second run and lands in `unchanged`, so running the same command again finishes the job; `--if-revision` then guards the named stage only, which may by then be unchanged.

| `code` | When |
|--------|------|
| `invalid_status` | `--status` is not a status or an alias; `unknown` can't be set (`details.status`, `details.allowed`) |
| `no_spine` | The workspace has no `spine/` folder (`details.workspace`, `details.dir`) |
| `unknown_stage` | No stage has that path (`details.path`, `details.stages`) |
| `stale_revision` | `--if-revision` differs from the file's revision; `details.revision` and `details.status` are the current ones |
| `spine_unwritable` | The file can't be rewritten safely. `details.reason`: `link`, `not_a_file`, `too_large` (over 64 KB), `not_utf8`, `no_frontmatter` (no opening `---`, or none closed within 100 lines), `no_file` (a stage folder without a file), `missing`, `lock_unavailable` (the lock file in the state folder can't be opened), `unreadable_result` (the change would not read back: the closing `---` would pass line 100 or the status the 40-key cap), `io_error`, `changed_while_writing`, or `lock_busy`; `details.file` |
| `usage` | A missing `--status` or path, or a `--note` or `--by` that is not one short line |

`spine_set` in [`capabilities`](README.capabilities.md) is `2` when this verb takes `--owner` and accepts `--note` or `--owner` without `--status`. The 64-character limit on `--owner` applies to the command; a hand-edited owner is read up to 500 characters.

## Checking a stage apart from its claim

A stage's `status` is its claim. A stage can also ask for a separate check: a second reader (a checker agent, a person) looks at the finished work and gives a verdict, so a worker saying `completed` is not the last word. The check is recorded in its own frontmatter lines, never in `note`:

| Key | Meaning |
|-----|---------|
| `check` | `required`, `pending`, `passed` or `failed` |
| `checked_by` | Who gave the verdict (`claude %27`, `person`), at most 100 characters |
| `checked_at` | When, UTC ISO |
| `check_note` | What was checked and found, one line of at most 300 characters |

**Opt-in is the presence of a `check:` line.** A stage with no `check:` (or one holding a value that is not one of the four, which is the warning `unknown_check`) has no check; its `check`, `checked_by`, `checked_at` and `check_note` read `null` in `spine show --json`, and nothing here changes how it behaves. One mechanism was chosen on purpose: a stage opts in by writing `check: required` in its file (a template, `spine init`'s output or a hand edit), so the request needs no second switch (a `checked` gate would have to be listed in `gates:` and kept in step with the value). `required` is the resting value: the stage asks for a check and has none to give yet.

`spine set` keeps the check in step with the claim, only for a stage that has opted in and only when the status changes: setting `completed` writes `check: pending` and removes `checked_by`, `checked_at` and `check_note`; setting any other status (a reopening) writes `check: required` and removes the same three lines. A call that leaves the status alone (a new `--note`, or `--status completed` on a completed stage) does not touch them. `spine verify` writes the verdict. Reopening a stage whose check `failed` keeps its `check_note` (and only that line, so `spine set` writes no `note`): the reason it failed stays in the file for whoever picks it up, beside `check: required`. It stays through further reopenings until `spine set --status completed` removes it again, and reopening a `passed` stage clears all three lines. A hand reopening that leaves `check: passed` behind is the warning `check_passed_not_completed`. A hand edit that sets `status: completed` without `spine set` leaves `check` as it was; `spine verify` accepts a completed stage whose check is `required`.

## spine verify

```sh
workspace spine verify [WORKSPACE] STAGE-PATH (--pass | --fail) --note TEXT [--by LABEL] [--if-revision REV] [--json]
```

Records the verdict of a check. It writes `check` (`passed` for `--pass`, `failed` for `--fail`), `checked_by`, `checked_at` (now, UTC) and `check_note`, and no other line: `status`, `note`, `owner`, `updated` and `updated_by` stay, since the claim did not change. Every other byte stays as `spine set` keeps it, and the write takes the same lock and temp-file-and-rename path. A verdict can be replaced: running `verify` again on a `passed` or `failed` stage overwrites the four lines.

| Option | Description |
|--------|-------------|
| `--pass`, `--fail` | The verdict; exactly one is required (a usage error otherwise) |
| `--note TEXT` | Required. One line of at most 300 characters, written as `check_note:`. A verdict with no reason is not accepted |
| `--by LABEL` | The `checked_by` label (at most 100 characters). Default as for `set`: `<agent> <pane>` (such as `claude %27`) when `$TMUX_PANE` is a pane the agent daemon has logged as a coding agent, else `person`. The label is the only record of which pane checked |
| `--if-revision REV` | Refuse with `stale_revision` unless the stage file's `revision` is `REV` |

Refusals: `check_not_required` (the file has no `check:` line; nothing is written), `stage_not_completed` (the file's status is not `completed`; `details.status`), `unknown_stage`, `no_spine`, `stale_revision` (checked before the two above), `spine_unwritable`. A stage that is only a folder is `spine_unwritable` with reason `no_file`.

When a line changed, one [`spine_changed`](README.event-log.md) line is recorded with `change: "check"`, `check`, `previous_check`, `status`, `check_note`, `by` and the new `revision`. The agent daemon recognises the write by its revision (as it does for `set`), so one write is one line. The same verdict, label and note again writes nothing and records nothing (`changed: false`), whatever the time, so a retry does not churn the revision; `checked_at` and `checked_by` are the verdict's time and author, since `updated` and `updated_by` keep the claim's. A file with `check: bogus` is `check_not_required` too, with `details.value` naming the bad value.

```json
{"schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh", "path": "verify", "file": "40-verify.md",
 "check": "passed", "previous_check": "pending", "checked_by": "claude %27", "checked_at": "2026-10-19T18:56:28Z",
 "check_note": "74 commands classed, no gaps", "changed": true, "revision": "0c1d2e3f"}
```

`spine_verify` in [`capabilities`](README.capabilities.md) is `1`. `spine_set` is `3` when `set` keeps the check in step with the status. `spine_eval` is `3`: `--evaluate` reads a completed stage with `check: required` or `pending` as `checking` and one with `check: failed` as `check_failed` (see [Evaluating the stages](#evaluating-the-stages)), neither is done for `current`, `waits_on`, the roll-up or `spine start`, and the [`snapshot`](README.snapshot.md) spine block follows. Plain `show` (no `--evaluate`) still prints the file's claim and `check`.

Model parity: the app's `model.ts` `rollUp` has no check states yet; until it does, `checking` and `check_failed` are the CLI's additions, counted as in progress and never as done, so the two agree on every stage that has not opted in.

## spine check

```sh
workspace spine check [WORKSPACE] STAGE-PATH --item N [--item N ...] (--done | --undone) [--if-revision REV] [--by LABEL] [--json]
```

Ticks (`--done`) or unticks (`--undone`) items of the stage's `## Done when` checklist. `N` is the item's 1-based position in `done_when.items`, as `show` lists them; repeat `--item` for several. Only the `[ ]` or `[x]` on each item's line changes. Every other byte stays (line endings, a BOM, the frontmatter, `updated` and `updated_by` too: a tick is not a status change). The write takes the same lock and the same temp-file-and-rename path as `set`. An item already in the asked state is left alone, and when no item changes nothing is written and no event is recorded. Every item number is checked first: one that is not there (`unknown_item`) writes nothing.

When a box changed, one [`spine_changed`](README.event-log.md) line is recorded with `change: "done_when"`, `items` (the numbers that changed), `by` and the new `revision`.

```json
{
  "schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh", "path": "verify", "file": "40-verify.md",
  "items": [{"n": 1, "text": "Tests pass", "done": true}, {"n": 2, "text": "Docs updated", "done": false}],
  "done_when": {"total": 2, "done": 1}, "changed": [1], "revision": "0c1d2e3f"
}
```

`items` lists every item after the call, `changed` only the ones this call flipped (empty when it was a no-op). Refusals: `unknown_item` (`details.item`, `details.total`), `stale_revision`, `spine_unwritable`, `no_spine`, `unknown_stage`. `spine_check` in [`capabilities`](README.capabilities.md) is `1`.

## spine goal set

```sh
workspace spine goal set [WORKSPACE] TEXT [--if-revision REV] [--by LABEL] [--json]
```

Writes `title:` in `spine/goal.md`. TEXT is one line of at most 120 characters, without control characters; an empty or multi-line TEXT is a usage error. An existing `goal.md` keeps every other byte (the body, other keys, line endings, a BOM). A missing one is made with `spine: 1`, `title:` and a `# TEXT` heading, without replacing a file that appears meanwhile. A workspace with no `spine/` folder is refused (`no_spine`); this verb never makes the folder (use `spine init`). The write takes the same lock and temp-file-and-rename path as `set`; a link, a file that isn't UTF-8 or one with no frontmatter is `spine_unwritable`. A title already equal writes nothing and records nothing. `--if-revision` is checked against `goal.md`'s revision (from `spine show`); a missing file has none, so it is `stale_revision`.

When the file changed, one [`spine_changed`](README.event-log.md) line is recorded with `change: "goal"`, `title`, `created`, `by` and the new `revision`.

```json
{"schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh", "goal": {"file": "goal.md", "title": "Fix the OAuth refresh race", "revision": "5e6f7a8b"}, "created": false, "changed": true}
```

`changed` is false when the title already read as asked (nothing written, no event). TEXT that starts with a dash needs `--` before it. For a missing `goal.md`, `stale_revision` has `details.revision` null. Refusals: `no_spine`, `stale_revision`, `spine_unwritable`. `spine_goal` in [`capabilities`](README.capabilities.md) is `1`.

## spine start

```sh
workspace spine start [WORKSPACE] STAGE-PATH [--pane PANE | --spawn KIND] [--play REF] [--if-revision REV] [--json]
workspace spine start [WORKSPACE] STAGE-PATH --fan-out [--spawn KIND] [--max N] [--json]
```

Gets an agent working on one stage. `STAGE-PATH` is as for `set`: with two arguments the first is the workspace, and with `--name WORKSPACE` the one argument is the path. It is modelled on [`plan start --task`](README.plan.md#one-task).

| Option | Description |
|--------|-------------|
| `--pane PANE` | Send the stage to that pane: a pane id (`%21`) or `window.pane` (`0.1`) of the workspace's own session (`bad_pane`, `no_such_pane`, `wrong_session` otherwise) |
| `--spawn KIND` | Split a new pane, start that agent in it (`claude`, `codex`, ..., as `plan start --spawn`), and wait until it is ready for text |
| `--play REF` | The play to send. Default: the stage file's `play:`, else by `kind`: `research` gets `research`, `plan` and `implement` get `implementation-plan`, `review` gets `review`, the others none |
| `--if-revision REV` | Refuse with `stale_revision` unless the stage file's `revision` is `REV` |
| `--json` | Print one JSON document |

Without `--pane` or `--spawn` the pane is the stage's `owner` when the agent daemon lists it as a coding-agent pane, else the main Claude Code or Codex pane. A workspace with no session is launched with the play and the brief (with the packs `launch` sends, the `spine` pack among them); `--pane` or `--spawn` on a workspace with no session is `no_session`.

It works in this order:

1. Under the spine write lock (the one `set` takes), the stage is read again and the file-only refusals are made again, then one write sets `status: in_progress` (when it isn't already), `owner: <pane>`, `updated` and `updated_by` (the pane's agent label, `claude %21`) and records `spine_changed`. A refusal here stops before anything is typed. The agent's first `spine show` therefore already reads `in_progress` with itself as the owner.
2. The brief is typed into the pane: the play's line, the `spine` pack, and a few lines that name the stage's path and file and the goal file, with the stage title quoted as data. No stage body is pasted.
3. The pane is bound as a play binding with the `spine` pack and `focus: "spine stage <path>"`, so the SessionStart hook repeats both after `/clear`. A pane bound to a run or a review keeps that binding. A binding that fails is a note in `message`.

A `--spawn` pane starts in the workspace's checkout, whatever directory `spine start` ran in. With `--spawn` the write waits until the new agent is ready, since its pane id is not known before; an agent that is not ready in time is `failed` with `reason: "prompt_not_sent"`, nothing is written or typed, and the new pane is closed again (`details.pane_id`, `details.pane_closed`; `false` when tmux could not close it); a refusal made under the lock after the split, or a failed delivery of the brief, names the new pane in `details.pane_id` (and `details.pane` for the refusal) with `pane_closed: false`, and the pane is left open. Only a pane `--spawn` split is closed (capability feature `spawn_cleanup`). A launch writes `in_progress` (with `updated_by: "spine start"`) before it launches and the owner once the launch names the pane. If the brief can't be delivered, the file is left as written, and the result is `failed` with the delivery's error code as `reason` and a `message` that gives the `spine set` command that sets the stage back (its previous status and owner).

```json
{"schema_version": 1, "ok": true, "workspace": "fix-oauth", "path": "verify", "file": "40-verify.md",
 "outcome": "sent", "reason": null, "pane": "%21", "owner": "%21", "status": "in_progress", "previous": "not_started",
 "revision": "3e1f0a9b", "play": null, "message": null}
```

`outcome` is `sent`, `spawned` (to a new pane), `launched`, `already_working` (the owner pane already works on the stage; nothing is written, and the document reads the file as it is), or `failed`, the one outcome with `ok: false` and exit status 1. `revision` is the stage file's revision after the write, for a later `--if-revision`. `play` is the play's ref, or null. Plain output is one line, plus any note.

| `code` | When |
|--------|------|
| `no_spine`, `unknown_stage` | As for `set` |
| `spine_unwritable` | As for `set`; `no_file` for a stage that is only a folder |
| `stage_done` | The file says `completed` or `skipped` (`details.status`); the message gives `spine set --status in_progress` to reopen it. A `completed` stage whose `check` is `failed` is not refused: `start` reopens it for rework (`in_progress`, `check: required`; the document's `previous` is `completed`, which marks a rework) and the brief quotes the `check_note` |
| `stage_waiting` | A stage in its `depends_on` is not `completed` or `skipped` by its file (a folder-only stage by its sub-stages); `details.waits_on`. File statuses only, so `start` runs no `gh`: a dependency `--evaluate` reads as `disputed` does not hold it back. A dependency that claims `completed` while its check is `required`, `pending` or `failed` holds it back; `details.reasons` maps its id to `check_pending` or `check_failed` (a folder-only dependency, held by a sub-stage's check, gets that sub-stage's reason, `check_failed` winning over `check_pending`) |
| `stale_revision` | `--if-revision` differs from the file's revision |
| `stage_owned` | Its owner pane is working on it and another pane, or `--spawn`, was asked for (`details.owner`) |
| `pane_busy` | The pane waits on a person or works on something else (`details.state`) |
| `no_agent_pane` | The named pane runs no coding agent the daemon knows, or no pane runs Claude Code or Codex |
| `no_daemon` | The workspace's agent daemon did not answer |
| `no_session` | `--pane` or `--spawn` and the workspace has no session |
| `usage` | A missing path, `--pane` with `--spawn`, an unknown `--spawn` kind, or an option of `show` or `set` |

`spine_start` in [`capabilities`](README.capabilities.md) is `1` when this verb exists.

### spine start --fan-out

```sh
workspace spine start [WORKSPACE] STAGE-PATH --fan-out [--spawn KIND] [--max N] [--json]
```

Starts one agent per sub-stage of `STAGE-PATH` (the stages in the folder named like its file). Each sub-stage that is `not_started` goes through the same `spine start --spawn` steps as one stage (claim under the spine lock, a new pane in the workspace checkout, the brief naming that sub-stage's file, the binding), one after another, so every refusal of the single form applies to it: `stage_waiting` (an unmet `depends_on`, including a check that is pending or failed), `stage_owned`, `pane_busy`, and a pane that was not ready (`prompt_not_sent`).

| Option | Description |
|--------|-------------|
| `--spawn KIND` | The agent to start in each pane. Default: the kind of the workspace's main agent pane (`claude` when there is none) |
| `--max N` | Spawn at most `N` panes (default 3, `--max=N` works too). A startable sub-stage past the cap is `skipped` with code `max_reached`; refusals do not count against the cap |

`--pane`, `--if-revision` and `--play` are usage errors with `--fan-out` (many stage files, each with its own play), and so is `--max` without `--fan-out`.

```json
{"schema_version": 1, "ok": true, "workspace": "fix-oauth", "path": "implement", "agent": "claude", "max": 3,
 "results": [
   {"path": "implement/api", "result": "spawned", "pane": "%31", "code": null, "message": null},
   {"path": "implement/ui", "result": "refused", "pane": null, "code": "stage_waiting", "message": "Stage implement/ui of 'fix-oauth' depends on api, ..."},
   {"path": "implement/docs", "result": "skipped", "pane": null, "code": "already_started", "message": "status is in_progress"}],
 "spawned": 1, "refused": 1, "skipped": 1}
```

A sub-stage that is not `not_started` is `skipped` (`stage_done` for `completed` or `skipped`, `already_started` otherwise), except one whose owner pane is working: that is `refused` with `stage_owned`. Fan-out never reopens a completed stage whose check failed; start that one by name. A refusal that follows a split names the new pane, which is left open.

A `spawned` entry's `message` is null unless the pane could not be bound (the single form's note). The `ok: false` document has `results` and no top-level `code`; read each entry's `code`.

Exit status is 0 unless nothing was spawned and at least one sub-stage was refused (`ok: false`, exit 1, the document still on stdout under `--json`). All skipped, or nothing startable, is exit 0.

These refuse the whole fan-out as an error (`ok: false`, a `code`), before anything is claimed: `no_spine`, `unknown_stage`, `no_substages` (the stage has no sub-stages; use plain `spine start`), `no_session` (the workspace is not running), `no_daemon`.

`spine_fanout` in [`capabilities`](README.capabilities.md) is `1` when `--fan-out` exists.

## spine init

```sh
workspace spine init [WORKSPACE] [--name WORKSPACE] [--template NAME] [--dry-run] [--json]
```

Creates the `spine/` folder in the workspace's notes directory from a template: a library entry of kind `spine`, a folder of stage files (see [`library`](README.library.md)). Templates layer like plays: a project's entry hides a global one of the same name, which hides the built-in `default`. A linked template is read through its link when `init` runs.

| Option | Description |
|--------|-------------|
| `WORKSPACE`, `--name WORKSPACE` | As for `show` |
| `--template NAME` | The template. Default: the workspace's `spine.template` (see below), else `default` |
| `--dry-run` | Say what would be written and write nothing, not even the notes directory |
| `--json` | Print one JSON document |

The built-in `default` has `10-research.md`, `20-plan.md`, `30-implement.md`, `40-verify.md`, `50-review.md`, `60-ship.md`, `goal.md` and `README.md`. Every stage has `spine: 1`, `title`, `description`, `kind`, `status: not_started`, `depends_on`, `gates` (Research `checklist`; Plan `plan`, `checklist`; Implement `plan`; Verify `checklist`, `ci`; Review `review`; Ship `pushed`, `pr`, `ci`, `merged`), a short brief and a `## Done when` list. A main checkout (a workspace name without a `.worktree-` part) gets any template without its Ship stage (`NN-ship.md` or `NN-ship/`).

Placeholders in every UTF-8 file are filled: `{{WORKSPACE}}` is the workspace name, `{{BRANCH}}` the checkout's branch (empty on a detached HEAD), `{{TITLE}}` the workspace's task title, else the branch, else the name, folded to one line. Other text is copied as it is. Links inside a template and names starting with a dot are not copied.

`init` never overwrites. When `spine/` exists with anything in it (a hidden file counts) or is a file, the outcome is `exists`; a `spine/` folder with no entries at all is filled in (`created`) and nothing is written; a `spine` that is a link is refused with `spine_unwritable`. The notes directory is made when needed, as `notes dir --create` does. The files are written into a temporary folder beside `spine/` and renamed into place, so a reader sees all of the spine or none.

```json
{ "schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh", "outcome": "created",
  "template": {"name": "default", "scope": "builtin", "source": "default"},
  "dir": "/src/api/.worktrees/fix-oauth-refresh/tmp/workspace-notes/spine",
  "files": ["10-research.md", "20-plan.md", "30-implement.md", "40-verify.md", "50-review.md", "60-ship.md", "README.md", "goal.md"] }
```

`outcome` is `created`, `exists` (`files` is empty) or `would_create` (`--dry-run`; `files` is what would be written). `template.scope` is `builtin`, `global` or `project`; `template.source` says where the name came from: `flag` (`--template`), `worktree`, `project` or `global` (the layer of `spine.template` that set it) or `default`. Errors: `unknown_workspace`, `unknown_template`, `notes_dir_unresolved`, `config_parse`, `spine_unwritable` (below).

`spine_init` in [`capabilities`](README.capabilities.md) is `1` when this command exists, `2` when the template and `start` can be chosen by config (below).

## Choosing the template by config

Two [config keys](README.config.md) choose the template without a flag. Both layer global, then project, then the workspace's own (worktree) file, the nearest one winning, and `config show --json` reports each with its `source`.

| Key | Default | Meaning |
|-----|---------|---------|
| `spine.template` | `default` | The `spine` library template `spine init` uses when `--template` is not given, and `start` uses for its init. A name no library entry has is a [`config validate`](README.config.md) warning (`unknown_spine_template`), and `spine init` answers `unknown_template` naming the layer it came from |
| `spine.auto` | `false` | When `true`, [`start`](README.start.md#spine) runs `spine init` once the new worktree exists |

```sh
workspace config set spine.template team                      # the project's default
workspace config set spine.template docs --name api.worktree-login   # one workspace's own
workspace config set spine.auto true
```

`start --spine[=NAME]` and `--no-spine` override both keys for that start.

## Telling agents the convention

The built-in `spine` play ("Keep this workspace's stages current", `workspace library show spine --builtin`) teaches an agent the rules: where `spine/` is; `workspace spine set <stage-path> --status in_progress --owner "$TMUX_PANE"` when it starts a stage; `--status blocked --note "<why>"` when stuck; `spine check --item N --done` for each `## Done when` item it has met and checked; `spine show --stage <stage-path> --evaluate` before it claims a stage done, and no `completed` while a gate fails or a dispute is open; for a stage with a `check:` line, claiming `completed` and stopping, never running `spine verify` on its own stage; a checker (a different pane or sub-agent) giving the verdict with `spine verify --pass|--fail --note`, never in `spine set --note`; a driver starting the next stage only when the dependency is out of `waits_on` in `spine show --evaluate --json` (check `passed`) and sending a `check_failed` stage back with `spine start`; working on its own stage and sub-stages only (no `spine start` for another stage unless it is the driver); leaving other files, numbers, `gates` and `depends_on` alone; and listing artifacts in `artifacts:`. It tells the agent to change `status:`, `owner:` and the `Done when` boxes only through these commands.

It is an automatic pack, like `notes`: [`start`](README.start.md#packs), [`launch`](README.launch.md) and `workspace instructions compose --start` add `spine` after `notes` (and before `dev`) whenever the workspace's `spine/` folder exists in its notes directory, found the way `show` finds it and never through a link. It is reported with `source: "config"` like the other automatic packs, `--no-packs` drops it, and it is recorded in the pane's [binding](README.binding.md#packs) `packs`, so SessionStart repeats it after `/clear` or compaction. A workspace without `spine/` gets nothing new.

`spine_pack` in [`capabilities`](README.capabilities.md) is `4` (the play and the brief `spine start` types tell the agent to set the stage's status and stop without waiting to be asked, and to write its handoff doc and stop at the context threshold) when the play and the automatic pack exist and the play teaches `spine set --owner`, `spine check`, `spine show --evaluate` and the checker and driver roles.

## The spine folder

The folder is `spine/` in the workspace's notes directory (see [`notes`](README.notes.md)), found the way `notes dir` finds it. The name is fixed.

- **Stage files** are named `<number>-<id>.md`: one to three digits, a hyphen, a lowercase id of letters, digits and hyphens (`10-research.md`, `35-security-review.md`). The number orders the stages (ties by id); the id names a stage. Number in tens, so a stage can be slotted in without renaming.
- **Sub-stages** live in a folder named like a stage file without `.md` (`30-implement/` beside `30-implement.md`), in the same convention, to three levels of stages (`spine/30-implement/20-api/10-routes.md`). A stage's `path` is its ids joined with `/` (`implement/api`). A folder with no stage file beside it is a stage with status `unknown` and the warning `folder_without_file`; its children still show.
- **`goal.md`** (top level only) holds the goal: its `title` is the goal line.
- Anything else is not a stage and is listed in `not_stages` (paths below `spine/`). Names that start with a dot are left out.

### Frontmatter

The same dialect as the plan file: a block between two `---` lines at the top, read line by line as `key: value`, not as YAML, so a stray colon in a title can't make a file unreadable. Quotes around a value are stripped. Two list forms are read: `key: [a, b]` on one line, or `key:` followed by indented (or not indented) `- a` lines. Nothing else from YAML is read; such a line is a `bad_line`. The closing `---` must be within the first 100 lines, or the file reads as having no frontmatter. Lines starting with `#` and blank lines are skipped. Repeated keys keep the first.

| Key | Values | Meaning |
|-----|--------|---------|
| `spine` | `1` | Format version. A higher number gives `newer_format`, and the file is still read |
| `status` | see below | The stage's claimed state |
| `description`, `note` | one line | What the stage is for; the reason that goes with the status |
| `title` | text | The label; default from the id (`security-review` is "Security review") |
| `kind` | `research`, `plan`, `implement`, `verify`, `review`, `ship`, `custom` | Default: the id when it is one of the first six, else `custom`. An unknown value is dropped (`unknown_kind`) |
| `owner` | a pane id, `you`, or an agent label | Who works on it |
| `depends_on` | sibling ids | Dependencies that are not siblings are dropped (`unknown_dependency`); so are edges in a cycle (`dependency_cycle`) |
| `gates` | `plan`, `checklist`, `pushed`, `pr`, `ci`, `merged`, `review` | Checks a reader runs from live facts. An unknown value is dropped (`unknown_gate`) |
| `artifacts` | paths or https URLs | Links for the stage |
| `play`, `agent` | a library ref; `claude`, `codex` | The play and agent a start uses |
| `updated`, `updated_by` | ISO date-time; `person` or an agent label | When and by whom the status was last set |
| `check` | `required`, `pending`, `passed`, `failed` | Opts the stage in to a separate check; an unknown value reads as no check (`unknown_check`). See [Checking a stage apart from its claim](#checking-a-stage-apart-from-its-claim) |
| `checked_by`, `checked_at`, `check_note` | a label; ISO date-time; one line (300 characters) | The verdict `spine verify` gives |

Other keys are ignored. `kind` and `gates` are read case-insensitively. A value that starts with `[` but is not a whole `[...]` list is read as text. The body is free Markdown; one part is read: the column-0 `- [ ]` and `- [x]` lines under a `## Done when` heading, up to the next heading (not indented, not in fenced code or HTML comments).

### Status

`status` in the JSON is always one of `not_started`, `in_progress`, `blocked`, `completed`, `skipped` or `unknown` (missing, empty or unrecognised, never an error). `status_raw` is the word in the file. Words are read case-insensitively, with `-` and spaces read as `_`:

| Status | Aliases |
|--------|---------|
| `not_started` | `todo`, `pending`, `planned`, `open` |
| `in_progress` | `active`, `started`, `doing`, `wip` |
| `blocked` | `stuck` |
| `completed` | `done`, `complete`, `finished`, `closed` |
| `skipped` | `skip`, `n/a`, `wontdo` |

### Limits

| What | Limit | Past it |
|------|-------|---------|
| Names read per folder | 64 | the rest are left out; top-level `truncated` is `entries` |
| Stages per folder | 24 | the first 24 by order are read; `truncated` is `stages` |
| Stages in all | 96 | a folder's own stages are counted before its sub-stages are read; later ones (in order) are not read; `truncated` is `stages` |
| Levels of stages | 3 | a folder below the third level is not read; `too_deep` on the stage |
| Bytes per file | 64 KB | the first 64 KB are read; `too_large` and `truncated: true` on the stage. The `revision` still covers every byte |
| Frontmatter | closing `---` within 100 lines; 40 keys; keys of 64 characters | `no_frontmatter` or `clipped` |
| Values | 500 characters (`title` 120, `description` and `note` 300); lists of 20 items | cut, with `clipped` |

Values are folded to one line: control characters and runs of white space (including Unicode line and paragraph separators) become one space, and format characters (such as bidi overrides) are removed. A closing line of `...` also ends the frontmatter. Names with control characters, invalid UTF-8 or a leading dot are skipped without a warning.

### Links

A link is never followed. A linked `spine`, stage file, `goal.md` or stage folder is a `link` warning, and nothing under it is read. A stage "file" that is a folder, a pipe or the like is `not_a_file`; bytes that are not UTF-8 are `not_utf8` and the file is not read.

## JSON output

```json
{
  "schema_version": 1, "ok": true,
  "workspace": "fix-oauth-refresh",
  "dir": "/src/api/.worktrees/fix-oauth-refresh/tmp/workspace-notes/spine",
  "exists": true,
  "goal": {"file": "goal.md", "title": "Fix OAuth token refresh race", "revision": "a1b2c3d4", "warnings": []},
  "stages": [
    {
      "path": "implement", "file": "30-implement.md", "number": 30, "id": "implement", "revision": "9f8e7d6c",
      "title": "Implement", "description": "Make the refresh path safe under concurrent requests",
      "status": "in_progress", "status_raw": "active", "note": null, "kind": "implement", "owner": "%6",
      "depends_on": ["plan"], "gates": ["plan"], "artifacts": ["IMPLEMENTATION_PLAN.md"], "play": null, "agent": null,
      "updated": "2026-10-17T21:40:00Z", "updated_by": "claude %6", "check": null, "checked_by": null, "checked_at": null, "check_note": null, "modified_at": "2026-10-17T21:40:02Z",
      "done_when": {"total": 4, "done": 2, "items": [{"text": "...", "done": true, "line": 18}]},
      "rollup": {"status": "in_progress", "done": 1, "total": 3, "counts": {"completed": 1, "in_progress": 1, "not_started": 1, "blocked": 0, "skipped": 0, "unknown": 0, "disputed": 0, "checking": 0, "check_failed": 0}},
      "warnings": [{"code": "bad_line", "line": 7, "message": "..."}],
      "truncated": false,
      "children": [{"path": "implement/api", "file": "30-implement/10-api.md", "...": "same shape"}]
    }
  ],
  "not_stages": ["Research notes.md"],
  "truncated": null,
  "warnings": []
}
```

| Field | Meaning |
|-------|---------|
| `dir` | The `spine/` folder, below the real path of the notes directory |
| `exists` | `false` when there is no `spine/`. A link or a file in its place is `true`, with a warning in the top-level `warnings` |
| `goal` | `goal.md`, or `null` |
| `stages` | The top-level stages in order, each with `children` in the same shape |
| `path` | Ids from the top, joined with `/`. A repeated id repeats the path; `file` tells them apart |
| `file` | The stage file below `spine/`; `null` for a folder with no stage file |
| `revision` | The first 8 hex digits of the SHA-256 of all of the file's bytes: it changes when any byte changes and only then. `null` when the file was not read (a link, a non-file). `spine set --if-revision` compares it |
| `status`, `status_raw` | See Status. `status_raw` is `null` when `status:` is missing or empty |
| `kind`, `depends_on`, `gates` | After the checks above: always a known kind, and only known gates and sibling ids |
| `modified_at` | The file's modification time, UTC, to the second |
| `done_when` | The `## Done when` checklist: `total`, `done` and the `items` with their line |
| `rollup` | Only on a stage with children: `status`, `done`, `total` and `counts`. It reads each child's effective state: the child's own `status`, or, when it has none (`unknown`, as a folder with no stage file always does) and has sub-stages of its own, the status of its own roll-up, worked out from the bottom up. Over the children that are not skipped (`total` counts them, `done` the completed ones): `skipped` when none are left; `completed` when all are completed; else `blocked` when any is blocked; else `in_progress` when any is in progress, completed or disputed; else `not_started`. A leaf with no status counts as not started. `counts` lists every child by effective state (`completed`, `in_progress`, `not_started`, `blocked`, `skipped`, `unknown`, `disputed`, `checking`, `check_failed`), skipped ones included; the last three are 0 until a verdict is evaluated. Plain `show` rolls a completed child that awaits a check up as `checking` (not done), so a parent is `completed` only when every child is done. A skipped stage still reports its `rollup` |
| `warnings` | `{"code", "line", "message"}`, plus `value` for the codes that name one; `line` is `null` for a warning about the whole file |
| `truncated` (stage) | Whether only the start of the file was read |
| `truncated` (top level) | `entries`, `stages` or `null` |
| `not_stages` | Names below `spine/` that are not stages, sorted |

### `--stage` and `--body`

With `--stage`, the document is `{"schema_version", "ok", "workspace", "dir", "goal", "stage"}`: `stage` has the shape above, `children` included, and there are no `exists`, `stages` or `not_stages` keys. With `--body`, `stage` (or `goal`, without `--stage`; `null` without `goal.md`) gains:

| Field | Meaning |
|-------|---------|
| `body` | The text after the frontmatter (the whole text when there is none), at most 16384 bytes, with line endings as `\n` (a CRLF file's `\r` is dropped, so the text can differ from the bytes `revision` covers). Plain output prints control characters other than newline and tab as `\u{..}`. `null` when there is no file or it was not read as text (a link, a non-file, not UTF-8) |
| `body_truncated` | Whether the body was cut at 16 KB, or the file itself was cut at 64 KB. Not `truncated`, which says only the first 64 KB of the file were read |

### Warning codes

`no_frontmatter`, `bad_line`, `duplicate_key`, `duplicate_id` (the second stage with an id; `depends_on` means the first), `unknown_kind`, `unknown_gate`, `unknown_check`, `check_passed_not_completed` (`check: passed` on a stage whose status is not `completed`; `value` is the status), `unknown_dependency`, `dependency_cycle`, `clipped`, `not_utf8`, `link`, `not_a_file`, `too_large`, `folder_without_file`, `too_deep`, `newer_format`.

## Errors

| `code` | When |
|--------|------|
| `unknown_workspace` | The workspace has no known checkout (`details.name`) |
| `not_in_workspace` | No workspace given and none detected from the current directory |
| `notes_dir_unresolved` | The notes directory can't be worked out (see [`notes`](README.notes.md)) |
| `unknown_item` | `check`: the stage's checklist has no item with that number (`details.item`, `details.total`, `details.file`) |
| `unknown_stage` | `show --stage` or `set`: no stage has that path (`details.path`, `details.stages`) |
| `usage` | A missing or unknown subcommand, an extra argument, or two different workspace names (`show`); `--stage`, `--body` or `--evaluate` with `set`; see above for `set` |
| `unknown_template` | `spine init`: no `spine` library entry has that name (`details.template`, `details.scopes`, `details.source`; the message says where the name came from) |
| `spine_unwritable` | `spine init`: `spine/` is a link, or the notes directory or a file could not be written (`details.path`); for `spine set` see above |
