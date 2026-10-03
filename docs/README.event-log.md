# workspace event-log

Show or compact the append-only event log of state changes and agent activity.

## Usage

```sh
workspace event-log <subcommand>
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `show` | Print events, oldest first |
| `compact` | Compact the event log to current state only |
| `help` | Show help |

### `show` options

| Option | Description |
|--------|-------------|
| `--project NAME` | Only events for this project |
| `--type TYPE` | Only events of this type; repeat it or comma-separate several. A type no event in the log has prints a warning to stderr listing the types the log does have |
| `--limit N` | Only the last N matching events |
| `--json` | Print `{"schema_version": 1, "events": [...]}` instead of lines |

Each line is `timestamp  project  type  key=value ...`. Control characters in logged text are replaced with spaces. A value containing a space or `=` is quoted (Ruby `String#inspect`) so the line stays splittable on `"  "`; scripts should use `--json` instead of parsing this format. `--json` applies to `show` only; `compact` always prints its one-line summary. It works no matter where the flag appears (e.g. `event-log --json show`); stdout then carries only the JSON object, including for usage errors (`{"schema_version": 1, "error": "..."}`); warnings, such as skipped corrupt lines, go to stderr.

## Details

Workspace tracks all state changes (launches, kills, window discoveries, repairs, prunes) as timestamped JSONL events in `~/.workspace-events.jsonl`. The state file (`~/.workspace-state.json`) is rebuilt from this log on every save.

This append-only approach eliminates race conditions from concurrent launches — multiple processes can safely append events without clobbering each other. Each event is written with a single `write` to a file opened for appending, so lines from different processes never interleave.

### Agent activity

The same log records what agents and pipelines do. `reconstruct` ignores these events, so they never change state. Each is `{timestamp, type, project, data}`; `project` is the workspace (or, for locks, the lock namespace's project — the parent/main workspace, shared by every worktree of one repo) name. Lock events recorded from a worktree also carry `data.workspace`, that worktree's own workspace name; `--project` matches either field, so `event-log show --project <worktree name>` still finds that worktree's lock waits and takeovers.

| Type | Written by | `data` |
|------|-----------|--------|
| `dispatched` | agent daemon, command delivered | `work_item_ref`, `dispatch_id`, `stage` and `pane` (pipeline only), `delivery` (`submitted` or `not_submitted`) |
| `dispatch_failed` | agent daemon, command never reached its pane | `work_item_ref`, `dispatch_id`, `message` |
| `stage_completed` | agent daemon, stage printed its sentinel | `work_item_ref`, `pane`, `next_stage`, `next_pane` (both `null` after the last stage), `summary` (first 500 characters) |
| `stage_timed_out` | agent daemon, stage ran past its `timeout` | `work_item_ref`, `pane`, `message` |
| `stage_failed` | agent daemon, stage's watch died, its pane was lost, the hand-off failed, or the coordinator aborted it | `work_item_ref`, `pane`, `message` |
| `pipeline_dropped` | agent daemon, coordinator has no record of the work item | `work_item_ref`, `message` |
| `agent_state` | agent daemon's session monitor, on each change | `pane_id`, `pane_pid`, `index`, `kind`, `state` (`working`, `idle`, `waiting`, `done`, `exited`, `closed`), `since`, and `stop_reason` for `done` |
| `agent_alert` | agent daemon's session monitor, once the notify command accepts an alert | `pane_id`, `pane_pid`, `kind` (`idle` or `waiting`; missing means `idle`); for `idle`: `idle_since` (when the output went quiet); for `waiting`: `agent_id` (`null` for the main agent), `waiting_since` |
| `lock_wait_started` | `lock acquire --wait`, `dev up` | `lock`, `pid`, `holder`; for `lock`: `task`, `position` |
| `lock_acquired` | same, once a wait ends with the lock | `lock`, `pid`, `waited_seconds` |
| `lock_takeover` | `lock acquire` taking over an idle holder; `dev up --force` | `lock`, `pid`, `from`; for `lock`: `waited_seconds`, `idle_since` |
| `lock_wait_gave_up` | `--max-wait` or the startup timeout passed while queued | `lock`, `pid`, `waited_seconds` |
| `lock_wait_cleared` | `lock clear` removed the waiter | `lock`, `pid`, `waited_seconds` |
| `lock_wait_abandoned` | `lock acquire --wait` interrupted | `lock`, `pid`, `waited_seconds`, `exit_code` |

An acquire that doesn't wait records nothing here; `locks.jsonl` in the lock store already audits every acquire and release.

A restarted agent daemon reads each pane's last `agent_state` back, so `workspace sessions` keeps each pane's state and `state_since` instead of starting afresh. The pane's pid must match, so a pane id reused by a new tmux server starts fresh. A pending wait is not restored. It also reads each pane's last `agent_alert` of each kind back, so a restart doesn't send an alert again: a pane still idle in the same quiet stretch isn't alerted again, and an agent that was waiting when the daemon stopped isn't alerted again when it asks again, as long as it sent no other hook event in between. A new quiet stretch or a new wait alerts as usual.

Recording activity never fails the command doing it: if the log can't be written, one warning goes to stderr and the command carries on. Nothing is written to stdout, so `--json` output stays JSON-only.

When the event log exceeds 1MB (`event_log_compact_threshold` in the global config), workspace warns you to compact it. Compaction replays the log and rewrites it with one `compacted` event per active project, plus the latest `agent_state` of each pane that still has an agent (and changed within the last 7 days), that pane's latest idle `agent_alert`, and, while it is still waiting, its latest waiting `agent_alert` per agent. All other activity history is dropped.

When an append leaves the log over 10MB, workspace rotates it on its own: the log is renamed to `.workspace-events.jsonl.1` (older files shift to `.2` and `.3`; the one past `.3` is deleted), and a new log, seeded with the same compacted state, takes its place. Rotated files keep the activity history, so the log and its rotated files stay under about 40MB. Rotation is safe with several workspace processes appending at once, and a failed rotation never fails the command that triggered it.

Existing users are automatically migrated on first run — the current state file is converted to `migrated` events in the log.

## Examples

```sh
# Compact the event log
workspace event-log compact
# => Compacted event log: 15360 -> 1024 bytes (8 project(s))

# The last 20 events for one project
workspace event-log show --project myapp --limit 20
```
