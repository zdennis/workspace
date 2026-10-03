# workspace capabilities

Print what this workspace supports, so a script or the UI can check a feature instead of comparing version numbers.

## Usage

```sh
workspace capabilities [--json]
```

It reads constants, config paths and the `PATH`. It starts no process and touches no state, git, tmux or daemon, so it is cheap to call.

## Options

| Option | Description |
|---|---|
| `--json` | Print one JSON document (below) instead of a readable summary |

## JSON output

```json
{"schema_version":1,"ok":true,"version":"0.27.1",
 "features":{"envelope":1,"error_codes":1,"name_scope":1,"no_input":1,"action_json":1,
   "sessions":1,"locks_json":1,"git_facts":1,"prune_safe":1,"snapshot":2,"events_follow":0,
   "actions_manifest":0,"agent_send":1,"agent_spawn":0,"focus_pane":1,"state_done":1,
   "doctor_json":0,"daemon_control":1,"config_json":1,"tmux_show":1,"tasks":1,"event_emitters":1,
   "ui_open":1},
 "exit_codes":{"ok":0,"failed":1,"not_submitted":2,"partial":3,"lock_cleared":4,"timeout":75},
 "paths":{"event_log":"/Users/me/.workspace-events.jsonl","run_dir":"/Users/me/.local/workspace/run"},
 "dependencies":{"window_tool":{"path":"/opt/homebrew/bin/window-tool"},
   "gh":{"path":"/opt/homebrew/bin/gh"},"tmux":{"path":null}}}
```

- `features` maps each name to an integer revision. `0` means this CLI doesn't have it, and a name missing from the map means the same. Check `features.no_input >= 1`; don't compare `version`. A revision goes up when the feature's output changes in a way a reader must handle. An older CLI that predates this command answers `Unknown subcommand` (exit 1), so treat that as "no features".
- `exit_codes` names the statuses commands use: `not_submitted` (2, `run`), `partial` (3, `--json` action documents), `lock_cleared` (4, a queued lock wait whose lock was cleared) and `timeout` (75, `--max-wait` ran out).
- `paths` are absolute.
- `dependencies` gives the first match on `PATH` for each tool, or `null` when it isn't there. Nothing is run, so there is no version.

### Features

| Feature | Meaning (revision 1) |
|---|---|
| `envelope` | `--json` failures are the error envelope, and successes carry `schema_version` and `ok` (see [`--json` output](README.json.md)) |
| `error_codes` | Error envelopes carry a stable `code` |
| `name_scope` | `--name` on `ask`, `lock`, `dev` and `config` |
| `no_input` | `--no-input` and `WORKSPACE_NO_INPUT` |
| `action_json` | `--json` action documents on the lifecycle commands, `dev up|down`, `lock release`, `config set`, `pipeline start|advance|reset`, and `agent run --json` |
| `sessions` | `sessions --json` |
| `locks_json` | `lock status --json` and `lock clear --json` |
| `git_facts` | `projects show` reports git facts per workspace |
| `prune_safe` | `prune` skips a worktree with unsaved work and reports it, rather than removing it |
| `snapshot` | `snapshot --json` (see [`snapshot`](README.snapshot.md)); `sessions --json` panes carry `display_label` (see [`sessions`](README.sessions.md)). Revision 1 was `display_label` alone |
| `events_follow` | Not available yet |
| `actions_manifest` | Not available yet |
| `agent_send` | `agent-run send --pane` types text or tmux keys into one named pane; `ask answer --deliver` types an answer into the asking pane |
| `agent_spawn` | Not available yet |
| `focus_pane` | `focus --pane` selects a pane after focusing the window |
| `state_done` | `sessions --json` panes can report `state: "done"` with a `stop_reason` (see [`sessions`](README.sessions.md)) |
| `doctor_json` | Not available yet |
| `daemon_control` | `daemon status`, `daemon restart` and `daemon log` (see [`daemon`](README.daemon.md)) |
| `config_json` | `config show --json` and `config validate --json` (see [`config`](README.config.md)) |
| `tmux_show` | `tmux show --json` (see [`tmux`](README.tmux.md)) |
| `tasks` | `start` records a task per worktree workspace (`--title`, `WORKSPACE_TASK` in its panes); `sessions --json` reports it as `task` and uses its title as the first `display_label` (see [`start`](README.start.md#tasks)); `finish` and `kill` archive it |
| `ui_open` | `ui open task\|review\|inbox` opens a `workspace-ui://` link (see [`ui`](README.ui.md)) |
| `event_emitters` | The event log records `ask_created`, `ask_answered`, `lock_released`, `lock_cleared`, `worktree_started`, `worktree_finished`, `daemon_started`, `daemon_stopped` and `config_changed` (see [`event-log`](README.event-log.md#state-and-lifecycle-events)) |

## Examples

```sh
workspace capabilities
workspace capabilities --json | jq '.features.no_input'
workspace capabilities --json | jq -r '.dependencies.window_tool.path'
```
