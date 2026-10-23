# workspace ask

Record a question an unattended agent hit, along with the default it took, so it can keep going instead of blocking on a person. A human reviews and resolves open questions later.

## Usage

```sh
workspace ask [WS] "<question>" --default "<default taken>" [options]
workspace ask list [WS] [--all] [--json]
workspace ask answer [WS] <id> "<answer>" [--deliver] [--json]
workspace ask deliver [WS] <id> [--pane P] [--json]
workspace ask withdraw [WS] <id> [--json]
```

## Options (recording a question)

| Option | Description |
|--------|-------------|
| `--default TEXT` | The default the agent took (required) |
| `--context TEXT` | Free-text pointer to the code in question, e.g. `"lib/cache.rb:12"` |
| `--json` | Emit the documented JSON schema instead of a message |
| `--name WS` | Act on workspace `WS` instead of the one detected from cwd |

## Details

**Never blocks on a person** — `ask` never reads stdin. It writes the question to disk and returns; the calling agent keeps going with the default it already stated. When `alerts.notify` is configured, `ask` waits for the notify command before returning, so the command actually runs; one still going after 10 seconds is stopped.

**Subcommand words** — `list`, `answer`, `resolve` and `help` as the first word are subcommands only when `--default` is absent. Recording always takes `--default`, so `workspace ask list --default "x"` records the question "list".

**Blank input** — a question or default that is empty or only whitespace is rejected (exit 1; with `--json`, an `error` payload).

**Workspace detection** — same as other commands: the marker file, then the active project for the current directory. `ask`, `ask list`, and `ask answer` all act on the workspace detected from the current directory, or the one named with `--name` (every `ask` subcommand takes it) or as the first argument after the subcommand (`ask list api`, `ask answer api q_7 "yes"`, `ask withdraw api q_7`, `ask api "Q?" --default d`), told apart by the number of arguments. A name that has no config fails with `unknown_workspace`; with no name, outside any workspace, `ask` fails with `not_in_workspace`.

**Storage** — questions are appended to `~/.local/state/workspace/<workspace>/asks.json`, guarded by `flock` so concurrent invocations (multiple panes or agents in the same workspace) never clobber each other's writes. The file survives an agent-daemon restart; it isn't daemon state. If the file can't be parsed, `ask` and `ask answer` fail without recording anything and leave the file unchanged, while `ask list` and `sessions` warn on stderr and show no questions.

**Pane** — when run inside tmux, the question is tagged with `$TMUX_PANE`, which is how [`sessions`](README.sessions.md) attributes it to a pane. Outside tmux, the question is still recorded (with no pane), and still shown by `ask list`.

**`answer`** (alias `resolve`) marks a question answered and records the answer text. Answering an unknown id fails with "No question '\<id\>'"; answering an id that is no longer open fails with `ask_not_open` and "Question '\<id\>' was already answered" (or withdrawn) (either way, exit 1; with `--json`, `{"schema_version":1,"ok":false,"error":"..."}`).

**`answer --deliver`** also types the answer, then Enter, into the pane that asked (the question's `pane`, from `$TMUX_PANE` when it was recorded), so an agent waiting on a person gets the reply without a trip to its terminal. The pane must be in the workspace's own tmux session and is checked **before** the question is touched: a question with no pane fails with `no_pane`, a pane from another session with `wrong_session`, and a pane that has gone with `no_such_pane`, all leaving the question open. Pane ids restart from `%0` when tmux does, so the question records the tmux server it was asked under (`tmux_server`, from `$TMUX`) and `--deliver` refuses with `stale_pane` when that is no longer the running server, or when the question predates the field; answer those without `--deliver`. The answer is recorded first and then typed: if typing fails, the question stays answered and the error says so (`details.answered`, `details.question`), so don't answer it again; retry with `ask deliver ID` (the error names it in `details.retry`). Exit codes follow [`agent-run send --body`](README.agent-run.md): 2 (`not_submitted`) means the text may already be in the pane. An answer starting with `-` needs `--` before it (`ask answer --deliver q_7 -- -y`). With `--json`, a successful delivery adds `"delivered":{"pane":"%19","submitted":true}` next to `question`.

**`deliver`** types an already-answered question's recorded answer, then Enter, into its pane again, for when `answer --deliver` recorded the answer but typing failed. It uses the same pane rules as `answer --deliver` (`no_pane`, `stale_pane`, `wrong_session`, `no_such_pane`) and the same exit codes (2 when the text may already be in the pane); the store is not changed, so check the pane first: it types the answer again even if the first delivery landed. A failure names the exact retry command in `details.retry` (with `--name`, and `--pane` when given); and a delivery that fails again carries `details.retry` too. A question that is still open or withdrawn fails with `ask_not_answered` (`details.id`, `details.status`). `--pane P` (a pane id or `window.pane` of the workspace's own session) types into that pane instead, skipping the tmux-restart check since you named the pane. `--json` prints `question` and `delivered` as `answer --deliver` does.

**`list`** shows open questions. `--all` also shows answered and withdrawn ones, with a `STATUS` column; the `--json` document then holds every question, whatever its `status`.

**`withdraw`** closes an open question its asker no longer needs answered, so the agent that asked can retire its own question. The record gets `status` `"withdrawn"` and a `withdrawn_at` time; `answer` stays `null`. Only an open question can be withdrawn: one already answered or withdrawn fails with `ask_not_open` (`details.id`, `details.status`), and an unknown id with a plain error. A withdrawn question leaves `ask list` (without `--all`), [`snapshot`](README.snapshot.md) and `inbox list --include-derived`, and `ask answer` on it fails with `ask_not_open` too. `ask_withdrawn` goes to the [event log](README.event-log.md) with the id and pane only. Feature `ask_withdraw` in [`capabilities`](README.capabilities.md).

**Alerts** — when the project has `alerts.notify` configured (see [`workspace config`](README.config.md)), it runs with the same alert-type variable [`sessions`'s alerts](README.sessions.md#alerts) use:

| Variable | Value |
|----------|-------|
| `WORKSPACE_ALERT` | `question` |
| `WORKSPACE_ALERT_WORKSPACE` | The workspace name |
| `WORKSPACE_ALERT_TEXT` | One-line summary, e.g. `myapp: Use pg or sqlite? (default: sqlite)` |
| `WORKSPACE_ALERT_QUESTION` | The question text |
| `WORKSPACE_ALERT_DEFAULT` | The default the agent took |
| `WORKSPACE_ALERT_ID` | The question's id |
| `WORKSPACE_ALERT_CONTEXT` | The `--context` value, if given |
| `WORKSPACE_ALERT_PANE` | tmux pane id, if run inside tmux |

`WORKSPACE_ALERT_KIND` (the agent kind, e.g. `claude`, used by `sessions`'s waiting/idle alerts) is deliberately not set here — a question has no agent kind of its own, and reusing that variable for something else would make a notify script that switches on it see two unrelated things through the same value. With no `alerts.notify` configured, the question is recorded and nothing else happens; that is not an error.

**`--json` schema** — `{"schema_version":1,"ok":true,"question":{...}}` for `ask`/`ask answer`, `{"schema_version":1,"ok":true,"workspace":"...","questions":[...]}` for `ask list`. Each question record: `id`, `question`, `default`, `context`, `pane`, `worktree`, `tmux_server` (the tmux server's process id, when asked from tmux), `asked_at` (ISO 8601 UTC), `status` (`"open"`, `"answered"` or `"withdrawn"`), `answer`, `answered_at`, and `withdrawn_at` on a withdrawn one. A failure writes `{"schema_version":1,"ok":false,"error":"..."}` to stdout and exits 1, whether the failure is a bad invocation or the workspace couldn't be detected — matching [`workspace lock`](README.lock.md)'s `--json` contract.

## Examples

```sh
# Answer a question and type the answer into the pane that asked
workspace ask answer --deliver a1b2c3 -- yes

# Record a question and keep going with the stated default
workspace ask "Use pg or sqlite for the cache?" --default "sqlite" --context "lib/cache.rb:12"

# See what's open for the current workspace
workspace ask list

# Resolve one
workspace ask answer a1b2c3 "Use postgres instead"

# Close one nobody needs answered any more
workspace ask withdraw a1b2c3

# Script against the open questions
workspace ask list --json | jq '.questions[].question'
```
