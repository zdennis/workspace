# workspace library

Store named plays, prompts, agents, skills and spine templates, globally or for one project, and read them back by name. A play is a document an agent reads and follows; a prompt is short text sent as typed; an agent is a Claude Code subagent file; a skill is a directory holding `SKILL.md`; a spine template is a folder of plan-spine stage files that [`spine init`](README.spine.md#spine-init) copies into a workspace. `start --agent` and `--skill` copy agents and skills into a new worktree. `lib` is an alias for `library`, and `workspace library` alone lists.

## Usage

```sh
workspace library list   [--kind KIND] [--global | --builtin | --project [NAME]] [--json]
workspace library show   REF [--global | --builtin | --project [NAME]] [--json]
workspace library info   REF [--global | --builtin | --project [NAME]] [--json]
workspace library add    PATH|- --kind KIND [--as NAME] [--link] [--force] [--project [NAME]] [--dry-run] [--json]
workspace library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]
workspace library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]
workspace library install   REF [--name WS | --user] [--from global|project] [--force] [--dry-run] [--json]
workspace library uninstall REF [--name WS | --user] [--force] [--dry-run] [--json]
workspace library installed [--name WS | --user] [--kind skill|agent] [--json]
```

`REF` is `kind/name` or a bare `name`. A bare name works when one kind has it; when two do, the command fails with `ambiguous_library_entry` and lists both. A built-in play never makes a bare name ambiguous: with your own `prompt/review`, `show review` prints the prompt, and `show play/review` the built-in play. Scripts should pass `kind/name`. Names are lowercase letters, digits and hyphens.

| Verb | What it does |
|---|---|
| `list` | Every entry visible from here, sorted by kind then name, with the project's entry before the global one of the same name, the built-in one last, and a hidden one marked `(hidden)` |
| `show` | Prints the body as it is, so `--prompt "$(workspace library show prompt/kickoff)"` works with every command that takes text |
| `info` | Kind, name, scope, path, whether it is a link and to what, description, modified time, and whether it is the entry in effect |
| `add` | Copies `PATH` into the store, or links it with `--link`. `-` reads the body from stdin and needs `--as`. The name defaults to the file name in kebab case (`Agent Orchestration Playbook.md` becomes `agent-orchestration-playbook`). Adding identical content again succeeds and changes nothing; different content under an existing name is refused unless `--force` is given |
| `update` | Replaces an existing entry's content from `PATH` or stdin, or repoints a link. It fails when the entry does not exist, which is the difference from `add --force` |
| `remove` | Deletes the entry, or the symlink, from the store. The source file is never touched |

| Option | Description |
|--------|-------------|
| `--kind KIND` | `agent`, `play`, `prompt` or `skill`; required for `add`, a filter for `list` |
| `--as NAME` | `add`: the entry name |
| `--link` | `add`, `update`: store a symlink to `PATH` instead of a copy, so the store always reads the current source |
| `--force` | `add`: replace an entry that has different content |
| `--yes` | `remove`: don't ask |
| `--global` | Reads: only the global store |
| `--builtin` | Reads: only the entries that ship with workspace |
| `--project [NAME]` | The project's store: `NAME`, or the project of the current directory (`--name` is the same) |
| `--dry-run` | `add`, `update`, `remove`: report what would happen and write nothing |
| `--json` | Print one JSON document |

The description is the `description:` frontmatter key if the file has one, else its first heading. For a skill, that file is its `SKILL.md`.

`--project` takes the next word as the name unless it is last or starts with `-`, so put `--project` after the positional arguments or write `--project=NAME`.

## Scopes

| Scope | Flag | Stored in |
|---|---|---|
| Global (default for writes) | none, or `--global` | `~/.config/workspace/library/global/<kind>/<name>.md` |
| Project | `--project [NAME]` | `~/.config/workspace/library/projects/<project>/<kind>/<name>.md` |
| Built-in (read-only) | `--builtin` | `lib/library/<kind>/<name>.md` inside workspace |

A skill is stored as a directory, `skill/<name>/`, holding `SKILL.md` and any other files it came with. `add --kind skill PATH` takes a directory with a `SKILL.md` in it (a file is a usage error) and copies the whole tree, or with `--link` links the directory. `add - --kind skill --as NAME` stores stdin as the `SKILL.md` of a new directory. A skill entry's `path` is the directory, `show` prints its `SKILL.md`, and `remove` deletes the directory, or only the link. Two copies of a skill hold the same content when they have the same files with the same bytes.

A spine template is stored as a directory, `spine/<name>/`, like a skill, but needs no particular file: `add --kind spine FOLDER [--as NAME] [--project] [--link]` takes a folder with at least one `.md` file in it (a file is a usage error; stdin is refused) and copies the whole tree, or with `--link` links the folder, which `spine init` then reads through the link when it runs. The built-in `default` ships in `lib/library/spine/default/`. A template's optional `README.md` gives its `description` (the frontmatter key, else the first heading). `list --kind spine --json` entries carry `files`, the template's regular files by relative path (links inside it and dot files are left out). `show` prints the template's `README.md`. `start --agent`/`--skill` and the plays never see spine entries, and a project template hides a global one of the same name, which hides the built-in.

The store is a directory of files with no index: `add` copies the file in, or `add --link` makes a symlink, and `info` reports which. Link a note in Obsidian or iCloud and edits to it take effect on the next read; an evicted or deleted target is reported as unreadable, and `show` fails with `library_source_missing`.

`--project` without a name means the project of the current directory, resolved the way `config set` and `parent` resolve it, so every worktree of a repo shares one project library. The name has to be a workspace `workspace list --all` knows, or the command fails with `unknown_workspace`; `library add --project` in `~/Downloads` does not create a "Downloads" library.

Reads (`list`, `show`, `info`) search the project of the current directory first (when it is a known workspace), then global, then built-in, so a project entry hides a global one of the same kind and name, and either hides a built-in one. `--global`, `--builtin` or `--project` limits a read to that scope. Writes go to the global store unless `--project` is given. Two of the three scope flags together are a usage error, and so is `--builtin` on `add`, `update` or `remove`.

## Built-in plays

workspace ships ten plays, the instruction packs [`workspace instructions compose`](README.instructions.md) builds its output from: `binding`, `orchestrator`, `commits`, `review`, `notes`, `handoff`, `dev`, `implementation-plan`, `research` and `spine`. `workspace library list --builtin` lists them and `workspace library show orchestrator --builtin` prints one. They can't be changed, and there are no built-in prompts, agents or skills.

The built-in scope is searched last here and by `--play`, so `workspace start --play orchestrator` sends the built-in play unless you have a project or global play of that name. `instructions compose --pack NAME` is the one lookup that searches built-in first: a play of yours named `review` never takes the place of the `review` pack. `start --agent` and `--skill` search the project and global stores only.

## Using a play

`workspace start --play NAME` and `workspace launch --play NAME` point the coding agent at a play by path: "Read `<path>` and follow it.", then any `--prompt` text. They look the play up as reads do (project, global, then built-in), and fail before creating anything when it is missing or unreadable. See [`start`](README.start.md#plays).

## Using agents and skills

`workspace start --agent NAME --skill NAME` copies library agents and skills into the new worktree, where Claude Code loads them: `.claude/agents/<name>.md` and `.claude/skills/<name>/`. Both flags repeat. They are looked up in the project's store, then global, and fail before anything is created when missing or unreadable. Each copy is listed in the repo's `info/exclude`, and a path the repo tracks is never overwritten. See [`start`](README.start.md#agents-and-skills).

## remove

`remove` asks before deleting. `--yes` skips the question. With `--json`, or under `--no-input` (`WORKSPACE_NO_INPUT`), it needs `--yes` or `--dry-run`, as `projects kill` does: `--json` without them is a `usage` error, `--no-input` without them is `confirmation_required` with `retry.flags: ["--yes"]`.

## install and uninstall

`install` copies a library agent or skill into an existing workspace's checkout, by the code `start --skill` and `--agent` use: `.claude/skills/<name>/` or `.claude/agents/<name>.md` (or the [directories you configure](#install-directories)), listed in the repo's `info/exclude`. `REF` is `skill/name`, `agent/name` or a bare name one kind has. It is looked up from the named workspace's project (its project store, then global), not from the current directory. `--name WS` picks the workspace (default: the one of the current directory; here `--name` is the workspace, as `--project` is for the other verbs). `uninstall` removes only that copy; the library entry is never touched and need not exist any more. It leaves the `info/exclude` line, which is harmless and which a later install needs.

`--json` prints one document (text goes to stderr):

```json
{"schema_version":1,"ok":true,"ref":"skill/write-tests","workspace":"my-app","result":"installed","path":"/abs/my-app/.claude/skills/write-tests","dry_run":false,"user":false,
 "entry":{"ref":"skill/write-tests","kind":"skill","name":"write-tests","scope":"global","path":"/Users/me/.config/workspace/library/global/skill/write-tests"}}
```

`entry` names the library entry `install` copied (`scope` is `global` or `project`, `path` its directory or file); it is `null` for `uninstall`.

| Command | `result` |
|---|---|
| `install`, nothing there | `installed` |
| `install`, identical content already there | `unchanged` |
| `install --force`, different content | `installed` (replaced) |
| `install`, different content, no `--force` | error `library_install_exists` |
| `uninstall`, the copy exists and matches the library entry (or the entry is gone) | `removed` |
| `uninstall`, the copy differs from the library entry, no `--force` | error `library_uninstall_modified` |
| `uninstall --force`, the copy exists | `removed` |
| `uninstall`, no copy | `absent` |
| any `--dry-run` that would write | `would_install` or `would_remove` |

`uninstall` compares the copy with the library entries of that kind and name in every store (project and global; the built-in store holds plays only): a copy is unmodified when it equals any of them, so a copy made with `install --from global` still removes without `--force` while a project entry of the same name shadows it. With no entry at all there is nothing to compare, so the copy is removed without `--force`. `--dry-run` raises the same refusals as the real command (so `library_uninstall_modified` shows in a preview) and writes nothing; where the real command would write it reports `would_install` or `would_remove`, and `unchanged`, `absent` and every refusal read as they do without it. Unlike `start`, which replaces an untracked copy silently, `install` refuses different content without `--force`. Neither verb touches a path the repo tracks (`path_tracked`) or goes through a symlinked install directory or one above it, such as `.claude` (`path_linked`); `library_path_outside` refuses any path not directly under the install directory. A `play`, `prompt` or `spine` ref is `library_kind_not_copyable`; unknown workspace is `unknown_workspace`; an unknown ref is `unknown_library_entry`.

`install` raises `library_source_missing` (`details.ref`, `details.path`) when the entry it would copy is a link whose target can't be read (`readable: false` in `library info`), for `--user` too, and `--dry-run` raises it as well: a preview reads the entry the same way. `uninstall` raises it only when it needs the entry to compare the copy with and that entry is an unreadable link; `uninstall --force` never reads the entry. Nothing is changed when it is raised.

### installed

`installed` lists the copies `install` made, read-only. It looks in the workspace's install directories (`--name WS`, default the workspace of the current directory) or, with `--user`, in `library.install.user_skills_dir` and `user_agents_dir`; `--kind skill|agent` narrows it. `--user` with `--name` is `usage`; a `--kind` of `play`, `prompt` or `spine` is `library_kind_not_copyable`; `unknown_workspace` and `invalid_library_install_dir` are as for `install`. Directories come from the same `library.install.*` keys.

Copies are plain files and directories, so there is no mark on them. The rule for what counts, so a hand-made skill of your own stays out of the list:

- In a workspace, an item counts when its name is a valid library name and either a library entry of that kind has the name (project or global), or the repo's `info/exclude` lists its path, which `install` and `start --skill/--agent` write and `uninstall` leaves. The second clause finds a copy whose library entry was deleted.
- At user level there is no `info/exclude`, so only an item named like a library entry counts; a user-level copy whose entry is gone is not listed.
- An install directory that is a symlink, or under one, lists nothing (`install` refuses it too); an unreadable one lists nothing.
- Recognition by name can include a hand-made item that shares a library entry's name; it then reads as `modified`. `info/exclude` is shared by every worktree of a repo, and a changed `library.install.*_dir` hides older copies that only the exclude line named.
- With `--user`, the entries compared against are those visible from the current directory (its project's and global). A symlinked copy always reads `modified`, as it does for `uninstall`.

```json
{"schema_version":1,"ok":true,"workspace":"fix-login","user":false,
 "copies":[{"kind":"skill","name":"pdf-tools","ref":"skill/pdf-tools",
   "path":"/abs/fix-login/.claude/skills/pdf-tools","entry":"global","modified":false}]}
```

`entry` is the scope of the library entry the copy matches (`global` or `project`; when entries of both scopes exist, the one it equals, else the first a lookup finds, with `modified` true), or `null` when the entry is gone. `modified` is the test `uninstall` refuses on without `--force`: the copy is a symlink, or differs from every entry of that kind and name, or no entry can be read; it is `false` when `entry` is `null` (there is nothing to differ from, and `uninstall` removes it freely). `workspace` is `null` with `--user`, which also sets `"user": true`. Copies are sorted by kind (agent, then skill) and name. Text output has one line per copy. `capabilities` reports `"library_installed": 1`. Matching any store changes what `entry` and `modified` say for a shadowed copy, but the revision is not bumped: revisions 4 and 1 have not been released, so no client has read the earlier answer.

### Install directories

Where a copy goes is config, read when the command runs. A project's value beats the global one, which beats the default:

| Key | Default | Meaning |
|---|---|---|
| `library.install.skills_dir` | `.claude/skills` | Where skills go, relative to the checkout |
| `library.install.agents_dir` | `.claude/agents` | Where agents go, relative to the checkout |
| `library.install.user_skills_dir` | `~/.claude/skills` | Where `install --user` puts skills |
| `library.install.user_agents_dir` | `~/.claude/agents` | Where `install --user` puts agents |

The two relative keys can be set globally or per project (`config set --global ...`, `config set --project ...`); a path that is absolute, starts with `~`, contains `..` or points inside `.git` is refused by `config set`. The two user keys are global only and must be absolute or start with `~/`. A value that was edited into a config file and is not valid makes `install`, `uninstall` and `start --skill/--agent` fail with `invalid_library_install_dir` (`details.key`).

```
workspace config set --global library.install.skills_dir .agents/skills
workspace config set --global library.install.user_skills_dir ~/.agents/skills
workspace library install skill/pdf-tools --name fix-login   # -> .agents/skills/pdf-tools in that checkout
workspace library install skill/pdf-tools --user             # -> ~/.agents/skills/pdf-tools
```

- `install --user` copies into the user-level directory, so every project sees it. It takes no `--name`, uses no git and writes no `info/exclude` line; the `unchanged` and `--force` rules and `--dry-run` are the same, and the library entry is looked up from the current directory's project. `--user` with `--name` is `usage`. The `--json` document has `"workspace": null` and `"user": true`.
- `uninstall --user` removes that copy from `library.install.user_skills_dir` or `user_agents_dir`, with the same results and rules as the workspace form: `removed`, `absent`, `would_remove` on a dry run, and `library_uninstall_modified` for a copy that differs from the library entry (looked up from the current directory's project) unless `--force`. It takes no `--name` (`usage`), writes no `info/exclude` line, and `library_path_outside` and `invalid_library_install_dir` apply. A user directory that is itself a symlink (a dotfiles-managed `~/.claude`) is allowed, as for `install --user`.
- `install --from global|project` pins the store the entry is copied from. Without it, the target's project store hides the global entry of the same name, so a project that has its own `skill/x` gets that one. `--from global` copies the global entry anyway; `--from project` copies only the project's. It applies to `--user` too, where the project is the one of the current directory. A value other than `global` or `project` is `usage`; nothing in that store is `unknown_library_entry` with `details.scopes` naming the store searched (`["global"]`, or `["project:NAME"]`, or `["project"]` when the directory is in no project). The result's `entry.scope` and `entry.path` say which entry was copied. `uninstall` takes no `--from`.
- The `info/exclude` line, the tracked-path check and `uninstall`'s allowed directory all follow the configured directory. `start --skill` and `--agent` use the same keys, so a new worktree and an existing one get the same layout.
- Changing a key does not move copies already installed. `uninstall` looks in the current setting, so remove copies before changing it.
- The setting only says where `workspace` copies files. Claude Code loads `.claude/skills/` and `~/.claude/skills/`; pointing the keys at `.agents/skills/` helps only for agents that read that location. Install refuses to write through a symlinked install directory (`path_linked`), so a link that makes both locations one directory must not be the configured install directory itself.
- One directory per kind: several destinations at once are not supported.

## Change events

`add`, `update` and `remove` write a `library_changed` line (`ref`, `scope`, `action`) to the event log when they change the store, so a reader can refetch `library list --json` instead of polling. An unchanged entry, `--dry-run`, a declined `remove` or a failed write writes nothing. See [the event log](README.event-log.md).

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
| `library_source_missing` | `PATH` does not exist, or a link's target can't be read; also `install` (with or without `--dry-run`) and `uninstall` of an entry whose link is unreadable | `ref`, `path` |

A bad name, an unknown kind, or a missing `--kind` is `usage`. `capabilities` reports `"library_copy": 4` for `install`/`uninstall` (revision 3 adds `install --user`, the `user` field and the `library.install.*` directories; revision 4 adds `uninstall --user`, `install --from` and the `entry` object in the install document), `"library": 2` (revision 2 adds the `agent` and `skill` kinds; a skill's `path` is a directory) and `paths.library`.

## Examples

```sh
workspace library add --kind play --link ~/Notes/Projects/Workspace/Agent\ Orchestration\ Playbook.md
workspace library add kickoff.md --kind prompt --project
echo "Start at CLI27." | workspace library add - --kind prompt --as start-cli27
workspace library list --kind play --json
workspace library add ~/.claude/agents/reviewer.md --kind agent
workspace library add ~/src/skills/write-tests --kind skill --link
workspace library info play/agent-orchestration-playbook
workspace start feature/x --prompt "$(workspace library show prompt/kickoff)"
workspace library update prompt/kickoff kickoff-v2.md
workspace library remove play/agent-orchestration-playbook --yes
```
