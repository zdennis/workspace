# workspace session-event

Forward one coding-agent hook event, read as JSON on stdin, to that workspace's agent daemon.

## Usage

```sh
workspace session-event [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--workspace NAME` | Send to NAME instead of the workspace detected from the pane |
| `--agent KIND` | Read the payload by KIND's hook event names: `claude` (the default) or `codex`, in any case. Any other KIND is dropped, exit 0, so a hook never fails over it |

## Details

Installed as a hook by [`workspace init`](README.init.md); not normally run by hand. `workspace doctor` reports whether hooks are installed for the current project's coding agent.

Reads a coding agent's hook payload from stdin, translates it into workspace's event vocabulary, and forwards it over the target workspace's agent socket to the daemon started by `workspace agentd` (or automatically by `workspace launch`). The workspace is normally resolved from the tmux pane the hook is running in (`TMUX_PANE`); `--workspace` overrides that.

It also keeps [`workspace lock`](README.lock.md)'s idle tracking current: `Stop` marks any lock the calling agent holds as idle, and `UserPromptSubmit` or any `PreToolUse` marks it active again, so a waiter can take over a lock whose agent has been idle for `locks.idle_grace`. Only the calling agent's own hold is changed. When there is no lock store, or no lock anywhere is held from this pane, this costs only file reads across the (few, small) namespace directories under the lock store — no subprocess. Only once a matching hold is found does it resolve which project's namespace it belongs to (shelling out to `git`) to act on it.

It also enforces the `edit` lock: a `PreToolUse` for `Edit`, `Write`, `MultiEdit`, `NotebookEdit` or Codex's `apply_patch` is denied when this namespace's `edit` lock is held by another agent — see [`workspace lock`](README.lock.md#details) for the message and cost. `SessionEnd`, and a `SessionStart` whose `source` is `clear`, release every lock the calling agent holds.

On a `SessionEnd` whose `reason` is not `clear`, it also looks (file reads only, no subprocess) for a `devenv` lock record whose `started_by.session_id` is the ending session, and if one exists starts `workspace dev __release SESSION_ID` as its own process, which stops that dev environment unless the project's `dev.release_on_session_end` is `false`. The hook does not wait for the stop. A `/clear` (`SessionEnd` with reason `clear`, then `SessionStart` with source `clear`) never releases it. See [`dev`](README.dev.md#release-when-the-session-ends).

Exits 2, with the deny message on stderr, when an edit is denied; a denied tool is not forwarded. Otherwise always exits 0, whether or not a daemon is listening, so a missing daemon never fails an agent's turn. Currently understands Claude Code's hook events (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `PreToolUse` for every tool — the `Task` tool marks a sub-agent starting; `Edit`/`Write`/`MultiEdit`/`NotebookEdit` are checked against the edit lock — `Notification`, which marks the pane `waiting` in [`workspace sessions`](README.sessions.md) and carries the agent's message (cut to 200 characters), and `PostToolUse`, which ends that wait once a tool runs after a permission prompt). Every event it forwards, except `Notification` and a `PreToolUse` for a tool other than `Task`, ends a wait: tools can run side by side, so one starting says nothing about another's permission prompt.

### Codex

With `--agent codex` (how [`init`](README.init.md#agent-session-hooks) installs it into `~/.codex/hooks.json`), it reads Codex's hook events instead:

| Codex event | Forwarded as | Notes |
|---|---|---|
| `SessionStart`, `SessionEnd` | `session_start`, `session_end` | `kind` is `codex`. Recorded in the session ledger with `kind: "codex"`, so [`restore`](README.restore.md) leaves the pane alone. Codex's `SessionEnd` reason is always `other` |
| `UserPromptSubmit` | `user_prompt` | The prompt is not forwarded |
| `PreToolUse`, `PostToolUse` | `tool_start`, `tool_use` | `tool` and `tool_use_id` only (`Bash`, `apply_patch`, `mcp__server__tool`, ...); `apply_patch` is checked against the edit lock. No `path`: Codex's `apply_patch` names no single file. `ok` is `true` unless the response carries one of the failure flags above |
| `PermissionRequest` | `notification` | Marks the pane `waiting`, with the message `Approval requested for <tool>`; the command it asks about is not forwarded. The PostToolUse that follows an approval ends the wait |
| `SubagentStart`, `SubagentStop` | `subagent_start`, `subagent_stop` | The sub-agent's own id and `agent_type`; no `Task` tool is watched for it |
| `Stop`, `Interrupt` | `stop` | An `Interrupt` carries `stop_reason: "interrupted"`. `last_assistant_message` is not forwarded |

The hooks are user-level, so they run in every Codex session on the machine, including ones outside a workspace. The installed command is guarded in the shell: `if [ -n "$TMUX_PANE" ]; then workspace session-event --agent codex; else cat >/dev/null; fi`. A Codex session outside tmux pays one `sh` and one `cat` per hook (a few milliseconds) and never starts Ruby; it gets no edit lock check either. A Codex session in a tmux pane that isn't a workspace's still starts Ruby (a few tenths of a second) and drops the event. `workspace hooks uninstall --agent codex` removes the hooks (see [`hooks`](README.hooks.md)). `SessionEnd` and `Interrupt` hooks get 3 seconds, the most Codex allows; the rest get 10.

`PreCompact` and `PostCompact` are ignored. Codex has no `Notification` event, so a Codex pane is `waiting` only on an approval prompt, not on a question asked in plain text. A `SessionStart` for a bound pane prints the same `additionalContext`, which Codex adds as developer context.

### What is forwarded

Every forwarded event carries the agent's `transcript_path` when the payload has one, and a `UserPromptSubmit` carries the user's `prompt` (cut to 1000 characters). The prompt is forwarded as typed, so anything pasted into it travels to the daemon too. A `Stop` also carries its `stop_reason` when it has a text one (cut to 64 characters); the daemon reports it on a `done` pane. The transcript path and the last prompt are kept in memory only, for the pane labels in `workspace sessions`, and are written nowhere else.

For the [events stream](README.events.md), tool and session events also carry:

| Event | Fields |
|---|---|
| `PreToolUse`, `PostToolUse` | `tool` (the tool's name) and `tool_use_id`, each cut to 64 characters; `path` for a file tool (`Edit`, `Write`, `Read`, `MultiEdit`, `NotebookEdit`, `NotebookRead`): its `file_path` or `notebook_path`, relative to the checkout (the nearest directory at or above the hook's `cwd` that holds `.git`). A file outside the checkout, a path with control characters or one over 1024 characters is left out |
| `PostToolUse` | `ok`: `false` when the tool's response says `is_error: true`, `success: false` or `interrupted: true`, else `true`; `duration_ms` when the payload carries a number for it |
| `PreToolUse` for `Task` | `description` (cut to 120 characters) and `subagent_type` (cut to 64) from the tool's input |
| `SessionStart`, `SessionEnd` | `kind` (`claude`), and `source` or `reason` |

Nothing else is read from a tool's input or response: no command text, file contents, edit text, sub-agent prompt or tool output is forwarded. Text fields have control characters and runs of whitespace replaced by one space.

### Delivery

The send to the daemon is bounded, because it now happens before every tool call: the connection must be taken within 0.2 seconds, and the hook then waits at most 0.3 seconds for the daemon's reply before closing. A line already written stays in the socket's buffer, so a daemon that is busy still reads it when it gets to it; a hung or restarting daemon costs a hook at most about half a second. The edit lock check runs before the send and is not affected by it.

It also appends every `SessionStart` and `SessionEnd` to `ledger.jsonl` in workspace's state directory (`$XDG_STATE_HOME/workspace`, default `~/.local/state/workspace`), mode 0600. Each line is JSON: `at`, `event` (`session_start` or `session_end`), `workspace`, `pane_slot` (`session:window.index`, which survives a tmux restart), `pane_id`, `tmux_server` (the tmux server's process id), `layout` (the tmux layout string of the pane's window), `session_id`, `transcript_path`, `cwd`, and the payload's `source` or `reason`; missing fields are left out. The file is append-only. [`restore`](README.restore.md) reads it to recreate panes and resume their sessions, and [`review`](README.review.md) reads it for a workspace's sessions. It is written before the event goes to the daemon, so a missing daemon doesn't lose it, and a failed write never fails the hook. Outside tmux nothing is recorded.

A `SessionStart` for a pane bound with [`workspace binding`](README.binding.md) also prints the binding's `additionalContext` on stdout, for every `source`, so the agent knows its run, review or play (or plays) again after a restart, `/clear`, resume or compaction. Nothing is printed for an unbound pane, or for a binding made in another tmux session or pane slot. If the binding lists [packs](README.binding.md#packs), they are composed again and printed after the subject, so `/clear` and compaction do not lose them; a pack that can't be read leaves them out and the subject still prints. A lookup that fails prints nothing and never fails the hook.

## Examples

```sh
# As installed by a hook (payload piped in by the coding agent)
echo '{"hook_event_name":"SessionStart","session_id":"abc"}' | workspace session-event

# Force delivery to a specific workspace, bypassing pane detection
echo '{"hook_event_name":"Stop"}' | workspace session-event --workspace my-project

# A Codex approval prompt, as Codex's hook pipes it in
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | workspace session-event --agent=codex
```
