# workspace agent-run

Send a raw JSONL message to a running workspace agent socket. Useful for manual testing, debugging pipelines, and scripting one-off commands without going through the work-coordinator.

## Usage

```sh
workspace agent-run <subcommand> [options]
workspace agent-run --body '<full message JSON>' [--dry-run]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `command` | Send a `command` message — delivers work to the first pipeline stage |
| `inject` | Send an `inject` message — steers a running work item |
| `restart` | Send a `restart_agent` message — clears the coding agent in one pane and types a fresh prompt |
| `examples` | Print all stock example messages without sending anything |

## Options

### Raw mode (`--body`)

| Option | Description |
|--------|-------------|
| `--body JSON` | Complete message JSON; workspace is read from the message |
| `--dry-run` | Print the message without sending it |

### `command` subcommand

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--work-item REF` | Work item reference, e.g. `WC-42` (required) |
| `--body TEXT` | Text to type into the first pipeline pane |
| `--dry-run` | Print the message without sending it |

### `inject` subcommand

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--work-item REF` | Work item reference (required) |
| `--body TEXT` | Text to inject into the pane (required) |
| `--interrupt` | Interrupt the running stage first (sends Ctrl-C) |
| `--dry-run` | Print the message without sending it |

### `restart` subcommand

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--pane PANE` | Pane to restart (required): a pane id (`%12`), `window.pane` (`0.1`), `session:window.pane`, or a pane index in window 0 |
| `--prompt TEXT` | Text typed once `/clear` is confirmed (required) |
| `--force` | Restart even when a pipeline stage is running on the pane |
| `--wait` | Wait for the restart to finish and report how it went |
| `--timeout DURATION` | Longest wait for context usage to drop after `/clear` (e.g. `45s`); default 30s, at most 600s |
| `--json` | Print the result as JSON |

## Details


`agent-run` connects directly to the agent's Unix socket and sends a single JSON message. The agent's reply is always printed. Every invocation prints the message being sent before sending it, even without `--dry-run`.

**Raw mode** (`--body`) accepts a full JSON message and sends it as-is. The `workspace` field inside the JSON determines which socket is targeted — no separate `--name` flag needed. This mode is useful for copy-pasting an example message and firing it immediately.

**`command`** builds and sends a `command`-type message with a generated `dispatch_id` (prefixed `debug-`), targeting the first pipeline stage of the named workspace.

**`inject`** sends an `inject`-type message to steer a work item that is already running. Add `--interrupt` to send Ctrl-C to the running stage's pane before typing the body.

**`restart`** asks the agent daemon to give the coding agent in one pane a fresh conversation. Unlike `command` and `inject`, it prints only the outcome, not the message it sends. The daemon waits for the pane to go quiet, types `/clear`, waits until a context reading taken after the `/clear` is lower than the one before it, then types the prompt. If that drop isn't seen within `--timeout`, the prompt is **not** typed. Context readings come from `workspace statusline` (or `context.source: scrape`); a pane with no reading is refused before anything is typed, with the reason and how to fix it.

The pane must be named. Nothing picks "the Claude pane" for you, so in a workspace with several agents the `/clear` can't reach the wrong one. A pane with a pipeline stage running on it is refused unless you pass `--force`, because clearing it leaves that stage waiting for a sentinel it will never print.

Because the daemon does the typing from outside the pane, an agent can restart itself: it runs `restart` on its own pane and ends its turn. Without `--wait` the command returns once the checks pass, and a later failure is printed on the daemon's stderr. With `--wait` it returns when the restart has finished (or failed).

With `--json`, success prints the daemon's reply with `schema_version: 1` (`status` is `started`, or `restarted` with `context_before`/`context_after` under `--wait`). Errors print `{"schema_version":1,"error":"<message>","code":"<daemon error code>",...}` and exit 1; see the `restart_agent` reply table in [README.agent.md](README.agent.md) for the codes.

**`examples`** prints the full set of stock example messages (with realistic field values for the detected workspace) without sending anything. Use it to see the wire format before firing a real message.

## Examples

```sh
# Send a command to WC-42 in the project detected from the current directory
workspace agent-run command --work-item WC-42 --body "Add OAuth support"

# Send a command to a named workspace, dry-run only
workspace agent-run command --name myapp --work-item WC-42 --body "Add OAuth support" --dry-run

# Inject a steer into a running work item
workspace agent-run inject --work-item WC-42 --body "Use Postgres, not SQLite"

# Inject and interrupt the currently running stage first
workspace agent-run inject --work-item WC-42 --body "Stop and pivot to the auth approach" --interrupt

# Send a full message JSON directly (workspace comes from the JSON)
workspace agent-run --body '{"type":"command","workspace":"myapp","work_item_ref":"WC-42","dispatch_id":"debug-1234","body":"go"}'

# Clear the agent in pane 0.1 and hand it a fresh prompt, waiting for the result
workspace agent-run restart --name myapp --pane 0.1 --prompt "Read HANDOFF.md and follow it." --wait

# Restart a pane by its tmux pane id, as JSON
workspace agent-run restart --pane %18 --prompt "Resume from HANDOFF.md" --json

# Print examples for the current workspace without sending
workspace agent-run examples
```
