# workspace handoff

Watches a Claude Code or Codex agent's context-window usage and hands off to a fresh conversation before it fills up. Replaces `~/bin/agent-context check|new`.

`check` tells the agent to save its state once usage crosses a threshold; `new` clears the conversation and resumes it (the same flow as `workspace agent-run restart`).

## Usage

```sh
workspace handoff check NAME [--pane PANE] [--threshold PCT] [--context-pct N] [--handoff-doc PATH | --handoff-prompt TEXT] [--json]
workspace handoff new   NAME [--pane PANE] [--handoff-doc PATH | --handoff-prompt TEXT] [--wait] [--json]
```

`NAME` defaults to the workspace detected from the current directory. With neither `--handoff-doc` nor `--handoff-prompt`, both commands use [the default doc](#the-default-doc).

## Options (check)

| Option | Description |
|--------|-------------|
| `--pane PANE` | A tmux pane id (`%19`; `"$TMUX_PANE"` inside the pane, or `pane_id` in `workspace sessions --json`), `window.pane` (`1.0`), or a pane index in window 0; default: the daemon's first Claude Code pane, else its first Codex pane. See [Naming the pane](#naming-the-pane) |
| `--threshold PCT` | Context-usage percent that triggers a handoff, 1-100 (default: `handoff.threshold`, or 11) |
| `--context-pct N` | Skip detection and use this value |
| `--handoff-doc PATH` | Doc the agent updates and resumes from (default: the plan when there is one, else `HANDOFF.md` in the notes directory) |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--json` | Print the result as JSON; errors as `{"schema_version":1,"ok":false,"error":...}` |

## Options (new)

| Option | Description |
|--------|-------------|
| `--pane PANE` | A tmux pane id (`%19`; `"$TMUX_PANE"` inside the pane, or `pane_id` in `workspace sessions --json`), `window.pane` (`1.0`), or a pane index in window 0; default: the daemon's first Claude Code pane, else its first Codex pane. See [Naming the pane](#naming-the-pane) |
| `--handoff-doc PATH` | Doc the agent reads and resumes from (default: the plan when there is one, else `HANDOFF.md` in the notes directory) |
| `--handoff-prompt TEXT` | Prompt sent verbatim instead of a doc |
| `--wait` | Wait for the restart to finish and report how it went. Don't use it from the agent being restarted: it would block the turn the restart waits on |
| `--json` | Print the result as JSON; errors as `{"schema_version":1,"ok":false,"error":...}` |

`--handoff-doc` and `--handoff-prompt` are mutually exclusive.

## The default doc

Given neither `--handoff-doc` nor `--handoff-prompt`, `check` and `new` use the workspace's [plan](README.plan.md) when the file `IMPLEMENTATION_PLAN.md` exists in its [notes directory](README.notes.md) (the one `workspace notes dir` prints), so there is one task list. With no plan file they use `HANDOFF.md` in that directory. `check --json` reports the one chosen as `doc`. `check` makes the directory (and lists it in `info/exclude` when it is inside the checkout) before it sends the save-state prompt, and the `workspace handoff new ... --handoff-doc PATH` command that prompt tells the agent to run names the doc by its full path. If the directory cannot be made, the prompt is still sent with a warning. If the notes directory cannot be worked out at all (for example a `{branch}` rule on a detached HEAD, `notes_dir_unresolved`), `check` falls back to what it did before: the prompt asks the agent to pick a path, and `doc` is `null`. `new` then fails with that error.

An explicit `--handoff-doc PATH` is always used as given, plan or no plan, and `--handoff-prompt` names no doc. When the plan is the doc, `new` also binds the pane to the built-in `implementation-plan` play before it restarts the agent, so the SessionStart hook points the fresh conversation back at the play (see [binding](README.binding.md)). A pane bound to a run or review keeps that binding; a pane bound to another play has that play replaced by this one and keeps its packs. The save-state prompt `check` sends in this case tells the agent to run `workspace handoff new NAME --pane ID` without `--handoff-doc`, so that `new` binds the pane, and to skip `new` when the plan is paused. If the binding cannot be made, `new` prints `Warning: could not bind pane ... to the plan play` and restarts anyway. The `handoff` pack tells an agent that when the plan's `status:` is `paused` it writes the doc and ends its turn without running `handoff new`.

## Naming the pane

Prefer the pane id. An agent handing itself off passes `--pane "$TMUX_PANE"` to both commands: the id names one pane for its whole life, where an index moves when a pane is split or closed. Quote it, since `%` is special in some shells. The command `check` types into the pane names it the same way (`workspace handoff new NAME --pane '%19' ...`).

The pane must belong to `NAME`'s own tmux session. Both commands look the pane up there before anything is typed, and from then on name it by its pane id: `check` types into that id, and `new` sends it to the agent daemon. A pane id from another session fails with `wrong_session`, a pane the session doesn't have with `no_such_pane`, a workspace with no tmux session with `no_session`, and anything that isn't a pane id, `window.pane` or an index with `bad_pane`. Each exits 1 with nothing typed, and with `--json` prints the usual error document with that `code`. The session is matched by its exact name, so a workspace `app` never reaches the panes of `app-ui`.

Without `--pane`, both commands use the first Claude Code pane the daemon lists (the first Codex pane when it lists no Claude Code pane), and check it against the workspace's session the same way. In a workspace with more than one agent pane that may not be the caller's, so pass `--pane`.

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

Every `check --json` document (the three above) also carries `next`, the exit code spelled out so a reader need not keep the table: `"continue"` (exit 0), `"handoff"` (exit 1, for `handoff_sent` and `handoff_send_failed` alike) or `"unknown"` (exit 2); and `doc`, the absolute path of the doc the agent writes and resumes from (`--handoff-doc` expanded, else the default doc), or `null` for `--handoff-prompt` or when the default cannot be worked out. `--json` without `--handoff-doc` reads the notes directory but makes nothing.

## Codex

`check` and `new` work on a pane running Codex as well as Claude Code. A pane running OpenCode or Pi is refused with a usage error that names both agents handoff does restart, and `new` through the daemon fails with `unsupported_agent`.

- **Clearing.** Codex's `/clear` clears the terminal and starts a fresh chat, so `new` types `/clear` into a Codex pane as it does for Claude Code, then types the resume prompt once the clear is confirmed.
- **Reading usage.** Codex has no status line for `workspace statusline` to route. Its input box shows a line such as `72% context left`, so `sessions --json` and `check` scrape that line from the pane and report the percent used (`28`). When the screen holds the text more than once, the last match counts, since the footer is the lowest line. Codex panes need no `context.source` setting for this.
- **Confirming the clear.** A Codex pane has no session id, so `new` counts the clear as done when a reading taken after `/clear` was typed shows less use than before. A pane at 0% used cannot be confirmed that way: `new` then reports `clear_not_confirmed` after the wait and does not type the resume prompt.
- **Other footers.** If your Codex footer reads differently (for example a custom `/statusline`), set `context.patterns` in `~/.config/workspace/config.yml` to a regex with one capture group that captures the percent *used*. A pattern listed there for an agent kind replaces the built-in one for that kind; `context.pattern` remains the fallback in `scrape` mode for a kind with neither:

  ```yaml
  context:
    patterns:
      codex: '(\d+)% used'
  ```
- **Automatic handoff.** The `handoff` pack, `handoff.auto`, `start --handoff` and `launch --handoff` accept a project whose main agent is Codex, and `plan start` sends the plan to a Codex pane when no Claude Code pane is the owner.

The text of the `/clear` and footer reading come from codex-cli 0.162.1's documentation and binary. They have not been checked against a live Codex pane, so the first handoff in a Codex pane is worth watching.

## Delivery

`check` types the save-state prompt directly into the named pane and confirms it landed, the same delivery primitive the agent daemon uses for pipeline stages -- but always at the pane you named (or the daemon's first Claude pane), never a pane the daemon picks for you. `new` hands off to `workspace agent-run restart`'s `/clear` + confirm + resume flow; see [README.agent-run.md](README.agent-run.md).

## Configuration

```sh
workspace config set handoff.threshold 11              # default 11
workspace config set handoff.check_prompt "..."         # overrides the built-in save-state prompt (doc flow)
workspace config set handoff.resume_prompt "..."        # overrides the built-in resume prompt (doc flow)
workspace config set handoff.auto true                  # start/launch send the handoff pack (default false)
```

`handoff.check_prompt` and `handoff.resume_prompt` only override the flow used when a doc is named (by `--handoff-doc` or the default doc); `--handoff-prompt` always sends its text as-is. They may use `%{usage}`/`%{doc}`/`%{new_cmd}` and `%{doc}` respectively. Their built-in text is the schema default: `workspace config show --json` reports it as `default` (and as `effective` while unset), so a reader need not keep its own copy.

## Automatic handoff

`start` and `launch` can make a Claude Code or Codex agent run the check itself. The built-in `handoff` pack (see [`instructions`](README.instructions.md)) tells the agent to run `handoff check --pane "$TMUX_PANE"` after every task, and, on exit 1, to write its state into the doc and run `handoff new` once. The pack passes no threshold and no doc: the command picks both, and the doc is [the plan, or `HANDOFF.md`, in the notes directory](#the-default-doc). The pack is bound to the pane with the others, so it comes back after `/clear` and compaction.

It is off by default. Turn it on for a project with `workspace config set handoff.auto true`, or for one run with `start --handoff` / `launch --handoff`; `--no-handoff` turns it off for one run. `--handoff` cannot be combined with `--no-packs`.

The pack needs Claude Code or Codex. `workspace` reads the project's tmuxinator config for the first pane that runs a known coding agent. It sees through `exec`, `env`, `bundle exec`, `VAR=value` prefixes and paths, but not a wrapper script or an ERB-built command, which count as no agent. For a worktree it reads the parent project's config, not the worktree's own. With `handoff.auto` on and any other agent (OpenCode, Pi, or none), the pack is skipped with a warning and the run goes on: the `packs` row reads `delivered: false, pane: null, reason: "handoff_unsupported_agent"` and `warnings` says why. With `--handoff` the same case is an error, `handoff_unsupported_agent` (`details.kind` is the agent found, or `none`), raised before any worktree, config or window is created.

Run with an explicit `--handoff-doc`, `check` and `new` send and exit exactly as before.

## Examples

```sh
# Check the first Claude pane in "myapp" against the default threshold, with the default doc
workspace handoff check myapp
workspace handoff check myapp --handoff-doc HANDOFF.md

# Check a specific pane against a lower threshold, for scripting
workspace handoff check myapp --pane 2 --threshold 20 --json

# Clear and resume pane 1 directly, without going through check
workspace handoff new myapp --pane 1 --handoff-doc HANDOFF.md

# An agent checking, then handing off, its own pane
workspace handoff check myapp --pane "$TMUX_PANE"
workspace handoff new myapp --pane "$TMUX_PANE"
```
