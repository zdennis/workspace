# workspace inbox

A durable list of things that need a person. Agents, scripts and outside tools post items; the person (or the app) reads them. Items live in one of three scopes: a workspace, a project (all worktrees of one repository), or global.

## Usage

```sh
workspace inbox add TITLE [--type TYPE] [--body TEXT | --body-file PATH|-] [--source-kind K] [--source-ref R] [--source-url URL]
                          [--dedupe-key KEY [--reopen]] [--expires DURATION|ISO] [--link-pane P] [--link-plan-task T] [--link-pr N] [--link-run R]
                          [--as-user] [scope] [--json]
workspace inbox add --from-json PATH|- [--json]
workspace inbox list [--state S[,S]] [--type TYPE] [--all] [scope] [--json]
workspace inbox show ID [scope] [--json]
workspace inbox edit ID [--title TEXT] [--body TEXT | --body-file PATH|-] [--expires DURATION|ISO | --no-expires]
                       [--link-pane P] [--link-plan-task T] [--link-pr N] [--link-run R] [scope] [--json]
workspace inbox done ID... [scope] [--json]
workspace inbox done --dedupe-key KEY [scope] [--json]
workspace inbox dismiss ID... [scope] [--json]
workspace inbox dismiss --dedupe-key KEY [scope] [--json]
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
workspace inbox add "CI failed" --type alert --dedupe-key github_check:zdennis/api:rspec:9f3c2e1 --global
workspace inbox done --dedupe-key github_check:zdennis/api:rspec:9f3c2e1 --global
workspace inbox reopen a1b2c3d4e5
```

## Adding from JSON

`add --from-json PATH|-` takes the whole item from one JSON object, read from a file or stdin (64 KB at most). Use it alone: a title, scope flag or item flag with it is a `usage` error; only `--json` goes with it. The output is the same as `add`.

```sh
echo '{"title":"CI failed","type":"alert","source":{"kind":"github_check","ref":"api#412"},"scope":{"kind":"global"}}' \
  | workspace inbox add --from-json - --json
```

| Key | Value |
|---|---|
| `title` | Required string |
| `type`, `body`, `expires_at` | Strings; the same rules as `--type`, `--body`, `--expires` (`expires_at` may be a duration or an ISO 8601 time) |
| `source` | Object with `kind`, `ref`, `url` |
| `links` | Object with `pane`, `plan_task`, `run_id` (strings) and `pr` (a positive integer) |
| `scope` | `{"kind": "global"}`, or `{"kind": "workspace" or "project", "name": "..."}`; left out, the workspace of the current directory |
| `dedupe_key` | A string or `null`; a string makes the add an upsert (see Dedupe). `--reopen` has no key here: to reopen a resolved item by key, use the flag form |

Any other key, a value of the wrong type, a non-object, invalid JSON or UTF-8, or input over 64 KB is `invalid_inbox_item` (`details.field` names the key, such as `state` or `source.host`; `json` for the document itself). Every field then passes the checks in the table below, and nothing is written when one fails.

## Dedupe

`add --dedupe-key KEY` (or `dedupe_key` in `--from-json`) adds an item once per key and scope, so a poster that repeats itself never duplicates. A key is 1 to 200 characters of `A-Z a-z 0-9 . _ : / # @ -`; anything else is `invalid_inbox_item` with `details.field` `dedupe_key`. The outcome says what happened:

| Outcome | When | What changes |
|---|---|---|
| `created` | No item in the scope holds the key | A new open item |
| `updated` | An open or snoozed item holds it | `title`, `body`, `source`, `links`, `expires_at` and `updated_at` (a field the repeat leaves out is cleared; every repeat stamps `updated_at` and writes `inbox_changed`; `type` is not changed); `id`, `state` and `snooze_until` stay |
| `suppressed` | A done, dismissed or expired item holds it | Nothing: a person who dismissed an alert is not nagged. The row carries the existing item |
| `reopened` | As `suppressed`, with `--reopen` | The item opens with the new fields |

The check and the write happen under one lock, so two processes upserting one key leave one item. A CI failure should key on the check and the head SHA (`github_check:<repo>:<check>:<sha>`): a new push that fails again is a new key. `--reopen` without `--dedupe-key` is a `usage` error.

`done --dedupe-key KEY` and `dismiss --dedupe-key KEY` resolve the item holding the key, which is how a poster clears its own alert. They take no ids. Unlike `done ID`, which searches every scope, the scope is the one `add` uses (a scope flag, else the workspace of the current directory, else `not_in_workspace`). The single row has `dedupe_key` and the item's `id`; with no match it is `unchanged` (`id` and `item` are `null`) and the exit code is 0, so a retry is safe.

## Scope

| Command | Without a scope flag |
|---|---|
| `add` | The workspace detected from the current directory; outside any, `not_in_workspace` |
| `list` | Open items of the current workspace, its project and the global list; outside a workspace, the global list. `--all` reads every scope that has a file |
| `show` | Searches every scope for the id; `ambiguous_inbox_item` if it is in more than one |
| `edit` | As `show`: searches every scope; `ambiguous_inbox_item` if the id is in more than one |
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

`edit` changes the title, body, expiry and links of one item, in any state (an edit never reopens a done or dismissed item). Pass at least one option; a missing one leaves that field as it is. Each value is checked like `add` (`invalid_inbox_item` names the field, and nothing is written when any is refused). An empty `--body` or link value clears it (`--link-pr ""` too), and `--no-expires` drops the expiry. The action document (`inbox edit`) has one row, outcome `updated`, or `unchanged` when every value is what the item already holds (nothing is rewritten, `updated_at` stays; a relative `--expires` such as `2h` is a new time each call, so repeating it is `updated`). An empty `--body-file` is refused (`--body ""` clears the body). An unknown or ambiguous id is the command's error, not a row. `type`, `source`, `scope` and the dedupe key are not editable.

Each `created`, `updated`, `resolved` or `reopened` outcome (an `edit` that changed something is `updated`) writes one `inbox_changed` event with ids and states only (see [`event-log`](README.event-log.md#state-and-lifecycle-events)); `unchanged`, `suppressed` and `failed` rows write none, and an event log that cannot be written does not fail the command.

Errors use the [`--json` error envelope](README.json.md): `invalid_inbox_item`, `unknown_inbox_item`, `ambiguous_inbox_item`, `inbox_store_unreadable`, `not_in_workspace`, `unknown_workspace`, `usage`.

`workspace capabilities --json` reports `features.inbox: 1` for these commands.

Exit 0, 1 on an error; `done`, `dismiss` and `reopen` exit 3 when only some ids failed.
