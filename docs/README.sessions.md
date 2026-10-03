# workspace sessions

Show which panes in a workspace are running a coding agent, whether each is working, idle, or waiting on a person, and any sub-agents they have started.

## Usage

```sh
workspace sessions [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--json` | Emit the raw payload instead of a table |
| `--watch` | Redraw until interrupted |
| `--interval SECONDS` | Seconds between redraws when watching (default 2) |
| `--worktrees` | Also show sessions for child worktree workspaces |

## Details

Requires a running agent daemon for the project (`workspace agentd <project>`, or launched automatically by [`workspace launch`](README.launch.md)). If no daemon is listening, the command fails with a message telling you how to start one. `workspace doctor` also reports whether the daemon is running for the current project.

`project` defaults to the project detected from the current directory, same as other commands.

The daemon holds the session state; this command only asks for it, over the agent's Unix socket. That keeps `--json` and the table behind one code path, so scripting against `--json` sees exactly what the table shows.

The reply is read with a 5 second limit, so a daemon that accepts the connection but never answers can't hang the command. It fails like a missing daemon, with `Agent daemon for '<project>' did not answer within 5.0s.` (and exit 1 with `--json`); under `--worktrees` that member is left out like any other without an answering daemon. [`workspace projects show`](README.projects.md#agents) reads the same snapshot with its own `--timeout`.

`--json` output starts with `"schema_version": 1`, matching [`workspace lock status --json`](README.lock.md) and [`workspace dev status --json`](README.dev.md). If no agent daemon is listening, `--json` writes `{"schema_version":1,"ok":false,"error":"..."}` to stdout and exits 1, instead of the plain-text error the table view prints to stderr.

Each pane shows its index, kind, title, state, how long it's been idle, a LOCK column, and an ASK column.

**STATE column** — one of:

| State | Meaning |
|-------|---------|
| `working` | The pane's output changed in the last 30 seconds |
| `idle` | The pane's output has not changed for 30 seconds or more |
| `done` | The agent's turn ended (Claude Code's `Stop` hook) and nothing has happened since. It outranks `working`, `idle` and `waiting`: a quiet screen or the agent's own "waiting for your input" notification a minute later leaves it `done`. A new prompt, a tool call, a sub-agent starting, a session starting or ending, or the agent leaving the pane ends it. A `Stop` from inside a sub-agent does not set it |
| `waiting` | The agent asked for permission or for input (Claude Code's `Notification` hook) and nothing has happened since. The agent's message is shown on the line below the pane |

A pane leaves `waiting` on the agent's next hook event: a submitted prompt, a finished tool (`PostToolUse`, which follows an approved permission prompt), or the turn or session ending. It also leaves `waiting` when the pane no longer runs an agent. The main agent and each sub-agent keep their own wait: two sub-agents can wait on a person at once, each alerting once, and an event from one agent (main or sub-agent) ends only that agent's wait, never another's. A new prompt, stop, or session start/end clears all of a pane's waits at once. `sessions` shows the pane's oldest wait (its time and message) when more than one is active. `waiting` needs the `Notification` and `PostToolUse` hooks, which `workspace init` installs; a project whose hooks predate them shows only `working`/`idle` until `workspace init` is re-run (`workspace doctor` reports the hooks as not installed until then).

`waiting` is detected for Claude Code only. Other agents (Codex, OpenCode, Pi) have no equivalent hook wired up, so their panes only ever show `working` or `idle`, never `waiting`.

The waiting message is cleaned before it is shown or passed on: each run of whitespace and control characters becomes a single space, and it is cut to 200 characters. `sessions --json` and the `WORKSPACE_ALERT_*` variables get the same cleaned text; the table further shortens it to 60 characters for display.

**`--json` `stop_reason`** — each pane carries `stop_reason`: the reason the `Stop` hook reported (cut to 64 characters), or `end_turn` when the hook carries none, which is what Claude Code sends today. It is `null` unless `state` is `"done"`. `state_since` is when the turn ended. Idle alerts are unchanged: a `done` pane still alerts once its output has been quiet for `alerts.idle_after`, since alerts go by screen activity. `workspace agent restart` still treats a done pane as idle.

**`--json` waiting fields** — each pane carries `waiting_since` (ISO 8601 UTC, or `null`), `waiting_seconds` (integer, or `null`) and `waiting_message` (the agent's cleaned message, cut to 200 characters, or `null`). All three are `null` unless `state` is `"waiting"`. `state_since` (ISO 8601 UTC) is when the pane entered its current `state`.

**State history** — the agent daemon appends each agent pane's state changes (`working`, `idle`, `waiting`, and `exited` or `closed` once the agent goes) to the event log as `agent_state` events; read them with `workspace event-log show --type agent_state`. A restarted daemon reads each pane's last state back, so `state` and `state_since` carry over instead of starting afresh. A pending wait is not carried over, since the event that ended it may have arrived while no daemon was running. Sub-agents started within a pane (Claude Code's `Task` tool invocations) are listed indented underneath their parent pane.

**LOCK column** — shows this pane's relationship to every lock in the project's namespace ([`workspace lock`](README.lock.md)), not just `edit`: a pane holding or queued for more than one lock (e.g. `edit` plus a `devenv` process lock) shows all of them, space-joined, `edit` first and any others alphabetical after it — `edit ✓ devenv #2`. A pane with no lock relationship shows blank, including one with no agent at all. A dead holder or waiter (its process no longer alive) never shows `✓`, and is skipped when numbering each lock's queue, so `#1` always refers to the next live waiter. The namespace is resolved from the *rendered workspace's* project root (its tmuxinator config), not the command's own working directory, so `workspace sessions other-project` always shows `other-project`'s lock state, never whatever project happens to be in front of it. If that project's root can't be resolved, the column is hidden rather than guessed. The lock store is loaded once per render (never once per pane), so the column costs one extra file read, not a `git`/`ps` call per row.

**`--json` lock fields** — alongside the human `"lock"` string described above, each pane in `--json` carries structured fields for scripting:

| Field | Values | Meaning |
|-------|--------|---------|
| `lock_state` | `"held"`, `"queued"`, or `null` | This pane's relationship to the `edit` lock, or to its first lock if it doesn't hold or queue for `edit` |
| `lock_position` | integer (1-based) or `null` | Live-queue position when `lock_state` is `"queued"`; `null` otherwise |
| `lock_name` | lock name or `null` | The lock these three fields describe; `null` if the pane holds or queues for no lock |
| `locks` | array | Every lock the pane holds or queues for, each `{"name", "state", "position"}` with the same meanings as above, in the same `edit`-first order as the `lock` label |

`lock_state`/`lock_position`/`lock_name` are kept for scripts written before multi-lock support: they always describe the `edit` lock when the pane has one, falling back to the pane's first lock (by the label's ordering) otherwise. A script that needs every lock a pane holds should read `locks` instead.

When the LOCK column is hidden (project root unresolved), all five fields (`lock`, `lock_state`, `lock_position`, `lock_name`, `locks`) are absent from each pane's JSON, not merely `null` — a consumer should treat a missing `lock_state` key the same as a `null` one.

**`--json` `display_label`** — each pane carries `display_label`, a short name for what the pane is working on, for a UI row to show instead of `claude · Claude Code`. It is the first of these that exists: the AI title in the pane's transcript (Claude's last `ai-title` line), the last prompt the agent daemon saw in that pane, or the transcript's `last-prompt` line. It is `null` for a shell pane, and for a pane no hook event has reached yet. Whitespace is collapsed and it is cut to 80 characters. The workspace's task title (`workspace start --title`) comes first when it has one.

**`--json` `task`** — the document carries `task`: `null` when the workspace has no active task, else `{"id", "title", "ref", "branch", "status"}` (see [`start`](README.start.md#tasks)). `status` is derived each time it is read, never stored: `blocked` when a coding-agent pane is `waiting`, else `working` when one is `working`, else `done` when one is `done`, else `idle`. `needs-review` (done, ahead of its base, no open question) is not reported yet.

`label` is unchanged: it is still the agent's name (`Claude Code`) or a shell's command, which is why the new field has its own name. The daemon keeps the transcript path and prompt in memory only, from the `session-event` hook; neither is written to the event log, and the prompt is not written anywhere (the transcript path is, as before, in the session ledger). It does read the transcript file, which Claude already keeps on disk, and only its last 256 KB, once per change to the file. A new session in the same pane starts with no label source. The table's TITLE column still shows `label`.

**ASK column** — the pane's open [`workspace ask`](README.ask.md) count: blank when there are none, `"N asked"` otherwise. `--json` carries the same count as `open_questions` (an integer, always present, `0` when there are none). A question recorded outside tmux carries no pane id and isn't counted against any row; `workspace ask list` still shows it. Answering a question (`workspace ask answer`) drops it from the count on the next render.

**Context usage fields** — a coding-agent pane (any pane whose `kind` isn't `"shell"`) carries `context_pct` (integer 0-100, or `null`), `context_error` (`null`, or a reason it couldn't be determined), and `context_updated_at` (ISO 8601 UTC, or `null`; set whenever a reading was recorded, including one from a session that hasn't reported usage yet). A shell pane never carries these fields at all. See [`workspace statusline`](README.statusline.md) for how the reading gets there. When `context_pct` is `null`, `context_error` is one of:

| Reason | Meaning |
|--------|---------|
| `no reading recorded (status line not routed through workspace, or not rendered yet)` | Claude's `statusLine` isn't set to `workspace statusline`, or it hasn't rendered yet this session |
| `no pane id (status-line process lacked $TMUX_PANE)` | The status-line process ran without `$TMUX_PANE` set; usually resolved automatically via the pane's agent process id |
| `no context.pattern configured (scrape mode)` | `context.source` is `scrape` but `context.pattern` isn't set |
| `pattern didn't match (scrape mode)` | `context.source` is `scrape` and `context.pattern` didn't match the pane's text |
| `the last reading is from an earlier Claude session in this pane` | The pane was reused (e.g. Claude restarted in it) and the only reading on record predates the current session |

The fix is always one of: run `workspace doctor --fix` (or add a `statusLine` entry to `~/.claude/settings.json` by hand: `"statusLine": {"type": "command", "command": "workspace statusline"}`), switch to scrape mode (`workspace config set context.source scrape` and `workspace config set context.pattern '(\d+)% ctx'`), or pass `--context-pct N` to whatever command needs the number. `context_pct` is never guessed — a stale reading is reported as-is, with `context_updated_at` showing its age, since renders are event-driven and none happen during a long tool call.

## --worktrees

`--worktrees` shows the root project's sessions plus every child worktree workspace's (config names `<project>.worktree-*`, same family `workspace tile` groups). With no `project`, the root is the parent of the current worktree (via `.workspace-project`/git ancestry), so running it from inside a worktree still shows the whole family. Passing a worktree's own name works the same way — it's resolved to its parent first.

A member workspace with no agent daemon running is left out silently; only when *none* of the family answers does the command fail the same way plain `sessions` does for a single project, naming the root. The table shows one section per workspace that answered — a `workspace: <name>` heading and its usual pane table, root first, then children sorted, separated by a blank line. `--json` nests each member's usual payload (same shape as plain `sessions --json`, `schema_version` included) under a `"workspaces"` array, itself wrapped in `{"schema_version": 1, "ok": true, "workspaces": [...]}`. `--watch`/`--interval` redraw every section each tick.

## Alerts

The session-monitor daemon can run a command of your choosing when an agent pane starts `waiting`, or when an agent pane's output stays unchanged for longer than `alerts.idle_after` (default `10m`). Set it with [`workspace config`](README.config.md):

```sh
workspace config set alerts.notify 'say "$WORKSPACE_ALERT_TEXT"'
workspace config set alerts.idle_after 15m
```

With no `alerts.notify` set, nothing runs; `sessions` still shows the state. Both settings are read when the daemon starts, so restart it (`workspace agentd <project> --force`, or relaunch) after changing them (`workspace doctor` confirms it's running). For a worktree, the settings come from its parent project, where `workspace config set` stores them, but the daemon to restart is the worktree's own.

Each wait alerts once, and each stretch of unchanged output alerts once, however long it lasts; a new wait, or output that changes and then goes quiet again, alerts again. A pane that is `waiting` doesn't also alert for being idle. Shell panes (no agent) never alert. A restarted daemon reads the alerts it already sent back from the event log, so it doesn't alert again for a quiet stretch that is still going, or for a wait the agent asks about again before sending any other hook event (see [event-log](README.event-log.md#agent-activity)).

The command runs through `/bin/sh -c`, in its own process group, with stdin and stdout discarded and stderr going to the daemon's log. It gets the alert only as environment variables; nothing from the agent is ever spliced into the command line, so quote the variables you use (`"$WORKSPACE_ALERT_TEXT"`):

| Variable | Value |
|----------|-------|
| `WORKSPACE_ALERT` | `waiting` or `idle` |
| `WORKSPACE_ALERT_WORKSPACE` | The workspace (tmux session) name |
| `WORKSPACE_ALERT_PANE` | Pane as shown in the PANE column, e.g. `0.1` |
| `WORKSPACE_ALERT_PANE_ID` | tmux pane id, e.g. `%12` |
| `WORKSPACE_ALERT_KIND` | Agent kind, e.g. `claude` |
| `WORKSPACE_ALERT_SECONDS` | Seconds the pane has been waiting or idle |
| `WORKSPACE_ALERT_MESSAGE` | The agent's notification message (empty for `idle`) |
| `WORKSPACE_ALERT_TEXT` | One-line summary, e.g. `myapp pane 0.1 (Claude Code) is waiting: Claude needs your permission to use Bash` |

The daemon never waits on the command. One still running after 10 seconds gets SIGTERM, then SIGKILL 2 seconds later, sent to its process group; a command that exits non-zero, can't start, or is stopped is reported in the daemon's log. At most 4 runs go at once; an alert raised while 4 are still running isn't lost, it goes out on a later scan once one of those finishes, and the daemon logs "skipped notify command for … (N earlier runs still going)" each time. Stopping the agent daemon stops any notify command still running the same way (SIGTERM, then SIGKILL after 2s).

If the daemon can't read the process table for 5 scans in a row (needed to tell working/idle/waiting apart), it prints one line to stderr — `workspace agent: can't read the process table for <workspace> (5 scans in a row: <error>); idle alerts are paused until it can` — once per streak; a scan that succeeds resets the count.

## Examples

```sh
# Show sessions for the current directory's project
workspace sessions

# Show sessions for a named project
workspace sessions my-project

# Watch and redraw every 2 seconds
workspace sessions --watch

# Watch with a custom interval
workspace sessions --watch --interval 5

# Emit raw JSON for scripting
workspace sessions --json

# Show sessions for a project and all its worktree workspaces
workspace sessions my-project --worktrees
```
