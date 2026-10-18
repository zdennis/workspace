# workspace hooks

Manage the hooks workspace installs into coding agents' own settings files. [`init`](README.init.md#agent-session-hooks), [`start`](README.start.md) and [`doctor --fix`](README.doctor.md) install them; `hooks uninstall` takes them out.

## Usage

```sh
workspace hooks uninstall --agent KIND [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--agent KIND` | The agent whose hooks to remove: `codex` or `claude` (any case). Required |
| `--dry-run` | Say what would be removed, and change nothing |
| `--json` | Print one action document (below) |

## Details

For `codex` it edits `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`); for `claude`, the current project's `.claude/settings.json`. Only hook handlers whose command is workspace's go: the current guarded command and the older unguarded `workspace session-event --agent codex`. A matcher group left with no handler goes with them, and so does an event left with no group. Your own hooks, a group that mixes yours with workspace's (yours stay), and every other key in the file are left as they were.

The file is backed up first (`hooks.json.workspace-backup-<timestamp>`, see [`init`](README.init.md#agent-session-hooks)) and replaced in one rename, so Codex never reads half a file; a symlinked file is written at its target. Running it again finds nothing and changes nothing, with no backup.

`workspace init`, `start` and `doctor --fix` install the hooks again when Codex is on `PATH`; run `init --no-install-hooks` to skip that step.

### JSON output

One [action document](README.json.md) with one row:

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
