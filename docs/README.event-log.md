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
| `--json` | Print `{"schema_version": 1, "ok": true, "events": [...]}` instead of lines |

Each line is `timestamp  project  type  key=value ...`. Control characters in logged text are replaced with spaces. A value containing a space or `=` is quoted (Ruby `String#inspect`) so the line stays splittable on `"  "`; scripts should use `--json` instead of parsing this format. `--json` applies to `show` only; `compact` always prints its one-line summary. It works no matter where the flag appears (e.g. `event-log --json show`); stdout then carries only the JSON object, including for usage errors (`{"schema_version": 1, "ok": false, "error": "...", "code": "usage"}`); warnings, such as skipped corrupt lines, go to stderr.

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
| `lock_wait_started`, `lock_acquired`, `lock_released` | a [workflow run](README.workflow.md) taking, getting or giving up a lock a step uses | `lock`, `run_id`, `step`, `workspace`; `position` and `holder` for a wait (the holder's `run_id` and `step` when a run holds the lock, else its `pid`; `pane`, `worktree` and `task` when known); `waited_seconds` for an acquire that ended a wait |

Hook-rate activity (each tool start and finish, sub-agent start and stop, session start and end, and prompt submitted) is not written here. Each agent daemon writes it to its own file, so it never rotates this log's history away and `compact` never handles it. [`workspace events`](README.events.md) reads those files and this log together as one stream, with a cursor to resume from.

An acquire that doesn't wait records nothing here; `locks.jsonl` in the lock store already audits every acquire and release.

### Agent recovery

The agent daemon writes two lines when it recovers an agent from an API error (see [`agentd`](README.agentd.md#recovering-from-an-api-error)). Neither holds the error's text, only its kind.

| Type | Written by | `data` |
|------|-----------|--------|
| `agent_recovery_attempt` | agent daemon, one attempt finished | `attempt` (from 1, of at most 12), `session_id`, `pane_id`, `error` (the kind), `mode` (`typed` or `restart`), `outcome` |
| `agent_recovery_gave_up` | agent daemon, it stopped trying and added one inbox item | `pane_id`, `session_id`, `attempts`, `error`, `reason` |

`outcome` is `typed` (Claude Code took the typed message), `resumed` (restarted and Claude Code took the message), `agent_left` (the message was taken, then no agent was left in the pane), `no_response` (no prompt hook within 30 seconds of the message), `not_submitted`, `not_typed`, `not_stopped`, `not_delivered`, `pane_not_clear`, `not_ready`, `person_resumed` (a person resumed the conversation first), `resumed_elsewhere` (the same session opened in another pane, so nothing was typed), `fresh_agent` (a different conversation started in the pane), `claim_lost` or `interrupted` (the daemon restarted during the attempt). The agentd page says what each one means. `fresh_agent` gives up. The failed outcomes count toward the 12 and schedule the next attempt.

`reason` is `attempts_exhausted`, `not_retryable`, `cannot_restart`, `fresh_conversation`, `deferred` or `unconfirmed`.

### State and lifecycle events

These record that something changed, so a reader can refetch (`snapshot --json`) instead of polling. They carry identifiers and names, never the user's text: no question, answer, prompt, task title, path or config value. Like every activity event, `reconstruct` ignores them. Every event has a string `project` (an event with a nil one is not written; the global `config_changed` uses an empty string), and the workspace name also sits in `data.workspace` where one applies.

| Type | `project` | Written by | `data` |
|------|-----------|-----------|--------|
| `ask_created` | the asking workspace | `ask`, once the question is stored | `id`, `workspace`, `pane_id` (the tmux pane id, or `null`) |
| `ask_answered` | the asking workspace | `ask answer`, once the answer is stored and before `--deliver` types it | `id`, `workspace`, `pane_id` |
| `ask_withdrawn` | the asking workspace | `ask withdraw`, once the question is marked withdrawn | `id`, `workspace`, `pane_id` |
| `lock_released` | the lock namespace's project, as for the lock waits | `lock release`, once per lock released | `lock`, `pid`, and `workspace` from a worktree |
| `lock_cleared` | the lock namespace's project | `lock clear`, for each lock it cleared; a lock kept for a process group it could not stop writes nothing | `lock`, `pid` (the clearer's), and `workspace` from a worktree |
| `worktree_started` | the worktree's workspace name | `start`, once the worktree's config is written and before it launches | `workspace`, `parent` (the main workspace's name), `branch`, `created` (`false` for an existing or adopted worktree), `task` (the task id, when a task store is wired), `promoted` (`true` only for a worktree `promote` just made) |
| `workspace_promoted` | the new workspace's name | `promote`, once the work is moved and the workspace made (after its `worktree_started` line); a dry run or a failed move writes none | `workspace`, `parent`, `branch`, `from_branch`, `branch_created`, `snapshot` (the stash commit id, or null), `notes` (`plan`, `spine`, `carried`: the count of notes copied). Names only, never paths |
| `worktree_finished` | the worktree's workspace name | `kill`, `finish` and the project actions built on them, once the worktree, its config and its settings are removed, as the session stops; `prune`, once per workspace it removes | `workspace`, `outcome` (`merged`, `pushed`, `abandoned`, `discarded` or `pruned`) |
| `workspace_renamed` | the workspace's new (lowercase) name | `agentd`, `agentd --ensure`, `agentd restart` and `launch`, once per mixed-case workspace they rename to lowercase before its daemon starts (a project's worktree workspaces each write their own) | `workspace` (the new name), `from` (the old name), `renamed` (what was renamed: `tmux_session`, `project_settings`, `socket`, `log`, `lock`, `state_dir`, `inbox`, `project_inbox`, `state`, `marker`, `tmuxinator_config`), `failed` (the same names, for steps that failed; the reasons are in the daemon log) |
| `daemon_started` | the workspace the daemon serves | `agentd`, once it is ready | `workspace`, `daemon` (`agent`), `pid` |
| `daemon_stopped` | the workspace the daemon served | `agentd`, as it shuts down | `workspace`, `daemon`, `pid` |
| `config_changed` | the project, or `""` (empty) for the global file | `config set` and `config unset` | `workspace` (project layer) or `scope` (`global`, global layer), `layer` (`project` or `global`), `via` (`set` or `unset`), `keys` (the key names written) |
| `dev_started` | the project | the `dev __run` wrapper, once its command is running (also as a workflow run's delegate) | `workspace` (the worktree's own name, or the project's for its main checkout), `lock` (`devenv`) |
| `dev_stopped` | the project | the wrapper when its command ends on its own (`exit`); `dev down` (also when it runs because the agent that started the environment ended, or `kill`/`finish` removed its worktree), `dev up --force` and `down --force` when they stop it (`down`, `forced`); `dev down` or the daemon's reaper finding the wrapper dead (`reaped`) | `workspace`, `lock` (`devenv`), `reason` (`down`, `exit`, `reaped` or `forced`). Refetch `dev status --json` |
| `agent_pane_refreshed` | the workspace | `launch`, once it has rewritten a stale agent pane in the tmuxinator config before starting the session (also with `--json` or when quiet), and `doctor --fix`, once per config it rewrites; written after the file is replaced, never for a config left as it was or one that could not be written. A reader that shows `doctor`'s `agent-pane-command` row refetches it | `workspace`, `path` (the config file), `running` (the program the pane ran), `wanted` (the program it runs now), `backup` (the backup file's path, or `null` when none was made) |
| `plan_changed` | the workspace | `plan init`, and `plan start`, `plan pause` and `plan delete` when they change the plan file (the `status:` line or `owner_pane:`, or the rename); a verb that finds nothing to change writes nothing | `workspace`, `status` (the plan's status after the change, `active`, `paused` or `done`, or `deleted`). Refetch `plan status --json` |
| `plan_progress` | the workspace | the agent daemon, which checks the workspace's plan file about four times a second and writes one line once the file has stopped changing for about half a second, so a burst of edits is one line, whether a plan verb, an agent or an editor made them. Only a change to a task's state, or a task added or removed, writes a line; prose and frontmatter edits write none. The daemon reads the plan when it starts and writes nothing for what was already there, so an edit made while no daemon runs is not reported | `workspace`, `counts` (as `plan status --json` reports them: `total`, `done`, `in_progress`, `skipped`, `blocked`, `todo`, `left`), `current` (the id of the in-progress task, else the first to do, or `null`), `changed` (the ids of the tasks that changed state, appeared or went away; a task without an id is not named). Never a title. Refetch `plan status --json` for the rest |
| `workflow_changed` | the run's workspace | `workflow run`, `resume`, `cancel`, `approve`, `reject`, `kill` (for the runs it cancels) and the `workflow advance` the agent daemon starts, each time a run's state, step or reason changes (a hold writes one line on entering, none for its later Stops) | `run_id`, `workflow`, `workspace`, `state` (`running` for a `turn_ended_background` reason, as `workflow status` reads it), `step`, `reason` (the stored reason code, or `null`; it can be `turn_ended_background`, which `workflow status` never shows). Refetch `workflow status --json` |
| `library_changed` | the project's name for a project-store entry, `""` (empty) for a global one | `library add`, `update` and `remove` after the store changed (an `add --force` that replaces an entry is `update`); an unchanged entry, `--dry-run`, a declined confirmation or a failed write writes nothing. The built-in store is read-only and never changes | `ref` (`kind/name`), `scope` (`global` or `project`), `action` (`add`, `update` or `remove`). Never the body. Refetch `library list --json` |
| `spine_changed` | the workspace | `spine set`, once per stage file it writes (a stage that already read the status writes nothing); and the agent daemon, which checks the workspace's `spine/` folder about four times a second and, once it has stopped changing for about half a second, writes one line per stage whose `status`, `note` or `owner` changed, however the file was edited, so a burst of saves is one line per stage. The daemon also writes a line when a stage file appears or goes. It reads the spine when it starts and writes nothing for what was already there; it skips a workspace whose notes directory can't be worked out, and never follows a link. An edit to anything but `status`, `note`, `owner` or the set of stage files writes nothing. A change that is a `spine set` write (the file's revision is the one in `spine set`'s own line for that stage, written in the last two minutes) is not logged a second time | A change line: `workspace`, `path` (the stage's path, such as `implement/api`), `status` and `previous` (canonical), `note` (the note after, or `null`), `owner` (the owner after, or `null`), `by` (for `spine set` the `updated_by` label; for the daemon the file's `updated_by` when `updated` moved in this change, else `file`), `revision` (the file's revision after the change, as `spine show` reports it). An added or removed line: `workspace`, `path`, `change` (`added` or `removed`) and nothing else. `spine check` writes its own line, `workspace`, `path`, `change: "done_when"`, `items` (the numbers of the items whose box changed), `by` and `revision`, once per call that changed a box; the daemon does not log a hand tick. `spine verify` writes `workspace`, `path`, `change: "check"`, `check` (`passed` or `failed`), `previous_check`, `status`, `check_note`, `by` (the `checked_by` label) and `revision`, once per call that changed a line; the daemon logs a hand edit of `check`, `checked_by` or `check_note` as a change line with `change: "check"`, `check`, `check_note`, `previous_check` and `by` (the file's `checked_by`), and the stage's `status`, `note` and `owner` (an edit that also moves the owner is labelled `owner`, with `check` still in the line) unless it is a `spine verify` write, and a `spine set` line for a stage with a check carries `check` after the change. The agent daemon writes `workspace`, `path`, `change: "owner_finished"`, `owner` (pane id) and `state` (`completed`, `checking` or `in_progress`) when a stage's owner pane ends its turn or the stage is set `completed` (`in_progress` at every turn end, a completed stage once when it is set; see [`spine`](README.spine.md#owner-finished)). `spine goal set` writes `workspace`, `change: "goal"`, `title`, `created`, `by` and `revision`, once per call that changed `goal.md`; the daemon does not watch the goal. A change line has `change: "owner"` when only the owner changed (by `spine set --owner` or by hand); a line without `change` is a status or note change (the owner may have changed with it). A stage file that can't be read for a moment (a link, bytes that are not UTF-8) counts as unchanged, and a renamed file is a `removed` and an `added` line. Refetch `spine show --json` |
| `inbox_changed` | the workspace's name for a workspace item, the project's display name for a project item, `""` (empty) for a global one | `inbox add`, `edit`, `done`, `dismiss`, `reopen`, `snooze` and `ack`, and once per item that expired when a write to its scope stores the expiry, once per item whose store changed; an `unchanged`, `suppressed` or failed row writes nothing | `id`, `scope` (`workspace`, `project` or `global`), `scope_key` (the workspace name, the project's git common dir, or `null`), `state` (the item's state after the change), `change` (`created`, `updated`, `resolved`, `reopened`, `snoozed`, `acked` or `expired`; an `ack` or a snooze of a derived row carries the derived id, and `state` is `open`). Never the title, body or ref. Refetch `inbox list --json` |

Not every change is covered:

- A lock released by the reaper, by `dev down`, by a SessionEnd hook or by `dev up --force` passes through none of these, so a reader should treat `lock_released` as a hint to refetch, not as a full record. `locks.jsonl` still audits every one.
- `state_removed` (a state event, above) is written when a workspace leaves the state file: by `stop`, `kill`, `finish` and `prune`. It means the workspace stopped running, not that it is gone; `worktree_finished` is the line that says a worktree was removed.
- A daemon killed with SIGKILL writes no `daemon_stopped`; its pid is gone from `snapshot --json`.
- `config_changed` comes from the CLI only. Edits made in an editor, and the richer shape the config editor will add (`file`, `affects`), are not written yet.
- `dev_ready` and `pipeline_status` are not written yet.
- `dev_stopped` is not written when `lock clear devenv` or a signal sent by hand stops the wrapper (the stop is not one `dev` made, and the wrapper only writes an end it was not asked to make). Only `dev down` and the agent daemon's reaper write `reaped`, so a dead wrapper first found by another lock command gets no `dev_stopped` until one of those sees it. Treat both events as a hint to refetch, not a full record; `locks.jsonl` audits every change.

These are written by whichever process makes the change: a short-lived CLI command or the agent daemon. Both go through the same append (one `write` to a file opened with `O_APPEND`, under the shared lock), so they land in one log without interleaving and a rotation never loses one.

A restarted agent daemon reads each pane's last `agent_state` back, so `workspace sessions` keeps each pane's state and `state_since` instead of starting afresh. The pane's pid must match, so a pane id reused by a new tmux server starts fresh. A pending wait is not restored. It also reads each pane's last `agent_alert` of each kind back, so a restart doesn't send an alert again: a pane still idle in the same quiet stretch isn't alerted again, and an agent that was waiting when the daemon stopped isn't alerted again when it asks again, as long as it sent no other hook event in between. A new quiet stretch or a new wait alerts as usual.

Recording activity never fails the command doing it: if the log can't be written, one warning goes to stderr and the command carries on. Nothing is written to stdout, so `--json` output stays JSON-only.

When the event log exceeds 1MB (`event_log_compact_threshold` in the global config), workspace warns you to compact it. Compaction replays the log and rewrites it with one `compacted` event per active project, plus the latest `agent_state` of each pane that still has an agent (and changed within the last 7 days), that pane's latest idle `agent_alert`, and, while it is still waiting, its latest waiting `agent_alert` per agent. All other activity history is dropped. There is no dry run, and `compact` ignores any extra flag: the log is still compacted.

When an append leaves the log over 10MB, workspace rotates it on its own: the log is renamed to `.workspace-events.jsonl.1` (older files shift to `.2` and `.3`; the one past `.3` is deleted), and a new log, seeded with the same compacted state, takes its place. Rotated files keep the activity history, so the log and its rotated files stay under about 40MB. Rotation is safe with several workspace processes appending at once, and a failed rotation never fails the command that triggered it.

Existing users are automatically migrated on first run — the current state file is converted to `migrated` events in the log.

## Examples

```sh
# Compact the event log: rewrites it in place and drops the history
workspace event-log compact
# => Compacted event log: 15360 -> 1024 bytes (8 project(s))

# Check what compaction kept: one compacted event per active project
workspace event-log compact && workspace event-log show --type compacted

# The last 20 events for one project
workspace event-log show --project myapp --limit 20

# Why a pipeline stage stopped
workspace event-log show --type stage_failed,stage_timed_out

# Who waited for a lock, and who took one over
workspace event-log show --type lock_wait_started,lock_takeover --project myapp

# The newest event as JSON, for a script
workspace event-log show --json --limit 1
```
