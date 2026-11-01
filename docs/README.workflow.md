# workspace workflow

Run a workflow in a workspace: an ordered list of steps, each done by the agent in the workspace's Claude pane. `workspace step` is the agent's side of it.

## Usage

```sh
workspace workflow show [ID] [--source] [--json]
workspace workflow validate PATH|- [--id ID] [--json]
workspace workflow add ID PATH|- [--dry-run] [--json]
workspace workflow update ID PATH|- --if-sha256 SHA [--dry-run] [--json]
workspace workflow remove ID [--yes] [--dry-run] [--json]
workspace workflow run ID [--name WORKSPACE] [--input KEY=VALUE]... [--note TEXT] [--pane PANE] [--dry-run] [--json]
workspace workflow render ID STEP [--name WORKSPACE] [--input KEY=VALUE]... [--json]
workspace workflow start [ID] [REF | --prompt TEXT] [--branch BRANCH] [--slug] [--base REF] [--input KEY=VALUE]... [--note TEXT]
                         [--agent-kind KIND] [--[no-]headless] [--prompt-timeout DURATION] [--force] [--dry-run] [--json]
workspace workflow status [RUN | --name WORKSPACE | --project [NAME] | --all] [--table] [--json]
workspace workflow status --needs-me [--name WORKSPACE | --project [NAME]] [--json]
workspace workflow events RUN [--since N] [--json]
workspace workflow files RUN [--json]
workspace workflow attempts RUN [--attempt-of STEP] [--json]
workspace workflow audit RUN [--attempt-of STEP] [--json]
workspace workflow stats ID [--last DURATION] [--name WORKSPACE | --project [NAME]] [--json]
workspace workflow compare ID [--by definition | --by pack:NAME] [--last DURATION] [--name WORKSPACE | --project [NAME]] [--json]
workspace workflow sweep [RUN | --name WORKSPACE] [--dry-run] [--json]
workspace workflow sweep --install | --uninstall [--dry-run] [--json]
workspace workflow sweep --installed [--json]
workspace workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--extra-attempts N] [--extra-tokens N] [--json]
workspace workflow cancel RUN [--json]
workspace workflow approve RUN [--step STEP [--attempt N]] [--note-sha256 HEX] [--note TEXT] [--json]
workspace workflow reject RUN --note TEXT [--step STEP [--attempt N]] [--to STEP] [--extra-attempts N] [--extra-tokens N] [--json]

workspace step done [--status pass|fail] [--summary TEXT] [--code WORD] [--json]
workspace step status [--json]
```

| Subcommand | Description |
|------------|-------------|
| `workflow show` | List the definitions, or print one: its inputs and what each step does. A `.yml` entry that can't be a definition (a name that is not an id, a directory) is listed as `INVALID` with why |
| `workflow validate` | Check a definition's text, from a file or `-` for stdin, with the checks a definition on disk gets. Lists every problem at once and writes nothing; see [Validating a definition](#validating-a-definition) |
| `workflow add` | Save a definition, from a file or `-` for stdin, as `~/.config/workspace/workflows/ID.yml` after the checks `validate` runs. Refused with `workflow_exists` when that file is there; a preset of the same id is left alone and the copy shadows it. See [Adding a definition](#adding-a-definition) |
| `workflow update` | Replace your `ID.yml` with new text, from a file or `-` for stdin, only if the file still has the `--if-sha256` you read. A file that does not pass the checks can be replaced. Refused with `stale_workflow` when it changed, `builtin_workflow` for a preset with no file of yours. See [Updating a definition](#updating-a-definition) |
| `workflow remove` | Delete your `ID.yml` (a link itself, never its target). Asks first unless `--yes` or `--dry-run`; refused with `confirmation_required` under `--no-input`. A preset of the same id is in effect again. See [Removing a definition](#removing-a-definition) |
| `workflow run` | Start a run in a workspace (the current one, or `--name`). `--dry-run` checks the inputs, the project's commands, the packs and the pane, and starts nothing. Run from the pane it would use, the run is made and [parked](#resuming-from-the-runs-own-pane) |
| `workflow render` | Print the instructions a step's agent would be sent for its first attempt, composed without a run. Writes nothing; see [Rendering a step's instructions](#rendering-a-steps-instructions) |
| `workflow start` | Make a workspace from a ticket, pull request, issue or branch `REF`, or from `--prompt TEXT`, wait for its coding agent and run the workflow in it. The `ID` may be left out when config names a default. `--dry-run` checks everything and makes nothing. `--ref REF` in place of `ID` picks the workflow from the ref's kind ([routing](#routing-a-ref-to-a-workflow)). See [Starting from a ticket or a prompt](#starting-from-a-ticket-or-a-prompt) and [Default workflows](#default-workflows) |
| `workflow status` | The runs still going in this workspace, another's (`--name`), a project's (`--project`) or every workspace's (`--all`), or one run (`RUN`). Each shows its step and, when it is not moving, [why](#where-a-run-is-stuck). See [Which runs `status` shows](#which-runs-status-shows). `--table` prints one row per run beside its workspace: [the status table](#the-status-table). `--needs-me` lists only the runs waiting for you: [what needs you](#what-needs-you) |
| `workflow events` | A run's history (going or finished), one line per event, oldest first. `--since N` gives only the events after line N; at most 1000 at a time. See [Reading a run's events](#reading-a-runs-events) |
| `workflow attempts` | What a run recorded about each attempt, going or finished: outcome, failure code, HEAD before and after, hashes, packs, outputs, check, agent, session, tokens and reasons. Reads the run file and writes nothing. See [Reading a run's attempts](#reading-a-runs-attempts) |
| `workflow audit` | Check the evidence copies a run kept against the hashes recorded for them, going or finished. Exits 1 when a copy changed, is gone or was replaced. Reads the run file and the evidence directory and writes nothing. See [Auditing a run's evidence](#auditing-a-runs-evidence) |
| `workflow stats` | How each step of a workflow went across its runs, going and finished, in every workspace unless `--name` or `--project` narrows it: attempts, passes, failures, median time, resumes and tokens per run. `--last DURATION` keeps the runs started in that window. Reads the run files and writes nothing. See [Step statistics](#step-statistics) |
| `workflow compare` | Sets a workflow's runs side by side, grouped by the definition they ran or by the text of one pack their agent was sent: runs, share that passed first time and resumes per run, always with a warning that it shows a direction and proves nothing. Reads the run files and writes nothing. See [Comparing runs](#comparing-runs) |
| `workflow files` | The files a run keeps: each attempt's prompt, check log and proof logs and each step's `produces` entries, with whether each exists and its size. Reads file metadata only; a link is reported, never followed. See [Reading a run's files](#reading-a-runs-files) |
| `workflow sweep` | One pass over the runs going: record a pane or agent that is gone, start an agent daemon that is not running, decide a step whose agent ended its turn unseen, and apply a step's `on_timeout`. Needs no agent daemon. See [Sweeping stopped runs](#sweeping-stopped-runs) |
| `workflow resume` | Get a run going again; `--from STEP` starts again at that step. Refused with `--from` at a waiting gate from a pane a run is bound to. Run from the pane it would type into, it is [parked](#resuming-from-the-runs-own-pane) (outcome `parked`) and carried out after the agent ends its turn |
| `workflow cancel` | End a run and release what it holds |
| `workflow approve` | Pass a gate. Refused from a pane a run is bound to, and from a process under the run's own pane, so an agent doesn't approve its own plan by mistake. Records the gate's note when it names one. See [Passing a gate](#passing-a-gate) |
| `workflow reject` | Turn a gate down: the gated step, or an earlier one named with `--to`, runs again with the note in its instructions. Refused where `approve` is |
| `step done` | For the agent: record what it says about its step, then end the turn. Optional |
| `step status` | For the agent: which run, step and attempt its pane is on, and whether the files the step must leave exist |

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | `run`: the workspace to run in. `render`: the workspace whose packs and commands are read. `status`: only this workspace's runs still going |
| `--input KEY=VALUE` | `run`, `start`, `render`: a value for one of the workflow's inputs (repeatable) |
| `--note TEXT` | `run`, `start`: added to every step's instructions. `resume`, `approve`, `reject`: added to the next attempt's |
| `--pane PANE` | `run`, `resume`: the pane to run in (`%19` or `0.1`), instead of the workspace's Claude pane |
| `--from STEP` | `resume`: start again at this step |
| `--to STEP` | `reject`: the step to run again (the gated step, or one before it) |
| `--step STEP` | `approve`, `reject`: the gated step you saw (`current.step` in `status --json`); refused with `gate_not_waiting` unless the run waits at that step's gate |
| `--attempt N` | `approve`, `reject`: that step's attempt you saw (`current.attempt`); needs `--step`; refused with `gate_not_waiting` unless the run is on that attempt |
| `--note-sha256 HEX` | `approve`: the sha256 of the gate's note you read (`gate_file.sha256`), 64 lowercase hex digits; refused with `stale_revision` when the note changed |
| `--source` | `show ID`: print the file's text, with its sha256 and problems, valid or not; see [Reading a definition's file](#reading-a-definitions-file) |
| `--prompt TEXT` | `start`: the task as free text: the workflow's `task` input, and the branch's name when there is no `REF` |
| `--branch BRANCH` | `start`: the branch for a `--prompt` (default: the prompt's words). Refused with a `REF`, whose branch comes from the ref |
| `--slug` | `start`: add the ticket title's words to a JIRA or issue branch, as `start --slug` |
| `--base REF` | `start`: the branch or ref a new branch starts from |
| `--[no-]headless` | `start`: start the session in plain tmux, as `start --headless` |
| `--agent-kind KIND` | `start`: the coding agent the main agent pane runs |
| `--prompt-timeout DURATION` | `start`: how long to wait for the coding agent to be ready (60s by default) |
| `--force` | `start`: start although the workflow's `applies_to:` does not list the `REF`'s kind (otherwise refused with `workflow_not_for_ref`); the run starts with a warning |
| `--ref REF` | `start`: take the place of `ID` and `REF`: run the workflow `workflows.by_ref.<kind>` or `workflows.default` names for the ref's kind, else the one that fits; see [Routing a ref to a workflow](#routing-a-ref-to-a-workflow). Not with an `ID`, a `REF` or `--prompt` |
| `--since N` | `events`: only the events after line N of the run's history (a whole number, 0 or more; default 0) |
| `--id ID` | `validate`: check the text as this workflow id |
| `--project [NAME]` | `status`: every run of a project, going or finished. With no NAME, the project of the current workspace; the optional NAME takes the next bare word, so `status --project wr_x` looks for a project called `wr_x` |
| `--all` | `status`: every workspace's runs, going and finished |
| `--table` | `status`: one row per run, finished ones too at every scope, with its workspace's status and what still exists (see [the status table](#the-status-table)) |
| `--if-sha256 SHA` | `update`: the sha256 of the file's raw bytes, from `show ID --source --json` or `show --json` (the list); required |
| `--dry-run` | `run`, `start`: report what would start and start nothing. `add`, `update`: run every check and write no definition (the workflows directory and `.ID.yml.lock` may still be created) |
| `--status pass\|fail` | `step done`: `pass` (default) or `fail` |
| `--summary TEXT` | `step done`: one line about what was done, or what is left |
| `--code WORD` | `step done`: a word for why, kept as the failed step's `details.code` (see [Failure codes](#failure-codes)). Lowercase letters, digits and `_`, starting with a letter, at most 40 characters; anything else is a `usage` error |
| `--json` | Print one JSON document |

## How a run works

`workflow run` writes the run's file, binds the pane to the run (see [`binding`](README.binding.md)) and starts the first step. For each step, the runner:

1. takes the locks the step `uses:` for the run, in sorted order, in the same queue as [`lock acquire`](README.lock.md) and [`dev up`](README.dev.md). If one is busy, the run waits in the queue and nothing is typed;
2. writes the step's instructions to `.workflow/<run>/steps/<step>.<attempt>.prompt.md` in the checkout, built by the [instruction composer](README.instructions.md#workflow-steps): the default packs, the workflow's packs and `instructions:`, the step's packs and prompt, and what the runner knows about this attempt;
3. types one line into the pane, `Read <file> and follow it.` A step starts in a fresh conversation (the agent daemon types `/clear` first, as [`agent-run restart`](README.agent-run.md) does) unless it says `context: continue`. Neither line is typed over a draft: a Claude Code pane whose input box holds text is refused with `pane_busy` and `details.reason` `input_not_empty`, and the draft stays. The grey suggestion Claude Code shows in an empty box is not a draft.

A step is done when the agent's turn ends in the bound pane, every file the step `produces:` has been written during this attempt as a non-empty regular file (not a symlink; see [Produced files](#produced-files)), and its `status:` check passes. The check runs through `sh -c` in the checkout with three environment variables: `WORKSPACE_RUN_ID`, `WORKSPACE_RUN_ARTIFACTS` (the run's `.workflow/<run>` directory) and `WORKSPACE_RUN_BASE_SHA` (the checkout's HEAD when the run started; empty on an unborn branch or for a run made before it was recorded). They are environment variables, never placeholders rendered into the command, so no input text reaches the shell. A file an earlier attempt left (before a reject, a `resume --from` or a loop back) does not count until the step writes it again; its instructions say so. The workspace's agent daemon ([`agentd`](README.agentd.md)) sees the turn end and decides the step; `workflow run` starts the daemon if none is running. The daemon says when the turn that ended began (the prompt that started it), and the end of a turn that began before the step's attempt did decides nothing: if you were talking to the agent in the run's pane when a step was started (at a gate, say), the end of that conversation does not pass the step. The step's own turn's end does. The agent never has to report: `step done` only adds its own word, and `step done --status fail` fails the step at the turn's end without running the check.

- A step with `gate: approve` waits for `workflow approve` once it has passed. The run holds no lock while it waits. See [Passing a gate](#passing-a-gate).
- A step that fails (its check exits non-zero or runs past its time limit, or the agent reported `fail`) goes back to the step its `on_fail: {goto, max}` names, at most `max` times, and never once the run has made `max_attempts` attempts across all its steps. The step it goes back to is told what failed, and, with `log_tail`, shown the end of the check's log. With `backoff` the retry starts after a wait instead of at once ([Retrying a failed step](#retrying-a-failed-step)). After that the run stops and waits for you.

`workflow resume` and `workflow reject` hold to the same budget: one that would start an attempt (a failed or undelivered step run again, `--from`, a retry's wait ended, a `--pane` resume of a running step, any reject) is refused with `attempts_spent` (`details`: `attempts`, `max_attempts`, `step`) once the run has made `max_attempts` attempts, and nothing changes. Pass `--extra-attempts N` (a whole number from 1 up) to add N to that run's allowance and go on; N must cover the overrun (the attempt about to start has to fit), and the refusal names the least that does (`details.needed`, also in its message); the run file keeps it as `extra_attempts`, the event log records `attempts_extended`, the definition is not rewritten, and a later `on_fail` check counts against the raised total (`failed_check` `details.max_attempts` shows it). It also applies when the budget is not spent yet. A resume parked from the run's own pane is checked when it is parked and again when it is carried out, but not when it is typed again after a busy pane (that attempt was already counted); the flag is applied once, on release. A resume that starts no attempt (it only reports `unchanged`, decides a running step from a turn that is over, looks at a check, moves a passed step on, or asks for a lock again) is never refused and ignores the flag, as do `tick` and `workflow sweep`; attempts the sweep typed again (`redelivered`) do not count. Runs stored before this check get the same refusal. `workflow status` marks every action that would start an attempt (a plain resume only for a step that a resume would run again; resume `--from`; a gate's reject) with the `extra_attempts` need while the run has spent its attempts, read from the run as it is now. The need is `{"name":"extra_attempts","flag":"--extra-attempts","min":N}`: pass at least `min` (the same number as `details.needed`).
- With a `budget:` the run also stops before an attempt it can no longer afford ([Token budgets](#token-budgets)).
- When the last step passes, the run is `completed`, its locks are released and its pane is unbound.
- A check still running when its run is cancelled, killed or moved to another step is stopped within a few seconds, so it doesn't go on using the test database beside the lock's next holder.

`.workflow/` is listed in the repository's `info/exclude` (the common dir's, for a linked worktree), so the checkout stays clean and `.gitignore` is not touched. Run state lives outside the checkout, in `~/.local/state/workspace/.workflows/` (`$XDG_STATE_HOME`): `runs/<run>.json` and `runs/<run>.events.jsonl` while a run is going, `archive/` once it has finished (the newest 200 are kept).

Killing a workspace ([`kill`](README.kill.md), [`finish`](README.finish.md), `projects kill`) cancels its runs. Stopping one leaves its runs as they are: `status` shows `pane_gone`, and `workflow resume` after a relaunch moves the run to the workspace's Claude pane. A run of a stopped workspace keeps the locks it holds and its place in a queue, and takes a lock that frees while nobody can start its step: its workspace's agent daemon is what moves it. `status` warns about such a run; the ways out are `workflow cancel`, relaunching the workspace and `workflow resume`, or `workspace lock clear NAME`. [`restore`](README.restore.md) carries a run's binding to the pane it recreates, so the run goes on there. [`doctor`](README.doctor.md#workflow-runs) lists the runs still going whose checkout is gone, run files that cannot be read, and run locks whose run is over, each with the command that clears it; it changes none of them.

## Which runs `status` shows

`workflow status` takes one scope. At most one of `RUN`, `--name`, `--project` and `--all` may be given; two of them are a `usage` error, and so is a scope flag with a `RUN`, which used to be ignored. An empty value (`--name ""`, `--project=""`) counts as not given.

| You give | You get |
|----------|---------|
| nothing | The runs still going in the current workspace. Outside any workspace: `not_in_workspace`, exit 1, naming `--name`, `--project NAME` and `--all` |
| `--name WS` | The runs still going in `WS`. A name no workspace has is not an error: it prints no runs, exit 0, because run files outlive their workspace |
| `--project` | Every run, going or finished, of the project that holds the current workspace. A workspace that is in no project (detected, but with no config) is `unknown_workspace`; outside any workspace it is `not_in_workspace` |
| `--project NAME` | The same for the project `NAME`, from anywhere. An unknown project is `unknown_workspace` |
| `--all` | Every run of every workspace, going and finished |
| `RUN` | That one run, going or finished |

**The current workspace** is the one the working directory belongs to, found in three steps: a `.workspace` marker, then a key in the state file, then the configured checkout (main or worktree) that contains the directory, the deepest one if several do. The last step means a linked worktree with no config of its own, inside a main checkout that has one, resolves to the main workspace.

**The current workflow** is the runs still going in the workspace, oldest first. A workspace whose runs have all finished has none: `runs` is empty and the exit code is 0, and the text output says `Finished runs show with --project or --all.` (The `--name` form prints no such hint.) A run's end is read with `--project`, `--all` or `workflow status RUN`.

A project's runs are those whose workspace is one of its members, whose stored `project` is its name, or whose workspace is a worktree named `PROJECT.worktree-...`. These last two apply to going runs as well as finished ones, and they keep the runs of a worktree that was killed. So `--project` can list a same-named project's runs in any state.

Limits:

- Two projects with the same name share the runs matched by name.
- A run left under a mixed-case workspace name by a rename to lowercase is not matched by `--name` or the project's members, as before.

**Replacing the old forms.** Bare `workflow status` used to list the active runs of every workspace, and `--name WS --all` listed one workspace's runs of any state. `--name WS --all` is now `usage`. With `jq`:

```sh
workspace workflow status --all --json | jq '.runs[] | select(.state != "completed" and .state != "failed" and .state != "cancelled")'
workspace workflow status --all --json | jq '.runs[] | select(.workspace == "WS")'
```

An agent that needs a run's inputs reads them with `workflow status RUN --json`: a bare read can return two runs.

### What needs you

`workflow status --needs-me` answers "what is waiting for me?" across every workspace. It is a filter over the reasons and `actions` that `workflow status` already works out, so it reads the same panes and questions and no more: one daemon read for each workspace, however many runs it has, so a workspace whose daemon is dead costs its one-second wait once.

```
RUN            WORKSPACE     STEP       WAITING  WHY                  DO
wr_2611...ab   api.fix-auth  plan       2h 14m   gate                 workflow approve wr_2611...ab --step plan --attempt 2
wr_2611...cd   web.search    verify     38m      failed_check (test)  workflow resume wr_2611...cd
wr_2611...ef   workspace     implement  21m      stalled (agent_gone) workflow resume wr_2611...ef
```

**Scope.** With no flag it shows the runs still going in every workspace, never finished ones (a bare `status` is this workspace; `--all` includes finished runs, so `--needs-me --all` is a `usage` error, as are `RUN` and `--table`). `--name WS` or `--project [NAME]` narrows it, with the same rules as `status`; the two together are a `usage` error. Finished runs are left out even under `--project`.

**Which runs count.** Every run still going with a shown reason is listed, so a reason added later appears until it is named as one that clears by itself. Left out: `turn_ended_background` (a hold for background tasks), a `retry_backoff` whose resume names no other pane (the wait ends alone), and a `waiting_lock` for 30 minutes or less, or with no `since` (nothing says how long it has waited); a lock wait past 30 minutes is listed, because a holder that has not let go in that time is stuck (its next command is the first of the reason's actions, `workflow status HOLDER_RUN`, `dev down` or `lock status RESOURCE --name WS`; never a bare `workflow cancel`, so `next_action` is null and `DO` is `-` when nothing else is offered). A run with no reason is listed when it is `stuck`: the sweep noted a stall (`step_stalled` with `agent_gone` or `daemon_down`, say) that nothing has put right and its pane is not working (a pane that cannot be read leaves the stall listed), or its pane is idle and the daemon gave the turn's end (the flag `idle`). A stale stall mark on a working pane, a `checking` step, a line still on its way or a hold for background tasks is not stuck. A working run and a [parked](#resuming-from-the-runs-own-pane) one are not listed.

**In the inbox.** `inbox list --include-derived` shows a row for each run of this list that is waiting on a failed check, a lock wait past the 30 minutes, or a stall (`workflow_failed_check`, `workflow_waiting_lock`, `workflow_stalled`, `workflow_idle`), through the same rule, so the two lists agree; a gate, an undelivered step, a prompt or a question keeps the row it had. See [derived items](README.inbox.md#derived-items).

**Columns.** `WAITING` is how long since the reason's `since` (a stall's recorded time, or the turn's end for `idle`), `-` when the run has none. `WHY` is the reason's code, or the kind for `waiting_you`, with the failing check's code or the stall's cause in parentheses. `DO` is the first of the reason's `actions` (a `focus` is left out when the run has no pane), written as `workflow status` writes them, with an upper-case placeholder for each value you supply; a run whose only action is `cancel` (a guard a resume cannot get past) shows that. Rows are sorted by longest wait. A gate shows its note in `WHY`, as `gate (note.md)`. **`next_action` is a suggestion for a person who has read the run; a script must not run it unattended** (it can approve a gate or cancel a run). Text is escaped, since run fields can hold agent-written text. Nothing waiting prints `No workflow runs need you.` and exits 0; an unreadable run file is a warning, as in `status --all`, and makes the list incomplete: the exit code is 3, and the text says `No readable workflow run needs you; N could not be read.` in place of the empty line.

`--json` prints `{"schema_version":1,"ok":true,"generated_at":...,"status":"ok","unreadable":0,"runs":[...],"warnings":[]}`; `status` is `partial` (exit 3) when `unreadable` run files were left out. Each row has `run`, `workflow`, `workspace`, `step`, `attempt`, `code` (the reason code, or `stalled` / `idle`), `kind`, `gate_file` (a gate's note, else null), `detail`, `since`, `waiting_seconds` (null when `since` is), `next_action` and `actions` (`{action, args, needs}` as in `workflow status --json`). `workflow status --json` also gains `current.stuck` (`code`, `cause`, `since`, `actions`) for such a run, and no key otherwise.

### The status table

`workflow status --table` prints one row per run instead of the full description, and shows finished runs at every scope, not only with `--project` and `--all`. It answers "which of these runs still has a workspace to go back to?".

```
Run                  State               Workspace         Status               Config  tmux session  Worktree  State dir
wr_2610041230559x3k  running (implement) api.worktree-pdf  Live, agent working  yes     yes           yes       yes
wr_2610031100aa11bb  completed           api.worktree-tax  Stopped              yes     no            yes       yes
wr_2610021000cc22dd  cancelled           api.worktree-old  Gone                 no      no            no        yes
```

`kill` leaves the state dir behind, so State dir `yes` on a `Gone` row is normal.

The State column shows the step in parentheses while a run is going. `--json` prints a `rows` document instead (see [Workflow status rows](README.json.md#workflow-status-rows)).

The workspace columns describe the workspace as it is now, not as it was when the run ran. If a workspace was deleted and made again under the same name, an old run reads `Live`. Run files outlive their workspace, so a name with no runs is not an error: it prints `No workflow runs in NAME.` and exits 0.

| Status | Meaning |
|--------|---------|
| `Live, agent working` | The tmux session exists and an agent pane is working. This beats `waiting`: with several agent panes, one blocked on you still reads `working` if another is working |
| `Live, agent waiting` | The session exists and an agent pane waits on you, with none working |
| `Live, agent idle` | The session exists and its agent panes are idle |
| `Live, agent unknown` | The session exists, but the agent daemon did not answer in time or answered with no agent panes, so what the agent is doing is not known |
| `Stopped` | The workspace has a config but no tmux session. `workspace launch` can bring it back when the worktree is still there (Worktree `yes`) |
| `Gone` | No tmux session and no config: the workspace was removed |
| `Unknown` | tmux could not say whether the session exists and the agent daemon did not answer, the session is gone but the config could not be read, or the run's workspace name is unusable |

The other columns say whether each piece exists: `yes`, `no`, or `?` when it could not be read (tmux gave no answer, for example). Worktree is the checkout path stored with the run. A `no` in State dir can also mean nothing was ever written there.

`--project NAME` for a project with no members left is refused with `unknown_workspace`; use `--all` to see its runs. Rows are not cut to the terminal width: use `less -S`, or `--json`.

## Starting from a ticket or a prompt

`workflow start [ID] [REF | --prompt TEXT]` is `start` and `workflow run` in one step, for work that has no workspace yet. `workflow run` needs a workspace; `start` makes one. It takes a `REF`, `--prompt`, or both, not neither; `--name` and `--pane` are refused, because the run goes in the new workspace's own agent pane.

A library recipe can name a workflow, and `workspace start --recipe NAME REF` then makes this same call, with every check below. See [Running a workflow](README.library.md#running-a-workflow).

1. It reads the `REF` as [`start`](README.start.md) does (a JIRA key or URL, a pull request, an issue or a branch) and, for a ticket, reads its title (folded onto one line), body and URL with `gh` or `jira`; for a pull request, also `isCrossRepository`. A pull request from a fork is refused here (below).
2. It picks the branch. With a `REF` it is the ref's own: the JIRA key (plus the title's words with `--slug`), `issue-<n>` for an issue, `pr-<n>` for a pull request, a plain branch as given. With only `--prompt` it is `--branch`, else the prompt's words with no prefix (`add a hello script` is `add-a-hello-script`). A prompt with no letters or digits is a usage error asking for `--branch`. `--branch` is only for a `--prompt`; with a `REF` it is a usage error.
3. It seeds the definition's inputs. `task` is `KEY: title (url)` for a ticket, the prompt text for a prompt, and the ticket line then the prompt when both are given. `spec` is the path of the ticket body, written to `.workflow/tickets/<key>.md` in the new checkout (listed in `info/exclude`), and only when the ticket has a body. Only inputs the definition declares are seeded, and an `--input` you give always wins.
4. It runs the checks `workflow run` makes (`input_required`, `workflow_command_unset` for a `status: command:` or a `require: command:` that is not `optional: true`, `invalid_input`) against the project's main checkout, so a refusal leaves nothing behind. For a workspace it reuses, it also checks that checkout's tree: a workflow with a `guard: unchanged` step refuses a dirty one with `dirty_worktree`, before any agent starts. A checkout it makes starts clean and is not checked.
5. It makes the workspace as `start` does, with no confirmation, no play, no packs and no spine (the run's steps send their own instructions), waits for the coding agent (`--prompt-timeout`), and starts the run in that pane.

A workflow whose `applies_to:` does not list the `REF`'s kind (`jira`, `github_pr`, `github_issue`, `branch`) is refused with `workflow_not_for_ref` (`details.workflow`, `details.kind`, `details.applies_to`) and prints `warning`-style text such as `pr-feedback applies to github_pr, branch, not jira. Pass --force to continue.` The check reads the ref's text only, so it comes before the ticket is read, before the fork check and before anything is made, also under `--dry-run`. `--force` starts anyway and adds the mismatch to `warnings`. In text mode the warning prints on stderr as `warning: ...`; with `--json` it is in `warnings`. `pr-feedback` lists `github_pr` and `branch` (a branch can hold the pull request); a JIRA key or issue is refused. `--prompt` with no `REF` has no kind and is never checked. A workflow with no `applies_to:` applies to everything.

### Routing a ref to a workflow

`workflow start --ref REF` picks the workflow from a table, with no model deciding. `--ref` says the word is a ref, so it is never read as a workflow ID, and adds the single-fit step below; a start with no ID and no `--ref` refuses when no key is set (see [Default workflows](#default-workflows)). It takes no `ID`, no positional `REF` and no `--prompt` (usage errors); `--force` and `--dry-run` work as for any start.

1. The kind comes from `REF` (`jira`, `github_pr`, `github_issue` or `branch`).
2. The config keys win: `workflows.by_ref.<kind>`, then `workflows.default`, read as for [Default workflows](#default-workflows). They are read from the project the ref would join (the parent project when you run it inside a linked worktree) and then the global file; the worktree's own file is not read, since the worktree does not exist yet. Set one with `workspace config set workflows.by_ref.jira rpiv --scope project`.
3. With no key, the definitions that fit the kind are listed: a definition fits when its `applies_to:` lists the kind or is left out. Exactly one fit runs. Several are refused with `no_default_workflow`, listing each with its `use_when`; none fit is refused with the same code. A definition that cannot be read might fit, so while any is broken the single-fit route is never taken: the refusal lists the readable fits and the broken ids (`details.broken`). A valid configured default still routes past a broken unrelated file. Most presets have no `applies_to:`, so a ticket needs a default.

```console
$ workspace config set workflows.by_ref.jira rpiv --scope project
$ workspace workflow start --ref PROJ-101
Routing PROJ-101 (jira) to rpiv, this project's default for jira. Use --dry-run to see the steps.
```

A default that is not a workflow id, or that names no valid definition, is refused with `invalid_workflow_default` (`details.reason` `invalid_value` or `unknown_workflow`), never skipped for another workflow. A default whose `applies_to:` leaves out the kind is refused with reason `not_for_kind`; `--force` starts it anyway with a warning, as for `workflow_not_for_ref`. After routing the start is the same as `workflow start ID REF`: the `applies_to:` check, the ticket read, the fork check and every other check run. Under `--json` the `Routing ...` line goes to stderr; the document's `routed` (`ref`, `kind`, `workflow`, `source` `default` or `only_fit`, `scope` `project` or `global` for a default and `null` for `only_fit`, `key`) says the same. The row has `routed` only when `--ref` was used; without it the key is absent. A config file that does not parse stops the start with its parse error before any routing line is printed. From a repository that is not a registered project the suggested `config set` carries `--scope global`.

A ticket that cannot be read is refused (`ticket_not_found`, `ticket_source_unavailable`) when it was the only source of `task`; with `--prompt` or `--input task=` it is a warning and the run goes on without it. A pull request that cannot be read is always refused, since it can't be checked for a fork. A branch derived from `--prompt` that already exists, locally, on `origin`, or as `.worktrees/<branch>`, is refused with `branch_exists`: pass `--branch NAME` to use it, or another name. `workflow start` needs Claude Code as the workspace's agent (`--agent-kind`, else `agent.kind`); any other kind is refused with `workflow_needs_claude` before anything is made. A workspace that already exists for a `REF`, or for a `--branch` you named, is reused, as `start` does (`would_create` is `false` in the dry run, and `path` is where a branch checked out in another worktree lives), and the run starts in its agent pane.

`workflow start` never checks out a fork's code or starts an agent in it, for any workflow: an agent that starts in a checkout loads its `CLAUDE.md` and `.claude/settings.json` hooks. It refuses with `fork_pull_request`, before any worktree, check or agent, also under `--dry-run`. `details.reason` says which rule refused, `details.next` holds the `workspace start` command to use only if you trust the code, and the refusal is permanent: running it again gives the same answer.

- A pull request `REF` passes only when `gh` says `isCrossRepository` is `false` and the pull request's base (the `host/owner/repo` of its URL) is `origin`'s or `upstream`'s repository, as configured in the project. A remote written as a git `url.<base>.insteadOf` short form is read as git expands it, and an ssh remote's host alias (such as `git@github-work:o/r.git`) as `ssh -G` reports its `hostname`; a name ssh can't resolve, or one that resolves to another host, is compared as written and so refused. `details.reason`: `cross_repository` (from a fork), `unknown_cross_repository` (no boolean in `gh`'s answer, as from an old GitHub Enterprise Server), `other_base_repository` (another repository's pull request, such as `attacker/evil#1`, a bare `#N` that `gh repo set-default` resolves elsewhere, or a URL that isn't that pull request's). `details.pr`, `details.url`, `details.cross_repository`. A pull request that can't be read keeps the read's code.
- A branch it would reuse or adopt, or a local branch with no worktree that `start` would check out, is refused when its git config tracks another repository (read with no network): `branch.<name>.merge` under `refs/pull/` (`pull_ref`), a `branch.<name>.remote` that is a URL (`url_remote`) or names no configured remote (`unknown_remote`), or a remote whose `host/owner/repo` is neither `origin`'s nor `upstream`'s (`other_repository`; a local path or relative remote counts as another). `details.branch`, `details.path` (the project's root for a branch with no worktree).
- A `pr-<n>` branch (or one tracking the local `pr-<n>`) must hold the pull request being started. `start` records the pull request it checked out as `branch.pr-<n>.workspace-pr` (`owner/repo#n`, when the ref named the repository, as `workflow start` always does); another recorded pull request is `other_pull_request`. With no record, `#n` (or the recorded one, for a branch `REF`) is read with `gh` and must pass the pull request rules above, and be the same pull request (`other_pull_request` otherwise), since `start '#n'` drops a fork's upstream and git config can't tell. A read that fails keeps its code (`ticket_not_found`, `ticket_source_unavailable`) with `details.branch` and `details.path`.

Tracking config is a proxy for where a branch's code came from, not proof: a branch fetched by hand with no upstream (`git fetch alice feature:feature`) can't be told apart from your own. GitHub Enterprise Server pull request URLs are not refs `start` reads (they are refused as invalid branch names); use `#N` from a checkout of that repository.

If you trust the code, `workspace start '#N'` (or `workspace start BRANCH`) makes or adopts the workspace, and `workspace workflow run ID` in it starts the workflow. Its agent then starts in that code and loads its `CLAUDE.md` and `.claude/settings.json` hooks. For a bare `#N`, the checkout names the repository `gh pr view` answered from (`owner/repo#N`), so it can't check out another remote's pull request than the one checked; on another host than github.com it stays `#N`, which `gh` resolves from the same repository config.

Once the workspace exists, a failure never removes it. The error keeps its code and gains `details.workspace`, `details.path` and `details.next`, an array holding one command: the `workflow run` command with the same inputs and note, which starts the workflow in that workspace by hand. This covers `agent_not_ready` (the agent was not ready in time) and a refusal from the run itself such as `pane_has_run`, and `start_failed` (the session did not start). A failure inside `start` itself, once the checkout exists, carries `details.path` and a `next` that is `cd PATH && workspace workflow run ...`, as the workspace name is not known.

### Default workflows

`workspace go` chooses a workflow the same way and then starts it; see [go](README.go.md).

`workflow start` can leave out the `ID`. Config then names the workflow, by the kind of `REF`:

1. `workflows.by_ref.<kind>`, where `<kind>` is `jira`, `github_pr`, `github_issue` or `branch`, or `prompt` for a start with `--prompt` and no `REF`.
2. `workflows.default`, for any kind that has no `by_ref` key.

All six keys can be set globally or per project (`workspace config set workflows.by_ref.jira rpiv --scope project`). A global `by_ref` key beats a project `workflows.default`, because the more specific key is read first. `workflow start` reads the global and project layers only. It does not read a worktree's own setting, because the worktree is not chosen until the ticket has been read, and the ticket read needs the workflow.

With one argument, what it means depends on the word:

| You type | It is read as |
| --- | --- |
| `workflow start rpiv` | the workflow `rpiv`, when a workflow of that id exists. It still needs a `REF` or `--prompt`. |
| `workflow start PROJ-101` | a JIRA ref, so config chooses the workflow |
| `workflow start '#123'` or a URL | a pull request or issue ref, so config chooses the workflow |
| `workflow start fix-uploads` | a branch, so config chooses the workflow, and a warning says so |
| `workflow start fix-uploads --prompt "..."` | a mistyped workflow id: `unknown_workflow` |
| `workflow start --prompt "..."` | a prompt, so config chooses the workflow |

With no workflow named and no key set for the kind, the start is refused with `no_default_workflow` before anything is made. `details.kind` is the kind, `details.ref` is the word that was read as the ref (null for `--prompt`), and `details.known` lists the workflows that exist. A key that holds an id no workflow has is `unknown_workflow`, and `workspace config validate` warns about it ahead of time as `unknown_default_workflow`.

Three things to know:

- With a default set, a mistyped workflow id becomes a branch. `workflow start rpvi` starts the default workflow on a new branch named `rpvi`. It prints `Warning: ...` naming the workflow config chose and the known ids, and the same text is in `results[0].warnings` under `--json`. A word shaped like a ticket does not warn. Run it with `--dry-run` first to see the branch and the workflow.
- A branch named like a workflow needs the two-argument form. If a branch is called `explore`, `workflow start explore` runs the workflow `explore`. Use `workflow start rpiv explore` to run `rpiv` on the branch.
- A global `by_ref` key beats a project `workflows.default`. To change one project's workflow for every kind, set the project's `workflows.by_ref.<kind>` keys too, or remove the global `by_ref` key.

```sh
workspace config set workflows.default rpiv
workspace config set workflows.by_ref.github_pr pr-feedback
workspace workflow start PROJ-101 --dry-run --json     # rpiv, from workflows.default
workspace workflow start '#123' --dry-run              # pr-feedback, from workflows.by_ref.github_pr
```

## Definitions

A definition is a YAML file named for its id. `~/.config/workspace/workflows/<id>.yml` is searched first, then the presets that ship with workspace, so copying a preset there and editing it replaces it.

```yaml
schema_version: 1
id: ship
title: Plan, build, verify
description: A small change with a plan gate.
inputs:
  task: {description: What to build, required: true}
include: [review]            # packs added after the default ones
instructions: |              # for every step
  You are working on {{inputs.task}} in {{workspace}}, branch {{branch}}.
  Put this run's files under {{artifacts}}/.
max_attempts: 6
steps:
  plan:
    prompt: Write {{artifacts}}/plan.md. Don't change code.
    produces: [plan.md]
    gate: approve
    timeout: 45m
  build:
    prompt: Implement {{artifacts}}/plan.md.
    uses: [devenv]
  verify:
    prompt: Run the tests and review the diff. Write {{artifacts}}/verify.md.
    produces: [verify.md]
    uses: [devenv, test-db]
    status: {command: test}
    on_fail: {goto: build, max: 3, context: continue}
```

Top-level keys:

| Key | Meaning |
|---|---|
| `schema_version` | `1`, or left out |
| `id` | The file's name without `.yml`, or left out |
| `title`, `description` | For `workflow show` |
| `inputs` | Input name to `description`, `required` (default false) and `pattern` (a Ruby regexp source, at most 300 characters, matched against the whole value as `\A(?:PATTERN)\z`; it must compile, else `invalid_workflow`). `run --input NAME=VALUE` supplies them; one that is not required and not given is empty. A set value that doesn't match, or (for an input with a pattern) is over 4096 characters, is refused with `invalid_input` (details `workflow`, `input`, `pattern`, never the value) before any run exists, also under `run --dry-run` and `start`, seeded values included; only a truly empty value skips the check (whitespace is checked). `.` does not match a newline, so prefer explicit character classes such as `[0-9]+` or `[\w.-]+`; the match is cut off after 1 second on Ruby 3.2 and later |
| `include` | Pack names composed after the default packs, for every step |
| `instructions` | Text for every step |
| `max_attempts` | Attempts the run may make across all its steps before a failure stops it (default 6) |
| `budget` | `{tokens: N, action: stop}`, or left out (the default, no budget): the tokens the run may use before the next attempt is held. `tokens` is a whole number from 1 up; `stop` is the only `action`. See [Token budgets](#token-budgets) |
| `stall` | A duration such as `20m`, or left out (the default): how long a step's pane may sit idle, its agent's turn over, before `workflow sweep` decides the step. Only the sweep reads it; left out, the sweep never decides a step for being idle |
| `redeliver` | A whole number from 0 to 10 (default 3): how many times `workflow sweep` types a step's line again when it was not delivered (see [Sweeping stopped runs](#sweeping-stopped-runs)). `0` turns the retry off. A run stored before the key existed reads as `0` and is never retried |
| `use_when` | One line (at most 200 characters) saying when to pick the workflow; shown by `workflow show` and listed by `workflow show --json`. Left out: none |
| `applies_to` | A list of the ref kinds the workflow is for: `jira`, `github_pr`, `github_issue`, `branch`. `workflow start` with a `REF` of another kind is refused with `workflow_not_for_ref` unless `--force`. Left out (the default): every kind, no check. A run stored before the key existed has none |
| `deny` | A list of shell-glob patterns (at most 50, each at most 200 characters with at most 8 `*` or `?`) for Bash commands the run's agent may not run; see [Denying commands](#denying-commands). A run stored before the key existed has none |
| `steps` | Step id to step, in the order they run |

Step keys:

| Key | Meaning |
|---|---|
| `title` | For `workflow show` and `status` |
| `prompt` or `prompt_file` | What the step asks for. `prompt_file` is a path beside the definition, read when the run starts |
| `include` | Pack names composed for this step |
| `produces` | Files the step must write, as paths under the run's artifacts directory |
| `status` | A check run in the checkout when the turn ends: a command line, `{run: COMMAND}`, or `{command: test}` / `{command: lint}` for the project's own [`commands.test` or `commands.lint`](README.config.md); an unset one is refused at the start (`workflow_command_unset`), as is a non-optional `require: command:`. `timeout` (default `20m`) stops it; a `timeout` with no value is refused |
| `gate` | `approve`: wait for `workflow approve` after the step passes |
| `guard` | `unchanged` or `config`: the engine checks the checkout when the agent's turn ends (see [The guard](#the-guard)) |
| `require` | A list of proofs checked after `produces` and before `status` (see [Required proofs](#required-proofs)) |
| `uses` | Lock names the run holds for the step. `dev-env` is `devenv`; `edit` is refused (only the agent that edits can hold it). A step that uses `devenv` is not sent the `dev` pack, even when it is in the defaults or an `include:`: the run holds the environment for it |
| `on_fail` | `{goto: STEP, max: N}`: on failure go back to an earlier step, at most `N` times (default 1). `context:` overrides the target step's `context` for that jump. `log_tail: N` (1 to 200) adds the last `N` lines of the failed check's log to the retry's instructions, and `backoff: DURATION` (`90`, `30s`, `2m`, `1h`; more than 0, at most 24 hours) delays the retry; see [Retrying a failed step](#retrying-a-failed-step) |
| `context` | `fresh` (default): start the step in a new conversation. `continue`: keep the pane's conversation |
| `timeout` | How long the step may take before `status` flags it `timed_out`. Nothing is stopped unless `on_timeout` says so and `workflow sweep` runs |
| `on_timeout` | `warn` (the default), `interrupt` or `fail`: what a step past its `timeout` gets when `workflow sweep` runs: nothing (`warn`), the agent's interrupt keys once (`interrupt`), or a failed step (`fail`). Without a sweep every value behaves as `warn`. `interrupt` or `fail` with no `timeout` is a `workflow validate` warning |

Text in `instructions` and `prompt` may use `{{workspace}}`, `{{branch}}`, `{{artifacts}}` (the run's directory, `<checkout>/.workflow/<run>`), `{{run}}` and `{{inputs.NAME}}`. Any other placeholder is a problem in the definition. A definition with problems is reported with all of them at once (code `invalid_workflow`).

### Validating a definition

`workflow validate PATH` reads the file; `workflow validate -` reads stdin. It runs the same checks `show` and `run` do, reports every problem at once, and writes nothing (it does not touch `~/.config/workspace/workflows/`). It exits 0 when the text is valid and 1 with `invalid_workflow` when it is not. A file that is not UTF-8 text or not a YAML mapping fails the same way; a PATH that can't be read is a usage error.

A valid text can also get **warnings**, which never change the exit code and never stop `start` or `run`. Today there are five. `on_timeout_without_timeout`: a step sets `on_timeout: interrupt` or `fail` but has no `timeout`, so it never applies. `step_without_proof`: a step with no `produces`, no `status`, no `require` and no `gate` passes on any turn end, even one that did nothing, so validate names the step (`warning: step build has no produces, status, require or gate, ...`) and says what to add: a file it must write, proofs about the repository, a command that must pass, or `gate: approve` so a person decides. A gate counts as proof because the run waits for the person after the turn ends. No shipped preset warns on its own text; `rpiv` and `rpiv-auto-approve` use `commands.test`, so they get `command_unset` in a project without it. Three more warnings need more than the text. `on_fail_exceeds_max_attempts`: a step's `on_fail.max` retries can never all start under `max_attempts`. The run spends one attempt per step it delivers, so step N (counting from 1) first fails on attempt N at the earliest, and each retry delivers the steps from `goto` to it again (`span` steps). Retry M can start only while fewer than `max_attempts` attempts are made, so the rule warns when `N + (M - 1) * span >= max_attempts`; the message says how many retries fit and the `max_attempts` that fits them all. `--extra-attempts` on a run can still raise the limit. Each `on_fail` is checked alone: three steps with `max_attempts: 8` and `on_fail` `max: 3` and `max: 2` stay quiet even when both loops together can't fit. `unknown_pack`: an `include:` (the workflow's or a step's) or a default pack (`workflows.defaults.include`, added to every step; `step` is `null`) names a pack the library can't find. For the workflow's, the defaults and the first step, `start` would refuse it; `start` reads only the first step's packs, so for a later step it passes and the run stops when it reaches that step, which the message says. A pack name that can't be a name at all (`Bad/Name`, `{{task}}`) is a warning everywhere. `command_unset`: a step's `status: command:` or a `require: command:` not marked `optional` names `test` or `lint`, and the project has no `commands.test`/`commands.lint`, which `start` there would refuse as `workflow_command_unset`. The hint names `--name` when the project is a workspace, and otherwise says to run `workspace add .` first and then `workspace config set`. A pack named by the workflow, the defaults or the first step is warned about once, not again for a later step. These two read the project of the current directory, so they are warnings (the definition may be started in another project, and a project library can hold the pack). Outside a git checkout there is no project: they are not raised, and the document lists what was left unchecked in `not_checked` (`pack_not_checked`, for a pack that is not built in or global; `commands_not_checked`, which also appears, with the parse error, when the project's own config file doesn't parse; a broken global config is read as defaults and reported nowhere), printed as `not checked: ...` lines. A definition that needs neither check has an empty `not_checked`. Scripts read warnings from `workflow validate --json` (the `warnings` and `not_checked` arrays); no other workflow command reports them.

The id the text is checked as is `--id`, else a string `id:` in the text, else the file's name without its extension, else `stdin` for `-`, or `file` for a file whose name is not an id. An `id:` that differs from `--id` is a problem. A relative `prompt_file:` is read from the file's directory for a PATH and from the current directory for `-`. The problems name the paths they looked at, never their contents.

### Rendering a step's instructions

`workflow render ID STEP` prints what the agent of step STEP would be typed to read: the packs, the workflow's `instructions:` and the step's prompt with its `{{placeholders}}` filled, and the line about the files it must produce, as `start` composes them for the step's first attempt. It runs the engine's own composing code, so it can't drift from a delivery; a spec compares the two. It writes nothing (no run file, event, binding, lock, worktree or `.workflow/` directory) and calls neither tmux nor the agent daemon, so it works outside a tmux session. `STEP` is any step of the definition, not only the first.

Inputs are checked as `start` checks them (`--input KEY=VALUE`, repeatable): an input the workflow doesn't have is a usage error, a value that misses its `pattern:` is `invalid_input`, and a required input left out is refused with `input_required` rather than rendered with `{{inputs.task}}` unfilled, since text with holes in it looks like a prompt that works. An unknown step is `unknown_step` (`details.workflow`, `details.step`, `details.steps`); an unknown workflow, an invalid definition and an unknown pack give `unknown_workflow`, `invalid_workflow` and `unknown_library_entry` as they do elsewhere.

The checkout the packs and the project's `commands.test`/`commands.lint` are read from is the current workspace's (`--name` picks another). Outside a git checkout and any workspace the render still works from the current directory, with `{{workspace}}` shown as `<workspace>` and a `not_in_checkout` warning, since the project's own packs and commands were not read.

Some values belong to a run that does not exist. These are previews: `{{run}}` is `wr_preview`, `{{artifacts}}` (and the binding's artifacts and instructions paths) lie under `.workflow/wr_preview/`, the attempt is 1, and `{{workspace}}` is `<workspace>` when none was found. The text names them on stderr; `--json` lists them under `previews`. Text the runner adds under `## For this attempt` is not added, because it comes from what happens during a run: the run's `--note`; a retry's text (a failed check's log, a rejected gate's note, a backoff's text); a `resume --note`; and, for the step after a gate, the approval's `--note` and the line "The approved note is PATH, sha256 ..." that names the gate's note (`pr-feedback` `fix`, `investigate` `fix`, `explore` `report`). A real first attempt can therefore carry that section: `workflow run --note` reaches attempt 1 of the first step, and an approval or a resume reaches the step it starts. A render never does. A step with `gate: approve` is rendered like any other; stderr says the run would wait after its turn.

On a terminal the text is written with control, bidi and zero-width characters escaped (`\e`, `\u202E`), line by line, tabs kept, because a pack, a definition or an input can hold them. Piped or redirected it is written as is, so it can be saved or diffed. Warnings and preview values are escaped the same way.

### Adding a definition

`workflow add ID PATH` (or `-` for stdin) checks the text as `validate --id ID` does, then writes it to `~/.config/workspace/workflows/ID.yml`. It writes nothing else: a preset is never touched, and a copy of a preset's id shadows it, which is how a preset is changed. An `id:` in the text must be ID or absent. A relative `prompt_file:` is read from `~/.config/workspace/workflows/`, where the file will be loaded from, so what passes is what `run` will load.

It is refused with `workflow_exists` when a file of that id is already there (a link counts, even one to a file that is gone); change it with `workflow update` instead. The check and the write happen under an exclusive lock on `.ID.yml.lock` in the same directory, so two adds of one id can't both pass; the text is written to a temp file there and renamed over `ID.yml`. The lock file is left in place. `--dry-run` takes the same lock and runs every check, and writes no definition; it may still create the workflows directory and the `.ID.yml.lock` file. An ID that could not be a file name is `invalid_workflow` before any path is touched. `add` writes no event-log line.

### Updating a definition

`workflow update ID PATH --if-sha256 SHA` (or `-` for stdin) checks the new text as `add` does (a relative `prompt_file:` is read from `~/.config/workspace/workflows/`), then replaces `~/.config/workspace/workflows/ID.yml` if the file's raw bytes still hash to SHA. Take SHA from `workflow show ID --source --json` or the rows of `workflow show --json`; both hash the raw bytes, valid or not. `--if-sha256` is the bare 64-hex sha256 (case and surrounding whitespace don't matter) and is required: without it `update` is a usage error.

The current file is read as bytes and never parsed, so a file that is invalid YAML, fails the checks or is not UTF-8 can still be replaced: read it with `show ID --source`, fix it, and update. Under the same exclusive lock `add` takes, `update` checks that the file exists (a link counts), compares the hashes and writes a temp file renamed over `ID.yml`, so a save that waited on another sees the other's bytes and fails. Outcomes:

- `updated` with the new `sha256`; `--dry-run` runs every check under the lock and answers `dry_run`, writing no definition.
- `stale_workflow` when the hashes differ (or the file can't be read): nothing is written and `details.sha256` is the current file's, so the editor can reload. Take the current text with `show ID --source` and merge.
- `builtin_workflow` when only a preset has the id: presets are never written; save a copy with `workflow add`.
- `unknown_workflow` when nothing has the id.

`update` writes no event-log line.

### Removing a definition

`workflow remove ID` deletes `~/.config/workspace/workflows/ID.yml`. Without `--yes` (and without `--dry-run`) it asks `Remove workflow ID (PATH)? [y/N]` first, before taking any lock; anything but `y` prints `Cancelled.`, answers nothing and exits 0. Under `--no-input` (or `WORKSPACE_NO_INPUT`, which is how workspace-ui calls it) it refuses with `confirmation_required` and the retry flag `--yes`; `--json` without `--yes` or `--dry-run` is a usage error, since it never prompts.

Under the exclusive lock `add` and `update` take, `remove` checks that the file exists (a link counts), then unlinks it. A link is removed itself and never its target; a file that is invalid, not UTF-8 or a link to nothing can be removed, which is the way out `stale_workflow` points to for an unreadable file. A directory at that path is refused with `invalid_workflow` and nothing is removed. The `.ID.yml.lock` file stays. Outcomes:

- `removed`; when a preset has the same id the message says so ("the preset of the same id is in effect again"). `--dry-run` runs the same checks under the lock and answers `dry_run`, deleting nothing.
- `builtin_workflow` when only a preset has the id: a preset can't be removed.
- `unknown_workflow` when nothing has the id.

`remove` writes no event-log line.

### Reading a run's events

`workflow events RUN` prints the run's history file (`<RUN>.events.jsonl`, in `runs/` while the run is going and in `archive/` after), one line per event: the line number, the time, the type and the rest of the line's keys as `key=value`. It reads the file and writes nothing; a run with no history file has no events. An unknown run is refused with `unknown_run`. `--since N` must be a whole number, 0 or more, or it is a usage error.

Each event's `n` is its 1-based line number in the file, so a reader that remembers the last `n` (or `next_since`) asks for `--since N` and gets only what is new. A complete line that is not a JSON object (hand-edited, or blank: a blank line counts as a bad line) is skipped, keeps its number and is named in `warnings`. A last line with no newline yet is an event still being written: it is not returned, counted or warned about, and `next_since` stays at the last complete line, so the next poll gets it. At most 1000 events are answered; when more follow, `truncated` is true and `next_since` is the line number to pass as `--since`.

### Produced files

A run started with this version stores `"produces_check": "strict"` in its definition snapshot (`workflow status --json` does not show it; the run file does). For such a run each file a step `produces` must be, at the turn's end, a regular file (read with `lstat`, so a symlink as the last part of the path is never followed, even one to a real file; a symlinked directory earlier in the path is followed, as the check does not look at the parents) that is not empty and was written during this attempt. A symlink, a directory or an empty file keeps the step from passing: the run stores `turn_ended_incomplete` with `details.invalid`, a list of `{file, rule}` where `rule` is `symlink`, `not_regular_file` or `empty`. The run holds there: `step status` and `workflow status` name the rule that was broken. Nothing is typed to the agent; the next turn's end or `workflow resume` looks again. A link to nothing is a `symlink`, not `missing`. This is a hold, not a failure, so there is no `details.code` or `code_source`, and no `on_fail` applies. A run stored before this change has no marker and keeps the old check: the path exists (through a link, a directory counts) and was written this attempt. `step status` and the `turn_ended` decision use the same check.

### What an attempt records

Each attempt in the run file (`~/.local/state/workspace/.workflows/runs/<RUN>.json`, under `steps.<id>.attempts`) keeps, besides its number, times, prompt file, report and outcome, a record of what it started from and ended with. `workflow status --json` shows only the count of attempts, so read the run file for these:

| Key | Set | Meaning |
|-----|-----|---------|
| `head.before` | when the attempt begins | what `git rev-parse HEAD` answers in the run's checkout path, or `null` (unborn branch, git could not answer, or git took longer than 5 seconds). A checkout that lost its `.git` inside another repository reads that repository's HEAD. A `require: commits` check counts from this commit. |
| `head.after` | when the attempt ends (see below) | HEAD then, read the same way, or `null` |
| `remote` | before the attempt's line is typed, only for a step that requires `remote_unchanged` | `{remote, ref, sha}`: the branch on its remote, from `git ls-remote`; or `{unread}` with why there is no reading (`detached_head`, `local_upstream`, `bad_remote`, `no_remote`, `unreachable`); absent for a step that does not require it |
| `proofs` | as each `require:` proof that runs outside the run's lock goes (`command`, `remote_unchanged`) | one row per proof run outside the lock, and one per skipped optional `command`: `proof`, `index` (its place in `require:`), `timeout`, `started_at`, `ended_at`, `token`; for `command` also `role`, `command`, `log`, `exit_code`, `timed_out`, `error`; an optional `command` whose project command is unset leaves a row with `skipped: "command_unset"`, `optional: true`, `role`, `index`, `started_at` and `ended_at` (and no token); for `remote_unchanged` also `before` and the reading. Absent for a step with neither |
| `definition_sha256` | when the attempt begins | the run's definition hash (the run's own `definition_sha256`) |
| `prompt_sha256` | when the attempt begins | SHA-256 of the prompt file as written |
| `packs` | when the attempt begins | `[{ref, sha256}]`, each pack composed into the prompt |
| `outputs` | when the attempt ends (see below) | `[{file, sha256, bytes}]`, one per `produces` file, named as the definition names it; `[]` for a step with no `produces`. `sha256` and `bytes` are `null` for a file that is missing, a symlink, not a regular file or unreadable. A file above 16 MiB is not read: `bytes` is its size, `sha256` is `null` and `too_large` is `true`. A link as the last part of the path is never followed; a linked parent directory is, as in the `produces` check above. |
| `evidence` | the prompt when the attempt begins, the rest when it ends (see below) | `[{name, kind, source, sha256, bytes}]`: the attempt's prompt (`kind` `prompt`, copied as it is written, before it is delivered), check log (`check_log`, only when it had a check) and each `produces` file (`output`). The copy is `~/.local/state/workspace/.workflows/evidence/<RUN>/<name>` (`evidence_dir/<id>/<name>`); `source` is the path it was copied from. `name` is `<step>.<attempt>.prompt.md`, `<step>.<attempt>.check.log` or `<step>.<attempt>.out.<index>.<file>`, where `<index>` is the file's place in `produces` and anything outside letters, digits, `.`, `_` and `-` in the file becomes `_`, so two files never share a name. `sha256` is the hash of the bytes copied. Nothing is copied, and `sha256` is `null`, for a file with `problem` `missing` (missing, a link, not a regular file or unreadable), `outside_artifacts` (its directory, links resolved, is not inside the run's artifacts directory) or `copy_failed` (the copy could not be written); one above 16 MiB has `too_large` `true` and its size, and `budget` `true` as well when it fit the limit but the attempt's files together passed 64 MiB. A problem never fails the step; `null` for an attempt stored before this key existed. See [Evidence outside the checkout](#evidence-outside-the-checkout). |
| `code` | when the attempt fails or is not delivered | the failure's `code` (`require_<proof>`, a guard code, `check_failed`, or the agent's own code from `step done --code`); for a `not_delivered` attempt the delivery's code (`not_delivered`, `pane_gone`, ...). Absent for an attempt that passed, was cancelled, or was stored before this key existed. It stays on the attempt when a retry begins; the retry has its own |
| `check.command` | when the check starts | the command that ran, as resolved then: a later change to `commands.test` does not rewrite it. Absent when the project's command is unset. A step that names `status: {run: ...}` also has that text in the run's stored definition; one that names `command: test` or `lint` has only the role there, so this key is the only record of the text that ran. |
| `session` | when the attempt ends | `{id, transcript}`: the latest coding-agent session started in the run's pane at or before the attempt's end, from the session ledger. Only entries recorded under the run's workspace (or its tmux session's name) and, when both sides know it, the same tmux server count, since tmux reuses pane ids. A session that ended before the attempt began is not chosen. Only a SessionEnd at or after the start closes it, so a session resumed under the same id counts as live. One that began before the attempt (more than 5 seconds before) and never ended is chosen when the pane's tmux server is known and is the one it started under; otherwise only when its transcript has a line inside the attempt's window, and with no way to prove that the key is `null`. The server is read with a 2 second limit; no answer (also what a pane that is gone gives) proves nothing. A fresh-conversation restart or a `/clear` starts a session after the attempt begins, so the last one is the conversation that did the work. `id` must be letters, digits, `.`, `_`, `-`; `transcript` must be an absolute `.jsonl` path with no control characters, else `null`. Only the last 1 MiB of the ledger is read, and lines are matched on the pane id before they are parsed |
| `agent` | when the attempt ends | `{kind, version, model}`: `kind` from the ledger (`claude` when it names none); `version` and `model` from the transcript's lines inside the attempt's time window, each `null` when not read or not of the expected shape. `null` with `session` |
| `usage` | when the attempt ends | `{input_tokens, output_tokens}` plus `cache_creation_input_tokens` and `cache_read_input_tokens` when not zero. It is the main thread's count only: it leaves out sub-agents (`isSidechain` lines; their own transcripts are not read) and anything written after `ended_at` (`step done` stamps `ended_at` mid-turn, so later tokens of that turn are not counted). It sums the Claude Code transcript's assistant messages whose first line is stamped between the attempt's `started_at` and `ended_at` (a cancelled attempt counts to the time of the cancel), each message by its last line. A resumed attempt in the same session therefore does not count earlier attempts. `null`, never a smaller number, for another agent; for a transcript that is missing, a link, not a regular file or without a message in the window; when the last 4 MiB read (the limit, since this runs under the run's lock) does not reach back to the attempt's start, or, for a session whose `source` is `startup` or `clear` (which begin a new transcript file; `resume` and `compact` keep the old one), to that session's first line when that began later; when any usage line in the tail has no readable time; when a message's `usage` is present but not an object, and when a count is present but not a whole number from 0 up (an absent count is 0) |
| `reasons` | on every change of the run's reason | `[{code, since, until[, parked]}]`: each reason the run showed while this attempt owned it, oldest first; `until` is `null` for the one still standing. A resume parked for a busy pane is recorded as the reason `parked`; a park that times out is worked out when read and never stored, so its entry stays open until a change drops the park. `parked: true` is transient, present only while a park stands over the wait it closed. A change of code or `since` closes the open entry and opens another. An open entry with the same code and `since` is never repeated, wherever it sits, so a reason that stands when a later attempt opens stays on the attempt it began on. A new entry goes on the step's open attempt; else on the attempt that change just ended, only when its ending set the reason (a failed check for that attempt, a gate wait); else on the run (below). The reason `create` sets (`not_started`) is recorded too |

Which outcomes have end fields (`head.after`, `outputs`):

| How the attempt ended | End fields |
|-----------------------|------------|
| `passed` | yes |
| `failed` (a check that exited non-zero, timed out or could not run, a guard, an agent's report of failure) | yes |
| the run was cancelled, or its workspace was killed, while the attempt was open | yes, with no `ended_at` or `outcome` added; an attempt that already ended (for example one waiting at a gate) is left as it was |
| `not_delivered` (nothing ran) | no, except the prompt's `evidence` entry, copied before delivery |
| a parked resume or a background hold that ran out | no attempt ends, so none |

In every end field `null` means git or the file could not answer: a removed checkout gives a `null` `head.after`, and a removed artifacts directory gives `outputs` with `null` hashes. A recording problem never fails the step, the cancel or the kill. A reason set when the step has no attempt to own it (a wait for a lock before the first attempt, or before a retry's attempt exists) is kept in the run's own `reasons` list, with a `step` key naming the step; the same list shape applies. That includes a dispatch that could not start, and a wait for a lock on an `on_fail` retry. The run's list holds the waits outside any attempt, so a reader joins them to attempts by `step` and by time (`since`/`until`). A wait that a parked resume interrupts and the park gives back stays one entry: the park closes it with a transient `parked: true` mark, and the entry is reopened (`until` cleared, mark removed) when the park ends with the same wait standing. `session`, `agent` and `usage` are added with the end fields (`head.after`, `outputs`), including for a cancelled or killed run's open attempt. An attempt stored before these keys existed has none of them (every new key is optional), and `head.after` and `outputs` are only added when it ends.

### Evidence outside the checkout

The prompt, the check log and the `produces` files live in the checkout, where the agent can edit them and `git worktree remove` deletes them. The engine copies them to `~/.local/state/workspace/.workflows/evidence/<RUN>/` and records each copy's name and SHA-256 in the attempt's `evidence`. The prompt is copied when it is written, before it is delivered, so an attempt that was never delivered still has it. The check log and the outputs are copied when the attempt ends (including a cancelled or killed run's open attempt). `kill`, `finish` and `cancel` leave the directory alone. It goes when the run's archive entry is pruned past the newest 200 finished runs (the evidence first, then the archive files); a run still going is never pruned.

Each file must lie under the run's artifacts directory once links in its parent directories are resolved (else `outside_artifacts`), is opened without following a link, taken only if it is a regular file, and hashed and copied from that one handle. `outputs` takes its hash from the same copy when evidence is recorded, so one attempt never holds two hashes of one file. One attempt copies at most 64 MiB in all; the limit is per attempt, so a run's evidence grows with its attempts, up to the archive's retention. A file the copy did not take is still hashed for `outputs` as before, except one refused as `outside_artifacts`, which `outputs` records with a `null` hash. The file is opened by its resolved path and checked against a fresh resolution after opening, so a directory swapped for a link in between gives `outside_artifacts`. A stray temp file (`.tmp.<pid>.<name>`) from a copy that died is swept at the next copy, when its process is gone or it is over an hour old.

An agent under the same account can still change a file before it is copied, or the copy itself. The evidence makes a later change visible by comparing against the copy and its hash; it does not prevent one, and the prompt is the only file copied before the agent could touch it. A check log is whole when a check passes or fails; a cancel or kill that stops a running check records the log as it stood, and what the stopped check writes afterwards is not copied. A run stored before this has no `evidence` (`null` in `workflow attempts`).

### Token budgets

`budget: {tokens: 4000000, action: stop}` holds a run to a token total across all its steps. It is off unless a definition declares it; a run stored before the key, or with a bad stored value, has no budget. It is checked where a new attempt would start and never interrupts a turn under way, so a run can finish an attempt past its budget: the budget stops the next one.

In the text status the run reads:

```console
  budget_spent: step build was not started: 4,120,000 of 4,000,000 tokens  (resume --extra-tokens 1000000)
    workspace workflow resume wr_2611... --extra-tokens EXTRA_TOKENS
```

The figure after `resume --extra-tokens` is `suggested`; with uncounted attempts the line adds `(at least; N ended attempts not counted)`.

What is counted. The sum of the `usage` each ended attempt recorded ([What an attempt records](#what-an-attempt-records)): `input_tokens`, `output_tokens` and `cache_creation_input_tokens`. Cache reads are left out: they re-read context already paid for, and counting them would make any long turn look huge. Two things are never counted, so the total is always a **minimum**, and `status` says so (`budget.minimum` is always `true`):

- Sub-agents. The recorded `usage` is the main thread's.
- An attempt that was replaced without ending (a `resume --from` or `--pane` over a running attempt) counts with its `usage` when it has one, and as uncounted when it has none. The attempt a run is working on right now is left out until it ends, and is not uncounted.
- An attempt whose `usage` is `null`: another agent than Claude Code, or a heavy attempt whose last 4 MiB of transcript does not reach back to its start. These are counted in `budget.uncounted`, never read as zero. An attempt that was never delivered ran nothing and is neither counted nor uncounted.

Claude Code is the only agent measured. A run whose ended attempts are all uncounted (a Codex run, say) has a total of 0, which is under any budget, so its budget never stops it; `budget.measured` is `false` and `budget.counted` is 0. The alternative, stopping on an unknown figure, would end every such run after its first attempt for a number nobody can check. A run with some counted and some uncounted attempts stops as soon as the counted ones alone reach the budget, since the real total is at least that.

Where it stops. A run is held when the budget is used (`used` has reached `tokens` plus `extra_tokens`) at each point an attempt would start:

| Where an attempt starts | With the budget used |
|---|---|
| A step passes and the next one starts, an `approve` | Held: the run waits, `budget_spent`, with the next step left as it was |
| An `on_fail` retry straight away | Held: the loop count is spent, the failure text and `context: fresh` are kept for the resume |
| An `on_fail` retry after its `backoff` (a tick or `workflow sweep`) | Held when the wait is over |
| `workflow resume`, `resume --from`, a `--pane` resume of a running step, `workflow reject`, a resume over a retry's wait | Refused with `budget_spent` unless `--extra-tokens N` covers it; nothing changes |
| A resume parked from the run's own pane | Refused when it is parked and when it is released; not when it is typed again after a busy pane (that attempt was already counted) |
| `workflow sweep` typing an undelivered line again | Not held: the attempt spent nothing new |
| A lock wait that ends | Not held: the attempt was allowed when the step was reached |
| `unchanged` answers, a running check, a turn left to decide | Not an attempt, never refused |

A held run reads `waiting` with the reason `budget_spent` (`details`: `step`, `used`, `allowance`, `tokens`, `extra_tokens`, `counted`, `uncounted`, `needed`, `suggested`), holds no lock, and keeps its pane binding. It is listed by `workflow status --needs-me` and has an inbox row (`workflow_budget_spent`). A hold sends the `failed` alert of `alerts.workflow` (once, when the hold begins; `WORKSPACE_ALERT_REASON` is `budget_spent` and the text says the token budget is used), since no sweep or status look would tell an unattended run's owner. It keeps the pane it had (`budget_hold` in the run file holds the pane and its identity, and the pane stays claimed against other runs like a retry's wait), so `resume --extra-tokens` is held with a sentence, writing nothing, when that pane is now another run's, gone, or looks reused; `resume --pane PANE` is the proof, as for a retry's wait. `resume --from STEP` drops the text that sent the run back to the held step, as it does for a retry's wait. `workflow sweep` reports a held run as `nothing` with the reason `budget_spent` (a hold is not a failure, so the exit status is 0).

`--extra-tokens N` (a whole number from 1 up) on `resume` and `reject` adds N to the run's allowance and goes on. N must cover the overrun (`used` minus the allowance plus one, `details.needed`, also in the message); `details.suggested` rounds that up to the next 100,000 so one more attempt has room. The run file keeps the total as `extra_tokens`, the event log records `budget_extended`, and the definition is not rewritten. The flag also applies when the budget is not used yet, and is ignored by a resume that starts no attempt and by a run without a budget. The event log records `budget_spent` when a run is held.

`workflow status --json` gives a run with a budget a top-level `budget`: `tokens`, `action`, `extra_tokens`, `allowance`, `used`, `counted`, `uncounted`, `measured`, `spent`, `minimum`. Each action that would start an attempt gets the need `{"name":"extra_tokens","flag":"--extra-tokens","min":N,"suggested":M}` while the budget is used.

### Reading a run's attempts

`workflow attempts RUN [--attempt-of STEP] [--json]` prints what the run file recorded for each attempt (see [What an attempt records](#what-an-attempt-records)), going or finished, in the order the attempts began. It reads the run file and writes nothing. An unknown run is refused with `unknown_run`; `--attempt-of` with a step the run's definition doesn't have is refused with `unknown_step` (`details.steps` lists the real ones). `--attempt-of` is the flag's name because `--step` is for `approve` and `reject`; it is refused on any other verb.

Rows come from the definition's steps in order, then any other step the run recorded attempts for, so no recorded attempt is left out. Text output is a table with one row per attempt: `STEP`, `ATTEMPT`, `OUTCOME`, `CODE` (cut at 40 characters with a `~`; `--json` is whole), `HEAD` (`before>after`, seven characters each), `DURATION` and `TOKENS` (the main thread's input/output tokens). `-` stands for a value that was not recorded, such as the outcome of an attempt still going or any field of a run stored before it existed. Stored text is printed with control and invisible characters escaped. A wait recorded outside any attempt is printed after the table as `Reason outside any attempt: STEP CODE SINCE UNTIL`.

`workflow attempts --json` prints `{"schema_version":1,"ok":true,"run":ID,"attempts":[...],"unowned_reasons":[...]}`. Each attempt holds `step`, `attempt` (the attempt's `n`), `outcome` (`passed`, `failed`, `not_delivered`, or `null` while it is open), `code`, `started_at`, `ended_at`, `agent`, `session`, `head`, `definition_sha256`, `prompt_sha256`, `packs`, `outputs`, `check`, `usage`, `evidence`, `reported`, `proofs`, `reasons` and `redelivered`, with the values the run file stores under those keys; `check` is the stored check's `command`, `log`, `started_at`, `ended_at`, `exit_code` and `timed_out`; `reported` is the agent's `step done` report (`status`, `summary`, `code`, `at`) and `proofs` the rows of the `require:` proofs that ran outside the lock (see [What an attempt records](#what-an-attempt-records)). Every key is always present and `null` when the run never recorded it (`reasons` too: an attempt with no reason history has `null`, not `[]`). `redelivered` is `true` for an attempt that ended `not_delivered` and was typed again by `workflow sweep` (it does not count against `max_attempts`; the text table adds "(retried)" to its outcome), else `null`. `code` is the code the attempt failed with (an engine code such as `require_commits` or `check_failed`, or the agent's own `step done --code`), `null` for an attempt that did not fail and for any attempt stored before this key existed. `unowned_reasons` is the run's own `reasons` list: the waits that had no attempt to own them, each `{step, code, since, until}`, oldest first; with `--attempt-of` only that step's. They are not attached to rows, since a wait before the first attempt has no row to sit on; a reader joins them to attempts by `step` and time.

Needs `workflow` 12 in `capabilities` (`redelivered`: 17).

### Step statistics

`workflow stats ID [--last DURATION] [--name WORKSPACE | --project [NAME]] [--json]` shows, for each step of a workflow, how its attempts have gone across the runs of definition `ID`:

```
$ workspace workflow stats rpiv-auto-approve --last 30d
STEP         ATTEMPTS  PASSED  FAILED  MEDIAN  RESUMES  TOKENS/RUN
research           10      10       0  6m            2  310k
plan               24      23       1  11m           3  420k
plan_review        26      10      16  9m            9  640k*
26 runs of rpiv-auto-approve started in the last 30d.
```

It reads the run files, going and finished, and writes nothing. `ID` needs no definition on disk: only the runs are read, so the figures of a deleted definition still show. An `ID` with no runs prints `No runs of ID.` (exit 0; `--json` gives empty `steps`). With no flag every workspace is covered; `--name` or `--project` narrows it as in `workflow status`, and `--all` is refused as not needed. Rows follow the step order of the newest run's definition, then any step only older runs had; a step is the same step across definition versions when its id is the same.

`--last` takes `30d`, `2w`, `12h`, `90m` (a bare number means seconds; days and weeks are whole numbers; the forms `90`, `90s`, `5m`, `1h` also work). Only this window takes days and weeks; config durations and timeouts still take seconds, minutes and hours. A run is in the window when it started (`created_at`) at or after the cutoff, a run that started exactly at the cutoff included. A run with no readable start time is left out of a window and counted in `undated`. A bad value is a usage error. Finished runs are kept up to 200, so a long window may hold fewer runs than were made, and a run archived before an item was recorded shows only what it kept.

| Column | Meaning |
|--------|---------|
| `ATTEMPTS` | `PASSED` + `FAILED`: attempts that reached the agent and ended |
| `PASSED`, `FAILED` | By the attempt's stored `outcome` |
| `MEDIAN` | The middle of `ended_at - started_at` over those attempts that have both times |
| `RESUMES` | `run_resumed` events in the runs' histories, on the step each resumed (`resume --from STEP` counts on `STEP`, any other on the step the run stood at). A resume does not record why it was needed, and many followed a failed delivery. One naming no step is `unattributed_resumes` in `--json` and is noted under the table |
| `TOKENS/RUN` | The mean, per run, of the step's tokens: input, output and cache creation tokens of the main thread, the count `budget:` uses, over the same attempts the budget counts: passed and failed ones, and one a cancel or `resume --from` ended with no outcome (its tokens were spent), but not one still going or never delivered. Cache reads and sub-agents are never counted |

Where other attempts go: an attempt that was never delivered to the agent (`not_delivered`, or one marked `redelivered`) did no work, so it is counted apart (`not_delivered`) and left out of every column; an attempt with no outcome (still going, or replaced without ending), or any other outcome, is counted apart as `unfinished` and also left out of the other columns (its tokens are still counted, as above, so a step whose only attempt was cancelled shows ATTEMPTS 0 and a token figure; `tokens_from_unfinished` in `--json` counts those attempts, and the text output adds a note under the table when there are any). The text output notes how many of each were left out.

`TOKENS/RUN` never hides a missing count. An attempt whose `usage` is null (another agent than Claude Code, a run from before tokens were recorded, or a heavy attempt the transcript tail could not cover) makes its whole run uncounted for that step. The mean is over the counted runs only; `*` after it marks a step where some runs were left out, and `-` a step where no run was counted. `--json` gives `runs_counted` and `runs_uncounted` for every step.

`--json` prints `{"schema_version":1,"ok":true,"workflow":ID,"status":"ok"|"partial","last":TEXT-or-null,"since":ISO-time-or-null,"workspace":NAME-or-null,"project":NAME-or-null,"runs":N,"unreadable":N,"undated":N,"unattributed_resumes":N,"steps":[...]}`, each step `{"step","attempts","passed","failed","not_delivered","unfinished","median_seconds":N-or-null,"resumes","tokens_from_unfinished","tokens":{"mean":N-or-null,"runs_counted","runs_uncounted"}}`. A run file that cannot be read (the runs directory or the archive) counts in `unreadable`, since it cannot be told which workflow it belongs to: a damaged file of another workflow makes `partial` too; then `status` is `partial`, the exit code is 3 and the text output warns, because the figures are incomplete. Needs `workflow` 23 in `capabilities` (`compare`: 24).

### Comparing runs

`workflow compare ID [--by definition | --by pack:NAME] [--last DURATION] [--name WORKSPACE | --project [NAME]] [--json]` sets the runs of definition `ID` side by side, to see whether a change to the definition or to a pack moved the results:

```
$ workspace workflow compare rpiv-auto-approve --by pack:plan-review
SHA       RUNS  PASS-1ST  RESUMES/RUN
1dd4e0aa     6       33%          1.5
9ae2b7c1     4       75%          0.5
Too few runs to call this a difference; tasks also differ between runs, so this shows a direction and does not prove a cause.
```

Scope, `--last`, `--name`, `--project` (`--all` is refused), an `ID` with no definition on disk and the damaged-file behaviour are those of [`workflow stats`](#step-statistics): unreadable run files make `status` `partial`, exit 3 and a warning. `--by` is `definition` (the default) or `pack:NAME`; any other text is a usage error. It reads only what each run stored, so older runs can lack the hashes.

A run counts in exactly one group:

| `--by` | The run's group |
|--------|-----------------|
| `definition` | The run's `definition_sha256` (the definition it was started from, kept whole in the run, so it cannot change mid-run), else the one `definition_sha256` its attempts agree on |
| `pack:NAME` | The `sha256` of pack `NAME` (its name or its full ref) in the `packs` its delivered attempts recorded. The pack's text can change between attempts of one run: such a run is in the `mixed` group, under neither sha |

A run with no readable hash is in the `unknown` group: for `pack:`, a run whose delivered attempts recorded no `packs` at all (stored before they were recorded) or no hash for the pack. A run whose attempts recorded `packs` without `NAME`, and a run that never delivered an attempt (`not_delivered` only, or none), are in no group and are counted apart (`without_pack`, `no_attempts`). A `NAME` no run used is not an error: the groups are empty (exit 0), because an archived run may not have kept it, and the output says so.

| Column | Meaning |
|--------|---------|
| `SHA` | The first 8 characters in the table, all 64 in `--json`; `unknown` and `mixed` as described above |
| `RUNS` | Every run in the group, going and finished |
| `PASS-1ST` | The share of the group's settled runs that were a first try: they `completed` and every step they reached had exactly one delivered attempt, which passed. A rejected gate, a `resume --from` rerun or a loop adds an attempt, so it is a miss. An attempt that never reached the agent does not count, so a redelivery is not a miss. Settled runs are: every `completed` run, and a `cancelled` run or a run waiting on `failed_check` or `budget_spent` that missed. A cancelled run with no miss and any other run still going are left out (`cancelled` and `running` in `--json`), so an abandoned clean run or a run in progress counts neither way. A stuck run counts as a miss while it waits (`stuck` in `--json`); a later resume can move it to a completed miss, never to a first try. `-` when none settled. `resume --pane` on a running step whose pane died starts a second attempt, so it reads as a miss though nothing failed (accepted). In a completed run an attempt with no outcome (passed over by `resume --from` a later step) is a miss too. No run is stored as `failed`: the engine ends runs `completed` or `cancelled` |
| `RESUMES/RUN` | The `run_resumed` events in the group's histories (every run of the group, counted as in `workflow stats`) divided by `RUNS`, one decimal |

The output always ends with the sample warning, and `--json` always carries it as `warning`. Its first clause, `Too few runs to call this a difference;`, is dropped once every group has at least 20 settled runs and there are at least two groups. The rest stays: the tasks differ between runs, so compare shows a direction and does not prove a cause.

`--json` prints `{"schema_version":1,"ok":true,"workflow":ID,"status":"ok"|"partial","last":TEXT-or-null,"since":ISO-time-or-null,"workspace":NAME-or-null,"project":NAME-or-null,"by":"definition"|"pack:NAME","runs":N,"matched":N,"without_pack":N,"no_attempts":N,"unreadable":N,"undated":N,"warning":TEXT,"groups":[...]}`, each group `{"sha","runs","settled","first_try","pass_first_percent":N-or-null,"running","cancelled","stuck","resumes","resumes_per_run"}`. `runs` counts the runs read and `matched` those in a group. Needs `workflow` 24 in `capabilities`.

### Auditing a run's evidence

`workflow audit RUN [--attempt-of STEP] [--json]` compares each file in the attempts' `evidence` (see [Evidence outside the checkout](#evidence-outside-the-checkout)) with the SHA-256 recorded for it, for a going or finished run. It reads the run file and the evidence directory and writes nothing. An unknown run is refused with `unknown_run`, an unknown `--attempt-of` step with `unknown_step`.

Each recorded file gets one status. The run file is the trust root: the audit trusts the hash it records, so an edit to both a copy and its recorded hash is not detected. The comparison always uses the entry's own `sha256`, never the attempt's `prompt_sha256` (that hashes the composed text and may differ from the prompt file).

| Status | Meaning | Counts as a mismatch |
|--------|---------|----------------------|
| `ok` | The copy hashes to the recorded `sha256` | no |
| `changed` | The copy now hashes differently (`reason: unreadable` or `too_large` when it could not be hashed); or the entry has no recorded hash and no `problem` or `too_large` (`reason: no_recorded_hash`; the engine writes a hash on every successful copy); or the entry says nothing was kept yet a copy is there (`reason: unexpected_copy`) | yes |
| `missing` | The copy is not there; `reason` is `no_evidence_directory` (the run's evidence directory is absent, a link, or the run id is not a valid one) or `invalid_name` (the stored name is not a plain file name, so nothing was read) | yes |
| `replaced` | The copy is now a link or not a regular file (`reason`: `symlink`, `not_regular_file`) | yes |
| `not_copied` | The entry has a `problem` (`missing`, `outside_artifacts`, `copy_failed`; the `reason`): nothing was kept | no |
| `too_large` | The file was past the size limit (`reason: size`) or the attempt's 64 MiB budget (`reason: budget`): nothing was kept | no |

Entries from a run stored before evidence existed have no `evidence` key: they are listed under `without_evidence` (text: "No evidence recorded"), never as a mismatch. A stored `name` is read only when it is a plain file name (letters, digits, `.`, `_`, `-`), directly inside `evidence/<RUN>/`; the copy is looked at with `lstat` first and never read through a link, and the run's evidence directory must itself be a real directory. A prompt's or check log's `source` in the checkout is also hashed (only when it lies under the run's artifacts directory) and shown as `source_status` (`same`, `differs`, `gone`, `outside`, `null` for outputs); `differs` is printed as "checkout copy differs" and does not change the exit status, since a cancelled check keeps writing its log and a later attempt rewrites an output. Text output escapes the stored names and paths.

Exit status is 0 when no copy mismatched (including a run with nothing recorded) and 1 when any file is `changed`, `missing` or `replaced`. With `--json` the exit status is the same and the document is still printed: `{"schema_version":1,"ok":true,"run":ID,"step":STEP-or-null,"clean":bool,"counts":{status: n},"directory":"<evidence dir>/<RUN>","files":[...],"without_evidence":[{"step","attempt"}]}`. `ok` says the command ran, `clean` says no copy mismatched. Each `files` row has `step`, `attempt`, `name`, `kind` (`prompt`, `check_log`, `output`), `source`, `status`, `reason`, `recorded_sha256`, `now_sha256`, `bytes` and `source_status`; every key is always present. An agent under the same account could change a copy and the run file's hash together, so a clean audit shows no change since the copy, not that nothing was altered.

Needs `workflow` 14 in `capabilities`.


### Alerts

`alerts.workflow` makes the project's `alerts.notify` command run for a run's events, which nothing else tells a person about. It is a comma-separated list of `gate` (a step waits at a gate), `failed` (a step failed, or its check did: `failed_check`; or a run was held by its [token budget](#token-budgets), `budget_spent`), `stalled` (the sweep found a stall and recorded it) and `finished` (the run completed). Unknown names are refused by `config set`. Unset means none, so nothing new runs.

```console
$ workspace config set alerts.notify 'say "$WORKSPACE_ALERT_TEXT"'
$ workspace config set alerts.workflow gate,failed,stalled,finished
```

The alert is sent by the process that makes the change (the CLI, `workflow advance` or the sweep), after it gives up the run's lock, and needs no agent daemon. It is read from the change itself, so an event fires once for each episode: a gate when the step starts waiting (not on each `status`), a failure once for each step attempt (a failure whose `on_fail` retry is coming, straight away or after a `backoff:`, is not one: only a run that waits for a person is), a stall once for each attempt and cause (the sweep's marks), a finish once. A new attempt, or a gate asked for again after a reject, is a new episode. The settings are read each time, with no restart. The caller never waits for the command: it starts a detached supervisor process (its own process group), which runs the command, stops it with SIGTERM and then SIGKILL to its group after 10 seconds, and exits, so a hung command is stopped even when the process that changed the run has long gone. Each supervisor is bounded by that limit, so no cap on how many run is needed. A command that fails or is stopped is reported in `workflow-alerts.log` in the state directory (past 1 MiB it is renamed to `workflow-alerts.log.1`, replacing the older one, so at most two files of about that size are kept); a supervisor that can't be started is a line on the stderr of the process that changed the run. Neither fails or holds up the change. `config set alerts.workflow` warns when no `alerts.notify` is set for the workspace, since it sends nothing without one.

The command gets `WORKSPACE_ALERT=workflow`, `WORKSPACE_ALERT_EVENT` (`gate`, `failed`, `stalled` or `finished`), `WORKSPACE_ALERT_RUN_ID`, `WORKSPACE_ALERT_WORKSPACE`, `WORKSPACE_ALERT_STEP`, `WORKSPACE_ALERT_TEXT` and, when the run has one, `WORKSPACE_ALERT_REASON` (the reason code) and, for `stalled`, `WORKSPACE_ALERT_CAUSE`. A workflow alert has none of the pane variables (`WORKSPACE_ALERT_PANE`, `_PANE_ID`, `_KIND`, `_SECONDS`, `_MESSAGE`): a script that treats every `WORKSPACE_ALERT` but `waiting` as idle must check for `workflow` first. The values come from the run file, so they are escaped (control characters become `\n`, `\e` and so on) and each is cut to its first 200 characters before escaping (so an escaped value can be longer), and reach the command only as environment variables, never in its command line. The run's `next_action` is not passed: it is a suggestion for a person, and nothing runs it. The scheduled [sweep](#sweeping-stopped-runs) runs with the short `PATH` its plist records, so a notify command that the sweep may send (for a `stalled` alert) must be an absolute path, such as `/usr/local/bin/notify-me`, not a name found on your login `PATH`. A run stored before this setting works as it did.

Needs `workflow` 20 in `capabilities`.

### Sweeping stopped runs

`workflow sweep [RUN | --name WORKSPACE] [--dry-run] [--json]` is one pass over the runs still going (every workspace's, unless you name a run or a workspace). It is for the failures nothing else sees: a daemon that died, a pane that closed, an agent whose turn ended while no daemon was watching. It needs no agent daemon, so a scheduler can run it, and a run that another process is changing is skipped and looked at on the next pass.

For a step that reads `running` (or, for the delivery row, waits on an undelivered line), the sweep takes the first row of this table that applies:

| It finds | It does | Writes (in the run's history) |
|----------|---------|-------------------------------|
| The run's pane is gone | Nothing to the run. It keeps its checkout and locks until `workflow resume` or `workflow cancel`; the sweep only surfaces it | `step_stalled` cause `pane_gone` |
| The workspace's agent daemon is not running | Starts it (once for each workspace in a pass) and does nothing more to that run in the pass, since a new daemon's reading is not evidence; the next pass reads the pane. It also starts one for a run that is checking, parked or waiting for a lock. A start that fails is tried again on the next pass. A workspace with no tmux session gets none (`workspace_stopped`, not a failure) | `step_stalled` cause `daemon_down`, then `step_recovered` action `daemon_respawned` (written whenever a start succeeds and it is not yet written, once for each attempt) |
| The step is held (it has a reason, such as `turn_ended_incomplete`, with or without `details.invalid`, or `turn_ended_background`), its line is still being delivered, or its pane waits for an answer | Nothing. A person decides a held step. One exception: a step past its `timeout` with `on_timeout: fail` that is held on `turn_ended_incomplete` is failed (`step_timed_out`, then `on_fail`), because otherwise the timeout is never enforced. A `turn_ended_background` hold has its own 90-minute limit and is never touched | none (the failure writes `step_stalled` cause `timed_out` and `step_recovered` action `failed`) |
| The failed step's `on_fail` retry waits out a `backoff` (reason `retry_backoff`) | Nothing before the time (outcome `nothing`, `reason` `backoff`, `cause` `retry_backoff`): this is not a stall, and `stall` and `timeout` do not apply. Once the time has passed it starts the retry, as the daemon's timer or a resume would (outcome `retried`). The retry types a line, so a dead agent daemon is started first (outcome `respawned`, `cause` `daemon_down`, no stall recorded) and the retry follows on the next pass; `--dry-run` only reports the respawn. Before the time, no daemon is needed. A resume, a cancel or a tick that got there first stands | `step_retry_started`, then the step's own events |
| The step waits on a line that was never delivered (reason `waiting_you`, kind `dispatch`, error `pane_busy`, `restart_in_progress` or `no_daemon` raised before a request was sent: the failures that prove the line never reached the pane), the run has no park and the definition's `redeliver` is above 0 | Waits out a backoff after the failed attempt ended (1 minute, then 5, then 15 for the third and later), then, with the daemon running (else it starts one and tries on the next pass) and the pane showing an idle agent (idle at least 5 seconds), types the line again exactly as `resume` would; the typing goes through the same checks as every step line (`pane_busy` if the screen holds a draft or a busy row). Nothing retries unless something runs the sweep, and the installed schedule runs it every 300 seconds, so a 1 minute backoff waits up to 5 minutes. The failed attempt is marked `redelivered` and does not count against `max_attempts`; a retry that fails too is retried again, up to `redeliver` times. When the retries run out the run stays as it was, waiting for a person (the inbox row shows it), and the sweep records `redelivery_exhausted` once. A gone pane, a missing checkout, an unreadable pack and every failure that does not prove the line was never typed (`not_delivered`, where a slow paste may have landed; `connection_failed` and `unreadable_reply`, where the daemon may have typed it; `prompt_unconfirmed`) are never retried; a person's `resume` starts the count again | `step_stalled` cause `undelivered` (`code`, `retry`, `of`), `step_recovered` action `redelivered`, then the step's own events; or `step_stalled` cause `redelivery_exhausted` |
| The pane shows a shell where the agent was | Nothing to the run; it surfaces it | `step_stalled` cause `agent_gone` |
| The agent's turn is over, and the pane has been idle for the definition's `stall`, or the step is past its `timeout` with `on_timeout` `interrupt` or `fail`, or the sweep interrupted it earlier | Decides the step as `workflow resume` does when given the same proof (its files, `require:` proofs and check), so it passes, fails by `on_fail`, or is held; with `on_timeout: fail`, a decision that is a `turn_ended_incomplete` stop fails the step instead. The pane is read again just before the change and must still show the turn over and idle for at least 5 seconds | `step_stalled` cause `idle_turn_over` (`idle_for`), `step_recovered` action `evaluated`, then the step's own events |
| The agent is working and the step is past its `timeout` | `on_timeout: interrupt` presses the agent's interrupt keys once for the attempt; `fail` presses them and then fails the step (`step_timed_out`, which then follows `on_fail`); `warn`, the default, does nothing and writes nothing, as before. The press is claimed under the run's lock, made with the lock given up, and confirmed under the lock; it is made only if the pane, read again just before, still shows the same agent working and still belongs to the run, and a claim whose press never finished can be taken over after 60 seconds. If the press fails under `on_timeout: fail`, the step is not failed: the claim is given back, and each pass retries and exits non-zero until the keys go through | `step_stalled` cause `timed_out`, then `step_recovered` action `interrupted` or `failed` |

A run with a live [park](#resuming-from-the-runs-own-pane), a step whose check is running, a run waiting at a gate or for a lock, and a run whose step is not being worked on are left alone. A step with no `stall` and an `on_timeout` of `warn` is never decided for being idle; set `stall` (such as `20m`), or `on_timeout: interrupt`. A step the agent finished while the daemon was down passes on the next sweep once it has been idle that long, and no sooner than 30 seconds after the attempt began.

Every change goes through the run's lock, and is made only if the run is still on the step and attempt the sweep read, so a `resume`, a turn's end or a cancel that got there first stands, and the sweep reports `moved_on`. A cause is recorded once for each attempt: a second sweep writes no event and presses no key again, and a new attempt starts afresh. The marks are the run file's `sweep` key (`step`, `attempt`, `stalled`, `interrupted_at`); a run stored before the sweep has none. The sweep leaves a run alone when it runs in the run's own pane or under it, as `resume` is refused there. A small window remains between reading the pane and taking the lock: a turn that begins in it is decided as if it had ended, which the second reading, the idle floor and the attempt check keep to a moment.

A scheduler runs the sweep with a short `PATH`, which must include a Ruby new enough for workspace (`/usr/bin/ruby` can't load the code) and `tmux`; a missing program is a `failed` result with reason `tool_unavailable` that names it. A run file that can't be read is a `failed` result with reason `unreadable_run`.

`--dry-run` reads everything and changes nothing; its rows have outcome `dry_run` and say the `action` they would take. Text output prints a line for each run it acted on or noted, then a count. With `--json` it prints the [action document](README.json.md) with one result for each run looked at: `workspace`, `outcome`, `reason`, `message`, `run_id`, `step`, `attempt`, `cause`, `action`. Outcomes: `nothing` (`reason`: `healthy`, `idle`, `held`, `parked`, `checking`, `not_running`, `delivering`, `prompt`, `timed_out`, `already_recorded`, `already_interrupted`, `no_interrupt_key`, `refused`, `busy`, `moved_on`, `unknown`, `finished`, `backoff`, `pane_busy`, `not_delivered`, `waiting_lock`, `retry_blocked`), `recorded`, `evaluated`, `interrupted`, `timed_out`, `respawned`, `redelivered`, `retried` (an `on_fail` retry started after its backoff; `cause` `retry_backoff`, `action` `retry`), `dry_run` and `failed` (`daemon_not_started`, `interrupt_failed`, `tool_unavailable`, `unreadable_run`, or the code of an error reading the run). Other reasons under `nothing`: `workspace_stopped`, `pane_changed`, `not_working`, `no_attempt`. A `failed` result is a daemon that could not be started, an interrupt that failed, a missing program or an unreadable run file; a stalled run found and recorded is a finding, not a failure. The exit status follows the action document: 0 when no result failed, 3 when some did, 1 when all did. A usage error or an unknown RUN (`unknown_run`) prints the error envelope and exits 1, so a script tells it from a failed action by the document's shape (`ok: false` and `code`, against `action` and `results`), not by the exit code. Needs `workflow` 15 in `capabilities`.

#### Running the sweep on a schedule

`workflow sweep --install` writes a per-user LaunchAgent, `~/Library/LaunchAgents/com.workspace.workflow-sweep.plist`, and loads it with `launchctl bootstrap gui/<uid>`. launchd then runs `workflow sweep` every 5 minutes (`StartInterval` 300; it does not run at load). It is never done for you: not by `doctor --fix`, not by any other command, because it changes your login session.

- The plist records absolute paths read at install: the Ruby that ran `--install`, the `workspace` program (the Homebrew `opt` keg's `libexec/bin/workspace`, else the checkout's `bin/workspace`, and only a file with a Ruby shebang; a linked worktree is refused with `sweep_source_worktree`) and a `PATH` of Ruby's directory, tmux's directory and the system ones. launchd's own `PATH` finds the system Ruby (2.6), which cannot load this code. Homebrew `Cellar` paths are rewritten to the stable `opt` ones when those exist. After a Ruby or install move, run `--install` again: it rewrites the plist and reloads it.
- stdout and stderr go to `/dev/null`, so nothing grows. A scheduled pass leaves no trace of its own failures: a daemon that could not be started (`daemon_not_started`) or a Ruby crash is invisible. Its findings that are events are in each run's events (`workflow events`). To check the schedule, run `workflow sweep --installed` (`loaded`, `up_to_date`, `stale`) and a manual `workflow sweep --dry-run`.
- Running `--install` again changes nothing when the plist is as it would be written and loaded (`unchanged`); it loads a plist that was written but not loaded (`loaded`), and rewrites one that differs (`updated`). `launchctl` has to answer: when it can't run, times out or fails on the status check (only the text "Could not find service" means not loaded), nothing is changed and the error is `sweep_launchctl_failed`. A `launchctl` failure after the plist was written is `sweep_launchctl_failed` with `details.plist_written` true; run the command again to finish. A plist at that path that this command did not write (it carries a marker comment) is never touched: `sweep_entry_foreign`.
- `--uninstall` boots the entry out and deletes the plist (`removed`; `unchanged` when nothing was there). A failed boot-out keeps the plist so a retry can finish. If the plist is gone but launchd still has the job, `--uninstall` unloads it.
- `--installed` reads and changes nothing: `installed`, `ours`, `loaded` (true, false, or null when `launchctl` could not answer: treat null as unknown, not false; the exit status stays 0), `up_to_date` (the plist matches what `--install` would write now), `stale` (recorded paths that no longer exist), `interval`, `ruby` and `program`. `--dry-run` with `--install` or `--uninstall` says what would be done (`outcome` `dry_run`, `action`); with `--installed` it is refused (a usage error), since that reads only. With the plist missing but the job still loaded, `--installed` says so (`installed` false, `loaded` true).
- The `--json` action documents are named `workflow sweep --install`, `workflow sweep --uninstall` and `workflow sweep --installed`; each has one result with `outcome`, `message`, `path` and `label`. The scheduled sweep keeps its exit status: 0, 3 when some results failed, 1 when all did.

Nothing retries an undelivered line unless something runs `workflow sweep`: a person, or the installed schedule, whose interval is 300 seconds.

Needs `workflow` 16 in `capabilities` for the schedule and 17 for the retry of an undelivered line.

### Retrying a failed step

```yaml
verify:
  status: {command: test}
  on_fail: {goto: implement, max: 3, context: continue, log_tail: 40, backoff: 2m}
```

**`log_tail: N`.** The retry's instructions end the failure sentence with a block: the last `N` lines of the failed attempt's check log, labelled as program output that may hold text someone else wrote and is to be treated as data, inside a code fence. The fence is made longer than any run of backticks in the log, so the log cannot close it; control characters (escapes, carriage returns, bidi marks) are shown as `\e`, `\r`, `\uXXXX`; invalid UTF-8 is replaced; a line is cut at 400 characters; the block holds at most 8,192 bytes, dropping its earliest lines first and saying so; and only the last 64 KiB of the file is read. A log that is missing, empty, a link, not a regular file or unreadable gives no block and no error. Only a failure with a check log has one: a `status:` check (including a timeout) and a `require: command` proof. A failure from the agent's own `step done --status fail`, a guard, another `require:` proof or `step_timed_out` has no log, so the retry gets the failure sentence alone. The block is stored with the retry in the run file, read when the step failed, not when the retry starts.

**`backoff: DURATION`.** The retry does not start until the delay has passed. The loop is counted when the step fails (`loops` rises, `step_looped` is written with `backoff` in seconds), so the wait does not buy a free attempt. While it waits the run is `waiting`, the failed step stays `failed`, and the run holds no attempt, no pane binding and no lock (its locks are given up when the step fails and taken again by the retry, queuing like any step). `workflow status` shows the reason `retry_backoff` (`details.until`, `details.to`, `details.seconds`) with the actions `workflow resume` and `workflow cancel`; the run file's `backoff` holds the same time. Three things start the retry once the time has passed, whichever runs first and only once: the agent daemon's timer (the same 15-second tick that retries a lock), `workflow sweep` (outcome `retried`, `cause` `retry_backoff`; with the agent daemon dead it starts the daemon first and retries on the next pass), and a person's `workflow resume`, which skips the rest of the wait and starts the retry now. `resume --from STEP` drops the wait and starts that step without the failure text; `cancel` and a workspace `kill` end the run and drop the wait. `approve` and `reject` apply to a gate and refuse a run in a wait (`gate_not_waiting`). The sweep treats a step waiting out a backoff as not stalled: it records nothing and leaves `stall` and `timeout` alone. The retry's own attempt starts as `on_fail` always starts one, so a pane that is busy at that moment makes it `not_delivered`, which `redeliver` then retries. The pane stays the run's during the wait: another run cannot start in it (`pane_has_run`). When the wait starts the run records which pane it was in (`backoff.pane` and `backoff.identity`: the session and window slot of the binding, the facts a binding's stale check compares). The wait holds the pane only while tmux still has it as that pane: a pane that is gone, or whose id a tmux restart gave to another pane, holds nothing. When the retry comes due and the pane is no longer the run's (another run is bound to it, tmux no longer has it, or it is another pane under the same id; a stored wait with no identity can't be shown to be the same pane and is treated alike) nothing is typed and the retry is not spent: the run keeps its wait, marked `backoff.blocked` (`pane_has_run`, `pane_gone` or `pane_changed`) so a tick and the sweep leave it, and reads `waiting` with the reason `waiting_you` (kind `dispatch`, `details.error` the same code) or, for a gone pane, `pane_gone`. `workflow status` offers `workflow resume` with the `--pane` it needs and `workflow cancel`; `workflow resume --pane PANE` names another agent pane and starts the retry (a `step_retry_blocked` event records the hold). The sweep leaves a held wait alone: the pass that finds the retry held, and each later pass, gives one `nothing` result with `reason` `retry_blocked` (no stall is recorded, and it is not a failure and does not change the exit status, since only a person can name the pane). Text output prints it on every pass (`left alone (retry_blocked)`) and counts it as reported, because a person must act. A `workflow resume` of a held wait is decided before anything is written, so a held resume (even with `--note` or a `--pane` that is gone) changes nothing, writes no `run_resumed` or repeated `step_retry_blocked` event, and a hold that has not changed (same code, same pane) keeps its reason as it was. A bare `workflow resume` of a held wait starts nothing: the row's outcome is `unchanged` ("Nothing was done: ...", exit status 0) and the run stays waiting; `--pane` names the proof, so it skips the check that the pane is the one the run was in (it must still exist and be free). A `pane_changed` hold may be a false alarm (closing a pane beside it renumbers its slot), which `--pane` with the same id clears. A tmux that can't be run reads as not the same pane. A stored wait whose `to` is not a step name is ignored, and a resume runs the failed step as it stands. The log tail is read without blocking and never from a link, FIFO or other non-regular file; control, bidi, zero-width and tag characters (U+E0000 to U+E007F), variation selectors and annotation marks in it are shown as `\uXXXX`. A run stored before these keys has neither key in its definition and retries at once with no log, as before.

### Reading a run's files

`workflow files RUN` lists the files a run keeps, going or finished, from the run's own record: for each attempt its prompt (`prompt`), when a check ran its log (`check_log`), when a `command` proof ran its log (`proof_log`), and for each step each file it `produces`. It reads file metadata only and writes nothing. An unknown run is refused with `unknown_run`.

A file that is not there is listed with `exists` false and `bytes` null. A symlink is listed with `exists` true, `bytes` null and `link` true: it is never followed, so its target's size is never shown. A path that is not inside the run's artifacts directory (after resolving `..`, or through a linked directory) is left out. A run recorded before artifacts directories were kept uses `<checkout>/.workflow/<RUN>`; a run with neither answers `artifacts_dir` null and no files.

### Reading a definition's file

`workflow show ID --source` answers the file itself, for an editor: the text exactly as stored, the `sha256` of its raw bytes and every problem the checks find. It works on a preset and on a global file that does not pass the checks (exit 0, where `show ID` fails with `invalid_workflow`), so a broken file can be loaded, fixed and saved. Without `--json` it prints the text alone and writes the problems to stderr. `--source` needs an ID.

### The `rpiv` preset

`rpiv` is a workflow that ships (with [`rpiv-auto-approve`](#the-rpiv-auto-approve-preset), [`pr-feedback`](#the-pr-feedback-preset), [`investigate`](#the-investigate-preset) and [`explore`](#the-explore-preset)): research (`research.md`), plan (the workspace plan, `IMPLEMENTATION_PLAN.md` in the notes directory, in the `implementation-plan` syntax, plus `plan.md` for the gate), which is only done once the plan file exists and has a task (its `status:` check reads `plan status --json`), implement (`implement.md`) and verify (`verify.md`). Verify holds `test-db`, so runs in worktrees of one repository verify one at a time; it is checked with the project's `commands.test`, and a failure goes back to implement up to three times in the same conversation. Its `max_attempts` is 10, which leaves room for those three trips and one rejected plan. `implement` requires `commits: 1` and `plan_status: done`. The agent sets the plan's `status: done` last, and the commit must be made during that attempt, so a rerun (a pass back from `verify`, or a `resume`) has to make a new commit for the fix. The prompt says never to amend or rebase, which makes the proof unproven (`history_rewritten`), and to use `git commit --allow-empty -m '<why>'` when no code change is needed. `verify` requires `command: lint` with `optional: true`, so it passes only when the tests and, if the project sets `commands.lint`, the lint command both exit 0 (a project without one skips that proof, recorded under `proofs`). A project with no `commands.test` is refused before anything starts (code `workflow_command_unset`):

`research` and `plan` are `guard: unchanged`, so `rpiv` needs a clean checkout to start: a dirty tracked file, a stopped git operation or a branch with no commit is refused as `dirty_worktree` before anything is made, and a research or plan step that commits or edits a tracked file fails with the guard code (`head_moved`, `tracked_changed`). The plan and the artifacts are untracked, so writing them is fine. A run that has already started keeps the definition it started with, so runs begun before this guard behave as they did. `workflow run rpiv` (its tree defaults to the workspace's worktree) is refused on uncommitted tracked changes the same way, not only `workflow start`. A project that tracks `IMPLEMENTATION_PLAN.md` inside the repository fails `plan` with `tracked_changed`; clean the checkout and `workflow resume`. `workflow resume --from research` or `--from plan` after `implement` has committed stops with `head_moved`.

```sh
workspace config set commands.test "bundle exec rspec"
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export"
```

### The `rpiv-auto-approve` preset

`rpiv-auto-approve` is `rpiv` with no gate, for a run no person watches. A `plan_review` step takes the gate's place: the agent starts three reviewer sub-agents (supportive, skeptical and implementer) and writes `plan-approval.md` with the plan's revision and each verdict. Its check passes only when the skeptic and at least one other approved and the revision is still the plan's, so the skeptic can't be outvoted. A rejection goes back to `plan` in the same conversation, so the agent that wrote the plan looks for an approach that meets every reviewer's concerns and it is reviewed again, at most nine times; a tenth rejection stops the run as `failed_check`. Use `workflow resume --from plan` from there, which allows one more round, in a fresh conversation: a plain `resume` reviews the same plan again. The run stops where `rpiv` does, on a verified branch, and pushes nothing. Its `implement` and `verify` steps carry the same proofs as [`rpiv`](#the-rpiv-preset).

The check reads what the step's agent wrote; it can't prove the reviewers ran, so this is a review, not a security boundary. The reviewers need a harness with sub-agents, and a permission prompt in the pane still stops the run as `waiting_you`.

Its `research` and `plan` steps are `guard: unchanged` like `rpiv`'s, so it also refuses a dirty checkout at start (`dirty_worktree`). `plan_review` is guarded too. A commit made there fails with `head_moved`, `on_fail` sends the run back to `plan`, whose guard fails the same way, and the run stops with only `cancel` offered: the research is lost and a new run is needed.

```sh
workspace workflow start rpiv-auto-approve --prompt "add a retry to the uploader"
```

### The `pr-feedback` preset

`pr-feedback` triages a pull request's review feedback, waits for you, then makes the approved fixes. It has two steps and never posts to GitHub and never pushes.

- `triage` (gate `approve`, 30m) runs `workspace pr feedback --json`, reads the code each thread points at and the tail of each failing check's log, and writes a note `<date>-pr-<n>-feedback.md` in the notes directory: the counts of fix, answer, decline and needs-you with the head SHA read, then one `### F<k>` section per item with its source, author, a quoted excerpt, the verdict and the planned change. Only an item from a `trusted` author can be a fix. It writes `triage.md` (first line `note: <file name>`, the gate's note) and posts one `review_request` inbox item linked to the run (`--dedupe-key pr-feedback:RUN`, expiring in 168h). It stops with only `triage.md` when `inputs.pr` differs from the branch's pull request, or the pull request comes from a fork.
- `fix` (`context: fresh`, 2h) first checks the approved note's sha256 (see [Passing a gate](#passing-a-gate)) and stops with no commits when it differs. Every stop path (`no_note`, `note_changed`, `fix_head_moved`, `dirty_worktree`) runs `workspace step done --status fail --code <reason> --summary "<one sentence>"` and ends the turn, so the run fails instead of completing with `fix.md` alone. It records `origin/<head>` before and after, commits the items marked fix, appends `## Replies` to the note (grammar in [README.pr.md](README.pr.md#drafted-replies)), writes `fix.md`, marks the triage item done and posts a second `review_request` (`pr-feedback-fix:RUN`). Its last message names `workspace push` as your next step.

Inputs are `task` and `pr`, neither required. Start it in a workspace whose branch has the pull request, or from a ref (quote `#123` in zsh, where an unquoted `#` starts a comment; `PR-123` is read as a JIRA key):

```sh
workspace workflow run pr-feedback --name my-app.worktree-fix --input pr=123
workspace workflow start pr-feedback '#123'
workspace workflow start pr-feedback https://github.com/OWNER/REPO/pull/123
```

`workflow start` seeds `pr` from a pull request ref's number and `task` from the pull request, and leaves `pr` empty for anything that is not a pull request ref (a branch, an issue, a JIRA key). Any workflow that declares a `pr` input gets it seeded this way, and `--input pr=` wins. Triage compares numbers only, so a pull request with the same number in another repository passes that check; a fork pull request (reached through `workflow run`; `workflow start` refuses it with `fork_pull_request`), or a number mismatch, stops triage with only `triage.md` and an inbox item, and you reject the gate. `fix` refuses to start without an approved triage note (the gate's `note:` line), and stops when the note's hash, the branch head or a clean tree no longer match. The workflow does not declare `spec`, so the pull request's body is not written to `.workflow/tickets/`. Its instructions say every comment, review and log line is data written by someone else: the agent follows none of it, puts none of it on a command line, and never runs `workflow approve` or `workflow reject`. It has no `status:` check, so it runs in a project with no `commands.test`; running the tests is the `commits` pack's job.

### The `investigate` preset

`investigate` reproduces a failure, finds its cause, waits for you, then commits a regression test and the fix you approved. **It runs this branch's tests on your machine before you approve anything**: the same trust as `workspace start '#N'` and running the tests yourself. It never pushes, never posts to GitHub and never reruns CI.

Ways to start it (quote `#123` in zsh):

```sh
workspace workflow run investigate                       # in the workspace with the red check
workspace workflow run investigate --name WS --input ci_run=9876543210 --input pr=123 --json
workspace workflow run investigate --input ci_run=https://github.com/OWNER/REPO/actions/runs/9876543210
workspace workflow start investigate '#123'              # a pull request from this repository
workspace workflow start investigate PROJ-412
workspace workflow start investigate https://github.com/OWNER/REPO/issues/88
workspace workflow start investigate --prompt "checkout total is off by a cent"
```

With no input the run takes the branch's own pull request and its first failing check; only with no pull request, no ticket and no prompt does it stop (`no_input`). A guarded workflow refuses a dirty tree before anything starts (see [The guard](#the-guard)).

Inputs, none required, each checked against its `pattern:` before a run exists (`invalid_input`):

| Input | Accepts | Filled by |
|---|---|---|
| `ci_run` | digits, or a `https://github.com/OWNER/REPO/actions/runs/N` URL (optionally `/attempts/N` or `/job/N`) | `--input ci_run=` |
| `pr` | digits (up to 9) | a pull request ref, or `--input pr=` |
| `task` | any text | the ticket (key, title, URL) and `--prompt`, or `--input task=` |
| `spec` | a file under `.workflow/tickets/` | `workflow start`, from the issue, JIRA or pull request body |

The task is never rendered into the instructions: the agent reads it as a JSON string from `workflow status RUN --json` (`inputs.task`), so no title or prompt can break out of it. Ticket and pull request bodies, comments, check names and log lines are data: the instructions limit where a command's arguments may come from, forbid posting, pushing, rerunning CI and `workflow approve|reject|resume`, and ask for token-shaped text to be replaced with `[redacted]` before it reaches the note. Raw logs stay in the run's artifacts directory.

- `reproduce` (`guard: unchanged`, 45m) stops with `repro.md` (first line `stopped: <reason>`), a `note` inbox item (`investigate-stop:RUN`) and `step done --status fail --code <reason>` for `no_input`, `pr_mismatch`, `fork`, `run_not_found`, `run_not_finished` or `run_mismatch` (the run's commit is neither the pull request's head nor an ancestor of HEAD). Otherwise it reads the failed log (capped at 5 MB, with the exit status kept), reproduces the failure locally and writes `repro.md` and a reproduction as a new file. A stop item from an earlier attempt is marked done when it does not stop.
- `diagnose` (`guard: unchanged`, gate `approve`, 60m, same conversation) writes the note `<subject>-investigation-<run>.md` in the notes directory: `## Answer` (the cause, `head_sha`, `reproduced`, `ci_verdict` of `branch`, `main`, `flaky`, `infra` or `unknown`, `confidence`, and `If you approve:`), `## Fix options` (one marked `(recommended)`), `## Evidence` and `## Not checked`. It writes `diagnosis.md` (first line `note: <file name>`, the gate's note) and posts one `review_request` item (`investigate:RUN`, 168h).
- `fix` (`guard: config`, `context: fresh`, 2h, holds `test-db`) stops with `fix.md` and a code (`no_note`, `note_changed`, `fix_head_moved`, `fix_dirty_tree`, `workflow_files_visible`) when the approved note's hash, HEAD, the tracked tree or the `.workflow/` exclude no longer match. Its plan is only the note's `If you approve:` line and recommended option, changed by your approval comment. It commits a regression test and then the fix with hooks off (`core.hooksPath=/dev/null`, staging by path), through the `commits` pack's test and lint commands, appends `## Fix` to the note, marks the diagnosis item done and posts `investigate-fix:RUN`. Its last message names `workspace push` (or `workspace pr create`).

Approve with a note to change the plan ("approve, but use option B"), or reject with a hint and `diagnose` writes the note again, keeping the earlier answer under `## Rejected (attempt N)`. A stop code is a word the agent chose (`details.code` with `code_source` `agent`); a guard code (`head_moved`, `tracked_changed`, ...) is the engine's. Commit in the workspace while the gate waits and `fix` stops with `fix_head_moved`; `base_sha` in `workflow status --json` shows what HEAD should be. The guard bounds HEAD, the tracked tree and git's own files, not the machine: an agent talked into running something before the gate can do what your account can, so use it on code you would run anyway. `workflow run` never refuses a fork pull request; `reproduce` stops with `fork` (`workflow start` refuses it first, `fork_pull_request`).

A workflow's steps can hand the agent shell commands that hold the run's artifacts path, which lies under the checkout. `workflow run` (also `--dry-run`) and `workflow start` therefore refuse a checkout whose path holds a quote, a backtick, a dollar sign, a backslash, a control character or an invisible one (zero-width, bidi, U+2028, U+2029), with `unsafe_checkout_path` (`details.characters` names them, `details.path_kind` says `checkout` or `notes directory`; spaces and non-ASCII letters are fine). `workflow start` works out the path of a worktree it would create (`.worktrees/<branch>`) before anything is made, so a new unsafe path is refused first, also with `--dry-run`: no worktree, check or agent. The notes directory is held to the same rule for a workflow with a gate, since the fix step is handed the note's path (a branch name can reach it); the gate note is checked again when it is read. The refusal applies to every workflow, so a home directory like `/Users/o'brien` blocks them all.

### The `explore` preset

`explore` answers a question and changes no code: it surveys, waits for you to prune what it found, then writes a report. Use it for a gap analysis or design research, where `rpiv` would go on to build something. It needs no `commands.test`.

```sh
workspace workflow run explore --input task="What would make uploads resumable?"
workspace workflow start explore --prompt "What would make uploads resumable?"
```

- `survey` (`guard: unchanged`, gate `approve`, 90m) writes the note `<date>-<topic>-survey.md` in the notes directory: the questions, what exists today, each gap with its evidence, and a ranked list for you to prune. `survey.md` in the run's artifacts names the note on its first line, so the gate shows it, and a `review_request` inbox item (`explore:RUN`) links it. Approve with a note to cut the list or change the emphasis, or reject with a hint and it writes the note again.
- `report` (`guard: config`, 90m) reads the approved note, closes the inbox item, and writes `<date>-<topic>-report.md` in the notes directory with the verdict first, then ranked recommendations, then the detail, has a skeptical sub-agent check the claims against the code, and hands the note back through the `report` pack as a `note` inbox item. `report.md` in the run's artifacts holds the note's file name.

## Required proofs

A step's `require:` is a list of proofs the engine checks when the agent's turn ends, after the `produces` files are accepted and before the `status:` command runs (a step the agent reported as failed is not checked: it already failed). Each entry is one proof; the first that fails stops the check:

```yaml
implement:
  produces: [implement.md]
  require:
    - commits: 1              # at least one commit of the agent's own since this attempt began
    - nonempty: implement.md  # a non-empty regular file inside the run's artifacts directory, not a link
    - plan_status: done       # the workspace plan's status: is active, paused or done
    - tracked_clean: true     # no tracked file differs from HEAD, no rebase/merge/etc. under way (untracked files pass)
    - command: lint           # the project's commands.lint (or commands.test) exits 0
      optional: true          # with this line, an unset command passes the proof instead of being refused
    - inbox_item: "verify:{{run}}"  # the workspace's own inbox holds an item with this key, updated during the attempt
    - remote_unchanged: true  # the branch on its remote is where it was when the attempt began
```

A failed proof fails the step like a failed `status:` does, so `on_fail` and `workflow status` work unchanged. `details.code` is `require_commits`, `require_nonempty`, `require_plan_status`, `require_tracked_clean`, `require_command`, `require_inbox_item` or `require_remote_unchanged` (or `require_remote_unreachable`, see below), `code_source` is `engine`, `details.cause` is `require` and `details.detail` says what was required and found, such as `required 1 commit since 4f2a91c, found 0`. `commits` also has `required`, `found` and `base`; `tracked_clean` has `paths`. A proof that raises is `require_unknown` (unproven), with the exception class and message in `details.error`.

`commits` counts from the HEAD recorded when the attempt began (`head.before`, see [What an attempt records](#what-an-attempt-records)). The base is per attempt: commits an earlier failed attempt made do not count, and a `resume` of the same attempt keeps that attempt's base. It counts the commits on HEAD's first-parent line, merges left out (`rev-list --count --first-parent --no-merges`), and leaves out any commit reachable from another local branch or remote-tracking branch. Two refs are not "another": the branch itself, and its upstream when that holds the branch's own work, meaning a remote-tracking branch that is not the remote's default branch under a different name. An upstream that is a local branch, or `origin/main` for a branch named `feat`, is a shared base and does count as another branch (the default branch is what `refs/remotes/<remote>/HEAD` names, or `main` and `master` when that is not set; an upstream whose remote git cannot read is not exempt). So a merge, a fast-forward or a rebase onto `main` brings nothing in, and a commit also on a sibling branch is not counted. Two known limits: commits pulled from a topic branch's own upstream (`feat` tracking `origin/feat`) during the attempt still count, as does a commit the step pushes to it; and a commit a branch pushes straight to the default branch it tracks (`feat` tracking `origin/main`) is not counted, though a branch named like the default (`main` tracking `origin/main`) counts its own. A detached HEAD excludes nothing. If the base is not an ancestor of HEAD (the step amended, reset or rebased past it) the proof is unproven with `details.reason` `history_rewritten`: a step that rewrites its own attempt's base fails this proof. Empty commits still count, and are not detected. A proof that can't be read fails as unproven (`details.unproven` is `true`) and never passes: an attempt with no recorded starting commit (an attempt stored before HEAD was recorded, or an unborn branch), a base git doesn't know, git not answering within 5 seconds, a plan or notes directory that can't be read. Git runs the way the guard's does (see [The guard](#the-guard)): the global and system config are ignored, inherited `GIT_*` variables are dropped, hooks are off. `commits: N` takes a whole number from 1 to 1000. `nonempty` takes a plain relative path (no control character, no empty, `.` or `..` part, no leading or trailing space or `/`, not starting with `~`; validate refuses the rest) and is stricter than `produces`: the file must be a non-empty regular file and not a link, and its real path must lie inside the artifacts directory's real path, so a linked parent directory fails; a run with no recorded artifacts directory, or a file that can't be resolved, is unproven. `plan_status` reads `IMPLEMENTATION_PLAN.md` in the workspace's notes directory and compares the `status:` as written: a missing or non-canonical value (not `active`, `paused` or `done`) is unproven, even when `active` is required. `tracked_clean` also fails while a rebase, merge, cherry-pick, revert or bisect is in progress; it ignores submodules and cannot see `assume-unchanged` or `skip-worktree` files.

`command` takes `test` or `lint` and runs the project's `commands.test` or `commands.lint` the way a `status:` check does: through `sh -c` in the checkout, with `WORKSPACE_RUN_ID`, `WORKSPACE_RUN_ARTIFACTS` and `WORKSPACE_RUN_BASE_SHA` and no inherited `GIT_*` variable, its output in `steps/<step>.<attempt>.require-<role>.<token>.log` in the artifacts directory. It passes on exit 0 and fails on any other exit (`details.exit_code`, `details.log`). A command that is not set (unless the entry has `optional: true`, which skips the proof and records it in `proofs`; `workflow start` and `workflow run` refuse an unset non-optional one before anything starts, listing every unset command with its step), runs past 5 minutes (it is stopped) or cannot start is unproven. Because it runs a shell, the run's own agent cannot `resume` its run from its own pane (as for a `status:` or `guard:` step).

`inbox_item` takes a dedupe key, which may hold `{{run}}`, `{{workspace}}` and `{{inputs.NAME}}` (other placeholders fail `validate`). It passes when the workspace's own inbox holds an item with that key, in any state, whose `updated_at` is not before the attempt's `started_at` (the inbox keeps whole seconds, so the same second counts). So an item the step posted and closed counts, and one left from an earlier attempt or run does not, even under a key with no `{{run}}`. Only the workspace's inbox is searched: an item added with `--project` or `--global` does not count. Adding to a key whose item is done or dismissed changes nothing, so a step that runs again under such a key must pass `inbox add --reopen`. Anyone closing or editing an old item during the attempt also makes it count. When an agent forgets to post, the step fails with `details.code` `require_inbox_item` and a `details.detail` such as `required an inbox item with dedupe key explore:wr_1 in workspace app's inbox, found none`, and `on_fail` or a resume decides what follows. A key that renders to something that is not a valid dedupe key (1 to 200 letters, digits and `. _ : / # @ -`) is unproven.

`remote_unchanged` compares `git ls-remote` on the remote a `git push` would go to (`branch.<b>.pushRemote`, then the repository's own `remote.pushDefault`, then `branch.<b>.remote`, then `origin`) for the ref the branch tracks (`branch.<b>.merge`, else `refs/heads/<branch>`; on a push remote other than the tracked one, `refs/heads/<branch>`, except that a `pr-N` branch keeps a `refs/heads/` merge ref) with the reading recorded as the attempt's `remote` (`sha` is `null` when the remote has no such branch). Only a step that requires it touches the network. It fails when the sha differs (`details.before`, `details.after`: the step pushed, or deleted, the branch). Each `ls-remote` has a 15 second limit (with the local reads, at most 45 seconds in all) and no prompt (`GIT_TERMINAL_PROMPT=0`, ssh in batch mode, only the https, ssh, git and file protocols). The user's and the system's git config are ignored, so the remote needs a non-interactive credential such as an ssh key in an agent: a credential helper, `insteadOf` or `core.sshCommand` is not used, and a private https remote that relies on one reads as unreachable every time. A remote that cannot be read when the check runs is unproven with `details.code` `require_remote_unreachable`. It is unproven as `require_remote_unchanged`, with the reason in `details.detail`, when there was no reading when the attempt began (a detached HEAD, a branch whose upstream is local, a remote that does not exist, an unreachable remote), the attempt was stored with none, or the branch came to track something else.

`command` and `remote_unchanged` run with the run's lock given up, the way a `status:` check does, so `cancel`, `kill`, `approve`, `reject`, `resume` and `step done` don't wait for them. The step reads `checking` meanwhile. Entries still run in order: the ones after such a proof, then `status:`, run once it passes. A `cancel`, a `kill` or a `resume --from` stops a running `command` and its result is dropped; a `remote_unchanged` read is not stopped, and its result is dropped the same way. A process that dies during a proof leaves the step `checking`: past that proof's limit plus a minute a `tick` or a `resume` runs the step's proofs again from the first. Each run of a proof has its own token and log; an older run still alive is stopped and its result dropped. The baseline read happens with the lock given up too, after the attempt is stored and before its line is typed; a cancel during the read means nothing is typed, and a process that dies there leaves an attempt with no reading.

The proofs show facts about the repository, not that the work is good: `commits: 1` passes a useless commit. A definition stored before `require:` existed has no `require` in its snapshot and behaves as before. `workflow validate` lists every bad entry (an unknown proof, a repeated proof, a bad value) under `invalid_workflow`. A step with only `require:` has proof, so it does not warn.

The presets use them. `rpiv` and `rpiv-auto-approve` are described above. Every preset step that posts to the inbox on each successful path requires its `inbox_item`: `explore` (`explore:RUN` for `survey`, `explore-report:RUN` for `report`), `pr-feedback` (`pr-feedback:RUN` for `triage`, a stop path included, and `pr-feedback-fix:RUN` for `fix`) and `investigate` (`investigate:RUN` for `diagnose`, `investigate-fix:RUN` for `fix`). Their prompts post with `--reopen`, because a rerun of the step (after a rejected gate or a resume) uses the same key, and an item the person already closed would otherwise be left alone and fail the proof. A step that stops through `step done --status fail` is not checked, and `investigate`'s `reproduce` posts only on its stop paths, so it has no proof. A run already started keeps the definition it was stored with: a change to a preset affects new runs only.

## Denying commands

```yaml
deny:
  - "git push*"
  - "gh pr comment*"
  - "gh pr review*"
  - "gh run rerun*"
```

A `deny:` list stops the run's agent from running a Bash command that matches a pattern. The `session-event` hook that runs before each tool call looks up the run the pane is bound to, reads `deny` from the definition the run kept, and refuses a matching command with exit 2 and this text for the agent: `denied by workflow investigate, step fix: "git push*". Report this and stop.` Each denial writes `command_denied` to the run's history (`workflow events`) and to the [event log](README.event-log.md) (`run_id`, `workflow`, `workspace`, `step`, `pattern`, and the first 300 characters of `command`, control characters escaped). A pane with no binding costs one read of the bindings file. A pane bound to a run also pays the stale-binding check (two tmux calls) and one parse of the run file on each Bash call, whether or not the run has a `deny` list. The run's stored definition is what counts, so editing the definition file mid-run changes nothing for a run in flight. A run that has finished, or a run or binding file that can't be read, allows the command: an error in the check never stops the agent's other tools.

**This is a tripwire, not a sandbox.** It catches an agent that was misled or made a mistake with the plain forms of a command. `bash -c '...'`, a script, an alias, a variable holding the command, `$'...'` quoting, `timeout N`, `nice` or `xargs` in front of the command, a command after `if ...; then`, `!` or `{`, inside `((...))` (without the `$`), `[[ ]]` or a `case` pattern, and any tool other than Bash get past it. Do not rely on it against an agent that means harm. For the push, the proof after the fact is `require: remote_unchanged` on the step (see [Required proofs](#required-proofs)), which fails the step when the remote branch moved.

How a command is matched:

- It is cut into pieces at `;`, `&&`, `||`, `|`, `&`, newlines, parentheses and backticks that are not inside quotes, so `cd x && git push` and `$(git push)` are checked as `git push`. A quoted `;` does not cut: `git commit -m "a; git push"` is one piece and is not denied (and `echo "$(git push)"` is not looked into).
- An unquoted `#` that starts a word begins a comment, skipped to the end of the line. `$(( ))` is only watched so that a `<<` shift in it does not start a here-document; a `$(...)` or backtick inside it is still checked, but a bare command in it (`$((git push) )`) is not.
- Runs of spaces and tabs outside quotes count as one space. The body of a here-document (`<<WORD`, `<<-WORD`, `<<'WORD'`) is skipped up to its terminator line, or to the end of the text when the terminator never comes, so a commit message that contains `git push` is not denied.
- Each piece loses leading whitespace, leading `NAME=value` assignments and the words `sudo`, `command`, `env`, `exec`, `nohup` and `time` (with an option such as `-i` right after one, and the value of `sudo -u/-g` and `env -u`), so `FOO=1 sudo -u root git push` is checked as `git push`. A path before the program (`/usr/bin/git`) is dropped, and so are git's global options (`-C dir`, `-c k=v`, `--git-dir`, `--work-tree`, `--no-pager`, ...) and gh's `-R/--repo`, so `git -C x push` is checked as `git push`.
- The rest of the piece must match a pattern as a whole, as a shell glob: `*` matches any run of characters (slashes and newlines too) and `?` one character. Nothing in a pattern is run or evaluated; `[abc]` sets work, and `{a,b}` is plain text. `git push*` matches `git push origin HEAD` and also `git pushd`.

`workflow validate` collects a bad `deny` (not a list, an empty or non-text entry, too many, too long, too many wildcards) with the other problems under `invalid_workflow`. The `investigate` and `pr-feedback` presets deny the four patterns above, since neither pushes or posts; `workspace push` is not matched, so the person's next step still works.


## The guard

A step with `guard:` is checked by the engine when the agent's turn ends, before its `produces:` files are looked for (a step the agent reported as failed is not guarded: it already failed). The checkout it is checked against was recorded when the run started: `base_sha` (HEAD) and a snapshot of the repository's config, its hooks directory and its hidden-file flags, in the run file as `base_guard`. `workflow status --json` shows `base_sha` on the run.

- `guard: unchanged` finds any of the codes below.
- `guard: config` finds only the last three that follow `operation_in_progress` (`config_changed`, `hooks_changed`, `hidden_changed`) and `no_commit`. A step that commits (a fix) uses it.

A step with `guard: unchanged` also needs a clean checkout to start: `workflow run`, `workflow run --dry-run`, and `workflow start` (also `--dry-run`) into a workspace it reuses refuse with `dirty_worktree` (`details.guard`, `details.files`) when the checkout has no commit, a git operation stopped in it, or a change to a tracked file. Untracked files pass, so a reproduction can be written.

| Code | Found when | Actions offered |
|---|---|---|
| `no_commit` | The run has no base commit (an unborn branch) or HEAD can't be read | `cancel` |
| `head_moved` | HEAD is not `base_sha` (a commit, a checkout, a reset) | `cancel` |
| `operation_in_progress` | A merge, cherry-pick, revert, bisect or rebase is stopped in the checkout | `resume`, `resume --from`, `cancel` |
| `config_changed` | The common dir's `config`, a `config.worktree` (the worktree's or any linked worktree's), `info/attributes` or a `refs/replace/` ref changed | `cancel` |
| `hooks_changed` | The hooks directory (`core.hooksPath` of the repository config, else the common dir's `hooks`) changed: a file, its mode, its content or a link's target | `cancel` |
| `hidden_changed` | The `git ls-files -v` lines tagged assume-unchanged or skip-worktree changed from the start (flags that were already set, as in a sparse checkout, are fine) | `cancel` |
| `tracked_changed` | `git status` shows a staged or unstaged change to a tracked file (submodules are not looked at); `details.paths` names up to 20 | `resume`, `resume --from`, `cancel` |

The codes with only `cancel` can't pass again, and `base_sha` is never recorded anew: that would accept whatever moved HEAD, the agent's own commit included. Start a new run. For `tracked_changed` and `operation_in_progress` the person cleans the checkout and resumes.

The guard is a tripwire for an agent that was misled or made a mistake, not a boundary against one that means harm: a process of your own user can edit the run file, start a process outside the pane (`tmux split-window`), or forge the git index's stat data so an edit looks unchanged. Every git call it makes is the `git` found on `PATH` when `workspace` started, and ignores the global and system git config, drops every inherited `GIT_*` variable, ignores replace refs, and runs with fsmonitor and hooks off (and reads attributes from HEAD when git is 2.41 or newer), so a config the agent wrote can't run a command during the check. A `status:` check runs with every inherited `GIT_*` variable removed too. The guard does not see untracked files, submodules or anything outside the checkout. A part git can't read at check time fails with its code, even if it could not be read at the start; a guard that raises fails the step as `check_error`.

A plain `workflow resume` (no `--from`) and `workflow advance` of a step that has a `guard:` or a `status:` are refused with `bound_pane` from the pane the run is bound to or a process under it: otherwise the agent could decide its own step by hand with a fake `git` first on `PATH`. The agent daemon starts `advance` as a process of its own, with `$TMUX_PANE` removed.

### Failure codes

Every `failed_check` reason has `details.code` and `details.code_source`. `engine` codes are a closed set: the guard codes above, `require_commits`, `require_nonempty`, `require_plan_status`, `require_tracked_clean`, `require_command`, `require_inbox_item`, `require_remote_unchanged`, `require_remote_unreachable`, `require_unknown` (see [Required proofs](#required-proofs)), `check_failed` (a `status:` command exited non-zero), `check_timed_out`, `check_error` (the check could not run, or the project's command is unset), `step_timed_out` (`workflow sweep` failed a step past its `timeout` with `on_timeout: fail`; `details.cause` is `timeout`, with `timeout` and `elapsed` in seconds) and `reported` (`step done --status fail` with no `--code`). For a guard failure `details.guard` repeats `code`, `details.paths` is `[]` except for `tracked_changed`, and `head_moved` also has `base_sha` and `head`. A run stored before these keys existed has no `code` or `code_source` on its stored reasons. `step done --code` refuses the engine's words. An `agent` code is the word the agent gave with `step done --code`, stored as `reported.code`: a word it chose, which each workflow documents for itself. A client maps it to words, never to actions. `details.summary` stays free text, and `details.error` (why a check has no exit code) is not a code.

### A rejected gate

`workflow reject` marks the gated step's `gate` as `rejected`, and the step row of `status --json` keeps `"gate":"rejected"` while that step runs again (the first dispatch after the reject). After `reject --to` an earlier step, the gated step shows `rejected` until it is dispatched again. A later `resume` of a failed rerun clears it, and a rerun that passes replaces it with `waiting`.

## Passing a gate

`workflow approve` passes a waiting gate and `workflow reject` turns it down. Both are for a person, and refuse with `bound_pane` when run from a pane a workflow run is bound to (`$TMUX_PANE`), or from a process whose parent chain holds the run's own pane (the pane's pid, from `tmux list-panes`, among the caller's ancestors in one `ps` snapshot), which holds with `$TMUX_PANE` unset or set to another pane. That refusal's `details.agent` names the calling agent (`pid`, `started`) when one is found. When tmux or the process table can't be read, only the `$TMUX_PANE` check runs. A dev server started from the bound pane is under it, and gets `bound_pane` too.

These guards stop mistakes and a confused agent. They are not a security boundary: an agent with a shell can clear `$TMUX_PANE`, or start a process outside its pane's tree (`tmux new-window`, `tmux run-shell`, `launchctl`, `ssh localhost`), and that process gets past them.

A client that shows the gate builds its own argv from `workflow status RUN --json`, enabling its buttons only when `current.reason.code` is `waiting_you` and `details.kind` is `gate`:

```bash
workspace workflow approve --step=<current.step> --attempt=<current.attempt> --note-sha256=<gate_file.sha256> --json -- <run>
workspace workflow reject --step=<current.step> --attempt=<current.attempt> --note=<reason> --json -- <run>
```

With `--step` (and `--attempt`), a run that is at another step, on another attempt, or whose gate there is not waiting is refused with `gate_not_waiting`: the row is stale, so read the status again rather than retry. `details.step` and `details.attempt` are the run's, `details.expected_step` and `details.expected_attempt` the caller's. Without the flags a gate is passed wherever the run waits, as before. A gate's `actions` in `status` carry `--step` and `--attempt` in their `args`, for terminal clients.

**The gate's note.** When the gated step's first `produces` file starts with the line `note: <file>`, the gate is about that note: `<file>` is a plain file name (no `/`) in the workspace's notes directory ([`notes dir`](README.notes.md)), a regular file and not a link. While the gate waits, `status` adds `gate_file: {name, path, sha256}` to `current.reason.details`, hashed when status is read; it is `null` when the step's first file has no `note:` line, and `null` with a warning when the note can't be read, in which case `current.reason.details.gate_file_error` is `gate_note_unreadable` (else `null`), the same code `approve` refuses with. `approve` hashes the note once, under the run's lock and after the checks above, records `gate: {file: {path, sha256}}` with the approval, and adds `The approved note is <path>, sha256 <hash>.` to the next step's instructions; a note that is missing or can't be read is refused with `gate_note_unreadable`. With `--note-sha256 HEX`, a note whose hash is not `HEX` is refused with `stale_revision` (`details.revision` its sha256 now, `details.path` the note, `details.run_id`, `details.step` and `details.attempt` the gate), and a gate with no `note:` line with `gate_note_unreadable`; the hash recorded is the one compared, so what is recorded is what the caller read. After the approval, the step's row in `steps` has `gate_file: {path, sha256}`, the hash approve recorded, and `note_changed: true` when the note's bytes differ now (or it can no longer be read). When the gated step's first file is missing, a plain `approve` is recorded without a hash, as for a gate with no `note:` line.

Every refusal leaves the run file as it was.

## Where a run is stuck

A run that is not moving has a `reason`: a `code`, `since`, `details`, and `actions`, the commands that resolve it. Every entry has `action`, `args` and `needs`:

- `needs: []`: run `workspace <action> <args...>` as written.
- Otherwise the caller supplies one value per entry of `needs` (`name`, `flag`) and appends it after `args`: the flag then the value, or `--` then the value when `flag` is `null`. `workflow reject` needs `{"name":"note","flag":"--note"}`; an action that would be refused with `attempts_spent` also lists `{"name":"extra_attempts","flag":"--extra-attempts","min":N}`, where the value must be a whole number of at least `min` (`min` is only on this need); one refused with `budget_spent` lists `{"name":"extra_tokens","flag":"--extra-tokens","min":N,"suggested":M}` the same way; and `ask answer` needs `{"name":"answer","flag":null}`. No placeholder is ever in `args`; the text output shows one for a person (`workspace workflow reject RUN --note NOTE`).

| Code | Meaning | `details` |
|---|---|---|
| `waiting_lock` | Queued for a lock a step uses | `resource`, `step`, `position`, `total`, `holder` (`kind`; `run_id`, `step`, `workspace`, `worktree` for a run; `pid` and `worktree` for an agent or a dev environment, `kind: "process"`, which adds `dev down` to `actions`); `actions` also hold `lock status RESOURCE --name WS` when `resource` is a plain name |
| `waiting_you` | A person is needed. `kind` says for what: `gate` (a passed step waits for approval), `prompt` (the pane shows a permission prompt), `ask` (a question asked from the run's pane with [`ask`](README.ask.md) is open), `dispatch` (the step's line could not be typed), `delivery` (the process typing the step's line stopped before the agent daemon answered, and the pane's agent has ended its turn: it may never have had the line) | `kind`, `step`; `artifacts`, `gate_file` and `gate_file_error` (see [Passing a gate](#passing-a-gate)) for a gate; `pane`, `message` for a prompt; `ask`, `question` for a question; `error`, `message`, `pane`, `workspace` for a dispatch; `attempt`, `pane`, `workspace` for a delivery |
| `turn_ended_incomplete` | The turn ended and a file the step produces is missing, is not a non-empty regular file (a symlink, a directory or an empty file), or was left by an earlier attempt and not written again. The next turn's end, or `workflow resume`, looks again. A fresh one is hidden for its first 10 seconds and while the pane is working (the run reads `running`, with no reason), so a real stop can show up to 10 seconds late: a task that settled just before the turn ended starts a new turn on its own. After 90 minutes of a hold (below) it is stored in place of `turn_ended_background`, with `background_tasks` | `step`, `attempt`, `missing`, `stale`, `invalid` (only when a file broke a rule: a list of `{file, rule}`, `rule` being `symlink`, `not_regular_file` or `empty`); `background_tasks` (`id`, `type`) after a hold ran out |
| `turn_ended_background` | The turn ended with background tasks still listed (sub-agents, shells, monitors) and a file the step produces is missing, is not a non-empty regular file, or is stale. Each task that ends starts another turn, so this is not a stop. `workflow status` never shows it: the run reads `running` with no reason and `flags: ["background_work"]`. Only the event log's `workflow_changed` carries the code | `step`, `attempt`, `missing`, `stale`, `invalid` (as for `turn_ended_incomplete`), `tasks` (`id`, `type`) |
| `failed_check` | The step failed and has no loop left | `step`, `attempt`, `cause` (`check`, `reported`, `guard` or `require`), `require`, `detail`, `unproven`, `required`, `found`, `base`, `reason` (`history_rewritten`), `exit_code` and `log` (`command`), `before` and `after` (`remote_unchanged`) (a `require` failure; `error` also names a proof that raised), `code`, `code_source`, `guard` and `paths` (a guard failure), `exit_code`, `timed_out`, `log`, `error` (a check that could not be run, or was stopped), `summary`, `loops`, `attempts`, `max_attempts` |
| `budget_spent` | The next attempt would start with the run's token budget used; it was not started (see [Token budgets](#token-budgets)) | `kind: "budget"`, `step`, `used`, `allowance`, `tokens`, `extra_tokens`, `counted`, `uncounted`, `needed`, `suggested` |
| `retry_backoff` | A failed step's `on_fail` retry waits out its `backoff`; a tick, `workflow sweep` or `workflow resume` starts it | `step`, `attempt`, `to` (the step the retry goes back to), `until`, `seconds`, `loops` |
| `pane_gone` | The run's pane, or its workspace, is not running | `step`, `pane`, `workspace`; when it was found while starting a step (stored), also `kind: "dispatch"`, `error` and `message` |

`pane_gone` and the `prompt`, `ask` and `delivery` kinds of `waiting_you` are read from tmux, the agent daemon and the question store when `status` runs; the others are stored in the run. A step past its `timeout` gets `flags: ["timed_out"]` and keeps running. A step that reads `running` with no reason while its pane's agent has ended its turn (the daemon shows it `idle`, or `done` for ten seconds) gets `flags: ["idle"]`: the turn ended and nothing decided the step (an interrupted turn, a daemon that was down, an `advance` that died). The flag is withheld for 30 seconds after the attempt starts, because a pane reads idle for a moment after a dispatch. Run `workflow resume`, which decides the step as the turn's end would have.

A turn that ends with background tasks listed does not stop the run. Claude Code 2.1.145 and later list them in the `Stop` hook input (`background_tasks`, each with a `type` and an `id`); `session-event` forwards only the types `subagent`, `workflow`, `shell`, `monitor`, `MCP task` and `cloud session` and ids of word characters and dashes, and the daemon passes them to `workflow advance` as `--background-task TYPE:ID` (repeatable; internal, not meant to be typed). If files the step produces are still missing, the run stores `turn_ended_background` and keeps `running`; files present, or a step reported failed, decide the step as before. A hold lasts 90 minutes from the last `Stop` that listed tasks. After that the daemon's timer turns it into `turn_ended_incomplete`, with the tasks named in the notice, so a task that never ends or an agent that died cannot hide a stopped run for good; with no daemon running nothing ends the hold, but the run then reads `stuck` in `workspace goal`. Codex and older Claude Code versions send no list and behave as before. A held run has no reason and no `idle` flag, so workspace-ui offers no Resume; a person who knows the agent is dead runs `workspace workflow resume RUN`, which acts on a held run.

A step's attempt is stored, running and bound to its pane, before its line is typed; the line is typed after the run's lock is given up, because the agent daemon may take up to two and a half minutes to answer a fresh-conversation step. A process that dies meanwhile (a `workflow run` that is killed) leaves a run whose next turn's end decides the step as usual. While the line may still be on its way (the daemon's time limit plus a minute after the attempt starts) the step gets `flags: ["delivering"]` instead of `idle`, and `resume` leaves it alone (outcome `unchanged`), so two resumes never type it twice; only `--from` or `--pane` types it again then. After that, a pane whose agent has ended its turn reads `waiting_you` with kind `delivery`: look at the pane, then `workflow resume` decides the step from its files and check as a turn's end would, and `workflow resume --from STEP` types it again in a new attempt.

`workflow resume` does what the reason calls for: asks for the lock again, runs a failed or undelivered step again, looks again at a step whose files were missing, and moves the run to the workspace's Claude pane (or `--pane`) when its own pane is gone. For a step that reads `running` it asks the daemon whether the pane's agent has ended its turn, and decides the step if it has. A resume that does nothing moves no pane and keeps no `--note`. It leaves a step an agent is working on, a step whose line is still on its way, and a check that is still running, alone (outcome `unchanged`), and refuses a run at a gate (code `gate_waiting`). It keeps the run in its pane unless that pane is gone.

A run waiting for a lock needs no `resume`: the workspace's agent daemon asks again every 15 seconds. The same timer starts an `on_fail` retry when its `backoff` is over; `resume` starts it now.

A turn that ends on an API error does not end the step: while the pane's agent shows `turn_failed` in [`sessions --json`](README.sessions.md), `workflow resume` (without `--pane`) leaves the run as it is, and the step stays running. The agent daemon [recovers the agent](README.agentd.md#recovering-from-an-api-error) and the step goes on when a turn completes. A new prompt typed in the pane clears the failed turn too, and so does `workflow resume --pane PANE`, which sends the step to that pane again. While the failed agent is gone and the pane shows a shell (the daemon stopped it to restart it), that send is refused as `pane_busy`: wait for the resumed agent.

### Resuming from the run's own pane

An agent that runs `workflow resume` (or `workflow run`) in the pane the step would be typed into can't be cleared during its own turn: the old path waited 120 seconds on that turn and gave up. The command now stores the request on the run instead and answers outcome `parked` (exit 0), with `parked: {pane, expires_at}` in its row. The `message` tells the caller to end its turn now; a sub-agent should finish and let the main agent end its turn. Nothing is typed, bound or locked yet, and no attempt exists, so a gate or lock the run had keeps what it had.

Once the turn in that pane is proven over, the agent daemon runs `workflow advance` as a process of its own, outside the pane, and the resume is carried out: `/clear` for a fresh step, then the step's line (a `context: continue` step gets the line alone). It starts from the turn's `Stop`, or from the daemon's 15 second timer. A `workflow run` parked in a pane with no binding yet starts on the timer, so it can take up to 15 seconds.

`status` shows a parked run with the flag `parked` and `current.parked` (`pane`, `from`, `requested_at`, `expires_at`; never the note). The run's stored reason is not shown while the park lasts, except for a prompt or question waiting on a person. The run file keeps a `resume_parked` event and, when it ends, `resume_parked_ended` (`how`: `released`, `unchanged`, `failed`, `taken_over`, `moved_on`, `expired` or `ended`).

The turn counts as over only when all of this holds, read from the daemon's snapshot, the transcript and the screen:

- The pane runs Claude Code with hooks, the daemon heard the main agent's `Stop`, and the transcript shows nothing from the main agent after it (a background task's notice can wake the agent after a `Stop`; nothing is typed until that turn has ended).
- No tool is open, no wait or failed turn stands, and the screen shows the prompt with an empty input box and no spinner or other sign of a running turn. A draft stops the release until it is cleared, which is how a person steps in; so does `workflow cancel`.
- With no `Stop` to go by (after Esc, or a daemon restarted since the `Stop`), the pane must read idle with no hook event for 30 seconds. A pressed Esc counts as the turn ending once the screen has been still for 30 seconds, and the conversation is then cleared.

What can go wrong:

- **Time limit.** A park waits at most 1 hour. Past it the run reads `waiting_you`, `kind: dispatch`, error `parked_timeout`, in `status` and in `inbox list --include-derived` (worked out when read, so it shows with no daemon too; a daemon that is up records it). A `--from` or `--pane` on that resume was not applied, and a note is kept for the next attempt. A step still running is decided as usual when its turn ends. A check that finished while the run was parked is not recorded; resume again to run it. A background job that keeps redrawing the pane after Esc keeps the screen moving and ends here.
- **A pane that is gone.** If the pane closed, or its agent quit (a shell for 30 seconds), the park ends the same way with `pane_gone` or `not_an_agent`, and nothing is typed into the shell.
- **A failed release.** A release that can't type the line because the pane is `pane_busy` or a restart is in progress (`restart_in_progress`) is parked again, up to 3 times within the same hour. Any other failure, such as `not_an_agent`, ends the park and the run waits as `waiting_you` (`dispatch`) with the error. A failure has no caller to read it, so it also goes to the daemon's log and the `inbox` shows a `workflow_undelivered` row.
- **`question_open` after Esc.** Claude Code sends no hook when Esc closes an `AskUserQuestion` or `ExitPlanMode`, so the tool stays open and any wait its notification opened stays too; installing the hooks again changes nothing. The daemon reads the pane instead: the normal input box, empty, with no spinner over it and no dialog hint under it, unchanged for 8 seconds with no hook event (two scans at the default interval). Then it closes the tool and the wait. Until then a release waits, and `agent-run restart` is refused with `question_open`; `--force` does not get past it. So after Esc a park releases within about a minute, and an open dialog, which never draws that box (as measured on Claude Code 2.1.316), is left alone. A status line that keeps moving, or a background sub-agent firing hook events, can hold a parked release after Esc until `parked_timeout`, because a release with no Stop needs a still pane. A draft in the box keeps the refusal until it is cleared.
- **A daemon from before this change** has no `features` key in its snapshot, so the resume takes the old path and fails as it did. Run `workspace daemon restart` once. See [`agentd`](README.agentd.md#workflow-runs).
- **A pane outside window 0** can't be parked: the daemon scans window 0 only. The resume takes the old path.

A second own-pane resume while one is parked changes nothing: it answers `unchanged` and keeps the first request (a `--from`, `--note` or `--pane` on the second is dropped, and the message says so). A resume from another pane takes over from the park, and `cancel` ends it. A resume from a sub-agent of the run's pane parks the same way, and the proof is already there if the main agent is idle.

A resume from another pane over a screen that keeps moving does not park. It waits for the pane as `agent-run restart` does (see [its notes on a moving screen](README.agent-run.md#restart-subcommand)), and when the turn is proven over it types `/clear` anyway. The step's `step_dispatched` event then carries a `warning` that background work may be lost, and `proof_missing` names what was missing when the wait failed. A background shell or sub-agent that was running can be lost when `/clear` goes through. A different `warning` appears when the daemon's monitor, from hooks, saw a sub-agent started and not yet ended in the pane's Claude Code agent as `/clear` was typed, even with the main turn over (a resume run by a background sub-agent while the main agent idles is the usual case): "a sub-agent was still running in pane %N when /clear was typed and may be lost"; `/clear` can end that sub-agent, and the clear is not held back. The moving-screen text is "background work in pane %N was still running when /clear was typed and may be lost"; when both apply only the sub-agent text is used. Either warning is in the `step_dispatched` event only, not in `workflow status --json`. The monitor can't see a background shell, so a shell running alone gives no warning, though it can be lost too.

A run file in `runs/` that can't be read as a run (not JSON, not readable, naming another id than its file's, or with a name that is not a run id, which no verb can name) is not shown; `status` names the file in `warnings`. The lock store still counts that run as going, so what it held stays held: free a lock with `workspace lock clear NAME`, or delete the file. So is one without a state for every step of its definition. Naming such a run to any verb answers `unknown_run` with the file in `details.path`.

## JSON output

`workflow run`, `start`, `resume`, `cancel`, `approve`, `reject` and `step done` print one [action document](README.json.md#actions). Its one result row has `workspace`, `outcome`, `reason` (the reason code, or `null`), `message`, and `run`, the run as `status` shows it (including `worktree`, the stored checkout path or `null`):

```json
{"schema_version":1,"ok":true,"action":"workflow run","status":"ok",
 "results":[{"workspace":"api.worktree-pdf","outcome":"started","reason":null,"message":null,
   "run":{"id":"wr_2610041230559x3k","workflow":"rpiv","state":"running","current":{"step":"research","attempt":1,"state":"running","reason":null,"flags":[]}}}],
 "warnings":[],"summary":{"started":1}}
```

`outcome` is `started`, `resumed`, `parked` (a `resume`, `run` or in-place `go` from the pane it would type into: stored, to be carried out once the agent ends its turn; the row also has `parked` with `pane` and `expires_at`, exit 0; see [Resuming from the run's own pane](#resuming-from-the-runs-own-pane)), `unchanged` (a `resume` that did nothing: an agent is working on the step, its line is still on its way, its check is still running, or a resume is already parked; `message` says which, exit 0), `cancelled`, `approved`, `rejected` or `recorded` (`step done`). A run that waits (for a lock, at a gate) still has that outcome, with the reason code in `reason`. When a step's line could not be typed the outcome is `failed`, `status` is `failed` and the exit code is 1; the run exists, `message` says why, and `workflow resume` tries again. `workflow start` prints the same action document; its row is the `run` row merged with `branch`, `path`, `created`, `task`, `ticket` (`key`, `title`, `url`; `null` when none was read) and `warnings`. `start --dry-run` prints `status: "dry_run"` with a row of `workflow`, `step`, `project`, `branch`, `path`, `would_create` (`false` when an existing workspace would be reused), `inputs`, `packs`, `warnings` and `ticket`. `run --dry-run` prints `status: "dry_run"` with a row of `workflow`, `step`, `pane` (`null` when the agent daemon is not running yet), `inputs` and `packs`. `step done`'s row has `run_id`, `step`, `attempt` and `reported` (`status`, `pass` or `fail`, and `summary`, as `step status` gives it) in place of `run`. `run_id` is always a run's id, in rows, events and error `details`; `run` is only the run object in an action row.

`workflow status --json` (each run also carries `worktree`, the stored checkout path or `null`; the example leaves it out):

```json
{"schema_version":1,"ok":true,"generated_at":"2026-10-04T21:14:03Z","runs":[
 {"id":"wr_2610041230559x3k","workflow":"rpiv","title":"Research, Plan, Implement, Verify",
  "workspace":"api.worktree-pdf","project":"api","state":"waiting",
  "created_at":"2026-10-04T20:30:55Z","started_at":"2026-10-04T20:30:55Z","ended_at":null,"cancelled_by":null,
  "current":{"step":"verify","attempt":null,"state":"waiting",
    "reason":{"code":"waiting_lock","since":"2026-10-04T21:02:40Z",
      "details":{"resource":"test-db","step":"verify","position":1,"total":2,
        "holder":{"run_id":"wr_261004121500ab12","step":"verify","workspace":"api.worktree-tax","worktree":"/src/api-tax","kind":"run"}},
      "actions":[{"action":"workflow status","args":["wr_261004121500ab12"],"needs":[]},{"action":"workflow cancel","args":["wr_2610041230559x3k"],"needs":[]}]},
    "flags":[]},
  "steps":[{"id":"research","title":"Research","state":"passed","attempts":1,"gate":null,"gate_file":null,"note_changed":false},
    {"id":"plan","title":"Plan","state":"passed","attempts":1,"gate":"approved","gate_file":null,"note_changed":false},
    {"id":"implement","title":"Implement","state":"passed","attempts":2,"gate":null,"gate_file":null,"note_changed":false},
    {"id":"verify","title":"Verify","state":"waiting","attempts":0,"gate":null,"gate_file":null,"note_changed":false}],
  "base_sha":"3b1d2c4e5f60718293a4b5c6d7e8f9012a3b4c5d","pane":"%19","task":"3f9a1c2e","inputs":{"task":"PROJ-101 invoice PDF export","spec":""},"loops":{"verify->implement":1},
  "artifacts_dir":"/src/api-pdf/.workflow/wr_2610041230559x3k",
  "events_path":"/Users/me/.local/state/workspace/.workflows/runs/wr_2610041230559x3k.events.jsonl"}],
 "warnings":[]}
```

- A run's `state` is `running`, `waiting`, `completed` or `cancelled` (`cancelled_by` is `cancel` or `kill`). A run with a reason reads `waiting`; a stored `turn_ended_incomplete` hidden by a working pane or by its 10-second hold-back, and a `turn_ended_background` hold, leave `state` `running` with no reason.
- A step's `state` is `pending`, `waiting` (not started: a lock, or a line that could not be typed), `running`, `checking` (its check, or a `require:` proof that runs outside the run's lock, is running), `passed` or `failed`. `gate` is `waiting`, `approved`, `rejected` or `null`. `gate_file` is `{path, sha256}` as approve recorded it, or `null`; `note_changed` is true when that note's bytes differ now (see [Passing a gate](#passing-a-gate)).
- `warnings` are strings: a workspace's agent daemon did not answer, so a permission prompt would not show; a run will not move because its workspace has no agent daemon; a run file can't be read or shown.
- `events_path` is the run's own history, one JSON line per transition (`run_started`, `resume_parked` and `resume_parked_ended` (a resume stored for later and how it ended), `step_dispatching` (the attempt is stored and its line about to be typed), `step_dispatched` (the daemon answered; `delivered` says whether the line landed, `warning` when background work may have been lost to the `/clear` (a moving screen, or a running sub-agent), `proof_missing` when a moving screen wasn't accepted), `step_reported`, `check_finished`, `proof_finished` (a `require:` proof run outside the lock: `proof`, `passed`), `step_passed`, `step_failed`, `step_looped` (`backoff` in seconds when the retry waits), `step_retry_started` (the wait ended; `from`, `to`), `step_retry_blocked` (the wait ended but its pane is no longer the run's, so nothing was started; `from`, `to`, `code`), `gate_waiting`, `gate_approved` and `gate_rejected` (with `note` when the person gave one; `gate_approved` with `sha256` when it recorded a note), `run_resumed`, `run_completed`, `run_cancelled`), each with `ts` and `type`.

`workflow show --json` prints `{"schema_version":1,"ok":true,"workflows":[...]}` (each `id`, `title`, `description`, `source` (`global` or `builtin`), `path`, `sha256`, and `problems`, empty for a valid file), or with an ID `{"workflow":{...}}`: the definition with defaults filled in, `steps` as a list in run order, plus `source`, `path` and `sha256`.

`workflow show ID --source --json` prints `{"schema_version":1,"ok":true,"workflow":{...}}` with `id`, `source` (`global` or `builtin`), `path`, `text` (the file's text, or `null` when its bytes are not UTF-8), `sha256` (of the file's raw bytes, whatever they are) and `problems` (empty when the file is valid). When `problems` is empty the definition's own fields (as `show ID` gives them) are added to the same object.

`workflow validate --json` on a valid text prints `{"schema_version":1,"ok":true,"workflow":{...}}`: the definition with defaults filled in (as `show ID` gives it), plus `source` (`file`, or `stdin`), `path` (absolute, or `null` for stdin) and `sha256` of the text's bytes. A top-level `warnings` array sits beside `workflow` (empty when there are none); each entry is `{"code":CODE,"step":STEP_ID,"message":TEXT}` (`step_without_proof`, `on_timeout_without_timeout`, `on_fail_exceeds_max_attempts`, `unknown_pack` or `command_unset`; `step` is `null` for the workflow's own `include:` and the default packs). `not_checked` has the same entry shape for what could not be checked: outside a git checkout, and, for `commands_not_checked`, when the project's config file doesn't parse (`pack_not_checked`, `commands_not_checked`). On an invalid one it prints the error envelope with `code: "invalid_workflow"` and `details: {"workflow": ID, "path": PATH or null, "problems": [...]}`, and exits 1.

`workflow render --json` prints `{"schema_version":1,"ok":true,"workflow":ID,"step":STEP,"workspace":NAME,"worktree":PATH,"inputs":{},"gate":"approve"-or-null,"packs":[REF,...],"instructions_path":PATH,"previews":[{"name":"run","value":"wr_preview"},...],"warnings":[{"code":"not_in_checkout","message":TEXT}],"text":TEXT}` (`text` is the instructions unescaped; `instructions_path` is where a real attempt's file would go; needs `workflow` 25; see [rendering](#rendering-a-steps-instructions)).

`workflow update --json` prints the same row with `outcome` `updated` (or `dry_run`) and the new `sha256`. Refusals print the error envelope: `invalid_workflow`, `unknown_workflow`, `builtin_workflow` (`details.workflow`), `stale_workflow` (`details.workflow`, `details.path`, `details.sha256` of the current file, or `null` when unreadable) or `usage`. For example `{"schema_version":1,"ok":false,"error":"The workflow file /home/me/.config/workspace/workflows/ship.yml changed: its sha256 is 9f2c..., not ab12.... Nothing was changed.","details":{"workflow":"ship","path":"/home/me/.config/workspace/workflows/ship.yml","sha256":"9f2c..."}}`.

`workflow remove --json` prints the same row with `outcome` `removed` (or `dry_run`), `workflow` and `path` (the file removed, or that would be). Refusals print the error envelope: `invalid_workflow` (an id that could not be a file name, or a directory at the path), `unknown_workflow`, `builtin_workflow`, `confirmation_required` or `usage`.

`workflow add --json` prints an [action document](README.json.md#actions) with one row: `outcome` `added` (or `dry_run`, with the document's `status` `dry_run`), `workspace` `null`, `workflow` (the id), `path` (the file written, or that would be) and `sha256` (of the text's bytes, as `show ID --source` will report it). Refusals print the error envelope: `invalid_workflow` (with `details.problems`), `workflow_exists` (`details.workflow`, `details.path`) or `usage`.

`workflow events --json` prints `{"schema_version":1,"ok":true,"run":ID,"events":[...],"truncated":false,"next_since":N,"warnings":[]}`. Each event is `{"n","ts","type", ...}`: `n` the line number from 1, then the line's own keys (`ts`, `type` and the event's details; `n` in a line is ignored). A `gate_approved` or `gate_rejected` line has `note`, the text given to `approve --note` or `reject --note`, and no `note` key when there was none. In text output a value holding a line break or other control character is printed as a JSON string, so each event stays on one line. `next_since` is the last event's `n` when `truncated`, else the number of the last line read (or `--since` when nothing was read), so it is always the value to ask for next. For example, `workflow events wr_2610250930abcd --since 1 --json` on a run whose third line is not an object:

<!-- workflow-events-example -->
```json
{"schema_version":1,"ok":true,"run":"wr_2610250930abcd","events":[{"n":2,"ts":"2026-10-25T09:30:00Z","type":"step_dispatched","step":"research","attempt":1},{"n":4,"ts":"2026-10-25T09:30:00Z","type":"step_done","step":"research","attempt":1,"status":"pass"}],"truncated":false,"next_since":4,"warnings":["Line 3 of the history is not a JSON object; skipped."]}
```

`workflow files --json` prints `{"schema_version":1,"ok":true,"run":ID,"artifacts_dir":PATH,"files":[...]}`. Each file is `{"path","kind","step","attempt","exists","bytes"}` plus `"link":true` for a symlink, and for a `produces` file `"problem"`: the rule it breaks (`symlink`, `not_regular_file` or `empty`, else `null`; always `null` for a run started before the rules existed), from the same check the engine uses: `path` is absolute; `kind` is `prompt`, `check_log`, `proof_log` or `produces`; `attempt` is the attempt number, or `null` for `produces`; `bytes` is `null` when the file is missing, a link or not a regular file. For example, on a run whose first step has one attempt, a `produces` file that is there, one that is missing and one that is a symlink:

<!-- workflow-files-example -->
```json
{"schema_version":1,"ok":true,"run":"wr_2610250930abcd","artifacts_dir":"/work/app/.workflow/wr_2610250930abcd","files":[{"path":"/work/app/.workflow/wr_2610250930abcd/steps/research.1.prompt.md","kind":"prompt","step":"research","attempt":1,"exists":true,"bytes":12},{"path":"/work/app/.workflow/wr_2610250930abcd/steps/research.1.check.log","kind":"check_log","step":"research","attempt":1,"exists":true,"bytes":3},{"path":"/work/app/.workflow/wr_2610250930abcd/research.md","kind":"produces","step":"research","attempt":null,"exists":true,"bytes":11,"problem":null},{"path":"/work/app/.workflow/wr_2610250930abcd/plan.md","kind":"produces","step":"research","attempt":null,"exists":false,"bytes":null,"problem":null},{"path":"/work/app/.workflow/wr_2610250930abcd/notes.md","kind":"produces","step":"research","attempt":null,"exists":true,"bytes":null,"link":true,"problem":"symlink"}]}
```

`step status --json` prints `{"schema_version":1,"ok":true,"step":{...}}` with `run_id`, `workflow`, `workspace`, `step`, `attempt`, `state`, `instructions`, `artifacts_dir`, `produces` (each `path`, `exists`, `problem` (`symlink`, `not_regular_file` or `empty`, else `null`; always `null` for a run started before the rules existed) and `current`: written during this attempt and passing the rules), `check` (whether the step has one), `reported` (`status` and `summary`, or `null`) and, once a proof has run outside the run's lock, `proofs` (the attempt's rows, see [What an attempt records](#what-an-attempt-records)).

Failures print the [error envelope](README.json.md). Codes: `unknown_workflow`, `no_default_workflow` (`workflow start` with no ID and no default for the ref's kind), `invalid_workflow`, `workflow_exists`, `stale_workflow`, `builtin_workflow`, `input_required`, `workflow_command_unset`, `invalid_input`, `dirty_worktree` (`workflow run`, `run --dry-run`, and `workflow start` into a reused workspace, for a `guard: unchanged` step), `fork_pull_request` (`workflow start`), `no_agent_pane`, `pane_has_run`, `checkout_has_run`, `no_daemon`, `unknown_run`, `unknown_step` (`workflow attempts`), `run_not_active`, `attempts_spent` and `budget_spent` (`workflow resume`, `reject`, `--extra-attempts` and `--extra-tokens`), `gate_not_waiting`, `gate_waiting`, `bound_pane`, `not_bound`, `step_not_running`, and `usage`.

## Events

Every change to a run writes one `workflow_changed` to the [event log](README.event-log.md), under the run's workspace, with `run_id`, `workflow`, `workspace`, `state`, `step` and `reason` (the stored reason code, or `null`). It says a run changed; refetch `workflow status --json`. A hold (`turn_ended_background`) writes one line on entering, with `state` `running`, and none for its later Stops. A denied command writes `command_denied` (see [Denying commands](#denying-commands)). A run's locks write `lock_wait_started`, `lock_acquired` and `lock_released` under the repository's project, with `run_id` in place of `pid`. The sweep writes `step_stalled` and `step_recovered` to the run's own history (`workflow events`), not to the event log.

## Examples

```sh
workspace workflow validate lib/workflows/rpiv.yml --json
cat draft.yml | workspace workflow validate - --id ship
workspace workflow add ship draft.yml --dry-run --json
cat draft.yml | workspace workflow add ship -
workspace workflow remove ship --yes
workspace workflow events wr_2610041230559x3k --since 40 --json
workspace workflow files wr_2610041230559x3k --json
workspace workflow update ship draft.yml --if-sha256 "$(workspace workflow show ship --source --json | jq -r .workflow.sha256)"
workspace workflow show
workspace workflow show rpiv
workspace workflow show rpiv --source --json
workspace workflow render rpiv plan --input task="add a hello script"
workspace workflow render rpiv plan --input task=x --json | jq -r .text
workspace workflow run rpiv --name my-app.worktree-pdf --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --note "Keep the public API as it is."
workspace workflow start rpiv PROJ-101 --dry-run --json
workspace workflow start rpiv PROJ-101 --slug --base main
workspace workflow start rpiv --prompt "add a hello script" --headless
workspace workflow start PROJ-101 --dry-run --json
workspace workflow start --prompt "add a hello script"
workspace workflow status
workspace workflow status --project
workspace workflow status --json | jq '.runs[] | {id, step: .current.step, why: .current.reason.code}'
workspace workflow approve wr_2610041230559x3k --note "Skip the migration."
workspace workflow reject wr_2610041230559x3k --note "Too big; split it in two."
workspace workflow resume wr_2610041230559x3k --from implement
workspace workflow cancel wr_2610041230559x3k

# In the run's pane, for the agent:
workspace step status
workspace step done --status fail --summary "Two specs still fail in billing."
workspace step done --status fail --code not_reproduced --summary "The failure did not happen locally."
```

## Notes

- One run per pane: `run` and `resume --pane` refuse a pane another run is using (code `pane_has_run`, exit 1, nothing written).
- One run per checkout: `run` and `start` refuse a checkout (matched by real path) that has a run going, including one waiting or parked (code `checkout_has_run`; `details.run_id`, `details.step`, `details.next` hold the `workflow cancel` command). A cancelled, failed or completed run does not count, nor does a run whose worktree is gone. The check and the creation of the run happen under one store lock, so two starts at once cannot both win. `resume` is never refused by it. A live run on a path that was removed and made again still blocks it until the run is cancelled, and so does a run whose pane is gone, until it is cancelled or resumed.
- The runner types into the pane you may be using. A fresh step waits up to two minutes for the pane to go quiet before `/clear`; one that stays busy, or a daemon that does not answer within two and a half minutes, is reported as `waiting_you` (`dispatch`) and `resume` tries again. A draft in a Claude Code pane's input box is refused (`pane_busy`, `details.reason` `input_not_empty`) for `/clear` and for a `context: continue` step's line alike; `turn_started` says a turn began during the last check; a draft that appears while the pane is being cleared (the prompt is checked again for 5 seconds after the clear) leaves the pane cleared and the prompt untyped, and `resume` tries again; `run_unbound` says the run moved on (it was cancelled) during the restart. A screen that keeps moving after the agent went idle is accepted only on proof the turn is over (the main `Stop`, the transcript and the screen, held 5 seconds); `background_activity` is the reason when it never was. The restart's reply names what was missing in `details.proof_missing`.
- A turn's end is matched to its step only when the daemon saw that turn begin. One it did not see begin (the daemon was restarted in the middle of the turn, or was started before this version: run `workspace daemon restart` once after upgrading) counts for the step the run is on, as every end did before. A `context: continue` step's line is not typed into a pane whose agent is in the middle of a turn or at a permission prompt: the step waits as `waiting_you` (`dispatch`, error `pane_busy`), and `workflow resume` types it once the agent is done. A pane in which the daemon has seen no turn end (after Esc, after a `/clear` typed by hand, or in a workspace just launched) counts as busy until its screen has been still for `alerts.idle_after`; one prompt the agent finishes clears that at once.
- If a step's own turn's end is ever not counted, the step reads `running` with the `idle` flag once its pane is quiet, and `workflow resume` decides it.
- Everything a workflow reads and writes is UTF-8, whatever the locale of the process (cron and apps started by launchd have none; see [Text encoding](../README.md#text-encoding)): definitions, `prompt_file`s, run files, step files, and the `--note`, `--input` and `--summary` arguments. An argument that is not valid UTF-8 (a string cut in the middle of a character) is refused with a usage error before anything is done; a definition or `prompt_file` that is not is reported as a problem (`invalid_workflow`); a run file that is not counts as one that can't be read. A value put into a prompt (the branch, a path) that is not UTF-8 has its bad bytes replaced. The workspace's questions and tasks are read as UTF-8 too; if they can't be, `status` says so in `warnings` and goes on.
- A `workflow run` that is interrupted before its first step is under way leaves a run that waits (`waiting_you`, `dispatch`, error `not_started`); `workflow resume` starts it.
- A dev environment the run's agent started under `uses: [devenv]` is stopped by the runner when the run gives `devenv` up on the way into a step that doesn't use it. One still running when the run stops at a gate, on a failure or at its end keeps the lock until `workspace dev down` (see [`dev`](README.dev.md)).
- A run copies its definition when it starts, so editing the file changes the next run, not one in flight.
- `pipeline` is deprecated in favor of `workflow` and will be removed in a later release.
