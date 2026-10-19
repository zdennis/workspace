# workspace spine

Read a workspace's plan spine, and set a stage's status. The spine is the stage level of a workspace's plan (research, plan, implement, verify, ...): one Markdown file per stage in a `spine/` folder of the workspace's notes directory. The task level is [`IMPLEMENTATION_PLAN.md`](README.plan.md), which the spine links to and does not replace.

## Usage

```sh
workspace spine show [WORKSPACE] [--name WORKSPACE] [--stage STAGE-PATH] [--body] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `WORKSPACE`, `--name WORKSPACE` | The workspace to read. Default: the one detected from the current directory. Give it once; two different names are a usage error |
| `--stage STAGE-PATH` | Only that stage, with its sub-stages (`verify`, `implement/api`, as `path` reports). Its own flag because the one positional is the workspace. A path no stage has is `unknown_stage` with the paths there are, the one place `show` errors on content |
| `--body` | Add the text after the frontmatter: to the stage with `--stage`, else to `goal` (stage bodies are never added to the whole tree). At most 16 KB (16384 bytes), cut on a character boundary; read without following links |
| `--json` | Print one JSON document |

`show` only reads. It creates no folder and writes no file, never follows a link, and never fails because of what a file holds: a problem is a `warnings` entry, and the exit status stays 0. The only errors are `unknown_workspace`, `notes_dir_unresolved` and `config_parse` (the notes directory can't be worked out), and `not_in_workspace`. A workspace with no `spine/` answers `exists: false`.

Plain output is a short summary: one line per stage with its status, owner, `Done when` counts and the codes of its warnings.

`spine` in [`capabilities`](README.capabilities.md) is `2` when this command has the roll-up described below, `--stage` and `--body`.

## Setting a status

```sh
workspace spine set [WORKSPACE] STAGE-PATH --status VALUE [--note TEXT] [--if-revision REV] [--recursive] [--by LABEL] [--json]
```

`STAGE-PATH` is the stage's ids joined with `/` (`verify`, `implement/api`), as `show` reports `path`. With `--name WORKSPACE` the one argument is the path.

| Option | Description |
|--------|-------------|
| `--status VALUE` | Required. A status or an alias (see Status), written as the canonical value. `unknown` is refused (`invalid_status`) |
| `--note TEXT` | One line of at most 300 characters, written as `note:`. Without it the note is cleared when the status changes and kept when it stays. An empty `--note ""` clears it |
| `--if-revision REV` | Refuse with `stale_revision` unless the stage file's current `revision` is `REV`. With `--recursive` it checks the named stage's file only |
| `--recursive` | Also set every sub-stage, at any depth, that is neither `completed` nor `skipped`, parents first, each file written whole. A sub-stage that is a folder with no file is left out |
| `--by LABEL` | The `updated_by` label (at most 100 characters). Default: `<agent> <pane>` (such as `claude %6`) when `$TMUX_PANE` is a pane the workspace's agent daemon has logged as a coding agent, else `person` |

The file's `status`, `note`, `updated` (now, UTC) and `updated_by` lines are the only bytes that change: the other lines, the body, line endings (LF or CRLF), a byte order mark, comments, unknown keys and lists stay as they were. A key that is missing is added at the end of the frontmatter block; a note being cleared is removed. A note or label that is not plain words is written as a double-quoted string. Nothing is written when the stage already reads the status and the note would not change; the stage is in `unchanged`.

The file is read as bytes, opened without following a link, written to a temp file in the same folder (a dot name, so it is never read as a stage), fsynced and renamed over the original. If the file changes between the read and the rename, the write starts over once, then is refused (`changed_while_writing`). Writers of one workspace take turns through a lock file in the CLI's state folder (`$XDG_STATE_HOME/workspace/.spine/`, never the notes folder), waited for up to 10 seconds, so two calls that overlap both land, the second one on top of the first. An editor holding an unsaved buffer is not covered by the lock.

Each file written appends one [`spine_changed`](README.event-log.md) line to the event log, carrying the new `revision`.

A stage changed some other way, by hand in an editor or by an agent's edit tool, is logged too while the workspace's agent daemon runs (`spine_events` in [`capabilities`](README.capabilities.md)): see [`event-log`](README.event-log.md). The daemon recognises a `spine set` write by its revision, so one write is one line.

```json
{
  "schema_version": 1, "ok": true, "workspace": "fix-oauth-refresh",
  "written": [
    {"path": "verify", "file": "40-verify.md", "status": "completed", "previous": "in_progress", "revision": "0c1d2e3f",
     "updated": "2026-10-17T22:01:00Z", "updated_by": "person", "note": null}
  ],
  "unchanged": [{"path": "review", "file": "50-review.md", "status": "completed", "revision": "5a6b7c8d"}]
}
```

`written` and `unchanged` are in tree order. Plain output is one line per stage.

A refusal is the standard error document. With `--recursive` the run stops at the first refusal of a stage file and `details.written` lists the stages already written (rows as above); a refusal before any write (`invalid_status`, `no_spine`, `unknown_stage`, `lock_busy`) has no `written`. A stage already written reads the status on a second run and lands in `unchanged`, so running the same command again finishes the job; `--if-revision` then guards the named stage only, which may by then be unchanged.

| `code` | When |
|--------|------|
| `invalid_status` | `--status` is not a status or an alias; `unknown` can't be set (`details.status`, `details.allowed`) |
| `no_spine` | The workspace has no `spine/` folder (`details.workspace`, `details.dir`) |
| `unknown_stage` | No stage has that path (`details.path`, `details.stages`) |
| `stale_revision` | `--if-revision` differs from the file's revision; `details.revision` and `details.status` are the current ones |
| `spine_unwritable` | The file can't be rewritten safely. `details.reason`: `link`, `not_a_file`, `too_large` (over 64 KB), `not_utf8`, `no_frontmatter` (no opening `---`, or none closed within 100 lines), `no_file` (a stage folder without a file), `missing`, `lock_unavailable` (the lock file in the state folder can't be opened), `unreadable_result` (the change would not read back: the closing `---` would pass line 100 or the status the 40-key cap), `io_error`, `changed_while_writing`, or `lock_busy`; `details.file` |
| `usage` | A missing `--status` or path, or a `--note` or `--by` that is not one short line |

`spine_set` in [`capabilities`](README.capabilities.md) is `1` when this verb exists.

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

The built-in `spine` play ("Keep this workspace's plan spine current", `workspace library show spine --builtin`) teaches an agent the rules: where `spine/` is, `workspace spine set <stage-path> --status in_progress` when it starts a stage, `--status blocked --note "<why>"` when stuck, ticking `## Done when` items as each is met, `--status completed` only when all are met and checked, working on its own stage and sub-stages only, leaving other files, numbers, `gates` and `depends_on` alone, and listing artifacts in `artifacts:`. It names `spine set` for status changes and allows editing `status:` by hand only when the command is missing; `owner:` and the `Done when` ticks are edited in the file, since `spine set` does not write them.

It is an automatic pack, like `notes`: [`start`](README.start.md#packs), [`launch`](README.launch.md) and `workspace instructions compose --start` add `spine` after `notes` (and before `dev`) whenever the workspace's `spine/` folder exists in its notes directory, found the way `show` finds it and never through a link. It is reported with `source: "config"` like the other automatic packs, `--no-packs` drops it, and it is recorded in the pane's [binding](README.binding.md#packs) `packs`, so SessionStart repeats it after `/clear` or compaction. A workspace without `spine/` gets nothing new.

`spine_pack` in [`capabilities`](README.capabilities.md) is `1` when the play and the automatic pack exist.

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
      "updated": "2026-10-17T21:40:00Z", "updated_by": "claude %6", "modified_at": "2026-10-17T21:40:02Z",
      "done_when": {"total": 4, "done": 2, "items": [{"text": "...", "done": true, "line": 18}]},
      "rollup": {"status": "in_progress", "done": 1, "total": 3, "counts": {"completed": 1, "in_progress": 1, "not_started": 1, "blocked": 0, "skipped": 0, "unknown": 0, "disputed": 0}},
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
| `rollup` | Only on a stage with children: `status`, `done`, `total` and `counts`. It reads each child's effective state: the child's own `status`, or, when it has none (`unknown`, as a folder with no stage file always does) and has sub-stages of its own, the status of its own roll-up, worked out from the bottom up. Over the children that are not skipped (`total` counts them, `done` the completed ones): `skipped` when none are left; `completed` when all are completed; else `blocked` when any is blocked; else `in_progress` when any is in progress, completed or disputed; else `not_started`. A leaf with no status counts as not started. `counts` lists every child by effective state (`completed`, `in_progress`, `not_started`, `blocked`, `skipped`, `unknown`, `disputed`), skipped ones included; `disputed` is 0 until a verdict is evaluated. A skipped stage still reports its `rollup` |
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

`no_frontmatter`, `bad_line`, `duplicate_key`, `duplicate_id` (the second stage with an id; `depends_on` means the first), `unknown_kind`, `unknown_gate`, `unknown_dependency`, `dependency_cycle`, `clipped`, `not_utf8`, `link`, `not_a_file`, `too_large`, `folder_without_file`, `too_deep`, `newer_format`.

## Errors

| `code` | When |
|--------|------|
| `unknown_workspace` | The workspace has no known checkout (`details.name`) |
| `not_in_workspace` | No workspace given and none detected from the current directory |
| `notes_dir_unresolved` | The notes directory can't be worked out (see [`notes`](README.notes.md)) |
| `unknown_stage` | `show --stage` or `set`: no stage has that path (`details.path`, `details.stages`) |
| `usage` | A missing or unknown subcommand, an extra argument, or two different workspace names (`show`); `--stage` or `--body` with `set`; see above for `set` |
| `unknown_template` | `spine init`: no `spine` library entry has that name (`details.template`, `details.scopes`, `details.source`; the message says where the name came from) |
| `spine_unwritable` | `spine init`: `spine/` is a link, or the notes directory or a file could not be written (`details.path`); for `spine set` see above |
