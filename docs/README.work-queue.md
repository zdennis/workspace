# workspace work-queue

Keep a queue of work for a workspace: items that run one at a time, each a workflow run or a `workspace go`. `wq` is another name for `work-queue`. A new queue is off, and in this version only `work-queue advance` moves a queue.

## Usage

```sh
workspace work-queue add workflow ID [--ref REF] [--prompt TEXT] [--input K=V]... [OPTIONS]
workspace work-queue add go ARG [--text] [--workflow ID] [--input K=V]... [OPTIONS]
workspace work-queue list [--name WORKSPACE | --project [NAME]] [--json]
workspace work-queue show ITEM [--name WORKSPACE] [--json]
workspace work-queue active [--name WORKSPACE] [--json]
workspace work-queue rm ITEM... [--name WORKSPACE] [--json]
workspace work-queue move ITEM (--before ID | --after ID | --top | --bottom) [--if-revision N] [--name WORKSPACE] [--json]
workspace work-queue cancel [ITEM] [--and-continue] [--name WORKSPACE] [--json]
workspace work-queue enable [--name WORKSPACE] [--json]
workspace work-queue disable [--name WORKSPACE] [--json]
workspace work-queue resume [--name WORKSPACE] [--json]
workspace work-queue skip [ITEM] [--name WORKSPACE] [--json]
workspace work-queue advance [--name WORKSPACE] [--json]
workspace work-queue status [--name WORKSPACE | --project [NAME]] [--json]
workspace work-queue history list [--since DATE] [--before DATE] [--state STATE] [--name WORKSPACE | --project [NAME]] [--json]
workspace work-queue history show ITEM [--name WORKSPACE] [--json]
workspace work-queue history clear (--before DATE | --all) [--yes] [--name WORKSPACE] [--json]
```

Without `--name`, the workspace is the one detected from the current directory. `ITEM` is an item id or a unique start of one. `[OPTIONS]` on `add` stands for the flags in the table below that `add` takes.

## Options

A verb takes only the flags its own usage line and the table name; a flag it does not take is a usage error.

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace whose queue to use (default: detected from the current directory) |
| `--project [NAME]` | `list`, `status` and `history list`: every workspace of a project (NAME, or the project of the current workspace). Read only; excludes `--name` |
| `--top` | `add`: put the item first among the queued ones. `move`: move it there |
| `--bottom` | `move`: move the item to the end |
| `--after-current` | `add`: put the item right after the one that is running |
| `--before ID` or `--before DATE` | `add` and `move`: place the item before this item id. `history list` and `history clear`: finished before this date (`2026-01-31` or `2026-01-31T09:00:00Z`) |
| `--after ID` | `add` and `move`: place the item after this item id |
| `--if-revision N` | `move`: refuse with `stale_revision` unless the queue's revision is N |
| `--headless` | `add`: run the item without a pane |
| `--on-fail MODE` | `add`: `stop` (pause the queue when the item fails, the default) or `continue` |
| `--dedupe-key KEY` | `add`: adding the same key again changes nothing and says `unchanged` |
| `--ref REF` | `add workflow`: the ticket, pull request or branch to start from |
| `--prompt TEXT` | `add workflow`: the task text |
| `--input K=V` | `add`: a workflow input (repeatable) |
| `--text` | `add go`: ARG is free text, not a ticket, pull request or branch |
| `--workflow ID` | `add go`: the workflow to run instead of the one config picks |
| `--and-continue` | `cancel`: go on to the next item instead of pausing the queue |
| `--since DATE` | `history list`: finished at or after this date (`2026-01-31` or `2026-01-31T09:00:00Z`) |
| `--state STATE` | `history list`: only this outcome (`succeeded`, `failed`, `cancelled`, `skipped`, `interrupted`, `launch_failed`) |
| `--all` | `history clear`: remove every finished item |
| `--yes` | `history clear`: skip the question |
| `--json` | Print one JSON document |
| `-h`, `--help` | Show the help page; `workspace work-queue VERB --help` shows a verb's |

## Details

Each workspace has its own queue, kept in its state directory, with a log of finished items next to it. Items run one at a time. `add` puts an item at the end (or where `--top`, `--after-current`, `--before` or `--after` say; give at most one) and prints its id and position. A queue holds a limited number of items; past it `add` fails with `queue_full`. Adding a `--dedupe-key` again changes nothing.

### The queue is off, and only `advance` moves it

A queue is off until `work-queue enable`; `add` alone runs nothing. `disable` stops new starts; the running item keeps going and a pass still reads it.

In this version only `work-queue advance` moves a queue. A pass reads the running item and finishes or holds it, or starts the next one when the queue is on, not paused, and no workflow run is going in the workspace. Nothing runs a pass for you, so run `advance` again after each item ends. `advance` works in the workspace's own checkout and needs a branch. Each thing the pass did prints as a sentence. The exit code is 1 when every row of the pass ended badly, 3 when only some did, and 0 otherwise. A row ends badly when a start failed (`launch_failed`), a claim was lost, an item was `interrupted`, or a run `failed` or was `cancelled` and the queue paused for it; a failed or cancelled run under `--on-fail continue` does not count, and neither does an item that is just held. For `cancel --and-continue` the `cancelled` row is not counted. The outcomes and reasons are in [README.json.md](README.json.md#work-queue).

A pass that cannot start anything says why: the queue is `disabled`, `paused`, `empty`, or a workflow run is going (`run_going`).

### Item states

An item is `queued`, `starting`, `active` or `held`. At most one item is not `queued`, and it comes first. A finished item leaves the queue for history with an outcome: `succeeded`, `failed`, `cancelled`, `skipped`, `interrupted` or `launch_failed`. History is kept for 365 days.

- `starting`: a pass has claimed the item and is starting its run. The claim names the process that holds it. While that process is alive, another pass says the start is in progress and does nothing; run `advance` again once it lands. `rm`, `move`, `skip` and `cancel` refuse a starting item with `item_starting`.
- `interrupted`: a pass found a `starting` item whose process had died and no run carrying its claim. The item goes to history as `interrupted` and the queue pauses with that reason, since it is not known whether the start did anything. If the run did get made, the pass adopts it and the item goes on as `active`.
- `active`: the item's run is going. When the run completes the item finishes `succeeded`; when it fails or is cancelled the item finishes with that outcome.
- `held`: the item waits on a person. It is held at a gate, when the run waits for `workflow approve` (`work-queue active` says how to approve), and at a park, when the run is parked until something outside it changes (the actions are the run's own). It is also held when the run is stuck on a failure that a person can still repair (a failed check, a spent token budget, a run that timed out); then the queue pauses too. A held item moves on when its run does: approve it, or `work-queue skip` to give up on it.

### Failure pauses the queue and outlives the run

When an item fails or is cancelled, the queue pauses with that reason, unless the item was added with `--on-fail continue`. The pause is kept in the queue file, not in the run: it stays until `work-queue resume`, even after the run has ended and its item is in history. `resume` clears only the pause. A held item stays held; use `skip` for that.

`work-queue cancel` cancels the workflow run of the item given, or with no ITEM the one that is `starting`, `active` or `held`, records it as `cancelled` and pauses the queue. With `--and-continue` it does not pause, and one pass starts the next item (this needs a branch, as `advance` does). A queued item, or no current item, is `item_not_active`: remove a queued item with `work-queue rm`. A `starting` item is `item_starting`; retry once its start has landed.

`rm` takes several items at once and removes all of them or none; a name that matches no item, or two, removes nothing. `rm` and `move` refuse a `starting` item with `item_starting` and an active or held one with `item_active`.

### What `skip` does to a run that is still going

`skip` finishes the held item as `skipped`, clears the pause and never touches its run. If that run is still going it still blocks the next start (a pass refuses with `run_going`). The `skip` row then carries a warning and a `workflow cancel RUN` next action; run that to end the run. `skip` without a held item fails with `item_not_held`.

### `go` items need a linked worktree workspace

A `go` item runs `workspace go --here` in the workspace's checkout. `add go` refuses with `go_here_unavailable` where that cannot run in place: a main checkout, a worktree with no workspace of its own, a detached HEAD, or the default branch. Add the item from a linked worktree workspace. If a run is already going when the pass reaches the item, `go` takes its task route instead of starting a run, so nothing is started and the item is `launch_failed` with `run_going`.

### A `workflow` item without `--ref` runs in place

`add workflow ID` with no `--ref` starts the run in the workspace's checkout, on its current branch. The task comes from `--prompt` (when the workflow declares a `task` input), and the `task` and `pr` inputs are filled from the branch as `workflow start --here` fills them. With `--ref`, the run starts as `workflow start --ref REF` does. The run is never typed into the pane that runs the pass.

### Values and flags per kind

- `--on-fail` is `stop` (the default) or `continue`; anything else is a usage error. `--input` needs `KEY=VALUE`, and the value may hold `=`. `--if-revision` needs a whole number.
- `--ref` and `--prompt` belong to `add workflow`; `--text` and `--workflow` belong to `add go`. The other kind refuses them. `--input`, `--headless`, `--on-fail`, `--dedupe-key` and the position flags work for both.
- `add go` needs an ARG: a ticket, pull request or branch, or with `--text` the text itself. `add workflow` needs a workflow ID.

### Reading the queue

`list` prints one row per item (position, id, state, kind, what it runs, headless and age) and a footer: on, off or paused, and why. `show` prints one item: a line with its id, state, kind and what it runs, a line with its position, whether it is headless, its `on_fail` and when it was added, and, where set, one line each for its run id, reason, log path and error. A finished item is in `history show`. `active` prints the item that is starting, active or held and what it waits on, or `Nothing is active`. `status` prints one line per queue: on, off or paused, the active item and how many are queued. `--project` reads every workspace of a project and writes nothing.

`move` takes exactly one of `--before`, `--after`, `--top` and `--bottom`. The running item cannot move (`item_active`), and moving an item to where it is says `unchanged`. `--if-revision N` guards against someone else changing the queue: it fails with `stale_revision` unless the queue is at revision N. `list --json` gives the revision.

`history list` shows finished items oldest first; `history show` prints one with its spec, and its next action is the `work-queue add` that queues it again. `history clear` takes exactly one of `--before DATE` and `--all`, asks first unless `--yes`, and under `--json`, `--no-input` or without a terminal fails with `confirmation_required` instead of asking.

### JSON output

See [README.json.md](README.json.md#work-queue). Action verbs (`add`, `rm`, `move`, `cancel`, `enable`, `disable`, `resume`, `skip`, `advance`, `history clear`) print an action document; the reading verbs print a document with their payload under `queues`, `item`, `entries` or `entry`.

## Examples

```sh
# Two workflow items: run the first to its gate, approve it, then the second
workspace work-queue add workflow rpiv --prompt "Add SSO login"
workspace work-queue add workflow rpiv --prompt "Add audit log"
workspace work-queue enable
workspace work-queue advance       # starts the first item
# ...once the run reaches its gate:
workspace work-queue advance       # holds the item at the gate
workspace work-queue active        # shows the run id and the next action, `workflow approve RUN`
workspace workflow approve RUN     # RUN is the id `active` printed; see docs/README.workflow.md
workspace work-queue advance       # the item is still active: the run is not finished yet
# ...once `workspace workflow status RUN` says the run completed:
workspace work-queue advance       # records it `succeeded`, and starts the second item

# Queue an rpiv run, turn the queue on, and run the first pass
workspace work-queue add workflow rpiv --prompt "Add SSO login"
workspace work-queue enable
workspace work-queue advance

# Queue a ticket and run it before the others
workspace work-queue add go PROJ-42 --top

# A failure of this item does not pause the queue
workspace work-queue add go --text "Fix the flaky login spec" --on-fail continue

# See where the queue stands, then the item it waits on
workspace work-queue list
workspace work-queue active

# Give up on a held item, then run the next pass
workspace work-queue skip
workspace work-queue advance

# After a failure: look at it, then let the queue go on
workspace work-queue history list --state failed --since 2026-01-01
workspace work-queue resume

# For a script: move an item only if nobody changed the queue since revision 12
workspace work-queue move 3fa9 --bottom --if-revision 12 --json

# One line per workspace of the project
workspace wq status --project
```

The first block is a walkthrough. `advance` right after `workflow approve` shows the item still `active` (or `held`, if the run is still at its gate), because the run has not finished yet. `advance` reads a run only when it is called, so an item is held at its gate only on the first pass after the run reaches it. The second item starts on the first pass after the first run completes, which records the first item `succeeded` and goes on to start the next in the same pass. See [workflow](README.workflow.md) for `approve` and the gates. `add go` needs a linked worktree workspace (see above).
