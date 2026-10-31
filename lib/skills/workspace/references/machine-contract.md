# Machine contract for the workspace CLI

Written against workspace 0.75.0. Source: `docs/README.json.md`, `lib/workspace/error_codes.rb`, `workspace capabilities --json`.

## Mistakes agents make

1. Reading `ok: true` on an action document as success. It means the command ran. Read `status`, each `results[].outcome`, and the exit code.
2. Treating `list`, `status` and `parent --json` as enveloped. They print a bare array or object with no `ok`. Add `--json-envelope` for the envelope, or check for `ok == false` first.
3. Assuming exit 0 means success for `rebase --json` (a conflict is `outcome: conflict`, exit 0) or `agent run --json` (read `reply.ok`).
4. Leaving out `--no-input` and hanging on a prompt, or fixing `confirmation_required` by adding `--force` or `--yes` without asking the person.
5. Believing `--no-input` protects `prune --json`, `finish` or `stop`. It does not (see the next section).
6. Leaving out `--name WS` and acting on the workspace of the current directory.
7. Resending after `not_submitted`, `clear_unconfirmed` or `maybe_delivered: true`. That types the prompt twice. Look at the pane first.
8. Retrying `push_timeout`, or any error with `permanent: false` and no `retry`. Forcing a push by hand after `push_rejected`.
9. Comparing `version` instead of reading `features.NAME`.
10. Putting `--json` after a bare `--` (it goes to the child command), or adding it to `current`, `capture`, `dir`, `lookup`, `whereis`, `version`. Check `--help`.
11. Matching on `error` text. Match on `code`, and read `details`.
12. Running `kill` from inside the session it kills. The session ends last, so the document may never print.
13. Approving a workflow gate from the pane the run is bound to (`bound_pane`), or running `details.recover` from `move_incomplete`.
14. Writing to `spine` or plan tasks without `--if-revision`, then overwriting someone else's edit.

## No confirmation under the safe-looking pattern

| Command | What happens |
|---|---|
| `prune --json` | Removes every selected worktree, across all projects, with no prompt. The unsaved-work check still skips dirty ones. `prune --force` also skips that check. |
| `finish` | No prompt. Refuses dirty or unpushed work, otherwise removes the worktree. |
| `stop` | No prompt. Ends the tmux session and every agent in it. `--all` ends every workspace. |
| `kill --force` | Skips the unsaved-work check and deletes an unmerged branch. |

Do this instead: `workspace prune --dry-run --json`, read the rows, then `prune --json --name WS` for the ones the person approved. The `prune` text path does prompt, and answers `--force`.

## Envelope

Failure: `{"schema_version":1,"ok":false,"error":"text","code":"unknown_workspace","details":{...},"retry":{...}}`
- `code` is stable. `error` is for people. `details` appears when it has content.
- `retry` appears only when a flag forces the run: `{"flags":["--force"],"destructive":true}`. Run those flags only after the person approves, and always when `destructive` is true.
- `{"flags":[],"destructive":false}` means run the identical command again.
- No `retry` means retrying is unsafe or useless.

Action document: `{"schema_version":1,"ok":true,"action":"stop","status":"ok","results":[{"workspace","outcome","reason","message"}],"warnings":[],"summary":{}}`
- `status`: `ok`, `partial`, `failed`, `cancelled` (a prompt was declined), `dry_run`, `refused` (nothing changed).
- `dev up`, `dev down`, `dev wait` and `lock release` report only an exit code: a `failed` row with `reason: "exit_code"`. The explanation is on stderr.
- `rebase`, `push`, `promote`, `agent run` and `snapshot` have their own shapes. `promote` puts later problems in `warnings[]`, not as errors.

Under `--json`, stdout holds exactly one JSON value and failures are the envelope on stdout. Progress text goes to stderr.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok, cancelled, dry_run |
| 1 | failed or refused; most error envelopes |
| 2 | `not_submitted` (text reached the pane unconfirmed); `promote`'s `branch_required`; `handoff check` when context use is unknown (nothing sent). Other usage errors exit 1. |
| 3 | partial |
| 4 | `lock_cleared` (a queued lock wait was cleared) |
| 6 | `dev up` or `dev wait`: the ready check failed (the env is stopped) |
| 75 | `--max-wait` expired (`dev up`, `dev wait`, `lock acquire`), and `clear_unconfirmed`. `dev wait` leaves its wrapper in line; `dev up` stops it |

`--json` never changes the exit code. A command with its own code keeps it. `rebase --json` exits 0 for every `outcome`. `promote` with `launch_failed` is `ok: true` with exit 1.

## Scope

- `--name WS` picks the workspace on most commands. Some take it positionally: `spine show [WS]`, `sessions [project]`, `parent [NAME]`.
- Without `--name`, lifecycle commands (`stop`, `kill`, `finish`, `remove`, `restore`, `dir`) act on the workspace holding the current directory. Outside one they refuse with `not_in_workspace` (`details.path`).
- Bare `stop` and `restore` act on one workspace. `--all` is required for every one. Older CLIs differ: check `features.lifecycle_current >= 1`.
- Worktree workspaces are named `<project>.worktree-<branch>`.
- A name that differs only in case from an existing one is refused: `workspace_name_case_conflict`.

## Feature gates

`workspace capabilities --json | jq '.features.NAME'`. The value is a revision number; 0 or missing means absent. Check `>= N`. Names you will use: `no_input`, `lifecycle_current`, `plan`, `spine`, `pr_create`, `pr_feedback`, `rebase`, `inbox`, `workflow`, `agent_queue`, `agent_send`, `library`, `promote`, `snapshot`, `json_envelope`. `actions_manifest` is 0. `dependencies.gh.path` null means `pr create`, `pr feedback` and `finish --pr` give `gh_unavailable`; a `push` of a `pr-N` branch gives `push_rejected` with `details.pr_check` saying `gh` is missing.

## Error families and what to do

| Family | Codes | Do |
|---|---|---|
| Usage | `error`, `usage` | Fix the command. Do not retry it unchanged. |
| Scope | `unknown_workspace`, `not_in_workspace`, `workspace_name_case_conflict`, `checkout_missing`, `not_a_repository`, `not_a_directory` | Run `list --json` or `parent --json`, pass the right `--name`, or change directory. A status command (`workflow status`, `plan status`) with no flag reports this workspace; `not_in_workspace` from one is answered with `--name WS`, `--project NAME` or `--all`. |
| Needs a person | `confirmation_required`, `unsaved_work`, `unsaved_unknown`, `open_pull_request`, `pull_request_status_unknown`, `dev_held_by`, `agent_working`, `library_*_exists`, `library_uninstall_modified` | Show `details` to the person. Use `retry.flags` only after they approve. |
| Not running | `no_daemon`, `no_session`, `session_running`, `not_removable`, `no_agent_pane`, `no_window`, `window_gone` | Launch or start the workspace, or stop it first for `session_running`. `not_removable` is a worktree workspace: it ends with `kill`, `finish` or `prune`, which need the person. Do not loop. |
| Pane delivery | `not_delivered`, `not_submitted`, `connection_failed`, `unreadable_reply`, `pane_busy`, `pane_waiting`, `pane_not_ready`, `queue_full`, `clear_unconfirmed`, `not_ready`, `restart_in_progress`, `stale_pane`, `wrong_session`, `no_such_pane`, `bad_pane` | `not_delivered`: safe to resend, except with `details.clear_typed: true` (the conversation was already cleared; look at the pane first). `not_submitted`, `clear_unconfirmed`, `details.maybe_delivered: true`: read the pane or `prompt_queued` events before any resend. `pane_busy`: wait, or use `--when-idle`; with `details.reason: input_not_empty` a person has a draft in the box, so leave it. `pane_waiting`: someone must answer the prompt first. |
| Push, pull request, rebase | `push_rejected`, `push_failed`, `push_auth_failed`, `protected_branch`, `no_remote`, `no_upstream`, `upstream_gone`, `fetch_failed`, `push_network`, `push_timeout`, `nothing_to_push`, `gh_unavailable`, `no_pull_request`, `dirty_worktree`, `rebase_in_progress` | In order: `retry` present (its `flags` are empty for push errors), rerun it. `details.permanent: true`, stop and report. `details.state_unknown: true` (`push_timeout`), run `git ls-remote origin BRANCH` first. `permanent: false` alone does not make it retryable. A rebase `conflict` is an outcome, not an error. |
| Stale write | `stale_revision`, `plan_write_conflict`, `gate_not_waiting`, `stale_workflow` | Re-read the file or status, recompute, reapply. `gate_not_waiting`: read `workflow status`, do not retry. |
| Not found or precondition | `unknown_config_key`, `scope_not_allowed`, `unknown_stage`, `unknown_task`, `unknown_item`, `unknown_run`, `unknown_workflow`, `no_plan`, `no_spine`, `plan_done`, `stage_done`, `stage_waiting`, `stage_owned`, `task_owned` | Run the matching `show` or `list`. `details` names the valid values. |
| Human only | `bound_pane` | Stop and ask the person. An agent never approves its own gate. |
| Run resumed from its own pane | outcome `parked` (not an error; exit 0) | `workflow resume` or `workflow run` from the pane the step would be typed into types nothing: it stores the request. End your turn now (a sub-agent finishes and lets the main agent end its turn). The agent daemon carries it out after the turn, within 1 hour, else `workflow status` shows the reason `error: parked_timeout`. A second resume from the same pane answers `unchanged`. Do not poll or resume again. |
| Local write | `spine_unwritable`, `notes_dir_unwritable`, `notes_dir_unresolved`, `config_parse`, `editor_failed` | Read `details.reason` and `details.path`. `spine_unwritable` with `details.reason: lock_busy` (another write held the lock for 10 seconds) can be retried once; the rest need a fix. |
| promote | `move_failed`, `move_incomplete`, `not_main_checkout`, `branch_exists`, `nothing_to_move` | Refusals change nothing. `move_failed` was undone. For `move_incomplete`, show `details.recover` to the person and run none of it. |
| Daemon | `malformed_message`, `internal_error`, `wrong_workspace`, `unknown_type`, `not_bound`, `unsupported_agent`, `not_an_agent`, `no_interrupt_key` | Report. Usually the wrong pane or agent kind. |
| Warnings only | `saved_window_offscreen`, `window_position_unreadable`, `launcher_pane_missing`, promote's `default_ahead`, `left_behind`, `locks_held`, `launch_failed` | Appear in `warnings`, never as an error `code`. |

The full list with meanings is in `docs/README.json.md` and `lib/workspace/error_codes.rb` in the repo.
