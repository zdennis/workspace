# workspace agent

Run the long-lived agent for a project. The agent registers with work-coordinator, binds its own Unix socket, and drives the project's pipeline panes until it is terminated.

## Usage

```sh
workspace agent [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (defaults to the project detected from the current directory) |
| `--wc-socket PATH` | Override the path to the work-coordinator socket |
| `-f`, `--force` | Terminate a running agent for this workspace and take its place |

## Details

**One agent per workspace** — on startup the agent probes its own socket at `~/.local/workspace/run/workspace-<name>.sock`. If something answers, it refuses to start rather than stealing the socket from a running agent. A socket left behind by an unclean shutdown does not answer, so it is removed and the agent starts normally.

`--force` turns that refusal into a handover: the agent finds the process holding the socket with `lsof`, sends it `SIGTERM`, and waits up to 5 seconds for it to exit before binding the socket itself. In-flight state is already on disk, so the replacement picks the pipeline back up as it would after any other restart.

**Pipeline** — a project's stages come from `pipeline.panes` in `~/.config/workspace/projects/<name>.yml`. Each entry's position is its pane index:

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

Before replying, the agent checks that the pane exists and isn't running a shell, that no pipeline stage is running on it (unless `force`), that its context usage can be read, and that no other restart is running on it. Then a worker thread:

1. waits (up to 120s) for the pane's screen to stop changing and for the agent to stop waiting on a person,
2. types `/clear`,
3. waits (up to `timeout` seconds, default 30, at most 600) for a context reading taken after the `/clear` that is lower than the one before it (or 0%),
4. types the prompt, unless a pipeline stage started on the pane meanwhile (skipped with `force`).

If step 3 times out, the prompt is not typed. Without `wait`, the reply comes at once and a failure later is printed on the agent's stderr. With `wait`, the reply comes when the worker finishes; if the agent shuts down first, the connection closes with no reply.

| Reply | Meaning |
|-------|---------|
| `{"ok": true, "status": "started", "pane", "pane_id", "context_pct"}` | Checks passed; the worker is running (no `wait`) |
| `{"ok": true, "status": "restarted", "context_before", "context_after", "delivery"}` | Done (`wait`); `warning` is set when the prompt may not have been submitted |
| `warning` on a started reply | `force` restarted a pane with a pipeline stage on it; that stage finishes only if the new conversation prints its sentinel |
| `error: "missing_pane"` / `"bad_pane"` / `"no_such_pane"` / `"wrong_session"` | The pane was missing, unreadable, not found, or in another tmux session |
| `error: "not_an_agent"` | The pane is running a shell |
| `error: "pane_in_pipeline"`, `work_item_ref` | A pipeline stage is running on the pane; pass `force` to restart it anyway |
| `error: "context_unknown"`, `reason`, `fix` | The pane's context usage can't be read, so the `/clear` couldn't be confirmed; nothing was typed |
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
workspace agent

# Run it for a named project against a non-default coordinator
workspace agent --name scooter --wc-socket /tmp/wc-dev.sock

# Replace the agent already running for this workspace
workspace agent --force
```
