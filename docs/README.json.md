# `--json` output

Every command that takes `--json` prints exactly one JSON value on stdout, and with `--json` nothing is written to stderr for a failure. A failure (refusal, usage error, unknown subcommand) is always the error envelope below. Success is an enveloped object for every command except the three listed under [Success output without the envelope](#success-output-without-the-envelope).

## Success

```json
{"schema_version":1,"ok":true,"workspaces":[],"warnings":[]}
```

`schema_version` and `ok` come first, then the command's own keys (see each command's page).

### Success output without the envelope

These commands keep their original success shape, which other tools already parse. Their failures still use the envelope, so check for `ok` being `false` before reading the success shape.

| Command | Success shape |
|---|---|
| `list --json` | A bare array: names, or objects with `--show-urls`, `--liveness` or `--all`. |
| `status --json` | A bare object keyed by project name (`{}` when nothing is tracked). |
| `parent --json` | A bare object with `name`, `path`, `git_common_dir`, `is_worktree`, `worktree`; no `schema_version` or `ok`. |

Wrapping these in the envelope would change what existing callers parse, so it is later work and not part of CLI10. CLI12 and CLI13 in the implementation plan do not name it.

To ask which of these a given CLI supports, run `workspace capabilities --json` (see [capabilities](README.capabilities.md)).

## Actions

These commands take `--json` and print one action document: `launch`, `stop`, `kill`, `relaunch`, `restore`, `focus`, `repair`, `cleanup`, `deactivate`, `reactivate`, `dev up`, `dev down`, `lock release`, `config set`, `daemon restart`, `agentd restart`, `pipeline start`, `pipeline advance`, `pipeline reset`, `ui open`, `binding set`, `binding show`, `binding clear`, `library add`, `library update` and `library remove`. (`finish`, `start`, `lock clear` and `projects stop|kill` have their own pages; `projects stop|kill` use the same shape.)

```json
{"schema_version":1,"ok":true,"action":"stop","status":"ok",
 "results":[{"workspace":"api","outcome":"stopped","reason":null,"message":null}],
 "warnings":[],"summary":{"stopped":1}}
```

- `action` is the command's words: `launch`, `dev up`, `lock release`, `config set`, `pipeline start`.
- `results` has one row per target with `workspace` (null when the command has none, such as a global `config set`), `outcome`, `reason` (a short machine-readable cause, or null) and `message`. A row may carry more keys, named on the command's page (`iterm_window_id` for `launch` and `focus`, `play` for `launch --play`, `key` and `value` for `config set`, `work_item_ref` for `pipeline`).
- `outcome` is per command (see its page). `failed` and `refused` count as failures.
- `status` is `ok` (no row failed), `partial` (some did), `failed` (all did, or the command exited non-zero), `cancelled` (a prompt was declined; nothing changed), `dry_run` (`--dry-run` reported the plan; nothing changed), or `refused` (a preflight check refused every target; nothing changed).
- `ok` is `true` for every action document, including `failed`: it means the command ran and reports per-row outcomes. Check `status` and the exit code. A refusal or usage error is the failure envelope above, with `ok: false`.
- `summary` counts rows by `outcome`. `warnings` is a list of strings, each a sentence for a person to read; it is empty when there is nothing to say.
- The exit code is 0 for `ok`, `cancelled` and `dry_run`, 3 for `partial`, and 1 for `failed` and `refused`, except that a command that exits with its own code (`dev up` exits 75 after `--max-wait`) keeps it.
- The progress text a command prints goes to stderr, so stdout holds the one document. A command that reports only an exit code (`dev up`, `dev down`, `lock release`) gives a `failed` row with `reason: "exit_code"` and `exit_code`; the explanation is on stderr.
- `kill` ends the tmux session last. Run it from outside the session it kills, or the process can end before the document prints.
- `stop` with `--json` does not warn about a named workspace that isn't active; it gives that workspace a `not_running` row.
- `agent run --json` is not an action document. It prints `{"schema_version":1,"ok":true,"workspace":"api","work_item_ref":"wi_12","dispatch_id":"agent-run-ab12cd34","dry_run":false,"reply":{...}}`, where `reply` is the agent's reply as is, including its own `ok`. The exit code is 0 whatever the reply says; read `reply.ok`. With `--dry-run` there is `message` (what would be sent) and no `reply`.

## Snapshot

`snapshot --json` prints one read-only document of everything a UI polls (see [`snapshot`](README.snapshot.md)). `--json` is required; a source that can't answer is reported as unavailable (null fields, `daemons_unavailable` rows, `warnings`) rather than as clean, and the command still succeeds. Its `cursor` is `ev:<inode>:<byte offset>` of the event log.

## Failure

```json
{"schema_version":1,"ok":false,"error":"Unknown project 'api'","code":"unknown_workspace","details":{"name":"api"}}
```

- `error` is the message a person would read.
- `code` is one of the codes below. A code never changes meaning; renaming or repurposing one is a `schema_version` bump.
- `details` is machine data, present only when the command has some.
- `retry` is present only when a flag turns the refusal into a forced run: `{"flags":["--force"],"destructive":true}`.

The exit code is unchanged by `--json` (1 for most failures, 2 for `not_submitted`).

`--json` is found as its own argument anywhere before a bare `--`, so `workspace parent --json` and `workspace parent --json app` both ask for it, and `workspace run app -- cmd --json` passes `--json` through to the command.

## Never prompting

`--no-input`, or `WORKSPACE_NO_INPUT=1` (empty, `0` and `false` mean off), works on every command and may appear anywhere before a bare `--`. A prompt that would have read stdin fails with `confirmation_required` instead, before anything is printed or read: `details.prompt` is the question and `retry.flags` the flag that answers it (`--force` for `kill`, `cleanup` and `prune`; `--yes` for `projects kill`), with `retry.destructive` true. Prompts with no such flag, like choosing a branch, give no `retry`. Commands that never prompt are unaffected; `session-event` still reads its hook payload from stdin.

## Error codes

| Code | Meaning |
|---|---|
| `error` | Any failure without a more specific code. |
| `usage` | A bad option, a missing or extra argument, or an unknown subcommand. |
| `unknown_workspace` | The named workspace isn't known. `details.name`. |
| `not_in_workspace` | No workspace could be detected from the working directory. `details.path`. |
| `no_daemon` | No agent daemon is running for the workspace. |
| `connection_failed` | The agent daemon's socket refused or dropped the connection. |
| `unreadable_reply` | The agent daemon's reply couldn't be read. |
| `unsaved_work` | The worktree has uncommitted changes or unpushed commits. `details` has the counts; `retry` is `--force`. |
| `unsaved_unknown` | git couldn't tell whether the worktree has unsaved work. `retry` is `--force`. |
| `not_submitted` | Text reached the pane but wasn't confirmed submitted; check before resending. |
| `confirmation_required` | A prompt would have read stdin while `--no-input` or `WORKSPACE_NO_INPUT` was set. `details.prompt` is the question; `retry` names the flag that answers it, when there is one (`--force` or `--yes`, destructive). |
| `no_session` | The workspace has no running tmux session. `details.workspace`. |
| `bad_keys` | `agent-run send --keys` named something that isn't a tmux key name, or too many keys. `details.keys`. |
| `no_pane` | The question wasn't asked from a tmux pane, so `ask answer --deliver` has nowhere to type. `details.question`. |
| `stale_pane` | `ask answer --deliver` can't be sure the question's pane is the one that asked: tmux restarted since, or the question was recorded without the tmux server. `details.question`, `details.pane`. |
| `focus_failed` | tmux couldn't select the pane for `focus --pane`; the window is already in front. |
| `checkout_missing` | The workspace's checkout directory no longer exists. |
| `config_parse` | A config file exists but can't be parsed as a YAML mapping. `details.path` and `details.reason`. |

The registry lives in `Workspace::ErrorCodes`; a spec checks that every code a raise site names is listed there and on this page. More codes arrive with the commands that need them.

### Agent daemon codes

`agent-run` and `pipeline` pass through the code the agent daemon replied with.

| Code | Meaning |
|---|---|
| `malformed_message` | The daemon couldn't parse the request. |
| `internal_error` | The daemon failed while handling the request. |
| `wrong_workspace` | The request named a different workspace than the daemon's. |
| `unknown_type` | The daemon doesn't know the request type. |
| `no_active_pipeline` | No pipeline work item is in flight. |
| `stale_token` | The pipeline token no longer matches the in-flight item. |
| `no_next_stage` | The pipeline has no stage after the current one. |
| `not_delivered` | The text never reached the pane, or `send --keys` stopped partway (`details.keys_sent`); safe to resend. |
| `missing_prompt` | restart needs a non-empty prompt. |
| `missing_pane` | restart needs a pane. |
| `bad_pane` | The pane reference isn't a pane id, window.pane, or index (`send`, `focus --pane` and `ask answer --deliver` accept only a pane id or window.pane). |
| `bad_timeout` | The timeout isn't a number of seconds in range. |
| `wrong_session` | The pane belongs to another tmux session. `details.pane`, `details.session` (also from `send`, `focus --pane`, `ask answer --deliver`). |
| `no_such_pane` | No pane matches the reference. `details.pane` (also from `send`, `focus --pane`, `ask answer --deliver`). |
| `pane_gone` | The pane closed before or during the restart. |
| `pane_busy` | The pane didn't go quiet in time; nothing was typed. |
| `pane_in_pipeline` | A pipeline stage is running on the pane; pass force to restart it. |
| `not_an_agent` | The pane is running a shell, not a coding agent. |
| `unsupported_agent` | The pane's agent can't be restarted. |
| `context_unavailable` | The agent can't report context usage, so /clear can't be confirmed. |
| `context_unknown` | The agent's context usage couldn't be read. |
| `clear_not_confirmed` | /clear was typed but a new conversation didn't appear. |
| `restart_in_progress` | A restart is already running on the pane. |
| `agent_stopped` | The agent stopped during the restart. |
| `not_bound` | The pane isn't bound to a run, review or play (`binding show`, `binding clear`). |
| `unknown_library_entry` | No library entry has that name in the scopes searched. `details.ref`, `details.scopes` in the order searched, e.g. `["project:api", "global", "builtin"]` (see [`library`](README.library.md)). |
| `ambiguous_library_entry` | A bare library name matches more than one kind. `details.ref`, `details.candidates`. |
| `library_entry_exists` | `library add` would replace an entry with different content. `details.ref`, `details.scope`; `retry` names `--force` (destructive). |
| `library_source_missing` | The file to add doesn't exist, or a linked entry's target can't be read. `details.ref`, `details.path`. |
