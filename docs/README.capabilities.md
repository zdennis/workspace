# workspace capabilities

Print what this workspace supports, so a script or the UI can check a feature instead of comparing version numbers.

## Usage

```sh
workspace capabilities [--json]
```

It reads constants, config paths and the `PATH`. It starts no process and touches no state, git, tmux or daemon, so it is cheap to call.

## Options

| Option | Description |
|---|---|
| `--json` | Print one JSON document (below) instead of a readable summary |

## JSON output

```json
{"schema_version":1,"ok":true,"version":"0.27.1",
 "features":{"envelope":1,"error_codes":1,"name_scope":1,"no_input":1,"action_json":1,
   "sessions":1,"locks_json":2,"git_facts":1,"prune_safe":1,"snapshot":3,"events_follow":0,
   "actions_manifest":0,"agent_send":1,"agent_spawn":1,"focus_pane":1,"state_done":1,
   "doctor_json":0,"daemon_control":4,"config_json":2,"config_scopes":2,"tmux_show":1,"tasks":1,"event_emitters":1,
   "ui_open":3,"pane_bindings":3,"library":3,"library_play":2,"library_copy":1,"instructions":1,"restore":1,
   "workflow":1,"window_state":1,"cleanup_dry_run":1,"notes":1,"start_packs":2,
   "handoff_auto":2,"handoff_codex":1,"dev_queue":2,"plan":4,"inbox":3,"ask_withdraw":1},
 "exit_codes":{"ok":0,"failed":1,"not_submitted":2,"partial":3,"lock_cleared":4,"timeout":75},
 "paths":{"event_log":"/Users/me/.workspace-events.jsonl","run_dir":"/Users/me/.local/workspace/run",
   "library":"/Users/me/.config/workspace/library"},
 "dependencies":{"window_tool":{"path":"/opt/homebrew/bin/window-tool"},
   "gh":{"path":"/opt/homebrew/bin/gh"},"tmux":{"path":null}}}
```

- `features` maps each name to an integer revision. `0` means this CLI doesn't have it, and a name missing from the map means the same. Check `features.no_input >= 1`; don't compare `version`. A revision goes up when the feature's output changes in a way a reader must handle. An older CLI that predates this command answers `Unknown subcommand` (exit 1), so treat that as "no features".
- `exit_codes` names the statuses commands use: `not_submitted` (2, `run`), `partial` (3, `--json` action documents), `lock_cleared` (4, a queued lock wait whose lock was cleared) and `timeout` (75, `--max-wait` ran out).
- `paths` are absolute.
- `dependencies` gives the first match on `PATH` for each tool, or `null` when it isn't there. Nothing is run, so there is no version.

### Features

| Feature | Meaning (revision 1) |
|---|---|
| `envelope` | `--json` failures are the error envelope, and successes carry `schema_version` and `ok` (see [`--json` output](README.json.md)) |
| `error_codes` | Error envelopes carry a stable `code` |
| `name_scope` | `--name` on `ask`, `lock`, `dev` and `config` |
| `no_input` | `--no-input` and `WORKSPACE_NO_INPUT` |
| `action_json` | `--json` action documents on the lifecycle commands, `dev up|down`, `lock release`, `config set`, `pipeline start|advance|reset`, and `agent run --json` |
| `sessions` | `sessions --json` |
| `locks_json` | `lock status --json` and `lock clear --json`. Revision 2: a holder or waiter can be a workflow run (`"kind": "run"` with `run_id` and `step`, and no `pid`), a run holder can carry a `delegate`, and `dev status --json` reports `running: false` for a run that holds `devenv` with no dev environment under it (see [`lock`](README.lock.md) and [`dev`](README.dev.md)) |
| `git_facts` | `projects show` reports git facts per workspace |
| `prune_safe` | `prune` skips a worktree with unsaved work and reports it, rather than removing it |
| `snapshot` | `snapshot --json` (see [`snapshot`](README.snapshot.md)); `sessions --json` panes carry `display_label` (see [`sessions`](README.sessions.md)). Revision 1 was `display_label` alone; revision 3 adds each member's `plan` |
| `events_follow` | Not available yet |
| `actions_manifest` | Not available yet |
| `agent_send` | `agent-run send --pane` types text or tmux keys into one named pane; `ask answer --deliver` types an answer into the asking pane |
| `agent_spawn` | `launch --json` rows carry `prompt_sent` and `pane`, and `run --split --json` names the new pane, so a caller need not compare two `sessions` reads to find the pane it started or sent to (see [`launch`](README.launch.md#json-output), [`run`](README.run.md#json-output)) |
| `focus_pane` | `focus --pane` selects a pane after focusing the window |
| `state_done` | `sessions --json` panes can report `state: "done"` with a `stop_reason` (see [`sessions`](README.sessions.md)) |
| `doctor_json` | Not available yet |
| `daemon_control` | `daemon status`, `daemon restart`, `daemon list` and `daemon log` (see [`daemon`](README.daemon.md)). Revision 2 adds `agentd restart`, `wc_socket` in the restart row, a restart that keeps the old daemon's work-coordinator socket (failure reason `wc_socket_unknown` when it can't be read back), and a 2-second limit on `lsof`, after which `status` gives `pid: null` and `restart` fails with `not_stopped`. Revision 3 adds `daemon list` and `daemon restart --all`. Revision 4 adds `version` to each `daemon list` row |
| `config_json` | `config show --json` and `config validate --json` (see [`config`](README.config.md)). Revision 2 adds `effective_path` on the `notes.dir` and `notes.default_dir` rows, the `notes.default_dir` key, type `path` and the `shared_notes_dir` warning |
| `config_scopes` | `config set/get/unset/show --scope global|project|workspace`, the `layers[]`, `overridable_in`, `doc`, `choices`, `min`, `max` and `unit` fields of `config show --json` rows, `unset --json`, `comments_preserved` in the write rows, and `config edit` (see [`config`](README.config.md#scopes)). `config_json` stays at 2. Revision 2 adds `config keys [QUERY] [--settable] [--json]` (see [`config keys`](README.config.md#config-keys)) |
| `tmux_show` | `tmux show --json` (see [`tmux`](README.tmux.md)) |
| `tasks` | `start` records a task per worktree workspace (`--title`, `WORKSPACE_TASK` in its panes); `sessions --json` reports it as `task` and uses its title as the first `display_label` (see [`start`](README.start.md#tasks)); `finish` and `kill` archive it |
| `ui_open` | `ui open task\|review\|inbox` opens a `workspace-ui://` link (see [`ui`](README.ui.md)). Revision 2 adds the `notes` view. Revision 3 adds the `plan` and `pane` views |
| `pane_bindings` | `binding set\|show\|clear` binds a pane to a run, review or play, and `session-event` prints it as `additionalContext` on `SessionStart` (see [`binding`](README.binding.md)). Revision 2: `binding show --json` adds `stale` to the `binding` object, `set` defaults `--pane` to `$TMUX_PANE`, and `--instructions` and `--artifacts` are stored as absolute paths. Revision 3: bindings carry `packs` (always in `binding show --json` and the `binding set` row), `binding set --pack` sets them, `start` and `launch` set them for the packs they send, and `session-event` prints them on `SessionStart` |
| `library` | `library list\|show\|info\|add\|update\|remove` stores named plays and prompts, globally or per project; `paths.library` is the store (see [`library`](README.library.md)). Revision 2 adds the `agent` and `skill` kinds; a skill is a directory, so its entry's `path` names a directory. Revision 3 adds the built-in scope: `list`, `show` and `info` return the plays workspace ships with `scope` `builtin`, `--builtin` narrows a read to them, and `unknown_library_entry` can name `builtin` in `details.scopes` |
| `library_play` | `start --play NAME` and `launch --play NAME` point the agent at a library play and report a `play` object in `--json` (see [`start`](README.start.md#plays)). Revision 2 binds the pane a play was delivered to, so `session-event` reminds the agent of the play after `/clear`, and adds `pane` to the `play` object |
| `library_copy` | `start --agent NAME` and `start --skill NAME` copy library agents and skills into the new worktree's `.claude/`, list them in the repo's `info/exclude`, never overwrite a tracked file, and report `agents` and `skills` in `--json` (see [`start`](README.start.md#agents-and-skills)) |
| `instructions` | `instructions compose [--pack NAME]...` prints the instructions built from library packs, with `--json` (see [`instructions`](README.instructions.md)); the `commands.test` and `commands.lint` config keys exist |
| `restore` | `restore [WORKSPACE...] [--dry-run] [--json]` recreates the agent panes the session ledger recorded and resumes their sessions; ledger entries carry the window `layout` and the `tmux_server` pid (see [`restore`](README.restore.md)) |
| `workflow` | `workflow show\|run\|status\|resume\|cancel\|approve\|reject` runs a workflow (ordered steps, the `rpiv` preset) in a workspace's agent pane, with `--json`; `step done\|status` for the agent on a step; the event log records `workflow_changed`, and `lock_wait_started`, `lock_acquired` and `lock_released` with `run_id` for a run's locks; `pipeline` is deprecated (see [`workflow`](README.workflow.md)) |
| `window_state` | `status --json` and `list --liveness --json` entries carry `window_alive` beside `alive`; `focus --json` names a missing window with `no_window` and `window_gone` (see [`status`](README.status.md#window-state)) |
| `cleanup_dry_run` | `cleanup --dry-run` reports what it would remove without prompting or changing anything (status `dry_run`), `--tmux-dead-only` limits a run to entries whose tmux session is gone, and `cleanup --json` rows carry `tmux_alive` and `window_alive` (see [`cleanup`](README.cleanup.md#json-output)) |
| `notes` | `notes dir [--name WS] [--create] [--json]` prints the absolute notes directory of a workspace, and `--create` makes it and keeps it out of git (see [`notes`](README.notes.md)) |
| `handoff_codex` | Level 1: `handoff check` and `handoff new`, `start --handoff`, `launch --handoff`, `handoff.auto` and `plan start` accept Codex panes, `sessions --json` reports `context_pct` for them, and the global `context.patterns` key maps an agent kind to a regex that reads its context use (see [`handoff`](README.handoff.md#codex)) |
| `handoff_auto` | `handoff check` and `handoff new` use `HANDOFF.md` in the notes directory (from level 3 of `plan`, the plan when there is one) when given neither `--handoff-doc` nor `--handoff-prompt`, `handoff check --json` carries `next` and `doc`, and `handoff.check_prompt` and `handoff.resume_prompt` report their built-in text as `default` Level 2. Level 1: `start` and `launch` take `--handoff` and `--no-handoff`, and the `handoff.auto` key turns the built-in `handoff` pack on for a project, so a Claude Code agent runs `handoff check` itself (see [`handoff`](README.handoff.md#automatic-handoff)); `--handoff` for any other main agent is refused with `handoff_unsupported_agent` |
| `dev_queue` | `dev up --queue` returns at once with its row carrying `status` and `position`, `dev wait` blocks until this worktree holds the lock and `dev.ready` passes, and `dev leave` takes it out of the line (see [`dev`](README.dev.md#queue-without-blocking)). At 2, `dev status --json` numbers each `queue` entry (`position`, `waiting_seconds`), the `holder` carries `agent_state` and `idle_since`, and `dev_started` and `dev_stopped` are written to the event log (see [`dev`](README.dev.md#following-the-dev-environment)) |
| `plan` | `plan status [--name WS \| --all \| --file PATH] [--json]`, `plan path`, `plan show` and `plan init` read and start a workspace's `IMPLEMENTATION_PLAN.md`, and the `plan.stall_seconds` key sets when an idle owner pane makes the plan `stalled` (see [`plan`](README.plan.md)). Level 3: the built-in `implementation-plan` play, `handoff check` and `new` using the plan as the handoff doc when there is one, and `doctor` warnings about a plan. Level 4: `plan start`, `plan pause` and `plan delete` (with `--json` action documents), and `plan_changed` in the event log |
| `ticket` | `ticket show REF [--name WS] [--json]` reads a JIRA key, pull request, issue or branch the way `start` does, with its title, body and URL and the workspace that already exists for it, and writes nothing (see [`ticket`](README.ticket.md)) |
| `pr_create` | `pr create [--name WS] [--draft] [--json]` pushes the branch when it has no upstream, returns the branch's pull request when it has one, and otherwise runs `gh pr create --fill`; `finish --json` carries `pr_url` (see [`pr`](README.pr.md)) |
| `rebase` | `rebase --onto local\|update\|remote\|upstream [--name WS] [--json]` and `push [--name WS] [--json]` (see [`rebase`](README.rebase.md)) |
| `inbox` | `inbox add\|list\|show\|done\|dismiss\|reopen` and `inbox add --from-json PATH\|-` keep a durable list of things that need a person, per workspace, project or global, with `--json` (see [`inbox`](README.inbox.md)). Level 2 adds `edit`, `snooze`, dedupe, expiry and the scope caps; level 3 adds `list --include-derived` and `ack`, and `snooze` of derived ids |
| `ask_withdraw` | `ask withdraw ID` closes an open question its asker no longer needs answered (see [`ask`](README.ask.md)) |
| `start_packs` | `start` and `launch` send the instruction packs that apply (`--pack`, `--no-packs`, the `notes.instructions` key) and report `packs` rows in `--json`; `instructions compose --start` prints them (see [`start`](README.start.md#packs)). Level 2: the `dev.instructions` key and the automatic `dev` pack for a project with `dev.up`, and a `dev.configured` row in `config show --json` |
| `event_emitters` | The event log records `ask_created`, `ask_answered`, `lock_released`, `lock_cleared`, `worktree_started`, `worktree_finished`, `daemon_started`, `daemon_stopped` and `config_changed` (see [`event-log`](README.event-log.md#state-and-lifecycle-events)) |

## Examples

```sh
workspace capabilities
workspace capabilities --json | jq '.features.no_input'
workspace capabilities --json | jq -r '.dependencies.window_tool.path'
```
