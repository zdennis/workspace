# workspace handoff

Watches a coding agent's context-window usage and hands off to a fresh conversation before it fills up. Replaces `~/bin/agent-context check|new`.

`check` tells the agent to save its state once usage crosses a threshold; `new` clears the conversation and resumes it (the same flow as `workspace agent-run restart`).

## Usage

```sh
workspace handoff check NAME [--pane PANE] [--threshold PCT] [--context-pct N] [--handoff-doc PATH | --handoff-prompt TEXT] [--json]
workspace handoff new   NAME [--pane PANE] (--handoff-doc PATH | --handoff-prompt TEXT) [--wait] [--json]
```

`NAME` defaults to the workspace detected from the current directory. `new` requires either `--handoff-doc` or `--handoff-prompt`.

## Options (check)

| Option | Description |
|--------|-------------|
| `--pane PANE` | A tmux pane id (`%19`; `"$TMUX_PANE"` inside the pane, or `pane_id` in `workspace sessions --json`), `window.pane` (`1.0`), or a pane index in window 0; default: the daemon's first Claude Code pane. See [Naming the pane](#naming-the-pane) |
| `--threshold PCT` | Context-usage percent that triggers a handoff, 1-100 (default: `handoff.threshold`, or 11) |
| `--context-pct N` | Skip detection and use this value |
| `--handoff-doc PATH` | Doc the agent updates and resumes from |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--json` | Print the result as JSON; errors as `{"schema_version":1,"ok":false,"error":...}` |

## Options (new)

| Option | Description |
|--------|-------------|
| `--pane PANE` | A tmux pane id (`%19`; `"$TMUX_PANE"` inside the pane, or `pane_id` in `workspace sessions --json`), `window.pane` (`1.0`), or a pane index in window 0; default: the daemon's first Claude Code pane. See [Naming the pane](#naming-the-pane) |
| `--handoff-doc PATH` | Doc the agent reads and resumes from |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--wait` | Wait for the restart to finish and report how it went. Don't use it from the agent being restarted: it would block the turn the restart waits on |
| `--json` | Print the result as JSON; errors as `{"schema_version":1,"ok":false,"error":...}` |

`--handoff-doc` and `--handoff-prompt` are mutually exclusive. `new` requires one of them; `check` doesn't -- when neither is given, the save-state prompt tells the agent to pick a doc path itself.

## Naming the pane

Prefer the pane id. An agent handing itself off passes `--pane "$TMUX_PANE"` to both commands: the id names one pane for its whole life, where an index moves when a pane is split or closed. Quote it, since `%` is special in some shells. The command `check` types into the pane names it the same way (`workspace handoff new NAME --pane '%19' ...`).

The pane must belong to `NAME`'s own tmux session. Both commands look the pane up there before anything is typed, and from then on name it by its pane id: `check` types into that id, and `new` sends it to the agent daemon. A pane id from another session fails with `wrong_session`, a pane the session doesn't have with `no_such_pane`, a workspace with no tmux session with `no_session`, and anything that isn't a pane id, `window.pane` or an index with `bad_pane`. Each exits 1 with nothing typed, and with `--json` prints the usual error document with that `code`. The session is matched by its exact name, so a workspace `app` never reaches the panes of `app-ui`.

Without `--pane`, both commands use the first Claude Code pane the daemon lists, and check it against the workspace's session the same way. In a workspace with more than one Claude Code pane that may not be the caller's, so pass `--pane`.

An agent daemon started by an older version of workspace can be listing another session's panes. `check` then exits 2 with the reason `the agent daemon for 'NAME' doesn't list pane %19 ...` and the restart command as the fix, or fails with `wrong_session` when `--pane` was left out, and `new` fails with the daemon's `no_such_pane`. `workspace agentd restart NAME` replaces the daemon.

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

The other two outcomes print `status` (`ok`, or `handoff_sent` / `handoff_send_failed`), `context_pct`, `threshold`, `pane` (the pane's index in its window) and `pane_id` (its tmux pane id, e.g. `%19`, which a later `--pane` accepts). At or over the threshold they add `delivery` and `landed`.

## Delivery

`check` types the save-state prompt directly into the named pane and confirms it landed, the same delivery primitive the agent daemon uses for pipeline stages -- but always at the pane you named (or the daemon's first Claude pane), never a pane the daemon picks for you. `new` hands off to `workspace agent-run restart`'s `/clear` + confirm + resume flow; see [README.agent-run.md](README.agent-run.md).

## Configuration

```sh
workspace config set handoff.threshold 11              # default 11
workspace config set handoff.check_prompt "..."         # overrides the built-in save-state prompt (doc flow)
workspace config set handoff.resume_prompt "..."        # overrides the built-in resume prompt (doc flow)
workspace config set handoff.auto true                  # start/launch send the handoff pack (default false)
```

`handoff.check_prompt` and `handoff.resume_prompt` only override the flow used when `--handoff-doc` is given (the common case); `--handoff-prompt` always sends its text as-is. Both may use `%{usage}`/`%{doc}`/`%{new_cmd}` and `%{doc}` respectively, matching the built-in templates.

## Automatic handoff

`start` and `launch` can make a Claude Code agent run the check itself. The built-in `handoff` pack (see [`instructions`](README.instructions.md)) tells the agent to run `handoff check --pane "$TMUX_PANE"` after every task, and, on exit 1, to write its state into the doc and run `handoff new` once. The doc is `IMPLEMENTATION_PLAN.md` in the workspace's [notes directory](README.notes.md) when that file exists, otherwise `HANDOFF.md` there. The pack is bound to the pane with the others, so it comes back after `/clear` and compaction.

It is off by default. Turn it on for a project with `workspace config set handoff.auto true`, or for one run with `start --handoff` / `launch --handoff`; `--no-handoff` turns it off for one run. `--handoff` cannot be combined with `--no-packs`.

The pack needs Claude Code. `workspace` reads the project's tmuxinator config for the first pane that runs a known coding agent. It sees through `exec`, `env`, `bundle exec`, `VAR=value` prefixes and paths, but not a wrapper script or an ERB-built command, which count as no agent. For a worktree it reads the parent project's config, not the worktree's own. With `handoff.auto` on and any other agent (or none), the pack is skipped with a warning and the run goes on: the `packs` row reads `delivered: false, pane: null, reason: "handoff_unsupported_agent"` and `warnings` says why. With `--handoff` the same case is an error, `handoff_unsupported_agent` (`details.kind` is the agent found, or `none`), raised before any worktree, config or window is created.

Nothing here changes `handoff check` or `handoff new` themselves, or what they send.

## Examples

```sh
# Check the first Claude pane in "myapp" against the default threshold
workspace handoff check myapp --handoff-doc HANDOFF.md

# Check a specific pane against a lower threshold, for scripting
workspace handoff check myapp --pane 2 --threshold 20 --json

# Clear and resume pane 1 directly, without going through check
workspace handoff new myapp --pane 1 --handoff-doc HANDOFF.md

# An agent checking, then handing off, its own pane
workspace handoff check myapp --pane "$TMUX_PANE" --handoff-doc HANDOFF.md
workspace handoff new myapp --pane "$TMUX_PANE" --handoff-doc HANDOFF.md
```
