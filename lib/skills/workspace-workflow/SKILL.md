---
name: workspace-workflow
description: "Start and follow `workspace` workflow runs: `go` from a ticket, PR or text, name a preset (rpiv, rpiv-auto-approve, investigate, pr-feedback, explore), `workflow start`, `workflow run`, read `workflow status`. Use for 'run rpiv on this' or 'start an investigate workflow on PROJ-101'. Not a worktree with no workflow, or ending one: use workspace-lifecycle."
---

Written against workspace 0.91.0 with go (features.go); check with the working --help form.

Shared rules for `--json`, exit codes and error codes: [machine-contract](../workspace/references/machine-contract.md).

Never run `workflow approve` or `workflow reject` unless the person asked for that exact thing. The table is under Safety in skill `workspace`.

## Start with go

`workspace go [REF | "TEXT"] [--workflow ID] [--input KEY=VALUE]... [--dry-run] [--json]`. Check `workspace capabilities --json` for `features.go`; if it is absent, use `workflow start`. Run with `--dry-run` first, then the same command without it.

- Any whitespace makes the argument free text. A lone word is a ref, so `go rpiv` looks for a branch named rpiv: name a workflow with `--workflow`. Quote `'#123'`.
- The workflow is `--workflow`, then `workflows.by_ref.KIND`, then `workflows.default`, then `pr-feedback` for a pull request, else `rpiv`.
- If the request does not name a workflow, show the person what `--dry-run` chose and why, and wait for a yes before the real start. Unattended, use `workspace ask` (or `inbox add`) and stop; see workspace-inbox.
- It runs in place only in a linked worktree workspace on a branch that is neither the default nor the main checkout's. Otherwise it makes or reuses `.worktrees/<branch>`. A stopped workspace passes `--dry-run` and then fails at the pane: `workspace launch NAME` first.
- Free text fills `task` when the workflow declares it, here or in a new checkout. A branch ref, or bare `go`, with `rpiv` needs `--input task=TEXT`.
- On the main checkout, free text leaves uncommitted changes behind; to move them into the new worktree use `promote` (skill workspace-lifecycle).
- Run in place from the pane it would type into (usual for an agent), `go` types nothing and answers outcome `parked`, exit 0. The first step starts after your turn ends: end your turn now, and do not poll or run it again. A sub-agent finishes and lets the main agent end its turn. After an hour `workflow status` shows `parked_timeout`.

## Refusals

| Code | Meaning and what to do |
|---|---|
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
| "run rpiv on this", in a worktree workspace off the default branch, with text | `workspace go "TEXT" --workflow rpiv` |
| same, no text to hand | `workspace go --workflow rpiv --input task=TEXT` |
| "run rpiv on this", on the main checkout | Bare `go` is a usage error: give a ref or text. |

## Other forms

- `workflow start [ID] [REF | --prompt TEXT]` has what `go` lacks: `--branch`, `--base`, `--slug`, `--note`, `--agent-kind`, `--[no-]headless`, `--prompt-timeout`. `workflow start --help` lists them.
- `workflow run ID` runs in an existing checkout, with `--name` and `--pane`. It makes nothing, reads no ticket and does no fork check. It parks as `go` does.
- For any other `workflow` verb (`workflow show`, `workflow validate` and the rest), read `workspace workflow --help`.

## Presets

`workflow show` lists all ids, yours too; a file in `~/.config/workspace/workflows/` shadows a preset of the same id. `workflow show ID` prints one with all its inputs, optional ones too.

| ID | Required input | Steps | For |
|---|---|---|---|
| `rpiv` | `task` | research, plan (gate), implement, verify | One feature end to end; needs `commands.test` |
| `rpiv-auto-approve` | `task` | as `rpiv`, three reviewers in place of the gate | The same, unattended |
| `pr-feedback` | none | triage (gate), fix | Review feedback on a PR; never posts or pushes |
| `investigate` | none | reproduce, diagnose (gate), fix | A failing check or bug; stops `no_input` with no input and no PR |
| `explore` | `task` | survey (gate), report | Read-only research or gap analysis |

## Reading status

`workspace workflow status [RUN | --name WS | --project [NAME] | --all] [--table] [--json]`. No scope shows this workspace's runs still going; `--project` and `--all` include finished runs.

| Reason | Who acts |
|---|---|
| `waiting_lock` | Nobody; wait. |
| `waiting_you` | The person for a gate or prompt; for an ask, see workspace-inbox. |
| `turn_ended_incomplete`, `failed_check` | `workflow resume RUN`. If `actions` lists only `cancel`, a resume can't get past it: tell the person. |
| `pane_gone` | Bring the pane back (`workspace launch NAME`), then `workflow resume RUN`. |

- Flags: `parked` (wait), `delivering` (do not resume). A reason's `actions` says what can be done, not what to do: `workflow resume` is yours, while `approve`, `reject`, `ask answer` and `dev down` wait for the person to ask.
- `workflow cancel RUN` can't be undone: run it only when the person asks, even when `actions` lists it.
- In a bound pane, `workspace step status` is your own read. The `bound_pane` and `parked` traps are in machine-contract.
