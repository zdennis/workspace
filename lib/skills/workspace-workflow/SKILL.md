---
name: workspace-workflow
description: "Start and follow `workspace` workflow runs: `go` from a ticket, PR or text, name a preset (rpiv, rpiv-auto-approve, rpiv-auto-approve-v2, investigate, pr-feedback, explore, bugfix), `workflow start`, `workflow run`, read `workflow status`. Use for 'run rpiv on this' or 'start an investigate workflow on PROJ-101'. Not a worktree with no workflow, or ending one: use workspace-lifecycle."
---

Written against workspace 0.97.0; check with the working --help form.

Shared rules for `--json`, exit codes and error codes: [machine-contract](../workspace/references/machine-contract.md).

Never run `workflow approve` or `workflow reject` unless the person asked for that exact thing. The table is under Safety in skill `workspace`.

## Start with go

`workspace go [REF | "TEXT"] [--workflow ID] [--input KEY=VALUE]... [--here] [--text] [--base REF] [--dry-run] [--json]`. Check `workspace capabilities --json` for `features.go`; if it is absent, use `workflow start`. `--here`, `--base` and `decision.route: task` need `features.go >= 2`; `--text` and a ref read out of a sentence need `>= 3`; at 1 those flags are invalid options, and free text from a worktree runs there. Run with `--dry-run` first, then the same command without it.

- Any whitespace makes the argument a sentence: free text, unless it holds exactly one pull request, issue or ticket link or key, which `go` runs as that ref with the sentence as the task (`decision.extracted` names the token; a link beats a bare key, and a bare key needs its ticket to read). A key inside a sentence must be uppercase (`fix proj-123` is not read); only a lone word may be lowercase. `--text` keeps a sentence plain, and `--workflow` turns off the lone lowercase key lookup. A lone word is a ref, so `go rpiv` looks for a branch named rpiv: name a workflow with `--workflow`. Quote `'#123'`.
- The workflow is `--workflow`, then `workflows.by_ref.KIND`, then `workflows.default`, then `pr-feedback` for a pull request, else `rpiv`.
- If the request does not name a workflow, show the person what `--dry-run` chose and why, and wait for a yes before the real start. Unattended, use `workspace ask` (or `inbox add`) and stop; see workspace-inbox.
- Free text always makes a new worktree workspace off the default branch, even from inside a worktree workspace. It runs in place only for bare `go`, a ref for the current branch, or free text with `--here`, and only in a linked worktree workspace on a branch that is neither the default nor the main checkout's (`--here` elsewhere is `go_here_unavailable`). Otherwise it makes or reuses `.worktrees/<branch>`. A stopped workspace passes `--dry-run` and then fails at the pane: `workspace launch NAME` first.
- Free text fills `task` when the workflow declares it, in the new checkout or, with `--here`, here. A branch ref, or bare `go`, with `rpiv` needs `--input task=TEXT`.
- Free text from the main checkout or from a worktree leaves uncommitted changes behind; to move them into the new worktree use `promote` (skill workspace-lifecycle).
- Free text without `--here` never types into your pane: it opens a new workspace and window, so do not end your turn expecting a step. In `--json`, `decision.route` says which happened: `start` is a new or reused checkout and nothing comes to this pane, `run` is in place, `task` is `--here` text added to the plan of a run already going on this checkout (nothing is typed into any pane; the run's agent takes it on its next plan read, so do not wait for a step). When it runs in place (bare `go`, the current branch, or `--here`) from the pane it would type into, `go` types nothing and answers outcome `parked`, exit 0. The first step starts after your turn ends: end your turn now, and do not poll or run it again. A sub-agent finishes and lets the main agent end its turn. After an hour `workflow status` shows `parked_timeout`.

## Refusals

| Code | Meaning and what to do |
|---|---|
| `go_here_unavailable` | `--here` where `go` can't run in place. Nothing started. Drop `--here`, or run it from a linked worktree workspace. |
| `checkout_has_run` | From `go --here "TEXT"`: the run going here is past every step that reads the plan, so the text would not be picked up. Drop `--here` for a new workspace. |
| `no_plan` | From `go --here "TEXT"`: the run's plan step has not written the plan yet. Run again after it does, or drop `--here` for a new workspace. |
| `plan_done` | From `go --here "TEXT"`: the plan is marked done under a run still going. Drop `--here` for a new workspace, or ask the person to reopen the plan. |
| `invalid_task` | From `go --here "TEXT"`: the text does not fit one task line (over 500 characters, several lines, or ` -- `). Shorten it yourself, or drop `--here`. |
| `plan_write_conflict` | From `go --here "TEXT"`: the plan kept changing while the task was written. Run it again. |
| `unknown_base` | `--base` names nothing git can find, or starts with `-`. Nothing started. |
| `branch_not_allowed` | The default branch or the main checkout's branch. Pick another. `workflow run` is no way round it: running on the default branch is the person's decision. |
| `branch_exists`, `unknown_ref` | Name taken, or no such branch (`details.did_you_mean` for a case variant). |
| `unknown_workflow` | No such id. `workflow show` lists them. |
| `dirty_worktree` | A step that must leave the checkout alone found it unclean. Ask the person. |
| `fork_pull_request` | Stop and tell the person. Going round it with `start` or `workflow run` is theirs to decide: it runs an agent on a stranger's code. |
| `workflow_needs_claude` | The main agent pane is not Claude Code. |
| `ticket_source_unavailable` | `gh` or `jira` missing, timed out or failed; also covers `ticket_not_found`. |

## Plain requests

| Request | Command |
|---|---|
| "start an investigate workflow on PROJ-101" | `workspace go PROJ-101 --workflow investigate --dry-run`, then without `--dry-run` |
| "run rpiv on this", in a worktree workspace off the default branch, with text, in this workspace | `workspace go --here "TEXT" --workflow rpiv` |
| "run rpiv on this", as a new workspace, with text | `workspace go "TEXT" --workflow rpiv` |
| "run rpiv on this", in a worktree workspace off the default branch, no text to hand | `workspace go --workflow rpiv --input task=TEXT` |
| "run rpiv on this", on the main checkout | Bare `go` is a usage error: give a ref or text. |

## Other forms

- `workflow start [ID] [REF | --prompt TEXT]` has what `go` lacks: `--branch`, `--slug`, `--note`, `--agent-kind`, `--[no-]headless`, `--prompt-timeout`. `workflow start --help` lists them.
- `workflow run ID` runs in an existing checkout, with `--name` and `--pane`. It makes nothing and does no fork check. With no `--input` it fills an unset `task` and `pr` from the branch's open pull request (else `task` is `Branch NAME`), never on the default branch or in the main checkout. It parks as `go` does.
- `workflow graph ID [--run RUN]` draws a definition (ASCII by default; `--format mermaid|dot|json`) and, with `--run`, where that run stands on it (needs `workflow` 52). It is read only, so use it to show the person a workflow's shape or a run's loops.
- For any other `workflow` verb (`workflow show`, `workflow validate` and the rest), read `workspace workflow --help`.

## Presets

`workflow show` lists all ids, yours too; a file in `~/.config/workspace/workflows/` shadows a preset of the same id. `workflow show ID` prints one with all its inputs, optional ones too.

| ID | Required input | Steps | For |
|---|---|---|---|
| `rpiv` | `task` | research, plan (gate), implement, verify | One feature end to end; needs `commands.test` |
| `rpiv-auto-approve` | `task` | as `rpiv`, three reviewers in place of the gate | The older unattended form; choose v2 for new runs |
| `rpiv-auto-approve-v2` | `task` | as `rpiv`, plan reviewed by built-in reviewers (`review:`) in place of the gate | The recommended unattended preset: no person reviews the plan, fewer steps, capped attempts, run timeout and token budget. The workspace's agent daemon runs the sweep, which presses a review pane past the review timeout, about every 5 minutes while the run is going. Suggest the person also run `workflow sweep --install` (you do not: it changes their login session) so a stopped daemon does not leave the run unwatched (a per-user launchd entry running every 5 minutes; `workflow sweep --installed` checks it, read-only). A plan has no gate, so never approve or reject it |
| `pr-feedback` | none | triage (gate), fix | Review feedback on a PR; never posts or pushes |
| `investigate` | none | reproduce, diagnose (gate), fix | A failing check or bug; stops `no_input` with no input and no PR |
| `explore` | `task` | survey (gate), report | Read-only research or gap analysis |
| `bugfix` | `task` | reproduce (gate), fix, verify | Experimental. One bug fixed test first: a failing test is proven before the gate. Needs `commands.test` that takes test files, `commands.test_files`, and a `workspace` with `step_expect_fail` in `capabilities --json` on the agent daemon's PATH |

## Reading status

`workspace workflow status [RUN | --name WS | --project [NAME] | --all] [--table] [--json]`. No scope shows this workspace's runs still going; `--project` and `--all` include finished runs.

| Reason | Who acts |
|---|---|
| `waiting_lock` | Nobody; wait. |
| `waiting_you` | The person for a gate or prompt; for an ask, see workspace-inbox. |
| `turn_ended_incomplete`, `failed_check` | `workflow resume RUN`. A guard stop (HEAD moved, hooks changed, and the like) can also be accepted with `resume RUN --accept-guard --note WHY [--retry]`: only when the person asked, never to get past your own change. It accepts the guard alone: the step's files, proofs and check still have to pass. Later guarded steps measure from the new base, so a cause still there (no commit, a rebase under way) stops them again. If `actions` lists only `cancel`, a resume can't get past it: tell the person. If `reason.recovery` is set, do that (or tell the person) before resuming. |
| `review_rounds_spent`, `review_no_change`, `review_incomplete`, `review_stale`, `review_guard` | A review of a step's work stopped. Plain `workflow resume RUN` starts a fresh round (`review_no_change`: reviews the same round; `resume RUN --from plan` reruns the author). `review_rounds_spent` refuses a plain resume: it needs `--extra-rounds N`. |
| `review_rejected` (`details.limit`) | `run` or `step`: `resume RUN --extra-attempts N`; `rounds`: `resume RUN --extra-rounds N`. `--extra-attempts` and `--extra-rounds` spend tokens and time: only when the person asked. |
| `pane_gone` | With `workflow status` showing `current.infra_retry` (`state` `scheduled` or `restarting`), do nothing: a new Claude Code pane restarts the step on its own at `due`, up to `workflows.infra_retry.max` times (needs `workflow` 50). When `state` is `exhausted`, or there is none: bring the pane back (`workspace launch NAME`), then `workflow resume RUN`. If the step's agent crashed with its attempt still open, `workflow resume RUN --restart-step` ends that attempt as `interrupted` and starts the step again in a fresh conversation (from another pane, never the run's own; it counts toward the run's attempt limit and token budget). |
| `paused` | The person paused the run. `workflow unpause RUN` lets it go on; `workflow resume` (including a parked resume, or one made from the run's own pane) is refused with `run_paused`. Never pause or unpause on your own. |

- A v2 run is polled with `workflow status --needs-me --json`. Follow each row's `next_action`, and run only commands in the row's `actions`.
- `current.review` is present only while a step is `reviewing`: `round`, `max_rounds` (includes any extras), `approvals`, `need`, `must`, `pending` (reviewers with no verdict), `stopped`, `held`, `next_round`, `rounds_spent` (true: a plain resume is refused), `pane` and `window`, and `reviews[]` with `reviewer`, `verdict`, `counted` and `problem`.
- `workflow events RUN --follow --json` streams a run's events until it finishes (first line says the follow started, last line has the final `state` and a `reason`; exit 0 when it completed, 1 when it ended cancelled, killed or failed, 75 when `--timeout DURATION` ran out first). `--types A,B` keeps only those event types; a `gap` line says lines were lost, so resume from the line number it names. `workspace daemon watch [WS] [--run RUN] [--since CURSOR] --json` (its first line says the follow started) adds the daemon's own decisions (advance started, run skipped, sweep started, process exited); pass the last `cursor` as `--since` to resume. Both only read; use them to see why a run is not moving. `workflow resume --json` carries `waits` (null, or `kind` and `text` saying what the run waits for). A refused line shows as `current.refusal` in `status` and `refusal` in `attempts`.
- `workflow trace RUN --json` (needs `workflow` 54) shows where a run's time went: `transitions`, `spans` (attempt, review_round, gate, wait, stall, downtime), `totals` (active_seconds plus stopped_seconds is clock_seconds; waiting by reason can overlap, so it may add up to more than stopped_seconds; `tokens` count cache-creation only) and `warnings` (lost events, a skipped line). `null` means unknown, never 0. It only reads.
- Each round's write-ups are in `<artifacts>/reviews/plan.<attempt>.r<round>/`, with `summary.md`; read them before resuming.
- `current.infra_retry` (`cause`, `n`, `max`, `due`, `state`, `reason`; null when none) means a step whose agent exited or whose pane is gone restarts on its own in a new Claude Code pane. `scheduled` and `restarting`: wait, and do not resume or restart it yourself. `exhausted` (`reason` says why): the run is stalled as before, so follow its `actions`. `infra_retry_not_claimed` means another process holds the restart; nothing was changed.
- Flags: `parked` (wait), `delivering` (do not resume). A reason's `actions` says what can be done, not what to do: `workflow resume` with empty `needs` is yours, while `approve`, `reject`, `resume --accept-guard`, `ask answer` and `dev down` wait for the person to ask. An action whose `needs` has an entry named `note` (`needs: [{"name":"note","flag":"--note"}]`) takes a note the person writes, not one you make up.
- Run `workflow recover` only when the person asks, after a reboot or tmux restart. It restores the workspaces of going runs, restarts steps that were mid-turn (at most `workflows.recover.max_per_run` times per run) and wakes the rest. Run `workflow recover --dry-run --json` first, since restoring a workspace also brings back all its recorded agent panes.
- The `--json` of `workflow audit` and `workflow sweep` has a next_actions list shaped like `actions` (plus an optional `why`). They are for the person: read them and tell the person; don't run them on your own beyond what the task allows.
- `workflow pause RUN [--interrupt] [--reason TEXT]` holds a run (nothing new starts, timeouts stop counting; `--interrupt` also stops the current turn); `workflow unpause RUN` releases it. `resume` is refused on a paused run (`run_paused`): unpause first. Only when the person asks.
- `workflow cancel RUN` can't be undone: run it only when the person asks, even when `actions` lists it.
- In a bound pane, `workspace step status` is your own read. The `bound_pane` and `parked` traps are in machine-contract.
