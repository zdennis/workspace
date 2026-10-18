# workspace events

Read or follow the event log and every agent daemon's hook events as one stream, and resume it from a cursor.

## Usage

```sh
workspace events [--follow] [--json] [--types A,B] [--since CURSOR]
```

## Options

| Option | Description |
|--------|-------------|
| `--follow` | Keep reading new lines until stopped. With `--json`, one JSON object per line (JSONL) |
| `--json` | With `--follow`, JSONL. Without it, one document: `{"schema_version": 1, "ok": true, "events": [...], "cursor": "..."}` |
| `--types A,B` | Only lines of these types; repeat it or comma-separate several. `gap` and `follow_started` lines are always printed |
| `--since CURSOR` | Resume after the line that carried `CURSOR` |

Without `--since`, `--follow` starts at the end of every file and prints only what is written from then on. A plain read prints what is kept: the current event log, and each daemon's file and its rotated copy. That can be several megabytes per workspace in one document, so a script that wants recent lines should pass `--since` or `--types`.

Without `--json`, each line is `at  workspace  type  key=value ...`, like [`event-log show`](README.event-log.md). Scripts should use `--json`.

## Details

The stream has two kinds of source:

- **The event log**, `~/.workspace-events.jsonl` ([`event-log`](README.event-log.md)): state changes and lifecycle events such as `plan_changed`, `plan_progress` (a plan task changed state), `spine_changed` (a spine stage's status or note changed, or a stage file was added or removed), `inbox_changed`, `ask_created`, `agent_state`. Its lines are printed as they are in the log (`timestamp`, `type`, `project`, `data`), with `source: "lifecycle"`, `at` (the `timestamp`) and `workspace` (`data.workspace`, else `project`) added.
- **Each agent daemon's hook event file**, `~/.local/state/workspace/.events/<workspace>.jsonl` (the `hook_events` path in [`capabilities --json`](README.capabilities.md)). [`agentd`](README.agentd.md) writes one line for each hook event [`session-event`](README.session-event.md) forwards, and one for each [`agent status post`](README.agent.md#status). Its lines are printed as they are in the file, with `source: "hook"` added.

Every printed line also carries `cursor`. Lines from different sources come out in time order, and lines from one file always keep that file's order.

`events` only reads files. A slow or stopped reader never holds up a daemon or a command that writes to the log, and one `events` process covers every workspace, including ones started after it.

### Hook event lines

Every line has `type`, `at` (ISO 8601, UTC, milliseconds), `workspace` (the name the daemon serves), `pane_id` (the tmux pane), `boot_id` and `seq`.

| `type` | Fields |
|---|---|
| `tool_started` | `tool` (the tool's name), `tool_use_id`, `agent_id` (the sub-agent the tool ran in, `null` for the main agent), `path` (file tools only, below) |
| `tool_finished` | the same, plus `ok` (`false` when the tool's response says it failed or was interrupted) and `duration_ms` (the payload's own, else the time since this daemon saw the matching `tool_started`; `null` when it saw none) |
| `subagent_started` | `tool_use_id` (of the `Task` call), `description` (cut to 120 characters), `subagent_type` (cut to 64), `agent_id` (`null`: Claude Code names a sub-agent only once it runs). A `tool_started` for `Task` comes just before it |
| `subagent_stopped` | `agent_id` (the stopping sub-agent's, when Claude Code gives one) |
| `session_started` | `kind` (`claude`), `source` (`startup`, `resume`, `clear` or `compact`) |
| `session_ended` | `kind`, `reason` |
| `prompt_submitted` | none |
| `agent_status` | `summary` (cut to 500 characters), `task` (or `null`), `progress` (`{"done": N, "total": M}` or `null`), `reply_to` (the status request it answers, or `null`). Posted by an agent with [`agent status post`](README.agent.md#status), not by a hook |

`path` is the file an `Edit`, `Write`, `Read`, `MultiEdit`, `NotebookEdit` or `NotebookRead` works on, relative to the checkout (the nearest directory at or above the agent's working directory that holds `.git`). A file outside the checkout has no `path`.

Nothing that can hold a secret is written: no command text, tool input or output, prompt text, or notification message. Text fields have control characters replaced and are capped.

**`boot_id` and `seq`.** `boot_id` is new each time the daemon starts, and `seq` starts at 1 for each boot and goes up by 1 for each line that daemon writes. The same `boot_id` with a skipped `seq` means a line is missing (one the daemon couldn't write, or one rotated away). A new `boot_id` means the daemon restarted. A reader can de-duplicate on `boot_id` and `seq`.

**Files and rotation.** Each daemon writes only its own file, so one busy workspace never pushes another's lines out, and none of these lines reach the event log: its rotation and [`event-log compact`](README.event-log.md) never see them. When a file passes 5MB (the default; set [`events.rotate_size`](README.config.md) to change it, read when the daemon starts) it is renamed to `<workspace>.jsonl.1`, replacing the one before, so about twice that size is kept per workspace. `kill` and `finish` leave the file in place.

### Stream lines

| `type` | When | Fields |
|---|---|---|
| `follow_started` | first line of `--follow` | `at`, `source: "stream"`, `cursor` |
| `gap` | at the start, for each source the `--since` cursor is older than | `at`, `source` (`hook` or `lifecycle`), `workspace` (`null` for the event log), `reason` (`cursor_not_retained`), `cursor` |

`follow_started` gives a follower a cursor to save before any event arrives.

### Cursor

A cursor is opaque: save it and pass it back with `--since`, and don't read its contents. Each one covers every source: the event log and every daemon's file. It starts with a format prefix (`1.`).

Resuming with `--since`:

- **The cursor's place is still kept** (the file is current, or is now a rotated copy): reading goes on just after that line, then through any newer files. No line is printed twice and none is skipped.
- **The cursor is older than what is kept** (the file was rotated out, or `event-log compact` replaced it): a `gap` line is printed first, then every kept line written after the cursor's time.
- **A workspace whose daemon file is gone** (with its `.1`): that part of the cursor is dropped without a word. It is not an error.
- **A daemon file the cursor doesn't name** (a new workspace): it is read from its start.

A cursor `events` can't read is a usage error with the code `invalid_cursor` (exit 1; with `--json`, the error document on stdout).

`--types` doesn't change what a cursor covers. The document's `cursor` without `--follow` covers every line read, including those `--types` left out. With `--follow`, each line's cursor covers everything before it.

**While following**, files are checked every 0.25 seconds and new daemon files every 2 seconds. A file that rotates or is compacted under a follower is read to its end and the follower goes on in the new file. Only lines after the last one read are printed, so the compacted copy a lifecycle rotation starts with is not printed again. Its `compacted` lines are new, so they are printed.

**Limits.** Across a rotation or compaction of the event log, lines are matched by time, not position. A line written in the same millisecond as the last one read before the switch, or one whose writer took its time before waiting for the log's lock and landed after the switch with an earlier time, is not printed. A daemon's file has no such limit, since its `seq` tells its lines apart. A cursor taken while the event log didn't exist yet replays every kept copy of the log when resumed. Each read takes at most 1MB from a source, so a large backlog comes out over several reads rather than all at once; while catching up that way, the order across sources is only approximate, though each file keeps its own order and every cursor stays correct.

A follower exits 0 on SIGINT or when its reader closes the pipe; SIGTERM ends it with the usual signal status. If reading fails in any other way, a follower with `--json` prints the error document (`{"schema_version": 1, "ok": false, "error": ..., "code": ...}`, which has no `type`) as its last line and exits 1, so a reader should restart it.

## Examples

```sh
# Follow every workspace's tool and sub-agent activity
workspace events --follow --json --types tool_started,tool_finished,subagent_started,subagent_stopped

# Resume a follower after a restart
workspace events --follow --json --since "$(cat ~/.cache/my-app/events.cursor)"

# What sessions started and ended recently, as text
workspace events --types session_started,session_ended
```
