# workspace handoff

Watches a Claude Code or Codex agent's context-window usage and hands off to a fresh conversation before it fills up. Replaces `~/bin/agent-context check|new`.

`check` tells the agent to save its state once usage crosses a threshold; `new` clears the conversation and resumes it (the same flow as `workspace agent-run restart`).

## Usage

```sh
workspace handoff check [NAME | --name WS] [--pane PANE] [--threshold PCT] [--context-pct N] [--handoff-doc PATH | --handoff-prompt TEXT] [--json]
workspace handoff new   [NAME | --name WS] [--pane PANE] [--handoff-doc PATH | --handoff-prompt TEXT] [--wait] [--json]
```

`NAME` (or `--name WS`) defaults to the workspace detected from the current directory; giving both with different names is a usage error. With neither `--handoff-doc` nor `--handoff-prompt`, both commands use [the default doc](#the-default-doc).

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

## Waiting for the restart

Capability `handoff_wait` (level 1). Without `--wait`, `new` returns once the agent daemon has accepted the restart; a later failure goes only to the daemon's stderr. With `--wait`, the daemon holds the connection until the restart ends and `new` prints the outcome. With `--wait --json`, stdout is one document:

- Success (exit 0): `{"schema_version":1,"ok":true,"pane":...,"pane_id":"%19","context_before":N,"context_after":N|null,"status":"restarted","delivery":"landed"|...}`, plus `warning` when the delivery has one. `status: "restarted"` means `/clear` was confirmed and the resume prompt was typed.
- Refusal or failure (exit 1): `{"schema_version":1,"ok":false,"error":"<message>","code":"<code>"}`, plus `pane` and `pane_id` once the daemon accepted the restart, and `context_before` once the context was read (so never with `pane_busy`). The list of `code` values is not exhaustive; branch on the ones you know and treat the rest as a failure. Before the restart starts: `no_daemon`, `connection_failed`, `unreadable_reply`, `bad_pane`, `no_such_pane`, `unsupported_agent`, `context_unknown`, and errors resolving the default pane or doc (a plain error document, no `pane`). While waiting: `pane_busy`, `clear_not_confirmed`, `pane_gone`, `pane_in_pipeline`, `not_delivered`, `context_unknown`, `agent_stopped` (the daemon shut down mid-restart), `internal_error`.

Waiting has two bounds, and each timeout has its own `code`, so it is not mistaken for another failure:

- `pane_busy`: the pane did not go quiet (screen unchanged for 2s and the agent neither working nor waiting on a person) within 120s, or Claude Code's input box holds a draft (`reason` `input_not_empty`) or shows a running turn (`turn_started`). Nothing was typed, and a draft stays where it is. A screen that keeps moving after the agent went idle is accepted once the main agent's `Stop`, the transcript and the screen all show the turn is over for 5s; the reply then has a `warning` that background work may be lost. A `warning` that a sub-agent was still running when `/clear` was typed comes for a Claude Code pane whose hooks showed a sub-agent started and not ended, even with the main turn over; a background shell is not detected. Without `--wait` a refusal shows only in the daemon's log, so a script that needs to know uses `--wait`. See [`agent-run restart`](README.agent-run.md#restart-subcommand).
- `clear_not_confirmed`: `/clear` was typed but neither a reading from a new conversation nor a SessionStart hook event with source `clear` arrived within 30s. The resume prompt was not typed, and the pane may be cleared.

Neither bound is configurable from `handoff new`: the 120s is fixed, and `handoff new` sends no timeout, so the 30s default applies (`agent-run restart --timeout` can change only that second bound, up to 600s). The client has no deadline of its own, so the worst case is about 150s plus the delivery. Do not run `--wait` from the agent being restarted.

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
   The last match on the screen counts, since the status line is the pane's lowest line; a percentage in the agent's output above it is never read as context use.

Or skip detection entirely for one call with `--context-pct N`.

That fix line is the one for a pane whose kind workspace doesn't know, and for Claude Code. A pane whose kind workspace reads by scraping the pane itself (Codex) gets that agent's fix instead — Codex has no `statusLine` to route, and `context.pattern` is not consulted for a kind-detected pane, so the fix is the `context.patterns` mapping in `~/.config/workspace/config.yml` (see [Codex](#codex)).

With `--json`, the reason and fix go in the JSON object instead of stderr:

```json
{"schema_version": 1, "status": "undetermined", "reason": "...", "fix": "..."}
```

`--context-pct N` skips detection for that call, so you can run a handoff even while detection is broken.

The other two outcomes print `status` (`ok`, or `handoff_sent` / `handoff_send_failed`), `context_pct`, `threshold`, `pane` (the pane's index in its window) and `pane_id` (its tmux pane id, e.g. `%19`, which a later `--pane` accepts). At or over the threshold they add `delivery` and `landed`. When the prompt landed, `handoff_sent` also carries [`followup`](#follow-ups).

Every `check --json` document (the three above) also carries `next`, the exit code spelled out so a reader need not keep the table: `"continue"` (exit 0), `"handoff"` (exit 1, for `handoff_sent` and `handoff_send_failed` alike) or `"unknown"` (exit 2); and `doc`, the absolute path of the doc the agent writes and resumes from (`--handoff-doc` expanded, else the default doc), or `null` for `--handoff-prompt` or when the default cannot be worked out. `--json` without `--handoff-doc` reads the notes directory but makes nothing.

## Codex

`check` and `new` work on a pane running Codex as well as Claude Code. A pane running OpenCode or Pi is refused with a usage error that names both agents handoff does restart, and `new` through the daemon fails with `unsupported_agent`.

- **Clearing.** Codex's `/clear` clears the terminal and starts a fresh chat, so `new` types `/clear` into a Codex pane as it does for Claude Code, then types the resume prompt once the clear is confirmed.
- **Reading usage.** Codex has no status line for `workspace statusline` to route. Its status footer shows a line such as `Context 72% used · Context 28% left`, so `sessions --json` and `check` scrape the "used" half of that line from the pane and report the percent used (`72`). When the screen holds the text more than once, the last match counts, since the footer is the lowest line. Codex panes need no `context.source` setting for this.
- **Confirming the clear.** A SessionStart with source `clear` from the pane's hooks, recorded after `/clear` was typed, confirms it for any agent that sends hooks. A Codex pane has no session id, so `new` counts the clear as done when a reading taken after `/clear` was typed shows less use than before. A pane at 0% used cannot be confirmed that way: `new` then reports `clear_not_confirmed` after the wait and does not type the resume prompt.
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
workspace config set handoff.followup_interval 30s      # quiet time before a follow-up (default 30)
workspace config set handoff.followup_max 10            # follow-ups per handoff; 0 turns them off (default 10)
workspace config set handoff.followup_prompt "..."      # overrides the built-in follow-up prompt
```

`handoff.check_prompt` and `handoff.resume_prompt` only override the flow used when a doc is named (by `--handoff-doc` or the default doc); `--handoff-prompt` always sends its text as-is. They may use `%{usage}`/`%{doc}`/`%{new_cmd}` and `%{doc}` respectively. Their built-in text is the schema default: `workspace config show --json` reports it as `default` (and as `effective` while unset), so a reader need not keep its own copy.

The three `handoff.followup_*` keys are described under [Follow-ups](#follow-ups). `handoff.followup_prompt` has one placeholder, `%{new_cmd}`, the `handoff new` command the save-state prompt named, and it must not be blank. A template that uses another placeholder prints a warning and the built-in text is sent instead.

## Automatic handoff

`start` and `launch` can make a Claude Code or Codex agent run the check itself. The built-in `handoff` pack (see [`instructions`](README.instructions.md)) tells the agent to run `handoff check --pane "$TMUX_PANE"` after every task, and, on exit 1, to write its state into the doc and run `handoff new` once. The pack passes no threshold and no doc: the command picks both, and the doc is [the plan, or `HANDOFF.md`, in the notes directory](#the-default-doc). The pack is bound to the pane with the others, so it comes back after `/clear` and compaction.

It is off by default. Turn it on for a project with `workspace config set handoff.auto true`, or for one run with `start --handoff` / `launch --handoff`; `--no-handoff` turns it off for one run. `--handoff` cannot be combined with `--no-packs`.

The pack needs Claude Code or Codex. `workspace` reads the project's tmuxinator config for the first pane that runs a known coding agent. It sees through `exec`, `env`, `bundle exec`, `VAR=value` prefixes and paths, but not a wrapper script or an ERB-built command, which count as no agent. For a worktree it reads the parent project's config, not the worktree's own. With `handoff.auto` on and any other agent (OpenCode, Pi, or none), the pack is skipped with a warning and the run goes on: the `packs` row reads `delivered: false, pane: null, reason: "handoff_unsupported_agent"` and `warnings` says why. With `--handoff` the same case is an error, `handoff_unsupported_agent` (`details.kind` is the agent found, or `none`), raised before any worktree, config or window is created.

Run with an explicit `--handoff-doc`, `check` and `new` send and exit exactly as before.

## Follow-ups

An agent can read the save-state prompt and never run `handoff new`: it answers, or goes quiet, and the pane sits at a context limit with no handoff. When `check` lands its prompt, it asks the pane's agent daemon to watch the pane. While the pane stays quiet, the agent daemon (not a person) types a short follow-up into it that opens with "Are you handing off to a fresh conversation?" and asks whether the agent is handing off, gives the `handoff new` command to run once its state is saved, and says to do nothing if it already ran it, or to say why and stop if it was refused.

**What a watch needs.** Only a Claude Code pane in hook mode is watched, because the follow-up is typed through Claude Code's ready prompt and the daemon needs the prompt text that only Claude Code's hooks forward. Only panes in window 0 can be watched, since that is the only window the daemon scans. A pane bound to a run or review gets none: [`binding.md`](README.binding.md) tells those agents not to run `handoff new` unless their instructions say so. A pane bound to a play is watched, including one other than the plan play, so a play pane that was told not to hand off can still get follow-ups, up to the cap. A pane with a pipeline stage running on it is refused. One watch is open per pane; running `check` again in a watched pane adds to it and does not reset its tries or its hour.

**When a follow-up is typed.** The pane must be quiet for `handoff.followup_interval` (default 30 seconds): no tool call or sub-agent running, no screen change, and no earlier follow-up, restart, API-error recovery hold or save-state prompt within that time. The daemon looks every 5 seconds, so a follow-up can come up to 5 seconds late. Activity does not end the watch; it pushes the next follow-up back, and follow-ups start again if the pane goes quiet with no handoff. A try is any attempt to type a follow-up, whatever its `outcome` (see below); a pane found gone ends the watch (`pane_gone`) and is not a try. After `handoff.followup_max` tries (default 10, about five minutes at the default interval) the next quiet interval ends the watch `stalled`. `0` turns follow-ups off.

**Stopping follow-ups.** To end the open watch, type any prompt of your own in the pane (`other_prompt`), run `/clear` (`carried_out`), or pause the plan (`plan_paused`). To stop them for future handoffs, run `workspace config set handoff.followup_max 0`; that does not close a watch already open.

**How it ends.** A watch records `handoff_watch_ended` with one of these `reason` values:

| `reason` | What happened |
|----------|---------------|
| `carried_out` | A `/clear` started a new conversation in the pane. This is any `/clear`, so a person's own `/clear` or an `agent-run restart` reads the same as a handoff |
| `other_prompt` | A prompt arrived that is neither the save-state prompt nor a follow-up, from a person or from `agent-run send` or a status request: something else is driving the pane. Claude Code reports a multi-line paste inside `pasted_content` tags, and the tags are removed before the comparison, so a person's own paste counts. A pasted-text placeholder or a prompt with no text can't be told from ours and does not count |
| `session_changed` | The pane's conversation changed without a `/clear`, for example a compaction, which starts a new session, or a resume. A lost SessionStart ends the watch this way too, so a follow-up can't land in a new conversation |
| `session_ended` | The agent's session ended other than by `/clear` |
| `pane_gone` | The pane closed or was replaced, or its agent process changed and stayed changed for 30 seconds |
| `plan_paused` | The workspace's `IMPLEMENTATION_PLAN.md` says `status: paused`, checked at every look. It applies to any plan, even when the handoff doc is not the plan, and to one paused before the watch started |
| `not_submitted` | A follow-up was pasted but Enter was not confirmed, so the text may be stuck in the input line. This also sends the stall alert |
| `stalled` | The tries reached `handoff.followup_max` and the pane went quiet again. Sends the stall alert |
| `expired` | An hour passed since the watch's first arm. Sends the stall alert |

**Events and the alert.** The daemon writes `handoff_watch_started`, one `handoff_followup` per try and `handoff_watch_ended` to the [event log](README.events.md#handoff-follow-up-lines). `handoff_followup` has `attempt` (from 1) and `outcome`: `submitted`, `not_submitted`, `refused` (the pane could not take text, for example a prompt waiting for the person), `not_landed` or `failed` (the paste never reached the pane), or `raised` (the typing itself raised an error). A follow-up that is held back at the last moment because the pane became busy is not a try and writes nothing. A `stalled`, `expired` or `not_submitted` ending also runs `alerts.notify` with `WORKSPACE_ALERT` set to `handoff_stalled` (see [sessions](README.sessions.md#alerts)). So does a `not_submitted` outcome on a watch that closed during the paste, since the text is still in the pane; that watch's ending stays what closed it. Without `alerts.notify` the `handoff_watch_ended` event is the only record.

**In `check --json`.** `handoff_sent` documents carry `followup`: `{"watching": true, "reason": null}` when the watch is open, else `{"watching": false, "reason": ...}`. `handoff_send_failed` documents have no `followup`, because no watch is asked for. The text output adds a line when it is open. A failure here never changes the exit code or the other fields. `reason` is one of these, from `check`:

| `reason` | Meaning |
|----------|---------|
| `disabled` | `handoff.followup_max` is `0` |
| `bound_pane` | The pane is bound to a run or review |
| `text_too_long` | The follow-up or save-state text is over 4,000 characters |
| `no_daemon` | No agent daemon answered on its socket (a warning is printed) |
| `no_reply` | The daemon gave no reply within 2 seconds (a warning is printed) |
| `bad_reply` | The reply was not a JSON object |
| `unsupported_daemon` | The daemon is older and does not know `handoff_watch`; `workspace agentd restart NAME` replaces it |
| `error` | `check` hit an error making the request (a warning is printed) |

or passed through from the daemon: `not_scanned` (not in window 0, or not scanned yet), `not_claude`, `no_hooks`, `invalid` (a setting the daemon refused), `usage`, `pipeline_stage`, `internal_error` (the daemon refused the request), `refused` (a refusal with no code), or `unknown` (an answer with no reason).

**Limits.**

- `check` waits at most 2 seconds for the daemon's reply, since it runs inside the agent's turn. When it times out it reports `watching: false` with `no_reply`, but the daemon may still have started the watch.
- Watches live in the daemon's memory. A daemon restart drops them, and that handoff gets no more follow-ups.
- If `agentd.poll_interval` is near or above `handoff.followup_interval`, the daemon sees activity late, and a follow-up can land on a pane that is already working.
- A status line with a clock or other timer that redraws counts as activity. The pane then never looks quiet, no follow-up is typed, and the watch ends `expired` after the hour.

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
