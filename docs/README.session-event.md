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

Reads a coding agent's hook payload from stdin, translates it into workspace's event vocabulary, and forwards it over the target workspace's agent socket to the daemon started by `workspace agent` (or automatically by `workspace launch`). The workspace is normally resolved from the tmux pane the hook is running in (`TMUX_PANE`); `--workspace` overrides that.

Always exits 0, whether or not a daemon is listening, so a missing daemon never fails an agent's turn. Currently understands Claude Code's hook events (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `SubagentStop`, and `PreToolUse` for the `Task` tool, which marks a sub-agent starting).

## Examples

```sh
# As installed by a hook (payload piped in by the coding agent)
echo '{"hook_event_name":"SessionStart","session_id":"abc"}' | workspace session-event

# Force delivery to a specific workspace, bypassing pane detection
echo '{"hook_event_name":"Stop"}' | workspace session-event --workspace my-project
```
