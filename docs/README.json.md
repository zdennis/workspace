# `--json` output

Every command that takes `--json` prints exactly one JSON value on stdout, and with `--json` nothing is written to stderr for a failure. A failure (refusal, usage error, unknown subcommand) is always the error envelope below. Success is an enveloped object for every command except three, which print their bare document under `--json` and the envelope under `--json-envelope`; see [Success output without the envelope](#success-output-without-the-envelope).

## Success

```json
{"schema_version":1,"ok":true,"workspaces":[],"warnings":[]}
```

`schema_version` and `ok` come first, then the command's own keys (see each command's page).

### Success output without the envelope

With `--json` these commands keep their original success shape, which other tools already parse. Their failures use the envelope with either flag, so check for `ok` being `false` before reading the success shape. `--json-envelope` (it implies `--json`) opts in to the envelope for one call.

| Command | Success shape |
|---|---|
| `list --json` | A bare array: names, or objects with `--show-urls`, `--liveness` or `--all`. |
| `status --json` | A bare object keyed by project name (`{}` when nothing is tracked). |
| `parent --json` | A bare object with `name`, `path`, `git_common_dir`, `is_worktree`, `worktree`; no `schema_version` or `ok`. |

| Command | With `--json-envelope` |
|---|---|
| `list` | `{"schema_version":1,"ok":true,"workspaces":[...],"warnings":[]}`; `workspaces` is the array `--json` prints (also with `--all`, `--show-urls`, `--liveness`). |
| `status` | `{"schema_version":1,"ok":true,"status":{...},"warnings":[]}`; `status` is the object `--json` prints. |
| `parent` | `{"schema_version":1,"ok":true,"parent":{...},"warnings":[]}`; `parent` holds `name`, `path`, `git_common_dir`, `is_worktree`, `worktree`. |

`warnings` is always a list (empty today). The bare `--json` default stays until a later major version. It is a per-call flag, not a config key, so a caller states which shape it parses in the command itself.

To ask which of these a given CLI supports, run `workspace capabilities --json` (see [capabilities](README.capabilities.md)).

## Actions

These commands take `--json` and print one action document: `add`, `launch`, `stop`, `kill`, `relaunch`, `restore`, `focus`, `repair`, `cleanup`, `deactivate`, `reactivate`, `dev up`, `dev down`, `dev wait`, `dev leave`, `lock release`, `config set`, `config unset`, `config edit`, `daemon restart` (also with `--all`), `agentd restart`, `pipeline start`, `pipeline advance`, `pipeline reset`, `prune`, `ui open`, `binding set`, `binding show`, `binding clear`, `library add`, `library update`, `library remove`, `workflow run`, `workflow resume`, `workflow cancel`, `workflow approve`, `workflow reject` and `step done`. (`finish`, `start`, `lock clear` and `projects stop|kill` have their own pages; `projects stop|kill` use the same shape.)

```json
{"schema_version":1,"ok":true,"action":"stop","status":"ok",
 "results":[{"workspace":"api","outcome":"stopped","reason":null,"message":null}],
 "warnings":[],"summary":{"stopped":1}}
```

- `action` is the command's words: `launch`, `dev up`, `lock release`, `config set`, `config edit`, `pipeline start`.
- `results` has one row per target with `workspace` (null when the command has none, such as a global `config set`), `outcome`, `reason` (a short machine-readable cause, or null) and `message`. A row may carry more keys, named on the command's page (`iterm_window_id` for `launch` and `focus`, `play` for `launch --play`, `prompt_sent` and `pane` for `launch` and `pane` for `run --json`, `key`, `value`, `global`, `scope`, `layer`, `file`, `comments_preserved` and `effective` for `config set`, the same without `value` for `config unset` (whose `outcome` is `unset`, or `noop` when the key was not set in that file and nothing was written), `effective` keeping the type `config show` uses for the key (a number may be a float, a boolean may be a string), `work_item_ref` for `pipeline`, `run` for `workflow`, and `run_id`, `step`, `attempt` and `reported` for `step done`).
- `outcome` is per command (see its page). `failed` and `refused` count as failures.
- `status` is `ok` (no row failed), `partial` (some did), `failed` (all did, or the command exited non-zero), `cancelled` (a prompt was declined; nothing changed), `dry_run` (`--dry-run` reported the plan; nothing changed), or `refused` (a preflight check refused every target; nothing changed).
- `ok` is `true` for every action document, including `failed`: it means the command ran and reports per-row outcomes. Check `status` and the exit code. A refusal or usage error is the failure envelope above, with `ok: false`.
- `summary` counts rows by `outcome`. `warnings` is a list of strings, each a sentence for a person to read; it is empty when there is nothing to say.
- `rebase --json` is a single result document, not an action document: it exits 0 for every `outcome`, `conflict` and `default_not_updated` included, so a script must read `outcome`. An error (the envelope above) exits 1. When git runs past its time limit during the rebase, the rebase is aborted and the error carries `details.aborted: true` (code `error`); if the abort fails, the code is `rebase_in_progress` with `details.aborted: false`.
- The exit code is 0 for `ok`, `cancelled` and `dry_run`, 3 for `partial`, and 1 for `failed` and `refused`, except that a command that exits with its own code (`dev up` exits 75 after `--max-wait`, `dev wait` after its own) keeps it.
- The progress text a command prints goes to stderr, so stdout holds the one document. A command that reports only an exit code (`dev up`, `dev down`, `dev wait`, `lock release`) gives a `failed` row with `reason: "exit_code"` and `exit_code`; the explanation is on stderr.
- `kill` adds `"notes_inside_worktree":{"dir":"/abs","files":3}` to its row, and a sentence to `warnings`, when the workspace's notes directory was inside the removed worktree and held files; the key is absent otherwise. `kill` also adds `"dev_stopped": true` to its row when it stopped the worktree's dev environment first; the key is absent otherwise. `finish` and `start` have their own pages (`finish` has both keys at the top level; `start` gains `notes_dir`).
- `config edit --json` opens no editor. Its one row has `outcome: "ready"`, `workspace` (the name whose file it is, null for the global file), `global`, `scope`, `layer`, `file` (the path) and `created` (true when the file was absent and a comment-header stub was written). See [`config`](README.config.md#config-edit).
- `kill` ends the tmux session last. Run it from outside the session it kills, or the process can end before the document prints.
- `stop` with `--json` does not warn about a named workspace that isn't active; it gives that workspace a `not_running` row. When iTerm2 does not answer within 5 seconds, `stop` still stops the workspace and leaves its window open; `warnings` says so.
- `agent run --json` is not an action document. It prints `{"schema_version":1,"ok":true,"workspace":"api","work_item_ref":"wi_12","dispatch_id":"agent-run-ab12cd34","dry_run":false,"reply":{...}}`, where `reply` is the agent's reply as is, including its own `ok`. The exit code is 0 whatever the reply says; read `reply.ok`. With `--dry-run` there is `message` (what would be sent) and no `reply`.

## Snapshot

`snapshot --json` prints one read-only document of everything a UI polls (see [`snapshot`](README.snapshot.md)). `--json` is required; a source that can't answer is reported as unavailable (null fields, `daemons_unavailable` rows, `warnings`) rather than as clean, and the command still succeeds. Its `cursor` is `ev:<inode>:<byte offset>` of the event log.

## Failure

```json
{"schema_version":1,"ok":false,"error":"Unknown workspace 'api'","code":"unknown_workspace","details":{"name":"api"}}
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
| `workspace_name_case_conflict` | A new workspace would have a name that differs only in case from an existing workspace with a different directory (`add`, `launch PATH`, `start`). The existing one is renamed to lowercase the next time its agentd starts. `details.name`, `details.existing`, `details.existing_root`. |
| `not_in_workspace` | No workspace could be detected from the working directory. `details.path`. |
| `no_daemon` | No agent daemon is running for the workspace. |
| `connection_failed` | The agent daemon's socket refused or dropped the connection. |
| `unreadable_reply` | The agent daemon's reply couldn't be read. |
| `unsaved_work` | The worktree has uncommitted changes or unpushed commits. `details` has the counts; `retry` is `--force`. |
| `unsaved_unknown` | git couldn't tell whether the worktree has unsaved work. `retry` is `--force`. |
| `not_prunable` | prune: a `--name` is not a prune candidate (text mode; with `--json` it is a failed row). `details.names`. |
| `prune_remove_failed` | prune --json: a row's `error` when git refused to remove the worktree (locked, for example). Appears in rows only. |
| `session_running` | remove: the workspace's tmux session is up; stop it first. `details.name`, `details.session`. |
| `not_removable` | remove: the workspace is a worktree project; use `kill`, `finish` or `prune`. `details.name`, `details.root`. |
| `not_submitted` | Text reached the pane but wasn't confirmed submitted; check before resending. |
| `confirmation_required` | A prompt would have read stdin while `--no-input` or `WORKSPACE_NO_INPUT` was set, or `plan delete` was run without `--yes` (`details.name`, `details.path`, `retry.flags` `["--yes"]`). `details.prompt` is the question; `retry` names the flag that answers it, when there is one (`--force` or `--yes`, destructive). |
| `no_session` | The workspace has no running tmux session. `details.workspace` (from `send`, `focus --pane`, `ask answer --deliver`, `agent-run restart`, `handoff`). |
| `bad_keys` | `agent-run send --keys` named something that isn't a tmux key name, or too many keys. `details.keys`. |
| `no_pane` | The question wasn't asked from a tmux pane, so `ask answer --deliver` has nowhere to type (`details.question`); or `agent status post` was run outside a tmux pane (`$TMUX_PANE` unset). |
| `stale_pane` | `ask answer --deliver` can't be sure the question's pane is the one that asked: tmux restarted since, or the question was recorded without the tmux server. `details.question`, `details.pane`. |
| `focus_failed` | tmux couldn't select the pane for `focus --pane`; the window is already in front. |
| `saved_window_offscreen` | `launch` found a saved window position on no connected screen and tiled the window instead. A warning on stderr (`Warning: saved_window_offscreen: ...`) and in `--json` `warnings`, never an error. |
| `window_position_unreadable` | `launch` could not read a workspace's `window.json`, tiled the window instead and left the file alone. A warning on stderr and in `--json` `warnings`, never an error. |
| `launcher_pane_missing` | `launch` still had no iTerm pane for a workspace after one retry. Reported as a warning on stderr (`Warning: launcher_pane_missing: Failed to create panes for: ...`), never an error; that workspace is not started in a pane. |
| `no_window` | `focus` found no iTerm window recorded for the workspace. `details.workspace`. |
| `no_windows_to_cycle` | `focus --cycle` found no tracked workspace with a live iTerm window. |
| `window_gone` | `focus` found that the recorded iTerm window no longer exists. `details.workspace`, `details.iterm_window_id`. |
| `checkout_missing` | The workspace's checkout directory no longer exists. |
| `config_parse` | A config file exists but can't be parsed as a YAML mapping. `details.path` and `details.reason`. |
| `unknown_config_key` | `config set`, `get`, `unset` or `show <key>` was given a key that is not a config key, or `config keys QUERY` matched no key. `details.key`. (Before this code existed these commands reported `usage`; the exit code is still 1.) |
| `scope_not_allowed` | `config set`, `get` or `unset` named a `--scope` the key doesn't allow (a global-only key at `project`, a project-only key at `workspace` in a worktree, ...). `details.key`, `details.scope` (the scope as typed) and `details.allowed`, the scopes the key does allow, lowest first (`global`, `project`, `workspace`). Nothing is written. |
| `editor_failed` | `config edit` could not open the editor: `$VISUAL` or `$EDITOR` is not a valid command (an unbalanced quote), or the editor could not be run or exited non-zero. `details.path` is the file to edit by hand. |
| `notes_dir_unresolved` | `notes dir` (and `handoff new` with no doc given) can't work out the directory: the project's `notes.default_dir` rule uses `{branch}` and the checkout is on a detached HEAD. `details.name`, `details.path` (the checkout). |
| `template_outdated` | `start --agent-kind codex` (or any kind but `claude`) found no Claude Code pane in the installed worktree template to swap. Run `workspace init --force` to refresh the template. `details.kind`. Nothing was created. |
| `unknown_agent_kind` | `start --agent-kind` named a kind that is not a known coding agent, or `hooks uninstall --agent` named one workspace installs no hooks for. `details.kind` is what was given and `details.known` the keys that work. Nothing was created or changed. |
| `hook_settings_unreadable` | `hooks uninstall` (and, as a warning, `init`, `start`, `doctor --fix`) found a coding agent's hook settings file that is not valid JSON, or not an object with a `hooks` object, and left it alone. `details.path` is the file. |
| `handoff_unsupported_agent` | `start --handoff` or `launch --handoff` was given for a project whose main agent is not Claude Code or Codex, so the `handoff` pack would not work. `details.kind` is the agent found (`opencode`, `pi`), or `none` when the project config runs no known agent. Nothing was created. The config key `handoff.auto` never raises it: there the pack is skipped with a warning (see [`handoff`](README.handoff.md#automatic-handoff)). |
| `notes_dir_unwritable` | `notes dir --create` couldn't make the directory or list it in `info/exclude`, or a `plan` verb couldn't write or rename the plan file. `details.path` is the directory. |
| `unknown_group` | `projects group add` or `plan status --group` named a group that no file in `~/.config/workspace/groups/` matches (by id, slug or name). `details.group`. |
| `group_exists` | `projects group create`: a group with that slug already has a file. `details.group`, `details.path`. |
| `invalid_group_name` | `projects group create`: the name has no letters or digits, has a control character, or makes a slug over 64 characters. `details.name`. |
| `repository_in_group` | `projects group add`: the repository is already in another group; a repository is in at most one. `details.repository`, `details.group`, `details.path` (the other group's file). |
| `not_a_repository` | `projects group add`: the path is not inside a git checkout. `details.path`. |
| `group_not_supported` | `projects stop`, `kill`, `show` or `members` was given a `group:` id. Act on each repository's project instead, or read the group with `projects group show`. `details.id`. |
| `unknown_template` | `spine init --template NAME` (or the default) found no `spine` library entry of that name, or the name is not lowercase letters, digits and hyphens. `details.template`, `details.scopes` in the order searched, `details.source` (`flag`, `worktree`, `project`, `global` or `default`: where the name came from; see [`spine`](README.spine.md)). Nothing was written. |
| `no_plan` | `plan show`, `start`, `pause` or `delete` found no `IMPLEMENTATION_PLAN.md` in the workspace's notes directory. `details.name`, `details.path`. |
| `not_a_directory` | `add --json`: a path is not a directory. In `add --json` it is the `reason` of that path's `failed` row, not an envelope; `projects group add` fails with it as an error envelope. `details.path`. |
| `plan_exists` | `plan init` found a plan already there and `--force` was not given. `details.path`. |
| `plan_done` | `plan start` or `plan pause` found a plan that is done (`status: done`, or nothing left to do). `details.name`, `details.path`. |
| `plan_write_conflict` | The plan file changed twice while a `plan` verb was writing it, so nothing was written; run the verb again. `details.path`. |
| `no_spine` | `spine set`, `spine check`, `spine goal set` or `spine start` found no `spine/` folder in the workspace's notes directory (`details.workspace`, `details.dir`). |
| `stage_done` | `spine start` named a stage whose file says `completed` or `skipped`; reopen it with `spine set --status in_progress`. `details.workspace`, `details.path`, `details.status`. |
| `stage_waiting` | `spine start`: a stage named in the stage's `depends_on` is not `completed` or `skipped` by its file (a folder-only stage by its sub-stages). `details.workspace`, `details.path`, `details.waits_on`. |
| `stage_owned` | `spine start`: the stage's owner pane is working on it, and another pane (or `--spawn`) was asked for. `details.workspace`, `details.path`, `details.owner`. |
| `unknown_stage` | `spine set`, `spine start` or `spine show --stage` was given a stage path no stage has (`details.path`, `details.stages` lists the paths there are). |
| `unknown_item` | `spine check` named an item number the stage's `## Done when` checklist does not have (`details.item`, `details.total`, `details.file`). Nothing is written. |
| `invalid_status` | `spine set --status` is not a status or an alias of one; `unknown` can't be set (`details.status`, `details.allowed`). |
| `stale_revision` | `spine set --if-revision`, `spine check --if-revision`, `spine start --if-revision` or `plan task --if-revision` named a revision the file no longer has. `details.revision` is the current one; `details.status` is the stage's for `spine set`, `details.path` the plan's for `plan task`. |
| `spine_unwritable` | `spine init` could not write (`spine/` is a link, the notes directory could not be made, or a file could not be written or renamed into place; `details.path`; nothing is left half-written). `spine set`, `spine check` and `spine goal set` can't rewrite the stage file safely (`no_frontmatter` does not apply to `spine check`): `details.reason` is `link`, `not_a_file`, `too_large` (over 64 KB), `not_utf8`, `no_frontmatter` (no block closed within 100 lines), `no_file` (a folder with no stage file), `missing`, `lock_unavailable` (the lock file in the state folder can't be opened), `unreadable_result` (the change would put the closing `---` past line 100 or the status past the 40-key cap, where it could not be read back), `io_error`, `changed_while_writing`, or `lock_busy` (another write held the workspace's lock for 10 seconds); `details.file` is the file below `spine/`. With `--recursive`, `details.written` lists what was already written. |
| `unknown_task` | `plan start --task`, `plan task` (or any write to one task line) named an id that no task under `## Tasks` has. `details.path`, `details.task`. |
| `task_exists` | `plan task add` named an id a task already has. `details.path`, `details.task`, `details.line`. |
| `invalid_task` | `plan task` was given an id, title, reason or place it cannot write (see [`plan`](README.plan.md#task-verbs)). `details.field`. |
| `reason_required` | `plan task` was asked for a blocked or skipped task with no reason. `details.task`, `details.state`. |
| `unknown_phase` | `plan task add --phase` or `move --phase` named a heading that is not under `## Tasks`. `details.path`, `details.phase`, `details.phases`. |
| `no_task_section` | `plan task add` found no `## Tasks` section. `details.path`. |
| `task_done` | `plan start --task` named a task that is done or skipped. `details.name`, `details.path`, `details.task`, `details.state`. |
| `task_owned` | `plan start --task`: the task's owner pane is working on it, and another pane (or `--spawn`) was asked for. `details.workspace`, `details.task`, `details.owner`. |
| `gh_unavailable` | `pr create` (or `finish --pr`) needs `gh`, which is not installed (`details.reason` `missing`) or not logged in (`not_logged_in`, with `details.detail`). |
| `nothing_to_push` | `pr create`: the branch has no commits ahead of its base. `details.branch`, `details.base`. |
| `dirty_worktree` | `rebase`: the workspace has changes to tracked files. `details.path`, `details.files`. |
| `rebase_in_progress` | `rebase` or `promote`: a rebase is already stopped in the workspace, or git ran past its time limit during the rebase and `git rebase --abort` failed (`details.aborted` `false`). `details.path`. |
| `no_upstream` | `rebase --onto upstream`: the branch has no upstream configured. `details.branch`. |
| `upstream_gone` | `rebase --onto upstream`: the branch's upstream no longer exists on the remote. `details.branch`, `details.upstream`. |
| `fetch_failed` | `rebase --onto update\|remote\|upstream` or `push`: `git fetch origin` failed. `details.remote`, `details.detail`. |
| `push_rejected` | `push`: origin refused the push, or the upstream has commits the branch never had so the push was not forced. `details.branch`, `details.upstream`, `details.detail`, `details.reason`: `origin_refused` (origin said no), `would_delete_commits` (the branch is only behind its upstream, so pushing would delete commits), `upstream_has_other_commits` (the upstream has commits the branch never had, or its reflog no longer shows them) or `upstream_mismatch` (the upstream is not `origin/<branch>`). |
| `ticket_not_found` | `ticket show` asked `gh` or `jira` for a ticket the tool says does not exist. `details.source`, `details.ref`. |
| `ticket_source_unavailable` | `ticket show` could not read the ticket (`ticket list` and `start --title-from-ticket` report it as a warning instead): `gh` or `jira` is not installed (`details.reason` `missing`), did not answer in time (`timeout`) or failed (`error`, with `details.detail`). `details.source`. |

### promote codes

`promote` refuses before it changes anything, except `move_failed` (undone) and `move_incomplete` (kept under a ref). Reused codes: `rebase_in_progress`, `usage`, `config_parse`, `unknown_workspace`. A `start` failure after the move carries `start`'s own code with `details.moved` and `details.next` (`["workspace start BRANCH"]`, which adopts the worktree).

| Code | Meaning |
|---|---|
| `not_main_checkout` | The path is not the top of a main checkout, or `--name` names a linked worktree's workspace. `details.path`. |
| `detached_head` | The main checkout is not on a branch with a commit. `details.path`. |
| `git_operation_in_progress` | A merge, cherry-pick, revert or bisect is stopped. `details.path`, `details.operation` (`merge`, `cherry_pick`, `revert`, `bisect`). |
| `unmerged_files` | Unmerged files. `details.paths`, `details.count`. |
| `intent_to_add` | Files added with `git add -N`. `details.paths`, `details.count`. |
| `submodule_changes` | A submodule has changes of its own. `details.paths`. |
| `hidden_files` | Files marked `--assume-unchanged` or `--skip-worktree`. `details.paths`, `details.count`. |
| `path_conflicts` | Untracked files where a deleted tracked file was (or inside or around it). `details.paths`, `details.count`. |
| `no_default_branch` | No local default branch. `details.path`. |
| `branch_required` | On the default branch with no `BRANCH` (a usage error, exit 2; `--dry-run` answers `branch_required: true` instead). `details.from_branch`. |
| `branch_exists` | The branch exists at a commit other than `HEAD`. `details.branch`, `details.commit`. |
| `branch_checked_out` | The branch (or the default branch) is checked out in another worktree. `details.branch`, `details.path`, `details.workspace` (or null). |
| `worktree_exists` | `.worktrees/<branch>` already exists. `details.path`. |
| `nothing_to_move` | No changes and no commits ahead of the default branch (use `workspace start BRANCH`). `details.branch`. |
| `agent_working` | An agent pane of the main checkout's workspace is working or waiting; the caller's own `$TMUX_PANE` never counts. `retry` is `--force`. `details.workspace`, `details.panes` (`pane`, `state`). |
| `stash_failed` | `git stash push` stored nothing; nothing changed. `details.path`. |
| `move_failed` | A step failed and was undone; the main checkout is as it was. `details.step` (`stash`, `switch`, `worktree_add`, `apply`, `verify`), `details.rolled_back`, `details.snapshot` (`ref`, `id`, `kept`, or null). |
| `move_incomplete` | The move stopped part way and could not be undone; the changes are under `details.snapshot.ref`. `details.step`, `details.steps_done`, `details.main_branch`, `details.worktree` (or null), `details.recover` (at most 8 `git -C ...` commands, in order; never run by promote). |

`promote --json` puts these in `warnings[]` as `{code, message, ...}`; none is an error envelope's code. Once the move is done, every later step is a warning: with `launch_failed` the document still says `ok: true` (the move and the workspace are done) and the exit code is 1, as for `start`'s `prompt_failures`; read `launched` and `warnings`.

| Code | Meaning |
|---|---|
| `default_ahead` | The local default branch is ahead of origin's; the new branch has those commits and the default is left as it is. `branch`, `upstream`, `count`, `command`. |
| `left_behind` | Untracked nested repositories were not moved. `paths`. |
| `extra_untracked` | The new worktree has files the main checkout did not have, likely from a hook. `paths`. |
| `hook_failed` | git exited with an error during a step that worked (likely `post-checkout`). `hook`, `step`. |
| `submodules_not_initialized` | The new worktree's submodules are empty. `command`. |
| `snapshot_not_deleted` | The work moved, but the snapshot ref could not be deleted. `ref`, `command`. |
| `locks_held` | Locks held in the repository were not released. `locks` (names). |
| `agent_state_unknown` | The main checkout's session runs, but its agent daemon did not answer, so busy panes were not checked. |
| `start_note` | One of `start`'s plain-text warnings. |
| `notes_unavailable` | The main checkout's notes directory is not known, so nothing was carried. |
| `spine_init_failed` | The spine asked for could not be made. |
| `plan_init_failed` | The plan asked for could not be made. |
| `launch_failed` | `--launch` did not start the workspace or deliver its first prompt (exit 1); the move and the workspace are done. |
| `same_notes_dir` | The main and new notes directories are the same, or one holds the other; nothing was carried. `path`. |
| `notes_link` | The plan, the spine or a file in it is a link, so it was not moved. `path`. |
| `notes_not_file` | `IMPLEMENTATION_PLAN.md` is not a file. `path`. |
| `notes_not_directory` | `spine` is not a directory. `path`. |
| `notes_clash` | The new notes directory already has the plan or spine; the main checkout's was left alone. `path`. |
| `notes_unwritable` | The plan or spine could not be moved. `path`. |
| `notes_not_renamed` | Moved, but the original could not be renamed `.moved-<time>`. `path`. |
| `ship_not_added` | The ship stage could not be added to the moved spine. |
| `carry_note_invalid` | A `--carry-note` path is not inside the main notes directory. `path`. |
| `carry_note_already_carried` | A `--carry-note` is inside the plan or spine, which moved whole. `path`. |
| `carry_note_link` | A `--carry-note` is, or would be written through, a link. `path`. |
| `carry_note_not_file` | A `--carry-note` is not a file. `path`. |
| `carry_note_clash` | A `--carry-note` is already in the new notes directory. `path`. |
| `carry_note_missing` | A `--carry-note` is not in the main notes directory. `path`. |
| `carry_note_unwritable` | A `--carry-note` could not be copied. `path`. |

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
| `bad_pane` | The pane reference isn't a pane id, window.pane, or index (`send`, `focus --pane` and `ask answer --deliver` accept only a pane id or window.pane; also from `agent-run restart` and `handoff`). |
| `bad_timeout` | The timeout isn't a number of seconds in range. |
| `wrong_session` | The pane belongs to another tmux session. `details.pane`, and `details.session`, the workspace's own session (also from `send`, `focus --pane`, `ask answer --deliver`, and from `agent-run restart` and `handoff` before the daemon is asked). |
| `no_such_pane` | No pane matches the reference. `details.pane` (also from `send`, `focus --pane`, `ask answer --deliver`, and from `agent-run restart` and `handoff` before the daemon is asked). |
| `pane_gone` | The pane closed before or during the restart. |
| `pane_busy` | The pane didn't go quiet in time, or `plan start` or `spine start` found it waiting on a person (or, with `--task` or `spine start`, working on something else); nothing was typed. `plan start` and `spine start` give `details.workspace`, `details.pane` and, with `--task` and always for `spine start`, `details.state`. |
| `pane_in_pipeline` | A pipeline stage is running on the pane; pass force to restart it. |
| `not_an_agent` | The pane is running a shell, not a coding agent. |
| `unsupported_agent` | The pane's agent can't be restarted. |
| `context_unavailable` | The agent can't report context usage, so /clear can't be confirmed. |
| `context_unknown` | The agent's context usage couldn't be read. |
| `clear_not_confirmed` | /clear was typed but a new conversation didn't appear. |
| `restart_in_progress` | A restart is already running on the pane. |
| `agent_stopped` | The agent stopped during the restart. |
| `not_bound` | The pane isn't bound to a run, review or play (`binding show`, `binding clear`), or not to a workflow run (`step done`, `step status`). |
| `pane_not_ready` | `agent status request`: the pane can't take typed text safely now; nothing was typed. `details.reason`: `unknown` (not scanned or not identified yet), `unsupported_agent` (an agent whose input prompt can't be recognized, so a dialog can't be ruled out), `waiting` (a permission prompt or question is open), `question_open` (`AskUserQuestion` or `ExitPlanMode` is running), `no_input_prompt` (the agent's input prompt isn't on screen), `input_not_empty` (the input line holds a draft), `input_changed` (from the check after pasting, which then answers `not_submitted`). `details.pane`, `details.pane_id`. See [`agent`](README.agent.md). |
| `status_request_open` | `agent status request`: the pane already has an open status request; nothing was typed. `details.request_id`, `details.expires_at`. |
| `status_request_unknown` | `agent status post --reply-to`: no open request has that id (already answered, never made, or the agent daemon restarted). `details.request_id`. |
| `status_request_expired` | `agent status post --reply-to`: the request expired before the reply. `details.request_id`. |
| `status_reply_wrong_pane` | `agent status post --reply-to`: the reply came from a pane other than the one asked; the request stays open. `details.request_id`. |
| `status_request_stale` | `agent status post --reply-to`: the pane id was reused since the request (a new tmux server; its pid differs). `details.request_id`. |
| `status_not_logged` | `agent status post`: the agent daemon couldn't write the `agent_status` line. |
| `unknown_library_entry` | No library entry has that name in the scopes searched. `details.ref`, `details.scopes` in the order searched, e.g. `["project:api", "global", "builtin"]` (see [`library`](README.library.md)). |
| `ambiguous_library_entry` | A bare library name matches more than one kind. `details.ref`, `details.candidates`. |
| `library_entry_exists` | `library add` would replace an entry with different content. `details.ref`, `details.scope`; `retry` names `--force` (destructive). |
| `library_install_exists` | `library install` would replace a worktree copy with different content. `details.ref`, `details.path`; `retry` names `--force` (destructive). |
| `library_kind_not_copyable` | `library install`/`uninstall` was given an entry that is not an agent or skill. `details.ref`, `details.kind`. |
| `library_uninstall_modified` | `library uninstall` would delete a worktree copy that differs from the library entry (or is a symlink). `details.ref`, `details.path`; `retry` names `--force` (destructive). |
| `library_path_outside` | `library install`/`uninstall` would act on a path not directly under the configured install directory (`.claude/skills/` or `.claude/agents/` by default). `details.ref`, `details.path`. |
| `invalid_library_install_dir` | A `library.install.*_dir` value in a config file is not valid (a hand edit; `config set` refuses such values). `details.key`. |
| `path_tracked` | `library install`/`uninstall`: the repo tracks that path, so it is never overwritten or deleted. `details.ref`, `details.path`. |
| `path_linked` | `library install`/`uninstall`: the install directory, or one above it such as `.claude`, is a symlink, so git can't tell what is tracked. `details.ref`, `details.path`. |
| `library_source_missing` | The file to add doesn't exist, or a linked entry's target can't be read. `details.ref`, `details.path`. |
| `unknown_workflow` | No workflow definition has that id. `details.workflow`, `details.known`. |
| `inbox_store_unreadable` | An inbox scope's file (or `acks`, the acks of derived rows) can't be read, so nothing was written to it. `details.scope`. |
| `inbox_full` | The scope already holds 500 open or snoozed items, so nothing was added (also for a reopen that would pass 500). `details.scope`, `details.limit`. |
| `unknown_inbox_item` | No inbox item has that id. `details.id`. |
| `ambiguous_inbox_item` | The id is in more than one inbox scope; pass `--name`, `--project` or `--global`. `details.id`, `details.scopes`. |
| `invalid_inbox_item` | A field of an item being added doesn't pass the checks: a control character, a length over its cap, a non-https URL, an unknown type or source kind, an expiry in the past. `details.field` (such as `title` or `source.url`), `details.reason`. |
| `unknown_derived_item` | `inbox ack` or `inbox snooze` named a derived id that no source produces right now (a pane that is no longer waiting, a stored item id given to `ack`). `details.id`. |
| `ask_not_open` | `ask answer` or `ask withdraw` named a question that is already answered or withdrawn. `details.id`, `details.status`. |
| `use_ask_answer` | `inbox ack` or `inbox snooze` named an `ask:` id; answer the question with `ask answer` (or close it with `ask withdraw`) instead. `details.id`. |
| `invalid_cursor` | `events --since` was given something that isn't a cursor an `events` line printed. |
| `invalid_workflow` | A workflow definition file doesn't pass the checks. `details.workflow`, `details.path`, `details.problems`. |
| `input_required` | workflow run is missing a required input. `details.workflow`, `details.inputs` (each `name` and `description`). |
| `workflow_command_unset` | A step's check names the project's test or lint command and the project has none. `details.workflow`, `details.project`, `details.commands`. |
| `no_agent_pane` | No pane of the workspace runs Claude Code, so a workflow has nowhere to run; or `plan start` or `spine start` found no agent pane to type into (with `--pane`, the named pane runs no coding agent the agent daemon knows, and `details.pane` names it). `details.workspace`. |
| `pane_has_run` | The pane already runs another workflow run. `details.pane`, `details.run_id`. |
| `unknown_run` | No workflow run has that id. `details.run_id`; `details.path` when a run file of that id exists and can't be read as a run. |
| `run_not_active` | The workflow run has finished, so nothing more can happen to it. `details.run_id`, `details.state`. |
| `gate_not_waiting` | workflow approve or reject named a run that isn't waiting at a gate. `details.run_id`, `details.step`, `details.state`. |
| `gate_waiting` | workflow resume named a run that waits at a gate; approve or reject it. `details.run_id`, `details.step`. |
| `bound_pane` | workflow approve, or resume --from at a waiting gate, was run from a pane bound to a workflow run; a gate is passed by a person. `details.pane`, `details.run_id`. |
| `step_not_running` | step done was run while the run's step isn't being worked on. `details.run_id`, `details.step`, `details.state`. |
