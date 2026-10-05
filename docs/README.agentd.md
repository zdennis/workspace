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

To check on or read the log of a running agent without holding a terminal, use [`workspace daemon`](README.daemon.md).

**`--ensure`** — makes sure the workspace has an agent without taking the terminal: if one answers on the socket it prints `agentd for <name> is already running` and exits 0; otherwise it starts one detached (output in the daemon log, `~/.local/workspace/run/workspace-<name>.log`), waits up to 5 seconds for it to answer, prints `Started agentd for <name>` and exits 0. A leftover socket file from a dead agent doesn't count as running. Concurrent calls, including `workspace launch` starting the same workspace, are serialized on `workspace-<name>.lock` in that directory, so they never start two agents. It exits 1 with the reason when the agent can't be started or doesn't answer in time, or when the project's pipeline config is invalid. `workspace launch` runs the same check for each project it launches; a failure there is a warning and the launch carries on. `--wc-socket` is passed through to a newly started agent. Only `--ensure` callers take the lock: a plain `workspace agentd` started by hand at the same instant can still race one.

**One agent per workspace** — on startup the agent probes its own socket at `~/.local/workspace/run/workspace-<name>.sock`. With a very long workspace name the filename is truncated with a short hash suffix (derived deterministically from the name) so the path stays within a 100-byte cap (headroom under the OS's 104-byte socket path limit); the daemon log filename is truncated the same way, against a 250-byte cap (headroom under the 255-byte per-component limit). If something answers, it refuses to start rather than stealing the socket from a running agent. A socket left behind by an unclean shutdown does not answer, so it is removed and the agent starts normally.

`--force` turns that refusal into a handover: the agent finds the process holding the socket with `lsof`, sends it `SIGTERM`, and waits up to 5 seconds for it to exit before binding the socket itself. In-flight state is already on disk, so the replacement picks the pipeline back up as it would after any other restart.

**Workflow runs** — when the main agent's turn ends in a pane bound to a [workflow run](README.workflow.md) (a `Stop` hook event with no sub-agent id), the daemon starts `workspace workflow advance RUN --turn-ended --pane ID [--turn-started AT]` as its own process, which decides the run's step. `AT` is when the pane's last prompt was submitted, when this daemon saw it; the run ignores the end of a turn that began before its step did. Every 15 seconds it starts `workspace workflow advance RUN` for each of the workspace's runs that waits for a lock, or whose check never reported back. Those processes write to the daemon's log. A workflow needs the daemon: without one, a run only moves on `workflow resume`.

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
| `error: "clear_not_confirmed"` | (`wait`) `/clear` was typed but usage didn't drop in time; the prompt was not typed |
| `error: "not_delivered"` | (`wait`) `/clear` or the prompt never reached the pane |

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
