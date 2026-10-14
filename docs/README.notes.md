# workspace notes

Print where a workspace's notes are kept. Notes are the working files an agent or a person keeps for a workspace (plans, findings, handoffs), outside the source tree.

## Usage

```sh
workspace notes dir [--name WORKSPACE] [--create] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | The workspace to answer for. Default: the one detected from the current directory |
| `--create` | Make the directory. When it is inside the checkout, also list it in the common git dir's `info/exclude`, so `git status` never shows it. Writes no config |
| `--json` | Print one JSON document |

## Details

Agents, scripts and the app all ask this one command, so they get the same directory. The path is the first of these that applies:

1. The workspace's own `notes.dir`: a worktree's own config file, or the project's file for a main checkout (a worktree never reads the project's `notes.dir`).
2. The project's `notes.default_dir` rule, with `{workspace}` and `{branch}` filled in.
3. `tmp/workspace-notes` inside the checkout.

See [`config`](README.config.md) for both keys. A stored value that fails its key's checks counts as unset, as it does in `config show`.

Plain output is the absolute path alone, so `"$(workspace notes dir)"` works in a script. Without `--create` the command only reads: it makes nothing and edits no file.

[`start`](README.start.md#notes-directory) sets the directory up for a new worktree (it writes the computed path as the worktree's own `notes.dir` and does what `--create` does), and [`kill`](README.kill.md) and [`finish`](README.finish.md) warn when they are about to delete notes that live inside the worktree.

`--create` is for a workspace `start` never set up (an existing worktree, or a main checkout). It is safe to repeat. The exclude line is rooted, for example `/tmp/workspace-notes/`; git's own glob characters in the path are escaped. A directory outside the checkout needs no exclude line. In a directory that is not a git checkout there is nothing to list the line in: the command still succeeds and reports `excluded: false`.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).

## JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","dir":"/src/api/.worktrees/x/tmp/workspace-notes","source":"default","exists":true,"inside_worktree":true,"excluded":true}
```

| Field | Meaning |
|-------|---------|
| `workspace` | The workspace the answer is for |
| `dir` | The absolute directory |
| `source` | `worktree` (the worktree's own `notes.dir`), `project` (the main checkout's `notes.dir`) or `default` (the rule, or `tmp/workspace-notes`) |
| `exists` | Whether the directory exists now |
| `inside_worktree` | Whether the directory is inside the workspace's checkout (symlinks are resolved on both sides) |
| `excluded` | Whether git will leave it alone: `true` when it is outside the checkout, and when it is inside and its rooted line is in `info/exclude`; `false` when it is inside and not listed (run with `--create`), and when the checkout is not a git checkout |

`notes` in [`capabilities`](README.capabilities.md) is `1` when this command exists.

## Errors

| `code` | When |
|--------|------|
| `unknown_workspace` | The workspace has no known checkout (`details.name`) |
| `not_in_workspace` | No `--name`, and no workspace could be detected from the current directory (`details.path`) |
| `notes_dir_unresolved` | The project's rule uses `{branch}` and the checkout is on a detached HEAD. Check out a branch, or set `notes.dir` for the workspace |
| `notes_dir_unwritable` | `--create` could not make the directory, or could not list it in `info/exclude` (`details.path`) |
| `config_parse` | A config file it reads can't be parsed (`details.path`, `details.reason`) |

## Examples

```sh
$ workspace notes dir
/src/api/.worktrees/x/tmp/workspace-notes

$ cd "$(workspace notes dir --create)"

$ workspace ui open notes api --print
workspace-ui://notes/api

$ workspace notes dir --name api --json
{"schema_version":1,"ok":true,"workspace":"api","dir":"/Users/z/notes/api","source":"project","exists":true,"inside_worktree":false,"excluded":true}
```
