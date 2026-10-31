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
| `send` | Type text or tmux keys into one named pane, straight through tmux (no daemon); with `--interrupt`, have the daemon interrupt the agent, wait for its prompt and type the text in one step; with `--when-idle`, hand the text to the agent daemon to type once the agent's turn ends; with `--clear-first`, have the daemon clear the conversation first |
| `queue` | `queue list` shows the prompts `send --when-idle` has queued; `queue cancel --id ID` takes one back. Both work with no agent daemon |
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
| `--when-idle` | With `--body`: typed now if the agent's turn has ended, else queued by the agent daemon and typed when it ends (Claude Code panes only) |
| `--clear-first` | With `--body`: the agent daemon types the agent's clear (`/clear`) first, waits for the new conversation, then types the text. With or without `--when-idle` (Claude Code panes with hooks only) |
| `--interrupt` | With `--body`: the agent daemon presses the agent's interrupt key (`Escape`), waits up to 15s for its prompt to come back, then types the text; one call, one result (Claude Code panes only) |
| `--json` | Print the result as JSON |

### `queue` subcommand

| Usage | Description |
|-------|-------------|
| `queue list [--name NAME] [--pane PANE] [--json]` | What is queued. `--pane` is a pane id (`%19`, matched as given with no tmux call) or `window.pane` (resolved through tmux, with the pane errors of `send`) |
| `queue cancel --id ID [--name NAME] [--json]` | Take a queued prompt back. Without `--name`, every workspace's queue is searched for the id |

## Details


`agent-run` connects directly to the agent's Unix socket and sends a single JSON message. The agent's reply is always printed. Every invocation prints the message being sent before sending it, even without `--dry-run`.

**Raw mode** (`--body`) accepts a full JSON message and sends it as-is. The `workspace` field inside the JSON determines which socket is targeted — no separate `--name` flag needed. This mode is useful for copy-pasting an example message and firing it immediately.

**`command`** builds and sends a `command`-type message with a generated `dispatch_id` (prefixed `debug-`), targeting the first pipeline stage of the named workspace.

**`inject`** sends an `inject`-type message to steer a work item that is already running. Add `--interrupt` to send Ctrl-C to the running stage's pane before typing the body.

**`restart`** asks the agent daemon to give the coding agent in one pane a fresh conversation. Unlike `command` and `inject`, it prints only the outcome, not the message it sends. The daemon first waits up to `AgentRestart::QUIET_TIMEOUT` (120s, fixed — **not** bounded by `--timeout`) for the pane to go quiet, types `/clear`, then waits for the new session's first status-line render (for a Codex pane, a scraped reading that shows less use than before; see [`handoff`](README.handoff.md#codex)) to confirm the clear, then types the prompt. `--timeout` only bounds that confirm step, after `/clear` has already been typed.

A Claude Code pane is checked once more under the delivery lock right before `/clear`: a draft in the input box refuses it with `pane_busy` and `reason` `input_not_empty` (the grey suggestion of an empty box does not), and so does a spinner or another sign of a running turn (`turn_started`, also the answer when a turn began between the last check and the typing). Nothing is typed then, so the draft stays. Without `--wait` the refusal shows only in the daemon's log; run with `--wait` to see it. A pane whose screen keeps changing after the agent went idle (a background shell or sub-agent redrawing it) is not stuck for good: once the daemon has the main agent's `Stop` and the transcript shows nothing after it, an empty input box and no running turn on screen, all held for 5 seconds, `/clear` is typed anyway and the reply carries a `warning` that background work may be lost. It then waits for the agent to report the prompt it was given (up to 15s) and fails with `not_delivered`, `reason` `prompt_unconfirmed` if it never does. When the proof does not stand the wait ends in `pane_busy` with `reason` `background_activity` (idle, but the screen kept changing), `working`, `waiting` or `unknown_state`, and `details.proof_missing` names the first thing missing (`no_stop_seen`, `no_hooks`, `open_tool`, `transcript_activity:<kind>`, ...). A restart sent for a workflow run stops with `run_unbound` if the run is cancelled while it waits. If the clear isn't confirmed within `--timeout`, the prompt is **not** typed. Confirmation depends on `workspace statusline` being installed as Claude's `statusLine` (or `context.source: scrape`): the clear counts only once a reading recorded after the moment `/clear` was typed arrives from a new Claude session. Readings are stamped to the microsecond, so Claude's re-render in the same second as the `/clear` still confirms it, and a reading from before the `/clear` never does. The pane's usage needn't be known beforehand — a pane just started or cleared (no usage reported yet) is restarted too, and so is a Claude pane with no reading at all, confirmed by the new session's first render. A pane no reading could ever confirm (scrape mode with no matching pattern, or no reading on a pane not yet identified as Claude) is refused before anything is typed, with the reason and how to fix it. Only Claude Code and Codex panes are accepted — a pane running another provider fails with `code: "unsupported_agent"`.

The pane must be named. Nothing picks "the Claude pane" for you, so in a workspace with several agents the `/clear` can't reach the wrong one. It must also be a pane of the workspace's own tmux session: `restart` looks it up there, by the session's exact name, before it asks the daemon, and sends the daemon the pane id. A pane id from another session fails with `wrong_session`, a pane the session doesn't have with `no_such_pane`, a workspace with no tmux session with `no_session`, and any other form with `bad_pane`, all before anything is typed. A pane with a pipeline stage running on it is refused unless you pass `--force`, because clearing it leaves that stage waiting for a sentinel it will never print.

Because the daemon does the typing from outside the pane, an agent can restart itself: it runs `restart` on its own pane and ends its turn. Without `--wait` the command returns once the checks pass, and a later failure is printed on the daemon's stderr. With `--wait` it returns when the restart has finished (or failed).

With `--json`, success prints the daemon's reply with `schema_version: 1` (`status` is `started`, or `restarted` with `context_before`/`context_after` under `--wait`). Errors print `{"schema_version":1,"error":"<message>","code":"<daemon error code>",...}` and exit 1; see the `restart_agent` reply table in [README.agentd.md](README.agentd.md) for the codes. A pane that isn't one of the workspace's own prints the same document with `bad_pane`, `no_session`, `wrong_session` or `no_such_pane`, without the daemon being asked.

**`send`** types into one pane through tmux directly, so it needs no agent daemon. It never guesses a pane: `--pane` is required and takes only a pane id (`%19`, as `workspace sessions --json` reports) or `window.pane`; there is no default, no title search and no bare index. The pane must belong to the workspace's own tmux session. A pane id from another session fails with `wrong_session`, an unknown one with `no_such_pane`, any other form with `bad_pane`, and a workspace with no session with `no_session`. Nothing is typed unless the pane resolved.

- `--body TEXT` pastes the text literally (key names in it are not interpreted; embedded newlines stay line breaks) and then presses Enter, unless `--no-enter`. Delivery is checked by reading the pane back, as in [`workspace run`](README.run.md): exit 0 when it landed and Enter took effect, 2 (`not_submitted`) when the text is, or may be, in the pane but wasn't confirmed submitted (check before resending), 1 (`not_delivered`) when it never reached the pane (safe to resend).
- `--keys KEYS` sends tmux key names, never text and never an implicit Enter; add `Enter` yourself. A key is a named key (`Enter Escape Tab BTab Space BSpace Up Down Left Right Home End PageUp PageDown PgUp PgDn NPage PPage Delete DC IC`), `F1` to `F12`, one printable character other than `-` and `;`, or any of those with `C-`, `M-` or `S-` modifiers (`C-c`, `M-x`). Anything else (a word such as `hello`, a flag-like `-l`) is refused with `bad_keys` before the first key is sent; use `--body` to type text. At most 64 keys. If tmux fails partway, the error says how many went through (`details.keys_sent`).
- `--body` and `--keys` are mutually exclusive, and one is required; `--no-enter` with `--keys` is a usage error.

With `--json`, success prints `{"schema_version":1,"ok":true,"workspace":"api","pane":"%19","mode":"text","submitted":true}`; `mode` is `keys` (with a `keys` array and `submitted: true`) for `--keys`. `submitted` is false only for `--body --no-enter`. `pane` is always the pane id, even when the pane was named `window.pane`. Failures are the standard error envelope with the codes above.

#### `send --when-idle`

`--when-idle` sends a prompt to an agent that may be in the middle of a turn without typing into that turn. The pane is checked as for `send` (same pane errors, before anything else), then the text goes to the workspace's agent daemon ([`agentd`](README.agentd.md)), which owns a queue per workspace (`~/.local/state/workspace/<workspace>/prompt-queue.json`) and is the only thing that types queued text:

- **The pane's turn has ended** (the agent reads `done` or `idle` in [`sessions`](README.sessions.md), from evidence this daemon saw itself): the text is typed during the call, as `send` types it (paste, then Enter), and the answer is `{"delivered": true, "submitted": true, "id": ...}`.
- **Otherwise** (the agent is working, holds a draft in its input line, or other prompts are queued ahead): the text is queued and the answer is `{"queued": true, "id": "<16 hex>", "position": N}`, `position` counting from 1 within the pane. When the first try was refused, the answer also has `"waiting_reason"` (the reason code, for example `input_not_empty`), and without `--json` a line says so. The daemon types it when the turn ends: on the main agent's Stop hook, or, for a Claude Code pane without hooks, on its regular scan (every 10s) once the screen has been unchanged for `idle_after` (30s). Several prompts for one pane go in order, one per turn end. The queue survives the app quitting and the daemon restarting; a restarted daemon types nothing until it has seen the turn end itself.

Before typing, the daemon waits for the screen to stay unchanged for 2s, then checks again, under the lock it types every prompt under, that the pane, its tmux server, its agent and its conversation (`session_id`) are the ones the prompt was queued for, that the turn is still over and no prompt was submitted since, and that the input line is empty and no dialog is open. A draft is not empty and keeps the prompt queued (reason `input_not_empty`); the grey suggestion Claude Code shows in an empty box counts as empty, but only when every character of it is read as faint, so a draft that merely looks dim stays refused. The text is pasted without Enter and Enter is pressed only once the input line shows it (or Claude Code's `[Pasted text #N` placeholder for a long paste). Text that never reached the pane goes back to the head of the queue; text that reached it, or may have, is never typed again.

A queued prompt is dropped, never typed, when its pane closed or was replaced or tmux restarted (`pane_gone`), its agent exited or was restarted, or its session ended other than by a `/clear` (`session_ended`), the pane started another conversation (`conversation_changed`), its text was pasted but Enter couldn't be confirmed (`not_submitted`; it stays in the pane), or a delivery was cut off after its paste started (`interrupted`). A prompt queued for a pane that is now waiting on a person is kept, and typed once the agent's turn ends again. These outcomes are `prompt_dequeued` events in [`events`](README.events.md); a prompt answered `queued` also records `prompt_queued`. A prompt typed during its own call records no event.

Refusals, all before anything is queued:

| `code` | When |
|---|---|
| `no_daemon` | No agent daemon runs for the workspace; nothing is queued. Start one with `workspace agentd --name WS`. |
| `not_an_agent` | The pane runs a shell. |
| `unsupported_agent` | The pane runs an agent whose screen can't be checked for an open dialog or a person's draft: Codex, OpenCode and Pi. Only Claude Code is supported. `details.kind`. |
| `pane_waiting` | The agent waits on a person (a permission prompt or question, or `AskUserQuestion`/`ExitPlanMode` is running). Answer it first. `details.reason`: `waiting` or `question_open`. |
| `queue_full` | The pane already has 8 prompts queued. `details.limit`. |
| `pane_not_ready` | The daemon hasn't scanned or identified the pane yet (`details.reason: unknown`); try again in a few seconds. |
| `usage` | `--body` is over 32 KB (`details.limit`), or `--when-idle` was given with `--keys` or `--no-enter`. |

When the call types the text itself it can also end in `not_submitted` (exit 2, `details.delivered: true`, `details.submitted: false`: pasted but not confirmed; check the pane before resending) or `not_delivered` (exit 1, `details.reason` says why the prompt was dropped instead; nothing reached the pane). A `connection_failed` or `unreadable_reply` with `details.maybe_delivered: true` means the daemon had the prompt but its answer was lost (no answer within 90s, or an unreadable one): the prompt may have been queued or typed, so check the pane (or `prompt_queued` in the events) before sending it again. In error `details`, `pane` is the pane id, as on success.

**One race is accepted.** After the last check and before Enter, the daemon reads the screen and waits for it to settle; a turn that starts in that window gets the text mid-turn, which Claude Code takes at its next step, as with `send` without `--when-idle`.

With `--json`, success prints `{"schema_version":1,"ok":true,"workspace":"api","pane":"%19","pane_id":"%19","queued":true,"id":"5f0c...","position":1}` or the same with `"delivered":true,"submitted":true` instead of `queued` and `position`. Exit codes: 0 typed or queued, 1 refused or not delivered, 2 `not_submitted`, 75 `clear_unconfirmed` (below).

#### `send --interrupt`

`--interrupt --body TEXT` replaces the two-step "press `Escape`, wait, type" with one call that no other writer can cut into. The pane is checked as for `send`, then the text goes to the workspace's agent daemon (message type `prompt_interrupt_send`), which, holding the pane and its delivery lock throughout:

1. refuses before pressing anything when the pane is not a Claude Code agent, waits on a person, is held by a restart, or its agent has no interrupt key;
2. presses the agent's interrupt keys (`Escape`, as `plan pause --interrupt` does);
3. waits up to 15s for the screen to stay unchanged for 2s with the agent's input prompt on screen and empty;
4. types the text with the same check-paste-check-Enter as `--when-idle`.

Nothing is queued: the text is typed now or not at all. A pane whose turn already ended is still interrupted (Escape at an idle prompt is harmless) and typed into. The daemon-wide delivery lock is held for the whole call, at most about 15s of waiting plus the typing, so other panes' deliveries wait meanwhile; that is what keeps any other writer from typing between the steps. Prompts already queued for the pane with `--when-idle` stay queued and go out at a later turn end. A draft in the input line is not cleared by the interrupt (and Claude Code may restore interrupted text into it), which ends as `not_ready` with `details.reason: input_not_empty` after the wait. A `connection_failed` with `details.maybe_delivered: true` may mean the agent was already interrupted. Because the prompt wait can time out after the interrupt, `not_ready` means the agent was interrupted but nothing was typed.

| Code | Meaning |
|---|---|
| `usage` | `--interrupt` without `--body`, or with `--keys`, `--no-enter`, `--when-idle` or `--clear-first`; or `--body` over 32 KB. Nothing is sent. |
| `no_daemon` | No agent daemon runs for the workspace. A daemon that predates `--interrupt` answers `error` ("restart it"). Check the `agent_send_interrupt` capability first. |
| `no_interrupt_key` | workspace knows no interrupt key for the pane's agent. `details.kind`. Nothing pressed or typed. |
| `not_an_agent`, `unsupported_agent`, `pane_waiting`, `pane_busy`, `pane_not_ready` | As for `--when-idle`; `pane_busy` here means a restart holds the pane. Nothing pressed or typed. |
| `not_ready` | Exit 1. The keys were pressed, but the prompt did not come back within 15s. `details.interrupted: true`, `details.keys`, `details.reason` (the last check). Nothing typed; the pane is already interrupted, so the same call is safe to retry. |
| `not_delivered` | Exit 1. A key press or the paste failed. `details.interrupted` says whether any key had been pressed. |

`not_submitted` (exit 2) is as for `--when-idle`. With `--json`, success prints `{"schema_version":1,"ok":true,"workspace":"api","pane":"%19","pane_id":"%19","interrupted":true,"keys":["Escape"],"delivered":true,"submitted":true}`.

#### `send --clear-first`

`--clear-first` gives the agent a fresh conversation before the text, so the caller never types `/clear` itself. It goes through the agent daemon like `--when-idle`, with the same checks, and works with or without it:

- **With `--when-idle`**, the clear happens at delivery time: now if the agent's turn has ended, else when it ends. The prompt is queued with `clear_first: true` (in `prompt_queued`). A change of conversation while it waits doesn't drop it (it is about to start a new one anyway), and the prompts queued behind it move to the conversation its clear starts.
- **Without `--when-idle`**, the clear and the text are typed now or not at all: a pane mid-turn, holding a draft, or held by a restart is refused `pane_busy` (`details.reason: not_ready`), and so is one with prompts already queued (`queued_ahead`). Nothing is queued.

At delivery the daemon checks the pane as for `--when-idle`, claims it the way `agent-run restart` does (a restart already running leaves the prompt queued, or refuses `pane_busy` without `--when-idle`), and types `/clear` with the same check-paste-check-Enter it uses for text. It then waits up to 15s for a SessionStart hook from that pane with `source: clear`, recorded after the clear was typed. A new `session_id` alone doesn't count, and a prompt submitted in the pane between the clear and that SessionStart voids it (a person typed into the pane). Once confirmed it waits for the screen to settle, checks the pane again (no prompt submitted since the clear), and types the text. The pane stays claimed until the text is typed, so `agent-run restart` and `agent status request` refuse it meanwhile (`restart_in_progress`). A prompt cancelled while the clear is being confirmed gets nothing typed after the clear.

**When the clear isn't confirmed, nothing more is typed.** A call that typed the clear itself answers `clear_unconfirmed` with `details.clear_typed: true` and exits **75**: nothing went wrong that a retry can't fix, but the conversation may or may not have been cleared, so look at the pane (or `workspace sessions --json`) before sending again. A queued prompt ends as `prompt_dequeued` with outcome `dropped` and reason `clear_unconfirmed`. Once its clear was typed a prompt never goes back to the queue: if the text then can't be typed it is dropped with reason `not_delivered` (answered `not_delivered`, exit 1, `details.clear_typed: true`), so the pane is never cleared twice for one prompt.

Only Claude Code panes whose hooks reach the daemon (`hook_mode: "hooks"` in [`sessions`](README.sessions.md)) can be confirmed. Anything else is refused `clear_unsupported` before anything is typed or queued: `details.reason` is `agent` for Codex, OpenCode and Pi (`details.kind` names it), and `no_hooks` for a Claude Code pane no hook event has reached yet (install them with `workspace init --install-hooks`, or wait for the agent's first hook event).

With `--json`, a call that cleared and typed prints `"delivered":true,"submitted":true,"cleared":true`. `--clear-first` takes `--body`; `--keys` and `--no-enter` with it are usage errors.

**`examples`** prints the full set of stock example messages (with realistic field values for the detected workspace) without sending anything. Use it to see the wire format before firing a real message.

#### `queue`

`queue list` and `queue cancel` read and write the workspace's `prompt-queue.json` directly and never ask the agent daemon, so they work with the daemon stopped or gone (the entries then wait for the next daemon). `queue list` takes the workspace from `--name`, else the working directory.

**`queue list --json`** prints `{"schema_version":1,"ok":true,"workspace":"api","entries":[...]}`. Each row is `{"id","pane_id","position","state","queued_at","clear_first","preview","length","waiting_reason","waiting_message","waiting_since"}`: `position` counts from 1 within the pane, `state` is `queued` or `delivering`, `preview` is the first 200 characters with control characters escaped (`\n`, `\r`, `\t`, `\e`, `\uXXXX`, including bidi and zero-width characters), and `length` is the full text's character count. `waiting_reason`, `waiting_message` and `waiting_since` say why the entry is still queued when the pane refused the text at its last try: the reason code (`input_not_empty` for a draft in the input line, `turn_started` for a spinner or other sign of a running turn, `pane_waiting`, ...), the wording, and when that reason first appeared (ISO 8601 UTC). All three are `null` for an entry nobody has tried yet and clear again when a try goes through. The daemon logs a `prompt_refused` event when the reason first appears or changes, not on every scan (see [`events`](README.events.md#queued-prompt-lines)). Rows are grouped by pane, the pane with the oldest `queued_at` first, each pane's rows in queue order. A pane with nothing queued lists nothing; that is not an error. The field is `pane_id`, the name `sessions --json` and the events use for the same `%N`. Without `--json`, one line per entry: pane, position, state, age, id and the preview cut to the terminal width, and under it a `waiting:` line with the reason, the wording and how long it has stood when there is one.

**`queue cancel --json`** prints `{"schema_version":1,"ok":true,"workspace":"api","cancelled":true,"id","pane_id","text"}`; `text` is the full prompt, so a caller can put it back in a prompt box. It records a `prompt_dequeued` event with outcome `cancelled` ([`events`](README.events.md)). It runs under the queue file's lock, so it never overlaps a delivery starting:

- a `queued` prompt is removed;
- one the daemon has claimed but not yet started to paste (for instance while a `--clear-first` clear is being confirmed) is marked to stop: the answer is the same plus `"cancel_requested":true`, and the delivery types nothing and removes it without a second event (cancelling it again answers the same and records no further event);
- one being pasted, already typed, dropped or never made is refused `unknown_id`, with `details.state: "delivering"` when its text may already be in the pane (check the pane). A pasted prompt whose text never landed goes back to `queued` and can be cancelled then; `queue list` shows it.

Exit codes: 0 listed or cancelled, 1 refused (`unknown_id`, `usage`, the pane codes of `send`, or a queue file that can't be read).

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

# Leave a draft in pane %19 without submitting it
workspace agent-run send --name myapp --pane %19 --body "Fix the typo in" --no-enter

# Interrupt whatever pane %19 is doing, as JSON
workspace agent-run send --name myapp --pane %19 --keys Escape --json

# Type a prompt into pane 0.1 and press Enter
workspace agent-run send --name myapp --pane 0.1 --body "Run the specs and report failures"

# Hand pane %19 its next prompt once its current turn ends
workspace agent-run send --name myapp --pane %19 --body "Now update the docs" --when-idle --json

# Interrupt pane %19, wait for its prompt, and type a new instruction, as one step
workspace agent-run send --name myapp --pane %19 --body "Stop; use the auth approach instead" --interrupt --json

# Give pane %19 a fresh conversation and its next prompt once its current turn ends
workspace agent-run send --name myapp --pane %19 --body "Start on the docs" --when-idle --clear-first --json

# See what is queued for pane %19, then take one prompt back
workspace agent-run queue list --name myapp --pane %19 --json
workspace agent-run queue cancel --id 5f0c1d2e3a4b5c6d --json

# Print examples for the current workspace without sending
workspace agent-run examples
```
