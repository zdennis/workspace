# workspace remove

Delete a stopped project's generated files: its tmuxinator config, its project settings file and its state entry. Afterwards the project no longer appears in `workspace list --all`. The project's directory, git worktrees and notes are never touched.

## Usage

```sh
workspace remove [NAME | --name WS] [--yes] [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--name WS` | The workspace to remove, the same as `NAME`. With neither, `remove` acts on the workspace the working directory is in: a worktree's `.workspace-project` marker, else the active workspace whose root holds the directory; outside any workspace it refuses with `not_in_workspace` |
| `--yes` | Don't ask first. Without it `remove` prompts; under `--no-input` (`WORKSPACE_NO_INPUT`) that is a `confirmation_required` error with `retry.flags: ["--yes"]` |
| `--dry-run` | List what would be removed and change nothing; no prompt |
| `--json` | Print one action document (see [`--json` output](README.json.md)); text goes to stderr. The prompt still asks unless `--yes` is given |

## Details

`remove` deletes, in this order:

1. The tmuxinator config (`~/.config/tmuxinator/workspace.<name>.yml`)
2. The project settings file (`~/.config/workspace/projects/<name>.yml`)
3. The state entry

Each file is first copied next to the original as `<file>.workspace-backup-<time>`, so the removal can be undone by hand. To undo a removal, copy a backup back to its original name (for the tmuxinator config, `workspace.<name>.yml`); the state entry comes back on the next `launch`. A `--dry-run` document has `summary` `{"would_remove":1}`. Missing files are skipped; a name with no config, no settings file and no state entry is `unknown_workspace`.

`remove` refuses:

- `session_running`: the workspace's tmux session is up. Run `workspace stop NAME` first.
- `not_removable`: the workspace is a worktree project (its root is a linked git worktree). Use [`kill`](README.kill.md), `finish` or [`prune`](README.prune.md), which remove the worktree too.

A refusal is the error envelope with `--json` (see [`--json` output](README.json.md)).

## JSON

One row, with `outcome` `removed`, or `would_remove` (status `dry_run`) for `--dry-run`. A declined prompt is `cancelled` (status `cancelled`, exit 0). Besides the usual keys the row carries `files` (the paths removed or that would be), `backups` (the copies made; empty on a dry run) and `state_entry` (whether a state entry existed).

```json
{"schema_version":1,"ok":true,"action":"remove","status":"ok",
 "results":[{"workspace":"app","outcome":"removed","reason":null,"message":null,
   "files":["/Users/me/.config/tmuxinator/workspace.app.yml"],"backups":["/Users/me/.config/tmuxinator/workspace.app.yml.workspace-backup-20261019120000"],"state_entry":true}],
 "warnings":[],"summary":{"removed":1}}
```

## Examples

```sh
# Ask, then delete its tmuxinator config, settings file and state entry (backups kept; the checkout is untouched)
workspace remove app

# The same for the workspace you are in
workspace remove

# See which files would go
workspace remove app --dry-run

# No prompt, one JSON document
workspace remove app --yes --json
```
