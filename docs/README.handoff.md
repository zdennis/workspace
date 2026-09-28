# workspace handoff

Watches a coding agent's context-window usage and hands off to a fresh conversation before it fills up. Replaces `~/bin/agent-context check|new`.

`check` tells the agent to save its state once usage crosses a threshold; `new` clears the conversation and resumes it (the same flow as `workspace agent-run restart`).

## Usage

```sh
workspace handoff check NAME [--pane N] [--threshold PCT] [--context-pct N] [--handoff-doc PATH | --handoff-prompt TEXT] [--json]
workspace handoff new   NAME [--pane N] (--handoff-doc PATH | --handoff-prompt TEXT) [--json]
```

`NAME` defaults to the workspace detected from the current directory. `new` requires either `--handoff-doc` or `--handoff-prompt`.

## Options (check)

| Option | Description |
|--------|-------------|
| `--pane N` | Pane index or tmux pane id (e.g. `%19`, from `workspace sessions --json`); default: the daemon's first Claude Code pane |
| `--threshold PCT` | Context-usage percent that triggers a handoff, 1-100 (default: `handoff.threshold`, or 11) |
| `--context-pct N` | Skip detection and use this value |
| `--handoff-doc PATH` | Doc the agent updates and resumes from |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--json` | Print the result as JSON |

## Options (new)

| Option | Description |
|--------|-------------|
| `--pane N` | Pane index or tmux pane id (e.g. `%19`, from `workspace sessions --json`); default: the daemon's first Claude Code pane |
| `--handoff-doc PATH` | Doc the agent reads and resumes from |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--json` | Print the result as JSON |

`--handoff-doc` and `--handoff-prompt` are mutually exclusive. `new` requires one of them; `check` doesn't -- when neither is given, the save-state prompt tells the agent to pick a doc path itself.

## Exit codes (check)

| Code | Meaning |
|------|---------|
| 0 | Under the threshold; nothing was sent |
| 1 | At or over the threshold; the save-state prompt was sent |
| 2 | Context usage can't be determined; nothing was sent (see below) |

Exit 2 is a deliberate departure from this project's usual `--json` error contract (exit 1): "undetermined" is a third outcome, not an error, so a caller can tell it apart from "over threshold" with a plain exit-code check.

## Exit codes (new)

Same as `workspace agent-run restart`: 0 once the restart has started (or, with `--wait`, finished), 1 if it was refused or failed.

## How context usage is read

`check` (and `new`, when `--pane` is omitted) reads the workspace's agent daemon `sessions` snapshot, which already carries each pane's `context_pct`/`context_error` (see [README.sessions.md](README.sessions.md) and [README.statusline.md](README.statusline.md)). Nothing here scrapes the pane itself or guesses a percentage.

If no agent daemon is running for the workspace, or the pane's context usage hasn't been recorded yet, `check` exits 2:

```
workspace: could not determine context usage
  reason: no agent daemon for 'myapp' (start one with: workspace agentd --name myapp)
  Fix: run `workspace doctor --fix` to route Claude's status line through
  workspace, or add manually to ~/.claude/settings.json (or a project's
  .claude/settings.json):
  "statusLine": {"type": "command", "command": "workspace statusline"},
  or set a scrape pattern with `workspace config set context.source scrape` and
  `workspace config set context.pattern '(\d+)% ctx'`, or pass --context-pct N.
```

That fix line packs three independent options together. Pick one:

1. **Route the status line through workspace** (recommended if you already use `workspace statusline`): `workspace doctor --fix`, or add a `statusLine` entry to `~/.claude/settings.json` by hand:
   ```json
   "statusLine": {"type": "command", "command": "workspace statusline"}
   ```
   `workspace doctor` (no `--fix`) reports whether this is already routed correctly.
2. **Scrape the pane's own status line instead**:
   ```sh
   workspace config set context.source scrape
   workspace config set context.pattern '(\d+)% ctx'
   ```

Or skip detection entirely for one call with `--context-pct N`.

With `--json`, the reason and fix go in the JSON object instead of stderr:

```json
{"schema_version": 1, "status": "undetermined", "reason": "...", "fix": "..."}
```

`--context-pct N` skips detection for that call, so you can run a handoff even while detection is broken.

## Delivery

`check` types the save-state prompt directly into the named pane and confirms it landed, the same delivery primitive the agent daemon uses for pipeline stages -- but always at the pane you named (or the daemon's first Claude pane), never a pane the daemon picks for you. `new` hands off to `workspace agent-run restart`'s `/clear` + confirm + resume flow; see [README.agent-run.md](README.agent-run.md).

## Configuration

```sh
workspace config set handoff.threshold 11              # default 11
workspace config set handoff.check_prompt "..."         # overrides the built-in save-state prompt (doc flow)
workspace config set handoff.resume_prompt "..."        # overrides the built-in resume prompt (doc flow)
```

`handoff.check_prompt` and `handoff.resume_prompt` only override the flow used when `--handoff-doc` is given (the common case); `--handoff-prompt` always sends its text as-is. Both may use `%{usage}`/`%{doc}`/`%{new_cmd}` and `%{doc}` respectively, matching the built-in templates.

## Examples

```sh
# Check the first Claude pane in "myapp" against the default threshold
workspace handoff check myapp --handoff-doc HANDOFF.md

# Check a specific pane against a lower threshold, for scripting
workspace handoff check myapp --pane 2 --threshold 20 --json

# Clear and resume pane 1 directly, without going through check
workspace handoff new myapp --pane 1 --handoff-doc HANDOFF.md
```
