# workspace agent-run

Send a raw JSONL message to a running workspace agent socket. Useful for manual testing, debugging pipelines, and scripting one-off commands without going through the work-coordinator. For the common case of sending a prompt, see the umbrella [`workspace agent run`](README.agent.md); for the daemon itself, [`workspace agentd`](README.agentd.md).

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
| `send` | Type text or tmux keys into one named pane, straight through tmux (no daemon) |
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
| `--work-item REF` | Work item reference, e.g. `WC-42` (default: random UUID) |
| `--body TEXT` | Text to type into the first pipeline pane (default: `Begin work.`) |
| `--dry-run` | Print the message without sending it |

When `--work-item` is omitted a random UUID is generated for the message's `work_item_ref`. Three things to know:

- The printed message always shows the generated ref — you need it for later `workspace agent-run inject --work-item <ref>` or `workspace pipeline status`, so copy it from the output.
- Re-running without `--work-item` starts a second, parallel pipeline entry; it does not re-dispatch the same one.
- A ref unknown to a running coordinator gets a `give_up` reply, which drops the pipeline. Passing a ref that is no longer in flight (or one that never was) removes the pipeline entry rather than steering it.

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

### `send` subcommand

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--pane PANE` | Pane to type into (required): a pane id (`%19`) or `window.pane` (`0.1`) |
| `--body TEXT` | Literal text to paste, then press Enter |
| `--keys KEYS` | Space-separated tmux key names to send, e.g. `Escape`, `Up Up Enter`, `C-c`, `y` |
| `--no-enter` | With `--body`, paste the text without pressing Enter |
| `--json` | Print the result as JSON |

## Details


`agent-run` connects directly to the agent's Unix socket and sends a single JSON message. The agent's reply is always printed. Every invocation prints the message being sent before sending it, even without `--dry-run`.

**Raw mode** (`--body`) accepts a full JSON message and sends it as-is. The `workspace` field inside the JSON determines which socket is targeted — no separate `--name` flag needed. This mode is useful for copy-pasting an example message and firing it immediately.

**`command`** builds and sends a `command`-type message with a generated `dispatch_id` (prefixed `debug-`), targeting the first pipeline stage of the named workspace.

**`inject`** sends an `inject`-type message to steer a work item that is already running. Add `--interrupt` to send Ctrl-C to the running stage's pane before typing the body.

**`restart`** asks the agent daemon to give the coding agent in one pane a fresh conversation. Unlike `command` and `inject`, it prints only the outcome, not the message it sends. The daemon first waits up to `AgentRestart::QUIET_TIMEOUT` (120s, fixed — **not** bounded by `--timeout`) for the pane to go quiet, types `/clear`, then waits for the new session's first status-line render to confirm the clear, then types the prompt. `--timeout` only bounds that confirm step, after `/clear` has already been typed. If the clear isn't confirmed within `--timeout`, the prompt is **not** typed. Confirmation depends on `workspace statusline` being installed as Claude's `statusLine` (or `context.source: scrape`): the clear counts only once a reading recorded after the moment `/clear` was typed arrives from a new Claude session. Readings are stamped to the microsecond, so Claude's re-render in the same second as the `/clear` still confirms it, and a reading from before the `/clear` never does. The pane's usage needn't be known beforehand — a pane just started or cleared (no usage reported yet) is restarted too, and so is a Claude pane with no reading at all, confirmed by the new session's first render. A pane no reading could ever confirm (scrape mode with no matching pattern, or no reading on a pane not yet identified as Claude) is refused before anything is typed, with the reason and how to fix it. Only Claude panes are accepted — a pane running another provider fails with `code: "unsupported_agent"`.

The pane must be named. Nothing picks "the Claude pane" for you, so in a workspace with several agents the `/clear` can't reach the wrong one. A pane with a pipeline stage running on it is refused unless you pass `--force`, because clearing it leaves that stage waiting for a sentinel it will never print.

Because the daemon does the typing from outside the pane, an agent can restart itself: it runs `restart` on its own pane and ends its turn. Without `--wait` the command returns once the checks pass, and a later failure is printed on the daemon's stderr. With `--wait` it returns when the restart has finished (or failed).

With `--json`, success prints the daemon's reply with `schema_version: 1` (`status` is `started`, or `restarted` with `context_before`/`context_after` under `--wait`). Errors print `{"schema_version":1,"error":"<message>","code":"<daemon error code>",...}` and exit 1; see the `restart_agent` reply table in [README.agentd.md](README.agentd.md) for the codes.

**`send`** types into one pane through tmux directly, so it needs no agent daemon. It never guesses a pane: `--pane` is required and takes only a pane id (`%19`, as `workspace sessions --json` reports) or `window.pane`; there is no default, no title search and no bare index. The pane must belong to the workspace's own tmux session. A pane id from another session fails with `wrong_session`, an unknown one with `no_such_pane`, any other form with `bad_pane`, and a workspace with no session with `no_session`. Nothing is typed unless the pane resolved.

- `--body TEXT` pastes the text literally (key names in it are not interpreted; embedded newlines stay line breaks) and then presses Enter, unless `--no-enter`. Delivery is checked by reading the pane back, as in [`workspace run`](README.run.md): exit 0 when it landed and Enter took effect, 2 (`not_submitted`) when the text is, or may be, in the pane but wasn't confirmed submitted (check before resending), 1 (`not_delivered`) when it never reached the pane (safe to resend).
- `--keys KEYS` sends tmux key names, never text and never an implicit Enter; add `Enter` yourself. A key is a named key (`Enter Escape Tab BTab Space BSpace Up Down Left Right Home End PageUp PageDown PgUp PgDn NPage PPage Delete DC IC`), `F1` to `F12`, one printable character other than `-` and `;`, or any of those with `C-`, `M-` or `S-` modifiers (`C-c`, `M-x`). Anything else (a word such as `hello`, a flag-like `-l`) is refused with `bad_keys` before the first key is sent; use `--body` to type text. At most 64 keys. If tmux fails partway, the error says how many went through (`details.keys_sent`).
- `--body` and `--keys` are mutually exclusive, and one is required; `--no-enter` with `--keys` is a usage error.

With `--json`, success prints `{"schema_version":1,"ok":true,"workspace":"api","pane":"%19","mode":"text","submitted":true}`; `mode` is `keys` (with a `keys` array and `submitted: true`) for `--keys`. `submitted` is false only for `--body --no-enter`. `pane` is always the pane id, even when the pane was named `window.pane`. Failures are the standard error envelope with the codes above.

**`examples`** prints the full set of stock example messages (with realistic field values for the detected workspace) without sending anything. Use it to see the wire format before firing a real message.

## Examples

```sh
# Send a command with a generated work-item ref (printed in the message output)
workspace agent-run command --body "Add OAuth support"

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

# Answer a permission prompt in pane %19 with a key, then confirm with Enter
workspace agent-run send --name myapp --pane %19 --keys "y Enter"

# Interrupt whatever pane %19 is doing, as JSON
workspace agent-run send --name myapp --pane %19 --keys Escape --json

# Type a prompt into pane 0.1 and press Enter
workspace agent-run send --name myapp --pane 0.1 --body "Run the specs and report failures"

# Print examples for the current workspace without sending
workspace agent-run examples
```
