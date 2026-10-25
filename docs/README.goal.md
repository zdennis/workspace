# workspace goal

Say where a goal is, at every level, what it waits for and on whom.

A goal is a workspace: the workspace name is its identity. The command combines reads that already exist (the snapshot's member row, `workflow status`, the plan, `spine/` or the stages inferred without one, and the agent daemon's panes). It writes nothing and makes no `gh` or network call; whether the work landed comes from local git only.

## Usage

```
workspace goal show [REF] [--json]
workspace goal list [--all] [--json]
workspace journey ...                 # another name for `workspace spine ...`
```

`REF` is tried in this order: a workspace name, an active (then a finished) workflow run id, an active task id, then a task or workspace whose ref, key or branch matches (a JIRA key or URL, a pull request or issue URL, a branch). With no `REF`, the workspace of the current directory.

A finished run id shows its workspace's goal with a `run_archived` warning. A main checkout is one goal. A second active run in the same workspace is the same goal: `step` follows the newest run and `runs` lists every active one.

## What it shows

| Level | Field | Source |
| --- | --- | --- |
| Goal | `workspace`, `project`, `title` (the task's title, else the workspace), `ref`, `branch`, `task_id` | snapshot, task store |
| Goal | `state`, `waiting_on`, `next` | the rules below |
| Stage | `stage`: `path`, `title`, `status`, `owner`, `source` (`spine` or `inferred`) | `spine/`, else the stages inferred from the plan, runs and panes |
| Step | `step`: a run (`source: workflow`: `run`, `workflow`, `step`, `attempt`, `state`, `reason` with `actions`, `flags`), else the plan's current task (`source: plan`) | `WorkflowStatus`, the plan |
| Turn | `turn`: `pane`, `kind`, `state`, `state_since`, `waiting_message`, `context_pct`, `subagents` | the run's pane, else the stage's owner, else the plan's owner, else the main agent pane |
| Tool | `tool` (`show` only): `current`, `since`, `last_event_at` | the daemon; null without hook events |

A level with nothing to show is `null` (see the nullability table below). A source that could not be read is `null` plus an entry in `warnings`, never an error. Stages and workflow steps are siblings today: no run records which stage it serves, so `stage` and `step` are reported side by side. The title does not yet read `spine/goal.md` or the plan's title, and the last finished tool call is not kept.

### State

The first rule that holds wins.

| `state` | When | `waiting_on` |
| --- | --- | --- |
| `done` | every spine stage `completed` or `skipped`, or the plan is `done` with no active run (a `completed` run does not count as active), **and** the branch's commits are on the default branch | `nothing` |
| `waiting` | run reason `waiting_you`, `failed_check` or `turn_ended_incomplete` (that one only while the turn is not `working`); plan `waiting`; the turn's pane `waiting` | `person` |
| `waiting_lock` | run reason `waiting_lock` | `lock` |
| `working` | the turn is `working`, or the plan is `working` | `agent` |
| `stuck` | run flag `idle` (the pane idle and the attempt at least 30s old) or `timed_out`, run reason `pane_gone`, plan `stalled`, or a running run whose workspace has no agent daemon | `person` |
| `waiting` | the plan or spine is finished but the branch is not on the default branch. Checked after `working` and `stuck` and before `stopped` and `idle`, so a waiting reason, a working turn or a stuck run wins over it | `person`, with `next.event` `delivered` |
| `waiting` | finished, but git could not say whether the branch landed (`delivery_unavailable`) | `nothing`, `next: null` |
| `stopped` | no tmux session | `person` |
| `idle` | a run, a `spine/` or a plan exists and nothing is working or waiting | `person` |
| `none` | no run, no plan, no `spine/` | `nothing` |

`next` is `{event, action}`: the event that moves the goal on (`gate_approved`, `ask_answered`, `lock_released`, `turn_ended`, `workflow_resumed`, `launched`, ...) and the command that would cause it as `{action, args, needs}`, or null.

`state` and `stage.status` are independent signals. `state` comes from the plan's or spine's own counts and the run; `stage.status` is the current stage's own status. They can disagree, for example `state: "done"` (the plan is done) beside a current stage that is `blocked`. Both are reported as they are, and a `stage_disagrees` warning (`details.stage`, `details.status`) says so whenever `state` is `done` and the current stage is not `completed` or `skipped`.

### Done means, not yet

**`done` now requires delivery** (revision 2 of the `goal` capability). A finished plan or spine, or a plan that is `done` beside a `completed` run, is no longer enough: the branch's commits must be on the default branch. Until then the goal is `waiting` on `person` with `next.event` `delivered` (or `next` null when git can't be read, see `delivery_unavailable`). This fixes goals that read `done` while their commits were never pushed or merged.

`goal show` says what done means and what is still missing. Until a `done:` block exists, done means the branch is merged into the default branch. The base is chosen by `Git#branch_vs_base`, one rule, from local refs only (no fetch, no network):

- With an `origin` remote, merged means on `origin/<default>` (`origin/HEAD`, else `origin/main`, `origin/master`). If none of those is fetched, the branch reads as not merged; it never falls back to the local default branch.
- With no remote, the local `main` (else `master`) counts.

A stale `origin/<default>` reads as not merged until you fetch. A squash or rebase merge leaves the branch's own commits off the default branch and reads as not merged; if the branch's upstream was deleted, `not_yet` says `upstream_gone` instead of `not_pushed`.

```
tally-1  (try-tally)  tally-1
State:  waiting (on person)
Done means: branch merged into main
Not yet:    not pushed; not on main (4 commits ahead)
```

| Field | Meaning |
| --- | --- |
| `done_means` (`show`) | list of `{code, text}`; today one entry, `merged_into_base` ("branch merged into <default>") |
| `not_yet` (`show`) | list of `{code, text}`, empty when merged, whatever the push state (a branch whose remote copy was deleted after the merge reads cleanly); `not_merged` also has `ahead_of_base` (null when no origin default branch is fetched) |
| `delivery` (`show`) | the facts, or null when git could not answer: `base`, `branch`, `remote` (an origin exists), `upstream`, `upstream_gone` (an upstream is configured but its branch is missing), `pushed` (null with no remote), `ahead_of_upstream` (null without a usable upstream), `merged`, `ahead_of_base` |
| `delivered` (`list`) | `true`, `false`, or null when git could not answer |
| `not_yet_codes` (`list`) | the `code`s of `not_yet`, as strings; the text and `ahead_of_base` are left out |

`list` reads git for every row (about six short, local `git` calls per workspace), so a long list costs more than before.

Pull request state is not read yet.

### Closed value sets

These sets are stable: a value is never renamed or removed within `schema_version` 1, and a new value is a schema change. Revision 2 of the `goal` capability added the delivery fields below, `delivered` to `next.event`, and the `delivery_unavailable` warning.

| Field | Values |
| --- | --- |
| `state` | `done`, `waiting`, `waiting_lock`, `working`, `stuck`, `stopped`, `idle`, `none` |
| `waiting_on` | `nothing`, `person`, `agent`, `lock` |
| `next.event` | `gate_approved`, `answered`, `check_passed`, `turn_ended`, `ask_answered`, `prompt_answered`, `lock_released`, `workflow_resumed`, `agent_restarted`, `launched`, `stage_started`, `task_started`, `delivered` |
| `done_means[].code` | `merged_into_base` |
| `not_yet[].code` | `not_pushed`, `not_merged`, `upstream_gone`, `delivery_unknown` |
| `turn.state` | `working`, `idle`, `waiting`, `done` (the agent's turn has ended and the pane is finished) |
| `step.source` | `workflow`, `plan` |
| `stage.source` | `spine`, `inferred` |

### Nullability

| Field | Null when |
| --- | --- |
| `ref`, `task_id` | the workspace has no recorded task |
| `delivery` | git could not answer (the goal is then not `done`, `not_yet` is `delivery_unknown`, and a `delivery_unavailable` warning is given when the goal is otherwise finished) |
| `delivery.base`, `delivery.ahead_of_base` | an `origin` exists but its default branch was never fetched (the branch then reads as not merged) |
| `next` | `state` is `done` or `none`, or `waiting` because the goal is finished but delivery is unknown (nothing is expected, nothing a person can do), or `working`, where it is `{event: "turn_ended", action: null}` and not null |
| `next.action` | no command would cause the event (`working`, `stage_started`, `task_started`) |
| `stage` | no `spine/` and no stage is current, the plan could not be read, or the spine has no current stage |
| `step` | no active run and no plan task to do |
| `turn` | no agent pane was found, or the agent daemon could not be reached: then a `turn_unavailable` warning names the workspace (none for a stopped workspace, which has no daemon to ask) |
| `tool` | `show` only: no turn, the daemon did not answer within 1 second, or its pane gave no row; `tool.current` is null when no tool is running |
| `turn.state_since`, `turn.waiting_message`, `turn.context_pct` | the daemon had no value |

### Warnings

| Code | When |
| --- | --- |
| `turn_unavailable` | the workspace runs but its agent daemon gave no panes (`workspace`) |
| `no_daemon` | the same, and a run is going that will not move without it (`workspace`) |
| `stage_disagrees` | `state` is `done` and the current stage is not `completed` or `skipped` (`workspace`, `details.stage`, `details.status`) |
| `delivery_unavailable` | the goal is otherwise finished, but git could not say whether the branch landed (no such branch, or no default branch to compare with); the goal is not `done` (`workspace`) |
| `run_archived` | `REF` was a finished run's id |
| `plan_unavailable` | the plan file could not be located or read (`workspace`) |
| `workflow_runs_unavailable` | a run file could not be read |

The snapshot's own warnings (`spine_unavailable`, `daemons_unavailable`, `task_store_unavailable`, ...) are passed on unchanged.

## show --json

```json
{
  "schema_version": 1, "ok": true,
  "goal": {
    "workspace": "lab-wc-lab-1", "project": "lab-wc", "title": "Total row for wc",
    "ref": "LAB-1", "branch": "lab-1", "task_id": "t_3f2a",
    "state": "waiting", "waiting_on": "person",
    "next": {"event": "gate_approved", "action": {"action": "workflow approve", "args": ["r_91c"], "needs": []}},
    "stage": {"path": "plan", "title": "Plan", "status": "in_progress", "owner": null, "source": "inferred"},
    "step": {"source": "workflow", "run": "r_91c", "workflow": "rpiv", "step": "plan", "attempt": 1,
             "state": "waiting", "reason": {"code": "waiting_you", "details": {"kind": "gate"}, "actions": []}, "flags": []},
    "runs": [{"id": "r_91c", "workflow": "rpiv", "step": "plan", "state": "waiting"}],
    "turn": {"pane": "%5", "kind": "claude", "state": "idle", "state_since": "2026-10-24T14:02:11Z",
             "waiting_message": null, "context_pct": 41, "subagents": []},
    "done_means": [{"code": "merged_into_base", "text": "branch merged into main"}],
    "not_yet": [{"code": "not_pushed", "text": "not pushed"}, {"code": "not_merged", "text": "not on main (1 commit ahead)", "ahead_of_base": 1}],
    "delivery": {"base": "origin/main", "branch": "lab-1", "remote": true, "upstream": null, "upstream_gone": false, "pushed": false,
                 "ahead_of_upstream": null, "merged": false, "ahead_of_base": 1},
    "tool": {"current": null, "since": null, "last_event_at": "2026-10-24T14:02:10Z"}
  },
  "warnings": []
}
```

`list --json` is `{"schema_version": 1, "ok": true, "goals": [...], "warnings": []}` with the same rows minus `tool`, `done_means`, `not_yet` and `delivery`, plus `delivered` and `not_yet_codes`. The `state` reflects delivery. Without `--all`, goals whose `state` is `none` are left out.

## Errors

| Code | When |
| --- | --- |
| `unknown_goal` | `REF` matches no workspace, run, task, ticket or branch. `details.ref`, `details.tried` |
| `ambiguous_goal` | `REF` matches more than one workspace. `details.ref`, `details.matches` |
| `not_in_workspace` | no `REF` and the current directory is not in a workspace (the code `ask` and `config` use too) |
| `usage` | a bad flag or argument: `--all` with `show`, a second `REF`, an unknown subcommand (see [README.json.md](README.json.md)) |

All exit 1; with `--json` they are the usual error envelope (see [README.json.md](README.json.md)).
