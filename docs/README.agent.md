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
    - role: implementer
    - role: reviewer
  handoff: file_handoff
```

A command from the coordinator is typed into the first stage's pane. When a stage prints `WORKSPACE_DONE: <summary>`, the agent captures that pane's output to a handoff file under `~/.config/workspace/handoffs/`, points the next stage at it, and moves on. The last stage finishing reports the work item complete.

A project with no `pipeline` block still works: commands go to pane 0 and nothing is tracked.

**Steering** — an `inject` message queues a note for the next stage without disturbing the running one. With `interrupt: true` it sends `C-c` to the running stage's pane first and types the note in immediately.

## Wire protocol

The agent answers every inbound connection with exactly one JSON line, so a caller can always tell an answer apart from a dead agent.

### Status reply actions

The coordinator's answer to a status report decides what the agent does next:

| Reply | Meaning |
|-------|---------|
| `{"ok": true}` | Report accepted |
| `error: "unregistered"`, `action: "reregister"` | Re-register and replay unacknowledged reports |
| `error: "unknown_work_item"`, `action: "give_up"` | Stop reporting on this work item and drop it |
| `error: "terminal_state"`, `action: "abort_pipeline"` | Fail the pipeline for this work item |

### Inject reply

| Reply | Meaning |
|-------|---------|
| `{"ok": true, "queued_for_pane": N}` | Steer accepted, delivered to or held for pane N |
| `error: "no_active_pipeline"` | Nothing is running for this work item |
| `error: "no_next_stage"` | The work item is on the last stage, so there is no later pane to hold this for |

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
