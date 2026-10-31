# workspace agentd

Run the long-lived agent for a project. The agent registers with work-coordinator, binds its own Unix socket, and drives the project's pipeline panes until it is terminated. This used to be `workspace agent`; that command is now the umbrella for driving an agent — see [README.agent.md](README.agent.md).

## Usage

```sh
workspace agentd [PROJECT] [options]
workspace agentd restart [PROJECT] [--wc-socket PATH] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `PROJECT` | Workspace name (defaults to the project detected from the current directory) |
| `--name NAME` | Same as the positional PROJECT argument |
| `--wc-socket PATH` | Override the path to the work-coordinator socket |
| `-f`, `--force` | Terminate a running agent for this workspace and take its place |
| `--ensure` | Start the agent in the background unless one is already answering, then return. Can't be combined with `--force` |
| `restart` | Subcommand: stop the running agent and start a new one in the background (see [restart](#restart)) |

## restart

```sh
workspace agentd restart [PROJECT] [--name NAME] [--wc-socket PATH] [--json]
```

`agentd restart` stops the agent running for the workspace and starts a new one in the background. It is the same command as [`workspace daemon restart`](README.daemon.md#restart) under the name people look for, and that page has the details: which process is stopped and when nothing is, the `--json` action document (`restarted` with `old_pid`, or `started` when none was running), and the failure reasons.

It differs from `--force` in one way: it does not hold the terminal. `--force` replaces the running agent with one that runs in your terminal until you stop it; `restart` starts the new agent detached, the way `--ensure` does, with its output in the daemon log (`workspace daemon log`), and returns.

The new agent keeps the work-coordinator socket the old one was started with. `--wc-socket PATH` gives it another; a relative path is made absolute from the current directory.

`restart` is the subcommand only as the first word that isn't an option. A workspace that is itself named `restart` is reached with `--name`: `workspace agentd --name restart` runs its agent, and `workspace agentd restart --name restart` or `workspace agentd restart restart` restarts it.

`restart` takes neither `--force` nor `--ensure`. With either one the word is a workspace name, as it was before the subcommand existed: `workspace agentd --ensure restart` and `workspace agentd -f restart` start the agent for a workspace named `restart`.

## Details

The workspace must have a config: a name is matched to existing configs ignoring case, and one that matches none is refused with `unknown_workspace`, for `agentd`, `agentd --ensure` and `agentd restart`.

### Renaming a mixed-case workspace

Workspace names are lowercase. A workspace written earlier with a mixed-case name (`Notes`) is renamed to lowercase (`notes`) when its agent starts, before the agent binds its socket, while no agent runs for it and the startup lock is held (`agentd --ensure` and `agentd restart` hold it from before the start; a foreground `agentd` takes it if it is free, and leaves the rename to whoever holds it). `launch` does the same before it starts the session, so the session starts under the name it keeps. Renamed:

- the tmuxinator config `workspace.<name>.yml`, and inside it the `name:` line, the `tmux ... -t <session>:` targets and the `workspace-<session>` window (the `root:` line keeps its case)
- the live tmux session, with `tmux rename-session` (pane ids don't change)
- `~/.config/workspace/projects/<name>.yml`
- the agent's `.sock`, `.log` and `.lock` files in `~/.local/workspace/run/`
- the state directory `~/.local/state/workspace/<name>/`
- the workspace's inbox file, and the project's inbox file when this workspace names the project
- the workspace's key in `~/.workspace-state.json`
- the `.workspace-project` marker in a worktree's checkout

A project's worktree workspaces (`<project>.worktree-<dir>`) are renamed with it, each with its own session. A worktree whose agent is running or starting is left alone, with a warning, and is renamed when its agent next starts.

The config is renamed last, and only when every other step went through, so once it is lowercase the rename is done and later starts do nothing. A step that fails, or whose lowercase name is already taken, is left as it was with a `Warning:` line in the daemon log (and on stderr from `launch` or a foreground `agentd`); the config keeps its mixed-case name so the next start tries again, and the agent starts under the lowercase name anyway. Each renamed workspace writes a `workspace_renamed` event-log line (see [the event log](README.event-log.md)). macOS file systems ignore case, so the names are compared from directory listings, and a rename that changes only case goes through a temporary name.

To check on or read the log of a running agent without holding a terminal, use [`workspace daemon`](README.daemon.md).

**`--ensure`** — makes sure the workspace has an agent without taking the terminal: if one answers on the socket it prints `agentd for <name> is already running` and exits 0; otherwise it starts one detached (output in the daemon log, `~/.local/workspace/run/workspace-<name>.log`), waits up to 5 seconds for it to answer, prints `Started agentd for <name>` and exits 0. A leftover socket file from a dead agent doesn't count as running. Concurrent calls, including `workspace launch` starting the same workspace, are serialized on `workspace-<name>.lock` in that directory, so they never start two agents. It exits 1 with the reason when the agent can't be started or doesn't answer in time, or when the project's pipeline config is invalid. `workspace launch` runs the same check for each project it launches; a failure there is a warning and the launch carries on. `--wc-socket` is passed through to a newly started agent. Only `--ensure` callers take the lock: a plain `workspace agentd` started by hand at the same instant can still race one.

**One agent per workspace** — on startup the agent probes its own socket at `~/.local/workspace/run/workspace-<name>.sock`. With a very long workspace name the filename is truncated with a short hash suffix (derived deterministically from the name) so the path stays within a 100-byte cap (headroom under the OS's 104-byte socket path limit); the daemon log filename is truncated the same way, against a 250-byte cap (headroom under the 255-byte per-component limit). If something answers, it refuses to start rather than stealing the socket from a running agent. A socket left behind by an unclean shutdown does not answer, so it is removed and the agent starts normally.

`--force` turns that refusal into a handover: the agent finds the process holding the socket with `lsof`, sends it `SIGTERM`, and waits up to 5 seconds for it to exit before binding the socket itself. In-flight state is already on disk, so the replacement picks the pipeline back up as it would after any other restart.

**Workflow runs** — when the main agent's turn ends in a pane bound to a [workflow run](README.workflow.md) (a `Stop` hook event with no sub-agent id), the daemon starts `workspace workflow advance RUN --turn-ended --pane ID [--turn-started AT] [--background-task TYPE:ID]...` as its own process, which decides the run's step. Each `--background-task` is a task the Stop input listed as still going (Claude Code 2.1.145 and later); the flag is internal, passed only by the daemon. `AT` is when the pane's last prompt was submitted, when this daemon saw it; the run ignores the end of a turn that began before its step did. Every 15 seconds it starts `workspace workflow advance RUN` for each of the workspace's runs that waits for a lock, whose check never reported back, or whose background hold ran out. Those processes write to the daemon's log. A workflow needs the daemon: without one, a run only moves on `workflow resume`.

**Hook events** — each hook event [`session-event`](README.session-event.md) forwards is also written, as typed lines (`tool_started`, `tool_finished`, `subagent_started`, `subagent_stopped`, `session_started`, `session_ended`, `prompt_submitted`), to the daemon's own file `~/.local/state/workspace/.events/<name>.jsonl`, with the daemon's `boot_id` and a `seq` that starts at 1 for each boot. The file rotates to `<name>.jsonl.1` past 5MB. [`workspace events`](README.events.md) reads every daemon's file together with the event log; the event log itself never gets these lines.

**Scan concurrency** — each agent's session monitor polls its tmux session on its configured interval, spawning a handful of processes per poll (`tmux list-panes`, a `ps` snapshot, one `tmux capture-pane` per pane). `WORKSPACE_SCAN_CONCURRENCY` bounds how many agents' monitors may scan at once, machine-wide (default `1`, capped at `64`), shared through slot files under `~/.local/state/workspace/scan-slots`. A monitor that can't take a slot skips that tick; it never waits. Values that are not a positive integer fall back to the default. The limit is read when the monitor is built, so changing it takes a daemon restart; under contention a monitor's effective interval averages out longer, roughly `interval × daemons ÷ limit`. Scrape-mode context reads share the same slot pool: each `sessions` request takes one slot per pane capture, and a read that can't take one falls back to that pane's last successful reading while it is no more than 30 seconds old, reporting the pane's usage as undetermined (`couldn't scrape the pane (every scan slot busy) and no fresh reading is cached`) past that.

**Pipeline** (deprecated, see [`pipeline`](README.pipeline.md)) — a project's stages come from `pipeline.panes` in `~/.config/workspace/projects/<name>.yml`. Each entry's position is its pane index:

```yaml
pipeline:
  panes:
    - role: researcher
      timeout: 30m
    - role: implementer
    - role: reviewer
      timeout: 15m
  handoff: file_handoff
```

A command from the coordinator is typed into the first stage's pane, followed by a line telling the stage how to signal it is done: `When you are done, print a single line: WORKSPACE_DONE:<token> <one-line summary>`. Every later stage gets the same line. The token is random and new for each stage, and only a line that starts with `WORKSPACE_DONE:<token>` ends that stage, so a test that prints `WORKSPACE_DONE:`, or an earlier stage's sentinel sitting in the scrollback, does not. The agent matches the token anywhere in the pane's history, so a full scrollback does not hide it.

When the stage prints its sentinel, the agent captures that pane's output to a handoff file under `~/.config/workspace/handoffs/`, points the next stage at it, and moves on. The last stage finishing reports the work item complete.

**Stage timeouts** — `timeout:` on a stage (`90`, `90s`, `30m`, `2h`) is how long that stage gets to print its sentinel. A stage still running at its deadline fails the work item: the agent prints `workspace agent: <REF> failed at pane N: timed out: …` on stderr, reports an `error` to the coordinator, and drops the item from its pipeline state. No further stage starts. A stage without `timeout:` waits as long as it takes. A `timeout:` that is not a positive duration stops the agent at startup with an error naming the stage.

**Restarts** — the token and deadline of each stage in flight are saved in the pipeline state file, so a restarted agent watches for the same token and keeps the same deadline. A stage that printed its sentinel while the agent was down advances as soon as the agent is back. State written by an older agent has no token; for those items the agent accepts any `WORKSPACE_DONE:` line printed after it restarts, as it did before tokens existed, and they have no deadline.

A project with no `pipeline` block still works: commands go to the Claude Code pane (detected by pane title, falling back to pane 1 if detection fails) and nothing is tracked.

**Steering** — an `inject` message queues a note for the next stage without disturbing the running one. With `interrupt: true` it sends `C-c` to the running stage's pane first and types the note in immediately.

A queued steer is delivered when the next stage hands off. If that delivery doesn't land cleanly, the agent reports it to the coordinator rather than silently dropping it: an `error` ("queued steer for pane N was not delivered: …") if it never arrived, or a `status_update` ("Warning: queued steer for pane N: …") if it may have.

**Delivery checks** — text is pasted into a pane in one piece and Enter is pressed once the pane stops changing. The agent reads the pane back to check each step. If the screen never changes after the paste, the text did not arrive. For a command, the agent then prints `workspace agent: command for <REF> was not delivered …` on stderr, reports an `error` to the coordinator, answers `not_delivered`, and does not start the pipeline. For a hand-off, the work item fails the same way a timed-out stage does. If the text arrived but Enter didn't change the screen, even on a second press, the stage still starts, with a `Warning:` status update, because sending the text again would type it twice.

A paste counts as having landed once the pane's screen shows the last 16 non-blank characters of the pasted text, or Claude Code's `[Pasted text #N` placeholder for a large paste.

**Unverified deliveries** — sometimes the agent can't tell whether the text arrived at all: the screen kept changing (so it never settled enough to compare) or it couldn't be read back. That outcome is "unverified" — it may or may not have landed, and, exactly like a text-landed-but-not-submitted delivery, it is never resent, since resending could type it twice. A command in this state starts the stage with a `Warning:` status update. An urgent steer in this state answers `not_submitted` (see below). A prompt sent by `launch --prompt` fails with a message ending "...it may not have arrived" (see [README.launch.md](README.launch.md)).

### Recovering from an API error

When a Claude Code turn ends on an API error, the agent daemon gets the agent going again. Claude Code reports the error through its `StopFailure` hook, which [`session-event`](README.session-event.md) forwards as `turn_failed` with the error's kind (`server_error`, `overloaded`, `rate_limit`, `unknown`, `authentication_failed`, ...). A sub-agent's failure is not the main agent's and is ignored. The hook is installed by `workspace init`, `start` and `doctor --fix`; a project whose hooks were installed earlier doesn't have it until one of those runs again.

**When it acts.** Only for the kinds `server_error`, `overloaded`, `rate_limit` and `unknown`. Any other kind, such as a bad credential, gets one [inbox](README.inbox.md) item at once (`not_retryable`) and nothing is stopped or typed. The daemon waits 30 seconds after the failure, then reads the session's transcript and checks that its last turn record is still that error and that the session is the one open in the pane. If Claude Code has gone on by itself, the daemon does nothing.

**It types first, and restarts only after that.** The first attempt of an outage types a short message at the live prompt (`An API error stopped your last turn (server_error). Continue where you left off.`) and stops nothing. If that turn fails again, or the message brings no prompt hook within 30 seconds (`no_response`), the attempts after it restart the agent: the daemon sends one SIGINT to the Claude Code process (never another signal, never to the shell), waits up to 15 seconds for it to leave, empties the shell's input line with `C-u`, types the resume command and waits up to 60 seconds for the agent. The resume command is the one [`restore`](README.restore.md) uses: the pane's configured command with `--resume SESSION_ID`, in the session's directory, plus `--dangerously-skip-permissions` when the agent being recovered was started with it. That is read from the Claude Code process's own arguments, under any wrapper, and kept with its pid, so it outlives the process; the workspace config never decides it, and a person's plain `claude` in a split stays plain. `ps` can't show where a prompt starts, so the flag counts only among the options: past a bare word that isn't the value of a known one-value option, including a second value of a multi-value option such as `--mcp-config a b`, it reads as absent, and that agent stops at permission prompts after its resume. With no flags read for the agent the daemon defers and types nothing. The session id, transcript and conversation stay the same. Then it types a second message that says the agent was restarted and its old locks were released, so it should take them again. That message gets the same 30-second wait for a prompt hook: Enter can fall on an agent that is still starting, and with no hook the attempt ends `no_response` and the next one stops that agent, with the message still in its input line if it is there. The daemon resumes only an agent it sent a SIGINT to, and only until a new agent reports in. An agent that leaves without that signal, during the typed attempt for example, isn't resumed, and neither is a resumed agent that vanishes, whether a person ended it or it crashed with no hook: the pane may be a person's by then, so the daemon gives up as `unconfirmed` at the end of that attempt and types nothing into the shell. An agent that ends after attempts with no completed turn gets the same give-up, whenever it ends, unless it ends with `/clear`. The cost is that a resumed agent that crashes needs a person to resume it.

**The schedule.** An outage gets up to 12 attempts, the typed one included, with waits of 1, 2, 4, 8 and then 15 minutes before each. The first wait counts from the failure and each later one from the end of the previous attempt, so 135 minutes is the sum of the waits, not the total time. A turn that completes ends the outage: the record is deleted, the inbox item (if any) is resolved, and the next outage types first again. After the 12th attempt the daemon gives up with one inbox item.

**What it waits for.** Before each attempt the daemon reads the pane, and it waits (the attempt isn't counted) while any of these holds:

- the screen is still changing, or shows `Retrying in` or `esc to interrupt`
- the input line holds text that isn't the daemon's own message
- a prompt was submitted since the failure
- the main agent has a sub-agent running (one with no event for 10 minutes stops counting, because an outage can kill a sub-agent before it reports)
- the agent's process group doesn't hold the pane's terminal, so typed text would reach a shell
- the pane is outside window 0 of the session, which the session monitor doesn't scan: such an agent is always deferred
- tmux, `ps`, the transcript or the session ledger can't be read
- a second `claude` process sits in the pane and is listed first: the real agent is refused, and the daemon types and stops nothing

A pane that waits 30 minutes without a break is given up as `deferred`, with nothing typed or stopped. A healthy agent is never stopped. An open [`ask`](README.ask.md) doesn't hold an attempt off, because an ask can stay open for good; it survives the restart.

**What a restart keeps and what it loses.** The dev server started with `workspace dev up` keeps running and keeps its lock, and prompts queued with `agent-run send --when-idle` stay queued and go to the resumed agent. A lock the old agent held is released. These are lost:

- text a person had typed at the shell of a pane the daemon stopped, because `C-u` empties the line before the resume command goes in
- a draft in the agent's own input line, because SIGINT makes Claude Code exit
- background Bash tasks, and background sub-agents whose record already closed at a Stop, because they live in the process that is stopped

While the daemon is recovering a pane, [`agent-run send`](README.agent-run.md) to a pane that currently reads as a shell answers `not_an_agent`. That can last until the next attempt, up to 15 minutes. A queued prompt isn't dropped.

**What it doesn't detect.** A frozen agent (one stopped with `SIGSTOP`, for example) isn't detected as such: the typed attempt ends `not_typed`, because the paste can't render, and a SIGINT stays pending until the process runs again. A request that hangs without failing isn't detected either, because Claude Code reports no error for it, and neither is a resumed agent that then hangs. Recovery acts on API errors Claude Code reports, nothing else.

**Turning it off.** `agent.recovery.enabled` is on by default. `workspace config set agent.recovery.enabled false` turns it off for the workspace, project or globally (see [`config`](README.config.md)); read the effective value with `workspace config agent.recovery.enabled` (`config get` prints nothing for a key that only has its default). The daemon reads the key when it starts, so the change takes effect at the next start: `workspace agentd restart`.

**Why a pane wasn't recovered.** A give-up writes an `agent_recovery_gave_up` line to the [event log](README.event-log.md#agent-recovery) and adds one inbox item, `agent-recovery:SESSION_ID`, with the pane id as its link. The `reason` is one of:

| Reason | What happened |
|--------|---------------|
| `attempts_exhausted` | The error kept coming through all 12 attempts |
| `not_retryable` | The error kind isn't one trying again can fix, so no attempt follows. A later retryable failure of the same session starts the schedule again |
| `cannot_restart` | The pane has its own start command, something other than a shell runs the agent, or the transcript is gone. No attempt was made |
| `fresh_conversation` | A new conversation took the pane's place (a `claude ... \|\| claude` wrapper started one), so nothing was typed into it |
| `deferred` | The pane stayed busy or unreadable for 30 minutes (the list above), or tmux no longer lists it. Nothing was stopped or typed in those 30 minutes; attempts before them may have |
| `unconfirmed` | The daemon could no longer confirm that the turn ended on the error, after attempts had been made (or, with no attempt made, an inbox item from an earlier failure was already open and a later failure could not be confirmed). A later retryable failure of the same session with an agent in the pane starts the schedule again, with the count kept |

The item is resolved when a later turn of that session completes. Each finished attempt writes an `agent_recovery_attempt` line whose `outcome` says how it ended; a failed attempt counts toward the 12 and schedules the next:

| Outcome | What happened |
|---------|---------------|
| `typed` | The message was typed, Claude Code took it (a prompt hook arrived) and it was still in the pane. The agent is watched until its turn ends |
| `resumed` | The agent was restarted, took the second message (a prompt hook arrived) and was still in the pane. It is watched until its turn ends |
| `agent_left` | The message was taken (`typed` or `resumed` so far), but no agent was left in the pane at the end of the attempt. The daemon gives up with `unconfirmed` at once and nothing is typed |
| `no_response` | The typed message, or the second message of a restart, got no prompt hook in 30 seconds. The next attempt restarts the agent. The text may still be in the input line |
| `not_submitted` | The text was pasted but Enter didn't take. It may be in the input line |
| `not_typed` | Nothing was typed: the pane wasn't safe to type into, a person's prompt came in, or the agent didn't hold the terminal |
| `not_stopped` | The agent was still running 15 seconds after the SIGINT. If it exits late, within 5 minutes of the signal, and its SessionEnd arrives after the attempt ended, the next attempt resumes it: that exit can't be told from a person's. Otherwise the daemon gives up with `unconfirmed`, nothing typed: with the SessionEnd seen during the attempt, after the pane defers until the signal is 5 minutes old; with one later than that, at once |
| `not_delivered` | The resume command didn't reach the pane |
| `pane_not_clear` | The pane wasn't at a shell prompt, a process still held the session, or the agent didn't hold the terminal |
| `not_ready` | The resumed agent didn't show its prompt in 60 seconds, or died first |
| `person_resumed` | A person resumed the conversation in the pane first. Nothing more was typed |
| `resumed_elsewhere` | The same session opened in another pane. Nothing was typed, so one session never runs in two panes, and the record is deleted |
| `fresh_agent` | A different conversation started in the pane. The attempt ends and the daemon gives up with `fresh_conversation` |
| `claim_lost` | Another restart took the pane |
| `interrupted` | The daemon itself stopped or restarted during the attempt; the next daemon found it and went on |

## Wire protocol

The agent answers every inbound connection with exactly one JSON line, so a caller can always tell an answer apart from a dead agent. (The one exception: a `restart_agent` caller that waits gets no line if the agent shuts down first.)

### Status reply actions

The coordinator's answer to a status report decides what the agent does next:

| Reply | Meaning |
|-------|---------|
| `{"ok": true}` | Report accepted |
| `error: "unregistered"`, `action: "reregister"` | Re-register and replay unacknowledged reports |
| `error: "unknown_work_item"`, `action: "give_up"` | Stop reporting on this work item and drop it |
| `error: "terminal_state"`, `action: "abort_pipeline"` | Fail the pipeline for this work item |

### Command reply

| Reply | Meaning |
|-------|---------|
| `{"ok": true}` | The command reached the pane (a `Warning:` status update follows if it may not have been submitted) |
| `error: "not_delivered"`, `message` | The command never reached the pane; nothing was started |

### Inject reply

| Reply | Meaning |
|-------|---------|
| `{"ok": true, "queued_for_pane": N}` | Steer accepted, delivered to or held for pane N |
| `error: "no_active_pipeline"` | Nothing is running for this work item |
| `error: "no_next_stage"` | The work item is on the last stage, so there is no later pane to hold this for |
| `error: "not_delivered"`, `message` | An urgent steer never reached the pane |
| `error: "not_submitted"`, `message` | An urgent steer is in the pane but Enter didn't appear to submit it; don't resend, or it will be typed twice |

### Prompt send

A `prompt_send` message queues a prompt for one coding-agent pane and types it once the agent's turn ends; `workspace agent-run send --when-idle` and `--clear-first` send it (see [README.agent-run.md](README.agent-run.md#send---when-idle) for what is checked, the drop rules and the events). With `"clear_first": true` the daemon types the agent's clear before the text and waits for its SessionStart (see [`--clear-first`](README.agent-run.md#send---clear-first)); with `"when_idle": false` as well, a prompt that would have to wait is taken out of the queue again and refused `pane_busy`. The daemon answers from a worker thread: a pane whose turn has ended gets the text typed before the reply.

```json
{"type": "prompt_send", "workspace": "myapp", "pane_id": "%18", "text": "Now update the docs"}
```

| Reply | Meaning |
|-------|---------|
| `{"ok": true, "delivered": true, "submitted": true, "id": ...}` | Typed during the call; `"cleared": true` after a confirmed clear |
| `{"ok": true, "queued": true, "id": ..., "position": N}` | Queued; typed when the turn ends |
| `error: "not_an_agent"`, `"unsupported_agent"`, `"clear_unsupported"`, `"pane_waiting"`, `"queue_full"`, `"pane_busy"`, `"pane_not_ready"`, `"no_such_pane"`, `"usage"` | Refused; nothing was queued |
| `error: "clear_unconfirmed"`, `clear_typed: true` | The clear was typed during the call but not confirmed; the text was not typed |
| `error: "not_submitted"` | Pasted during the call but not confirmed submitted; never typed again |
| `error: "not_delivered"`, `reason` | Dropped during the call (`reason` as in the drop rules; `clear_typed: true` when a clear was typed first) |

Every reply also carries `pane` (window.pane) and `pane_id`. The daemon checks the 32 KB limit on `text` too (`usage`). The queue's other triggers are the main agent's Stop hook and the session monitor's scan.

### Restart agent

A `restart_agent` message gives the coding agent in one pane a fresh conversation. `workspace agent-run restart` sends it (see [README.agent-run.md](README.agent-run.md)).

```json
{"type": "restart_agent", "workspace": "myapp", "pane": "%18", "prompt": "Read HANDOFF.md and follow it.", "force": false, "wait": false, "timeout": 30}
```

`pane` is required and is never guessed: a pane id (`%18`), `window.pane` (`0.1`), `session:window.pane`, or a pane index in window 0. The session may be the tmux session name or the workspace name.

Before replying, the agent checks that the pane exists and isn't running a shell, that no pipeline stage is running on it (unless `force`), that a `/clear` on it could be confirmed from its status-line readings, and that no other restart is running on it. Then a worker thread:

1. waits (up to 120s) for the pane's screen to stop changing and for the agent to stop waiting on a person,
2. types `/clear`,
3. waits (up to `timeout` seconds, default 30, at most 600) for a status-line reading recorded after the moment `/clear` was typed that comes from a new Claude session (a different `session_id`); a reading with no session id must instead show no usage yet, or less than before,
4. types the prompt, unless a pipeline stage started on the pane meanwhile (skipped with `force`).

If step 3 times out, the prompt is not typed. Without `wait`, the reply comes at once and a failure later is printed on the agent's stderr. With `wait`, the reply comes when the worker finishes; if the agent shuts down first, the connection closes with no reply.

| Reply | Meaning |
|-------|---------|
| `{"ok": true, "status": "started", "pane", "pane_id", "context_pct"}` | Checks passed; the worker is running (no `wait`). `context_pct` is `null` for a pane that hasn't reported usage yet |
| `{"ok": true, "status": "restarted", "context_before", "context_after", "delivery"}` | Done (`wait`); `warning` is set when the prompt may not have been submitted |
| `warning` on a started reply | `force` restarted a pane with a pipeline stage on it; that stage finishes only if the new conversation prints its sentinel |
| `error: "missing_pane"` / `"bad_pane"` / `"no_such_pane"` / `"wrong_session"` | The pane was missing, unreadable, not found, or in another tmux session |
| `error: "not_an_agent"` | The pane is running a shell |
| `error: "pane_in_pipeline"`, `work_item_ref` | A pipeline stage is running on the pane; pass `force` to restart it anyway |
| `error: "context_unknown"`, `reason`, `fix` | No reading could confirm the `/clear` (scrape mode with no matching pattern, or no reading at all on a pane the monitor hasn't identified as Claude Code); nothing was typed |
| `error: "restart_in_progress"` | Another restart is running on this pane |
| `error: "missing_prompt"` / `"bad_timeout"` | The prompt was empty, or `timeout` wasn't 1–600 seconds |
| `error: "pane_busy"` / `"pane_gone"` | (`wait`) The pane never went quiet, or closed; see `message` for what was typed |
| `error: "clear_not_confirmed"` | (`wait`) `/clear` was typed but neither a new conversation's reading nor a SessionStart hook event with source `clear` arrived in time; the prompt was not typed |
| `error: "not_delivered"` | (`wait`) `/clear` or the prompt never reached the pane |

### Handoff watch

A `handoff_watch` message opens a follow-up watch on a pane. `workspace handoff check` sends it after its save-state prompt landed (see [handoff](README.handoff.md#follow-ups)); the watch thread starts on the first one.

```json
{"type": "handoff_watch", "workspace": "myapp", "pane_id": "%18", "sent_at": "2026-10-30T12:00:00.000Z", "interval": 30, "max": 10, "text": "...", "sent_text": "..."}
```

`pane_id` is a tmux pane id, `sent_at` an ISO 8601 time, `interval` and `max` positive numbers (`max` an integer), and `text` (the follow-up) and `sent_text` (the save-state prompt as typed) 1 to 4,000 characters. The reply is `{"ok": true, "watching": true, "reason": null}`, or `"watching": false` with `reason` `not_scanned` (the pane is not in window 0, or not yet scanned), `not_claude`, `no_hooks` or `invalid`. A bad field is `{"ok": false, "error": "usage"}`, a pane running a pipeline stage `error: "pipeline_stage"` with `work_item_ref`, and anything unexpected `error: "internal_error"`. An older daemon answers `unknown_type`.

### Version

`{"type": "version", "workspace": "myapp"}` asks which workspace version the agent is running (the one loaded when it started). `workspace daemon list` sends it. The reply is `{"ok": true, "version": "0.37.1"}`; an agent from before this message answers `unknown_type`.

### Dispatch errors

| Reply | Meaning |
|-------|---------|
| `error: "wrong_workspace"` | Message was addressed to a different workspace |
| `error: "unknown_type"` | Unrecognized `type` field |
| `error: "malformed_message"` | The line was not valid JSON |
| `error: "internal_error"` | The message raised while being handled; the connection is dropped, the agent keeps running |

## Epochs and restarts

Every agent process mints a ULID epoch on startup, and every status reply carries the coordinator's. An epoch the agent has not seen means it is talking to a different coordinator process than the one it registered with, so it re-registers — reporting its current `in_flight` list — and replays whatever the previous coordinator never acknowledged.

An unreachable coordinator never takes the pipeline down. Reports are retried, then buffered (up to 500, oldest dropped first) and replayed in order once the coordinator is back.

**Socket resilience** — agent sockets live at `~/.local/workspace/run/` rather than `/tmp`, so OS temp-file sweeps never delete them. As an additional safeguard, a background watcher checks `File.socket?` every 5 seconds; if the file is gone (e.g. manual deletion, filesystem remount) it rebinds the socket at the same path and re-registers with the coordinator. If re-registration fails (coordinator also down at that moment) the watcher retries each cycle until it succeeds.

**Stale-slot recovery** — the agent includes its PID in every `register` message. When a fresh agent starts for a workspace that is already registered, the coordinator checks whether the registered PID is still alive. If the old process is dead, the coordinator replaces the registration; if it is alive, it rejects with `already_registered` as before.

**Agent restarts** — in-flight state is persisted to `$XDG_STATE_HOME/workspace/<name>/pipeline.json` (`~/.local/state/...` by default) on every change, written to a temp file and renamed so a crash mid-write cannot truncate it. A restarted agent reads it back and checks each recorded pane:

- The pane survived: the agent re-attaches its watch, and the stage finishes and advances as if nothing happened.
- The pane is gone: the work item is dropped and left out of the registration, which is what tells the coordinator to reconcile it rather than wait on a stage that will never finish.

## Inspecting a running pipeline

See [`workspace pipeline`](README.pipeline.md) for the operator commands that show what a project has in flight and drive it by hand.

## Examples

```sh
# Run the agent for the project in the current directory
workspace agentd

# Run it for a named project, positionally
workspace agentd scooter

# Run it for a named project against a non-default coordinator
workspace agentd --name scooter --wc-socket /tmp/wc-dev.sock

# Replace the agent already running for this workspace
workspace agentd --force

# Replace it with one running in the background, and get the terminal back
workspace agentd restart

# The same for a named project, as one JSON action document
workspace agentd restart scooter --json
```
