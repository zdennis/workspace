# workspace event-log

Manage the append-only event log that backs workspace state.

## Usage

```sh
workspace event-log <subcommand>
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `compact` | Compact the event log to current state only |
| `help` | Show help |

## Details

Workspace tracks all state changes (launches, kills, window discoveries, repairs, prunes) as timestamped JSONL events in `~/.workspace-events.jsonl`. The state file (`~/.workspace-state.json`) is rebuilt from this log on every save.

This append-only approach eliminates race conditions from concurrent launches — multiple processes can safely append events without clobbering each other.

When the event log exceeds 10KB, workspace warns you to compact it. Compaction replays the log and rewrites it with one `compacted` event per active project.

Existing users are automatically migrated on first run — the current state file is converted to `migrated` events in the log.

## Examples

```sh
# Compact the event log
workspace event-log compact
# => Compacted event log: 15360 -> 1024 bytes (8 project(s))
```
