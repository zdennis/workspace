# workspace inbox

A durable list of things that need a person. Agents, scripts and outside tools post items; the person (or the app) reads them. Items live in one of three scopes: a workspace, a project (all worktrees of one repository), or global.

## Usage

```sh
workspace inbox add TITLE [--type TYPE] [--body TEXT | --body-file PATH|-] [--source-kind K] [--source-ref R] [--source-url URL]
                          [--expires DURATION|ISO] [--link-pane P] [--link-plan-task T] [--link-pr N] [--link-run R]
                          [--as-user] [scope] [--json]
workspace inbox list [--state S[,S]] [--type TYPE] [--all] [scope] [--json]
workspace inbox show ID [scope] [--json]
workspace inbox done ID... [scope] [--json]
workspace inbox dismiss ID... [scope] [--json]
workspace inbox reopen ID... [scope] [--json]
```

Scope: at most one of `--name WORKSPACE`, `--project NAME|PATH`, `--global`. Every flag accepts the `--flag=value` form.

## Examples

```sh
workspace inbox add "Check the deploy" --type todo
workspace inbox add "CI failed" --type alert --source-kind github_check --global --json
workspace inbox list --all --state open,snoozed
workspace inbox show a1b2c3d4e5
workspace inbox done a1b2c3d4e5 f6a7b8c9d0
workspace inbox dismiss a1b2c3d4e5 --json
workspace inbox reopen a1b2c3d4e5
```

## Scope

| Command | Without a scope flag |
|---|---|
| `add` | The workspace detected from the current directory; outside any, `not_in_workspace` |
| `list` | Open items of the current workspace, its project and the global list; outside a workspace, the global list. `--all` reads every scope that has a file |
| `show` | Searches every scope for the id; `ambiguous_inbox_item` if it is in more than one |
| `done`, `dismiss`, `reopen` | As `show`, once per id; an id in more than one scope is that row's `ambiguous_inbox_item` failure, so pass a scope flag |

A project is keyed by the realpath of its git common dir, so two clones with the same name stay apart.

## Item

| Field | Rules |
|---|---|
| `title` | One line, 1 to 200 characters |
| `body` | Up to 8192 characters; newlines and tabs allowed. `--body-file` reads at most 64 KB |
| `type` | `todo` (default), `alert`, `note`, `review_request` |
| `source.kind` | `jira`, `github_pr`, `github_check`, `session`, `agent`, `cli`, `user`; default follows `created_by.kind` |
| `source.ref` | Up to 200 characters |
| `source.url` | `https://` only |
| `links` | `pane`, `plan_task`, `run_id` up to 64 characters; `pr` a positive number |
| `expires_at` | From `--expires`: a duration such as `2h` or an ISO 8601 time in the future. Once passed, the item reads as `dismissed` |
| `created_by` | `kind` is `agent` when the session ledger shows an agent session open in `$TMUX_PANE`, `user` with `--as-user`, else `cli`; also `pane`, `session_id`, `tmux_server` |

Text with NUL or another control character (an escape sequence, a C1 control, a line separator) is refused as `invalid_inbox_item`; a body may hold `\n` and `\t`. Text is data: it is never run, typed into a pane or put in the event log, and human output shows any control character as an escape such as `\e`.

## Output

`add --json` prints an action document (`inbox add`, one row with outcome `created`, the `id`, the scope as a label such as `workspace:api` or `global`, and the `item`, whose own `scope` is an object with `kind`, `key` and `name`). `list --json` prints `{"schema_version":1,"ok":true,"items":[...],"warnings":[...]}`, newest `updated_at` first. `show --json` prints `{"schema_version":1,"ok":true,"item":{...},"warnings":[...]}`. A scope file that can't be parsed reads as empty with an `inbox_store_unreadable` warning (on stderr in text mode); writing to it fails with the `inbox_store_unreadable` error.

`done`, `dismiss` and `reopen` take one or more ids and print an action document (`inbox done`, `inbox dismiss`, `inbox reopen`) with one row per id: `id`, `outcome`, `scope` (a label) and the `item`. Outcomes are `resolved` (done and dismiss), `reopened`, `unchanged` (already in that state, so a retry is safe; nothing is rewritten) and `failed`, whose row carries `code` (`unknown_inbox_item`, `ambiguous_inbox_item`), `error` and `details`. The action `status` is `ok`, `partial` (exit 3) or `failed` (exit 1); rows are processed in order and each one that can be resolved is. `done` or `dismiss` stamps `resolved_at` and `resolved_by` (`kind` `cli`, or `agent` when the session ledger shows an agent session open in `$TMUX_PANE`, plus `pane`); `reopen` clears both and any snooze.

Errors use the [`--json` error envelope](README.json.md): `invalid_inbox_item`, `unknown_inbox_item`, `ambiguous_inbox_item`, `not_in_workspace`, `unknown_workspace`, `usage`.

Exit 0, 1 on an error; `done`, `dismiss` and `reopen` exit 3 when only some ids failed.
