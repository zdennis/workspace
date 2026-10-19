# workspace hooks

Manage the hooks workspace installs into coding agents' own settings files. [`init`](README.init.md#agent-session-hooks), [`start`](README.start.md) and [`doctor --fix`](README.doctor.md) install them; `hooks uninstall` takes them out.

## Usage

```sh
workspace hooks uninstall --agent KIND [--name WS | --project [NAME]] [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--agent KIND` | The agent whose hooks to remove: `codex` or `claude` (any case). Required |
| `--name WS` | `claude` only: the checkout of workspace `WS` instead of the current directory |
| `--project [NAME]` | `claude` only: every checkout of the project, main and worktrees (a worktree without a workspace config too). `NAME` is a project name, a path in it or a member workspace; bare, it is the current directory's project. Not with `--name` |
| `--dry-run` | Say what would be removed, and change nothing |
| `--json` | Print one action document (below) |

## Details

For `codex` it edits `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`); for `claude`, the current project's `.claude/settings.json`. Only hook handlers whose command is workspace's go: the current guarded command and the older unguarded `workspace session-event --agent codex`. A matcher group left with no handler goes with them, and so does an event left with no group. Your own hooks, a group that mixes yours with workspace's (yours stay), and every other key in the file are left as they were.

The file is backed up first (`hooks.json.workspace-backup-<timestamp>`, see [`init`](README.init.md#agent-session-hooks)) and replaced in one rename, so Codex never reads half a file; a symlinked file is written at its target. Running it again finds nothing and changes nothing, with no backup.

`workspace init`, `start` and `doctor --fix` install the hooks again when Codex is on `PATH`; run `init --no-install-hooks` to skip that step.

### Other checkouts (`--name`, `--project`)

Without them, `claude` works on the checkout of the current directory. `--name WS` works on that workspace's checkout and `--project` on every checkout of the project; each gets its own file, backup and result. A checkout whose directory is gone is `skipped`; one whose file can't be read is `failed` and the others still go. Codex's file is user-level, so `--agent codex` with `--name` or `--project` (or both flags together) is a `usage` error. Unknown names fail with `unknown_workspace`, `not_in_workspace` or an uncoded `error` when no project is found.

With `--name` or `--project` each result row also has `checkout` (the directory) and `workspace` (`null` for a worktree with no config); `path` is its settings file. `status` is `partial` and the exit code 3 when some checkouts failed, `failed` and 1 when all did, in text mode too. A row's `outcome` can also be `failed` (`reason` is the error code, such as `hook_settings_unreadable`) or `skipped` (`reason` `checkout_missing`).

```sh
workspace hooks uninstall --agent claude --project --dry-run --json
```

### JSON output

One [action document](README.json.md) with one row (one per checkout with `--name`/`--project`):

```json
{"schema_version":1,"ok":true,"action":"hooks uninstall","status":"ok",
 "results":[{"workspace":null,"outcome":"removed","reason":null,"message":null,
   "agent":"codex","path":"/Users/me/.codex/hooks.json","removed":10,
   "backup":"/Users/me/.codex/hooks.json.workspace-backup-20261018090000","dry_run":false}],
 "warnings":[],"summary":{"removed":1}}
```

`outcome` is `removed`, `would_remove` (with `--dry-run`; `status` is then `dry_run`) or `not_installed` (nothing of workspace's in the file, or no file). `removed` counts hook handlers; `backup` is `null` unless a file was written.

Errors: `unknown_agent_kind` for an agent workspace installs no hooks for (`details.known` lists the ones it does), `hook_settings_unreadable` for a file that isn't a JSON object with a `hooks` object (left alone), and `usage` when `--agent` is missing.

## Examples

```sh
# See what would go
workspace hooks uninstall --agent codex --dry-run

# Remove them
workspace hooks uninstall --agent=codex
```
