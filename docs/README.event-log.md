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
| `--type TYPE` | Only events of this type; repeat it or comma-separate several |
| `--limit N` | Only the last N matching events |
| `--json` | Print `{"schema_version": 1, "events": [...]}` instead of lines |

Each line is `timestamp  project  type  key=value ...`. Control characters in logged text are replaced with spaces. With `--json`, stdout carries only the JSON object, including for usage errors (`{"schema_version": 1, "error": "..."}`); warnings, such as skipped corrupt lines, go to stderr.

## Details

Workspace tracks all state changes (launches, kills, window discoveries, repairs, prunes) as timestamped JSONL events in `~/.workspace-events.jsonl`. The state file (`~/.workspace-state.json`) is rebuilt from this log on every save.

This append-only approach eliminates race conditions from concurrent launches — multiple processes can safely append events without clobbering each other. Each event is written with a single `write` to a file opened for appending, so lines from different processes never interleave.

When the event log exceeds 1MB (`event_log_compact_threshold` in the global config), workspace warns you to compact it. Compaction replays the log and rewrites it with one `compacted` event per active project.

Existing users are automatically migrated on first run — the current state file is converted to `migrated` events in the log.

## Examples

```sh
# Compact the event log
workspace event-log compact
# => Compacted event log: 15360 -> 1024 bytes (8 project(s))

# The last 20 events for one project
workspace event-log show --project myapp --limit 20
```
