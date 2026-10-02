# `--json` output

Every command that takes `--json` prints exactly one JSON object on stdout. That holds for success, refusal, usage error and unknown subcommand alike; with `--json` nothing is written to stderr for a failure.

## Success

```json
{"schema_version":1,"ok":true,"workspaces":[],"warnings":[]}
```

`schema_version` and `ok` come first, then the command's own keys (see each command's page).

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
| `not_delivered` | The text never reached the pane; safe to resend. |
| `missing_prompt` | restart needs a non-empty prompt. |
| `missing_pane` | restart needs a pane. |
| `bad_pane` | The pane reference isn't a pane id, window.pane, or index. |
| `bad_timeout` | The timeout isn't a number of seconds in range. |
| `wrong_session` | The pane belongs to another tmux session. |
| `no_such_pane` | No pane matches the reference. |
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
