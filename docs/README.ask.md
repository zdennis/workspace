# workspace ask

Record a question an unattended agent hit, along with the default it took, so it can keep going instead of blocking on a person. A human reviews and resolves open questions later.

## Usage

```sh
workspace ask "<question>" --default "<default taken>" [options]
workspace ask list [--json]
workspace ask answer <id> "<answer>" [--json]
```

## Options (recording a question)

| Option | Description |
|--------|-------------|
| `--default TEXT` | The default the agent took (required) |
| `--context TEXT` | Free-text pointer to the code in question, e.g. `"lib/cache.rb:12"` |
| `--json` | Emit the documented JSON schema instead of a message |

## Details

**Never blocks on a person** — `ask` never reads stdin. It writes the question to disk and returns; the calling agent keeps going with the default it already stated. When `alerts.notify` is configured, `ask` waits for the notify command before returning, so the command actually runs; one still going after 10 seconds is stopped.

**Subcommand words** — `list`, `answer`, `resolve` and `help` as the first word are subcommands only when `--default` is absent. Recording always takes `--default`, so `workspace ask list --default "x"` records the question "list".

**Blank input** — a question or default that is empty or only whitespace is rejected (exit 1; with `--json`, an `error` payload).

**Workspace detection** — same as other commands: the marker file, then the active project for the current directory. `ask`, `ask list`, and `ask answer` all act on the workspace detected from the current directory.

**Storage** — questions are appended to `~/.local/state/workspace/<workspace>/asks.json`, guarded by `flock` so concurrent invocations (multiple panes or agents in the same workspace) never clobber each other's writes. The file survives an agent-daemon restart; it isn't daemon state. If the file can't be parsed, `ask` and `ask answer` fail without recording anything and leave the file unchanged, while `ask list` and `sessions` warn on stderr and show no questions.

**Pane** — when run inside tmux, the question is tagged with `$TMUX_PANE`, which is how [`sessions`](README.sessions.md) attributes it to a pane. Outside tmux, the question is still recorded (with no pane), and still shown by `ask list`.

**`answer`** (alias `resolve`) marks a question answered and records the answer text. Answering an unknown id fails with "No question '\<id\>'"; answering an already-answered id fails with "Question '\<id\>' was already answered" (either way, exit 1; with `--json`, `{"schema_version":1,"ok":false,"error":"..."}`).

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

**`--json` schema** — `{"schema_version":1,"question":{...}}` for `ask`/`ask answer`, `{"schema_version":1,"workspace":"...","questions":[...]}` for `ask list`. Each question record: `id`, `question`, `default`, `context`, `pane`, `worktree`, `asked_at` (ISO 8601 UTC), `status` (`"open"` or `"answered"`), `answer`, `answered_at`. A failure writes `{"schema_version":1,"ok":false,"error":"..."}` to stdout and exits 1, whether the failure is a bad invocation or the workspace couldn't be detected — matching [`workspace lock`](README.lock.md)'s `--json` contract.

## Examples

```sh
# Record a question and keep going with the stated default
workspace ask "Use pg or sqlite for the cache?" --default "sqlite" --context "lib/cache.rb:12"

# See what's open for the current workspace
workspace ask list

# Resolve one
workspace ask answer a1b2c3 "Use postgres instead"

# Script against the open questions
workspace ask list --json | jq '.questions[].question'
```
