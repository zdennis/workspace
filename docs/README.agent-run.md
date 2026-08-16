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

## Details

`agent-run` connects directly to the agent's Unix socket and sends a single JSON message. The agent's reply is always printed. Every invocation prints the message being sent before sending it, even without `--dry-run`.

**Raw mode** (`--body`) accepts a full JSON message and sends it as-is. The `workspace` field inside the JSON determines which socket is targeted — no separate `--name` flag needed. This mode is useful for copy-pasting an example message and firing it immediately.

**`command`** builds and sends a `command`-type message with a generated `dispatch_id` (prefixed `debug-`), targeting the first pipeline stage of the named workspace.

**`inject`** sends an `inject`-type message to steer a work item that is already running. Add `--interrupt` to send Ctrl-C to the running stage's pane before typing the body.

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

# Print examples for the current workspace without sending
workspace agent-run examples
```
