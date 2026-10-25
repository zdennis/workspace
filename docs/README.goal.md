# workspace goal

Say where a goal is, at every level, what it waits for and on whom.

A goal is a workspace: the workspace name is its identity. The command combines reads that already exist (the snapshot's member row, `workflow status`, the plan, `spine/` or the stages inferred without one, and the agent daemon's panes). It writes nothing and makes no `gh` call.

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

A level with nothing to show is `null`. A source that could not be read is `null` plus an entry in `warnings`, never an error. Stages and workflow steps are siblings today: no run records which stage it serves, so `stage` and `step` are reported side by side. The title does not yet read `spine/goal.md` or the plan's title, and the last finished tool call is not kept.

### State

The first rule that holds wins.

| `state` | When | `waiting_on` |
| --- | --- | --- |
| `done` | every spine stage `completed` or `skipped`, or the plan is `done` with no active run | `nothing` |
| `waiting` | run reason `waiting_you`, `failed_check` or `turn_ended_incomplete`; plan `waiting`; the turn's pane `waiting` | `person` |
| `waiting_lock` | run reason `waiting_lock` | `lock` |
| `working` | the turn is `working`, or the plan is `working` | `agent` |
| `stuck` | run flag `idle` or `timed_out`, run reason `pane_gone`, plan `stalled`, or a running run whose workspace has no agent daemon | `person` |
| `stopped` | no tmux session | `person` |
| `idle` | a run, a `spine/` or a plan exists and nothing is working or waiting | `person` |
| `none` | no run, no plan, no `spine/` | `nothing` |

`next` is `{event, action}`: the event that moves the goal on (`gate_approved`, `ask_answered`, `lock_released`, `turn_ended`, `workflow_resumed`, `launched`, ...) and the command that would cause it as `{action, args, needs}`, or null.

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
    "tool": {"current": null, "since": null, "last_event_at": "2026-10-24T14:02:10Z"}
  },
  "warnings": []
}
```

`list --json` is `{"schema_version": 1, "ok": true, "goals": [...], "warnings": []}` with the same rows minus `tool`. Without `--all`, goals whose `state` is `none` are left out.

## Errors

| Code | When |
| --- | --- |
| `unknown_goal` | `REF` matches no workspace, run, task, ticket or branch. `details.ref`, `details.tried` |
| `ambiguous_goal` | `REF` matches more than one workspace. `details.ref`, `details.matches` |
| `not_in_workspace` | no `REF` and the current directory is not in a workspace |

All exit 1; with `--json` they are the usual error envelope (see [README.json.md](README.json.md)).
