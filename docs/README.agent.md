# workspace agent

Umbrella for driving a workspace's agent: send it work with `workspace agent run "prompt"`, or start the daemon with [`workspace agentd`](README.agentd.md).

## Usage

```sh
workspace agent run PROMPT [options]
```

The prompt is the positional arguments joined with a space, so a multi-word prompt does not need quoting:

```sh
workspace agent run Add OAuth support
```

## Options

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--work-item REF` | Work item reference, e.g. `WC-42` (default: random UUID) |
| `--dry-run` | Print the message without sending it |

## Details

`agent run` builds and sends a `command` message to the workspace agent's socket — the same message [`workspace agent-run command`](README.agent-run.md) sends, minus the default body: the prompt positional is required. The message is printed before it is sent, so a generated `work_item_ref` (see the notes in [README.agent-run.md](README.agent-run.md)) is visible for later `inject` or `pipeline status` use.

**One agent per workspace** — on startup the agent probes its own socket at `~/.local/workspace/run/workspace-<name>.sock`. With a very long workspace name the filename is truncated with a short hash suffix (derived deterministically from the name) so the path stays within the OS's 104-byte socket path limit. If something answers, it refuses to start rather than stealing the socket from a running agent. A socket left behind by an unclean shutdown does not answer, so it is removed and the agent starts normally.

Sending work requires the daemon to be listening. Start one with [`workspace agentd <project>`](README.agentd.md) (`workspace launch` starts one automatically).

### Deprecation window

Before `agent` became this umbrella, `workspace agent` *was* the daemon. Daemon-era invocations — `workspace agent --name myproject --force`, or bare `workspace agent` — still start the daemon during the deprecation window (installed templates launch it that way), with a warning on stderr pointing at `workspace agentd`. A future release will drop the fallback.

## Examples

```sh
# Send a prompt to the current workspace's pipeline
workspace agent run "Add OAuth support"

# Send it to a named workspace with a known work-item ref, without sending
workspace agent run --name myapp --work-item WC-42 "Add OAuth support" --dry-run

# A prompt that starts with a dash needs --
workspace agent run -- "--verbose logging"

# Start the daemon for myapp
workspace agentd myapp
```

## Related

- [`workspace agentd`](README.agentd.md) — the long-lived agent daemon
- [`workspace agent-run`](README.agent-run.md) — the low-level form of `agent run`, plus `inject` and `restart`
