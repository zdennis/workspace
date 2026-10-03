# workspace library

Store named plays and prompts, globally or for one project, and read them back by name. A play is a document an agent reads and follows; a prompt is short text sent as typed. `lib` is an alias for `library`, and `workspace library` alone lists.

## Usage

```sh
workspace library list   [--kind KIND] [--global | --project [NAME]] [--json]
workspace library show   REF [--global | --project [NAME]] [--json]
workspace library info   REF [--global | --project [NAME]] [--json]
workspace library add    PATH|- --kind KIND [--as NAME] [--link] [--force] [--project [NAME]] [--dry-run] [--json]
workspace library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]
workspace library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]
```

`REF` is `kind/name` or a bare `name`. A bare name works when one kind has it; when two do, the command fails with `ambiguous_library_entry` and lists both. Scripts should pass `kind/name`. Names are lowercase letters, digits and hyphens.

| Verb | What it does |
|---|---|
| `list` | Every entry visible from here, sorted by kind then name, with the project's entry before the global one of the same name and a hidden global one marked `(hidden)` |
| `show` | Prints the body as it is, so `--prompt "$(workspace library show prompt/kickoff)"` works with every command that takes text |
| `info` | Kind, name, scope, path, whether it is a link and to what, description, modified time, and whether it is the entry in effect |
| `add` | Copies `PATH` into the store, or links it with `--link`. `-` reads the body from stdin and needs `--as`. The name defaults to the file name in kebab case (`Agent Orchestration Playbook.md` becomes `agent-orchestration-playbook`). Adding identical content again succeeds and changes nothing; different content under an existing name is refused unless `--force` is given |
| `update` | Replaces an existing entry's content from `PATH` or stdin, or repoints a link. It fails when the entry does not exist, which is the difference from `add --force` |
| `remove` | Deletes the entry, or the symlink, from the store. The source file is never touched |

| Option | Description |
|--------|-------------|
| `--kind KIND` | `play` or `prompt`; required for `add`, a filter for `list` |
| `--as NAME` | `add`: the entry name |
| `--link` | `add`, `update`: store a symlink to `PATH` instead of a copy, so the store always reads the current source |
| `--force` | `add`: replace an entry that has different content |
| `--yes` | `remove`: don't ask |
| `--global` | Reads: only the global store |
| `--project [NAME]` | The project's store: `NAME`, or the project of the current directory (`--name` is the same) |
| `--dry-run` | `add`, `update`, `remove`: report what would happen and write nothing |
| `--json` | Print one JSON document |

The description is the `description:` frontmatter key if the file has one, else its first heading.

`--project` takes the next word as the name unless it is last or starts with `-`, so put `--project` after the positional arguments or write `--project=NAME`.

## Scopes

| Scope | Flag | Stored in |
|---|---|---|
| Global (default for writes) | none, or `--global` | `~/.config/workspace/library/global/<kind>/<name>.md` |
| Project | `--project [NAME]` | `~/.config/workspace/library/projects/<project>/<kind>/<name>.md` |

The store is a directory of files with no index: `add` copies the file in, or `add --link` makes a symlink, and `info` reports which. Link a note in Obsidian or iCloud and edits to it take effect on the next read; an evicted or deleted target is reported as unreadable, and `show` fails with `library_source_missing`.

`--project` without a name means the project of the current directory, resolved the way `config set` and `parent` resolve it, so every worktree of a repo shares one project library. The name has to be a workspace `workspace list --all` knows, or the command fails with `unknown_workspace`; `library add --project` in `~/Downloads` does not create a "Downloads" library.

Reads (`list`, `show`, `info`) search the project of the current directory first (when it is a known workspace), then global, so a project entry hides a global one of the same kind and name. `--global` or `--project` limits a read to that scope. Writes go to the global store unless `--project` is given. `--global` with `--project` is a usage error.

## remove

`remove` asks before deleting. `--yes` skips the question. With `--json`, or under `--no-input` (`WORKSPACE_NO_INPUT`), it needs `--yes` or `--dry-run`, as `projects kill` does: `--json` without them is a `usage` error, `--no-input` without them is `confirmation_required` with `retry.flags: ["--yes"]`.

## --json

`list`, `show` and `info` print their own document:

```json
{"schema_version":1,"ok":true,"entries":[
  {"kind":"play","name":"agent-orchestration-playbook","ref":"play/agent-orchestration-playbook",
   "scope":"global","project":null,"effective":true,
   "path":"/Users/me/.config/workspace/library/global/play/agent-orchestration-playbook.md",
   "link":"/Users/me/Notes/Projects/Workspace/Agent Orchestration Playbook.md",
   "readable":true,
   "description":"Workspace - Agent Orchestration Playbook",
   "updated_at":"2026-10-03T09:00:00Z"}
]}
```

`effective` is true for the entry a read from here would use, and false for a global entry that a project entry hides. `link` is null for a copy; `readable` is false for a broken link, and then `description` is null. `updated_at` is the modified time of the file read (a link's target when it can be read). `info --json` returns one `entry`; `show --json` returns `entry` and `body`. An action row's `entry` has no `effective`: it describes the one store written to. A `--dry-run` row for a name that isn't stored yet has the same keys, with `link`, `readable`, `description` and `updated_at` null.

`add`, `update` and `remove` print an action document (see [README.json.md](README.json.md)); text goes to stderr. Each row has `workspace` (the project, or null for global), `entry` and an `outcome`:

| Command | Outcome | Exit |
|---|---|---|
| `add`, new name | `added` | 0 |
| `add`, same name and same content (or the same link target) | `unchanged` | 0 |
| `add --force`, different content | `replaced` | 0 |
| `add`, different content, no `--force` | error `library_entry_exists` | 1 |
| `update` | `updated`, or `unchanged` | 0 |
| `update` or `remove`, no such entry | error `unknown_library_entry` | 1 |
| `remove` | `removed` | 0 |
| `remove`, declined at the prompt | status `cancelled`, no rows | 0 |
| any, with `--dry-run` | status `dry_run`, the outcome it would have had | 0 |

```json
{"schema_version":1,"ok":true,"action":"library add","status":"ok",
 "results":[{"workspace":null,"outcome":"added","reason":null,
   "message":"Added play/agent-orchestration-playbook in the global library.",
   "entry":{"kind":"play","name":"agent-orchestration-playbook","ref":"play/agent-orchestration-playbook",
     "scope":"global","project":null,"path":"/Users/me/.config/workspace/library/global/play/agent-orchestration-playbook.md",
     "link":"/Users/me/Notes/Projects/Workspace/Agent Orchestration Playbook.md","readable":true,
     "description":"Workspace - Agent Orchestration Playbook","updated_at":"2026-10-03T09:00:00Z"}}],
 "warnings":[],"summary":{"added":1}}
```

Each command acts on one entry, so a failure is the error envelope, never a `refused` row or a partial result. A copy of an entry whose link target is the same file counts as different content: a copy and a link are not the same entry.

| Code | When | Details |
|---|---|---|
| `unknown_library_entry` | No entry has that name in the scopes searched | `ref`, `scopes` |
| `ambiguous_library_entry` | A bare name matches more than one kind | `ref`, `candidates` |
| `library_entry_exists` | `add` would replace different content | `ref`, `scope`; `retry` with `--force`, marked `destructive` |
| `library_source_missing` | `PATH` does not exist, or a link's target can't be read | `ref`, `path` |

A bad name, an unknown kind, or a missing `--kind` is `usage`. `capabilities` reports `"library": 1` and `paths.library`.

## Examples

```sh
workspace library add --kind play --link ~/Notes/Projects/Workspace/Agent\ Orchestration\ Playbook.md
workspace library add kickoff.md --kind prompt --project
echo "Start at CLI27." | workspace library add - --kind prompt --as start-cli27
workspace library list --kind play --json
workspace library info play/agent-orchestration-playbook
workspace start feature/x --prompt "$(workspace library show prompt/kickoff)"
workspace library update prompt/kickoff kickoff-v2.md
workspace library remove play/agent-orchestration-playbook --yes
```
