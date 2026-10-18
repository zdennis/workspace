# workspace spine

Read a workspace's plan spine. The spine is the stage level of a workspace's plan (research, plan, implement, verify, ...): one Markdown file per stage in a `spine/` folder of the workspace's notes directory. The task level is [`IMPLEMENTATION_PLAN.md`](README.plan.md), which the spine links to and does not replace.

## Usage

```sh
workspace spine show [WORKSPACE] [--name WORKSPACE] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `WORKSPACE`, `--name WORKSPACE` | The workspace to read. Default: the one detected from the current directory. Give it once; two different names are a usage error |
| `--json` | Print one JSON document |

`show` only reads. It creates no folder and writes no file, never follows a link, and never fails because of what a file holds: a problem is a `warnings` entry, and the exit status stays 0. The only errors are `unknown_workspace`, `notes_dir_unresolved` and `config_parse` (the notes directory can't be worked out), and `not_in_workspace`. A workspace with no `spine/` answers `exists: false`.

Plain output is a short summary: one line per stage with its status, owner, `Done when` counts and the codes of its warnings.

`spine` in [`capabilities`](README.capabilities.md) is `1` when this command exists.

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
      "rollup": {"status": "in_progress", "counts": {"completed": 1, "in_progress": 1, "not_started": 1, "blocked": 0, "skipped": 0, "unknown": 0}},
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
| `rollup` | Only on a stage with children. `status` is `completed` when every child is completed or skipped and one is completed; else `blocked` when any child is blocked; else `in_progress` when any is in progress or completed; else `not_started`. A child's own `status` is used; `unknown` counts as not started and a skipped child is not counted (it still shows in `counts`) |
| `warnings` | `{"code", "line", "message"}`, plus `value` for the codes that name one; `line` is `null` for a warning about the whole file |
| `truncated` (stage) | Whether only the start of the file was read |
| `truncated` (top level) | `entries`, `stages` or `null` |
| `not_stages` | Names below `spine/` that are not stages, sorted |

### Warning codes

`no_frontmatter`, `bad_line`, `duplicate_key`, `duplicate_id` (the second stage with an id; `depends_on` means the first), `unknown_kind`, `unknown_gate`, `unknown_dependency`, `dependency_cycle`, `clipped`, `not_utf8`, `link`, `not_a_file`, `too_large`, `folder_without_file`, `too_deep`, `newer_format`.

## Errors

| `code` | When |
|--------|------|
| `unknown_workspace` | The workspace has no known checkout (`details.name`) |
| `not_in_workspace` | No workspace given and none detected from the current directory |
| `notes_dir_unresolved` | The notes directory can't be worked out (see [`notes`](README.notes.md)) |
| `usage` | A missing or unknown subcommand, an extra argument, or two different workspace names |
