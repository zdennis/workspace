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

## Details

Installed as a hook by [`workspace init`](README.init.md); not normally run by hand. `workspace doctor` reports whether hooks are installed for the current project's coding agent.

Reads a coding agent's hook payload from stdin, translates it into workspace's event vocabulary, and forwards it over the target workspace's agent socket to the daemon started by `workspace agentd` (or automatically by `workspace launch`). The workspace is normally resolved from the tmux pane the hook is running in (`TMUX_PANE`); `--workspace` overrides that.

It also keeps [`workspace lock`](README.lock.md)'s idle tracking current: `Stop` marks any lock the calling agent holds as idle, and `UserPromptSubmit` or any `PreToolUse` marks it active again, so a waiter can take over a lock whose agent has been idle for `locks.idle_grace`. Only the calling agent's own hold is changed. When there is no lock store, or no lock anywhere is held from this pane, this costs only file reads across the (few, small) namespace directories under the lock store — no subprocess. Only once a matching hold is found does it resolve which project's namespace it belongs to (shelling out to `git`) to act on it.

It also enforces the `edit` lock: a `PreToolUse` for `Edit`, `Write`, `MultiEdit` or `NotebookEdit` is denied when this namespace's `edit` lock is held by another agent — see [`workspace lock`](README.lock.md#details) for the message and cost. `SessionEnd`, and a `SessionStart` whose `source` is `clear`, release every lock the calling agent holds.

Exits 2, with the deny message on stderr, when an edit is denied. Otherwise always exits 0, whether or not a daemon is listening, so a missing daemon never fails an agent's turn. Currently understands Claude Code's hook events (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `PreToolUse` for every tool — the `Task` tool marks a sub-agent starting; `Edit`/`Write`/`MultiEdit`/`NotebookEdit` are checked against the edit lock — `Notification`, which marks the pane `waiting` in [`workspace sessions`](README.sessions.md) and carries the agent's message (cut to 200 characters), and `PostToolUse`, which ends that wait once a tool runs after a permission prompt). Every event it forwards, except `Notification`, ends a wait (a `PreToolUse` for a tool other than `Task` is not forwarded to the daemon).

Every forwarded event also carries the agent's `transcript_path` when the payload has one, and a `UserPromptSubmit` carries the user's `prompt` (cut to 1000 characters). The prompt is forwarded as typed, so anything pasted into it travels to the daemon too. A `Stop` also carries its `stop_reason` when it has a text one (cut to 64 characters); the daemon reports it on a `done` pane. The daemon does not yet surface either, and keeps neither beyond the event it receives; they are there for labels in `workspace sessions`.

It also appends every `SessionStart` and `SessionEnd` to `ledger.jsonl` in workspace's state directory (`$XDG_STATE_HOME/workspace`, default `~/.local/state/workspace`), mode 0600. Each line is JSON: `at`, `event` (`session_start` or `session_end`), `workspace`, `pane_slot` (`session:window.index`, which survives a tmux restart), `pane_id`, `session_id`, `transcript_path`, `cwd`, and the payload's `source` or `reason`; missing fields are left out. The file is append-only and nothing reads it yet; it exists so a later `restore` can recreate panes and resume sessions. It is written before the event goes to the daemon, so a missing daemon doesn't lose it, and a failed write never fails the hook. Outside tmux nothing is recorded.

## Examples

```sh
# As installed by a hook (payload piped in by the coding agent)
echo '{"hook_event_name":"SessionStart","session_id":"abc"}' | workspace session-event

# Force delivery to a specific workspace, bypassing pane detection
echo '{"hook_event_name":"Stop"}' | workspace session-event --workspace my-project
```
