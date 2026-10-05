# workspace workflow

Run a workflow in a workspace: an ordered list of steps, each done by the agent in the workspace's Claude pane. `workspace step` is the agent's side of it.

## Usage

```sh
workspace workflow show [ID] [--json]
workspace workflow run ID [--name WORKSPACE] [--input KEY=VALUE]... [--note TEXT] [--pane PANE] [--dry-run] [--json]
workspace workflow status [RUN] [--name WORKSPACE] [--all] [--json]
workspace workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--json]
workspace workflow cancel RUN [--json]
workspace workflow approve RUN [--note TEXT] [--json]
workspace workflow reject RUN --note TEXT [--to STEP] [--json]

workspace step done [--status pass|fail] [--summary TEXT] [--json]
workspace step status [--json]
```

| Subcommand | Description |
|------------|-------------|
| `workflow show` | List the definitions, or print one: its inputs and what each step does. A `.yml` entry that can't be a definition (a name that is not an id, a directory) is listed as `INVALID` with why |
| `workflow run` | Start a run in a workspace (the current one, or `--name`). `--dry-run` checks the inputs, the project's commands, the packs and the pane, and starts nothing |
| `workflow status` | The runs still going, one workspace's (`--name`), finished ones too (`--all`), or one run. Each shows its step and, when it is not moving, [why](#where-a-run-is-stuck) |
| `workflow resume` | Get a run going again; `--from STEP` starts again at that step. Refused with `--from` at a waiting gate from a pane a run is bound to |
| `workflow cancel` | End a run and release what it holds |
| `workflow approve` | Pass a gate. Refused from a pane a run is bound to, so an agent doesn't approve its own plan by mistake. The refusal is a guard, not a boundary: an agent can clear `$TMUX_PANE` |
| `workflow reject` | Turn a gate down: the gated step, or an earlier one named with `--to`, runs again with the note in its instructions |
| `step done` | For the agent: record what it says about its step, then end the turn. Optional |
| `step status` | For the agent: which run, step and attempt its pane is on, and whether the files the step must leave exist |

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | `run`: the workspace to run in. `status`: only this workspace's runs |
| `--input KEY=VALUE` | `run`: a value for one of the workflow's inputs (repeatable) |
| `--note TEXT` | `run`: added to every step's instructions. `resume`, `approve`, `reject`: added to the next attempt's |
| `--pane PANE` | `run`, `resume`: the pane to run in (`%19` or `0.1`), instead of the workspace's Claude pane |
| `--from STEP` | `resume`: start again at this step |
| `--to STEP` | `reject`: the step to run again (the gated step, or one before it) |
| `--all` | `status`: finished runs too |
| `--dry-run` | `run`: report what would start and start nothing |
| `--status pass\|fail` | `step done`: `pass` (default) or `fail` |
| `--summary TEXT` | `step done`: one line about what was done, or what is left |
| `--json` | Print one JSON document |

## How a run works

`workflow run` writes the run's file, binds the pane to the run (see [`binding`](README.binding.md)) and starts the first step. For each step, the runner:

1. takes the locks the step `uses:` for the run, in sorted order, in the same queue as [`lock acquire`](README.lock.md) and [`dev up`](README.dev.md). If one is busy, the run waits in the queue and nothing is typed;
2. writes the step's instructions to `.workflow/<run>/steps/<step>.<attempt>.prompt.md` in the checkout, built by the [instruction composer](README.instructions.md#workflow-steps): the default packs, the workflow's packs and `instructions:`, the step's packs and prompt, and what the runner knows about this attempt;
3. types one line into the pane, `Read <file> and follow it.` A step starts in a fresh conversation (the agent daemon types `/clear` first, as [`agent-run restart`](README.agent-run.md) does) unless it says `context: continue`.

A step is done when the agent's turn ends in the bound pane, every file the step `produces:` has been written during this attempt, and its `status:` check passes. A file an earlier attempt left (before a reject, a `resume --from` or a loop back) does not count until the step writes it again; its instructions say so. The workspace's agent daemon ([`agentd`](README.agentd.md)) sees the turn end and decides the step; `workflow run` starts the daemon if none is running. The daemon says when the turn that ended began (the prompt that started it), and the end of a turn that began before the step's attempt did decides nothing: if you were talking to the agent in the run's pane when a step was started (at a gate, say), the end of that conversation does not pass the step. The step's own turn's end does. The agent never has to report: `step done` only adds its own word, and `step done --status fail` fails the step at the turn's end without running the check.

- A step with `gate: approve` waits for `workflow approve` once it has passed. The run holds no lock while it waits.
- A step that fails (its check exits non-zero or runs past its time limit, or the agent reported `fail`) goes back to the step its `on_fail: {goto, max}` names, at most `max` times, and never once the run has made `max_attempts` attempts across all its steps. The step it goes back to is told what failed. After that the run stops and waits for you.
- When the last step passes, the run is `completed`, its locks are released and its pane is unbound.
- A check still running when its run is cancelled, killed or moved to another step is stopped within a few seconds, so it doesn't go on using the test database beside the lock's next holder.

`.workflow/` is listed in the repository's `info/exclude` (the common dir's, for a linked worktree), so the checkout stays clean and `.gitignore` is not touched. Run state lives outside the checkout, in `~/.local/state/workspace/.workflows/` (`$XDG_STATE_HOME`): `runs/<run>.json` and `runs/<run>.events.jsonl` while a run is going, `archive/` once it has finished (the newest 200 are kept).

Killing a workspace ([`kill`](README.kill.md), [`finish`](README.finish.md), `projects kill`) cancels its runs. Stopping one leaves its runs as they are: `status` shows `pane_gone`, and `workflow resume` after a relaunch moves the run to the workspace's Claude pane. A run of a stopped workspace keeps the locks it holds and its place in a queue, and takes a lock that frees while nobody can start its step: its workspace's agent daemon is what moves it. `status` warns about such a run; the ways out are `workflow cancel`, relaunching the workspace and `workflow resume`, or `workspace lock clear NAME`. [`restore`](README.restore.md) carries a run's binding to the pane it recreates, so the run goes on there.

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
| `inputs` | Input name to `description` and `required` (default false). `run --input NAME=VALUE` supplies them; one that is not required and not given is empty |
| `include` | Pack names composed after the default packs, for every step |
| `instructions` | Text for every step |
| `max_attempts` | Attempts the run may make across all its steps before a failure stops it (default 6) |
| `steps` | Step id to step, in the order they run |

Step keys:

| Key | Meaning |
|---|---|
| `title` | For `workflow show` and `status` |
| `prompt` or `prompt_file` | What the step asks for. `prompt_file` is a path beside the definition, read when the run starts |
| `include` | Pack names composed for this step |
| `produces` | Files the step must write, as paths under the run's artifacts directory |
| `status` | A check run in the checkout when the turn ends: a command line, `{run: COMMAND}`, or `{command: test}` / `{command: lint}` for the project's own [`commands.test` or `commands.lint`](README.config.md). `timeout` (default `20m`) stops it; a `timeout` with no value is refused |
| `gate` | `approve`: wait for `workflow approve` after the step passes |
| `uses` | Lock names the run holds for the step. `dev-env` is `devenv`; `edit` is refused (only the agent that edits can hold it) |
| `on_fail` | `{goto: STEP, max: N}`: on failure go back to an earlier step, at most `N` times (default 1). `context:` overrides the target step's `context` for that jump |
| `context` | `fresh` (default): start the step in a new conversation. `continue`: keep the pane's conversation |
| `timeout` | How long the step may take before `status` flags it `timed_out`. Nothing is stopped |

Text in `instructions` and `prompt` may use `{{workspace}}`, `{{branch}}`, `{{artifacts}}` (the run's directory, `<checkout>/.workflow/<run>`), `{{run}}` and `{{inputs.NAME}}`. Any other placeholder is a problem in the definition. A definition with problems is reported with all of them at once (code `invalid_workflow`).

### The `rpiv` preset

`rpiv` is the one workflow that ships: research (`research.md`), plan (`plan.md`, with a gate), implement (`implement.md`) and verify (`verify.md`). Verify holds `test-db`, so runs in worktrees of one repository verify one at a time; it is checked with the project's `commands.test`, and a failure goes back to implement up to three times in the same conversation. Its `max_attempts` is 10, which leaves room for those three trips and one rejected plan. A project with no `commands.test` is refused before anything starts (code `workflow_command_unset`):

```sh
workspace config set commands.test "bundle exec rspec"
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export"
```

## Where a run is stuck

A run that is not moving has a `reason`: a `code`, `since`, `details`, and `actions`, the commands that resolve it. Every entry has `action`, `args` and `needs`:

- `needs: []`: run `workspace <action> <args...>` as written.
- Otherwise the caller supplies one value per entry of `needs` (`name`, `flag`) and appends it after `args`: the flag then the value, or `--` then the value when `flag` is `null`. `workflow reject` needs `{"name":"note","flag":"--note"}` and `ask answer` needs `{"name":"answer","flag":null}`. No placeholder is ever in `args`; the text output shows one for a person (`workspace workflow reject RUN --note NOTE`).

| Code | Meaning | `details` |
|---|---|---|
| `waiting_lock` | Queued for a lock a step uses | `resource`, `step`, `position`, `total`, `holder` (`kind`; `run_id`, `step`, `workspace`, `worktree` for a run; `pid` and `worktree` for an agent or a dev environment, `kind: "process"`, which adds `dev down` to `actions`) |
| `waiting_you` | A person is needed. `kind` says for what: `gate` (a passed step waits for approval), `prompt` (the pane shows a permission prompt), `ask` (a question asked from the run's pane with [`ask`](README.ask.md) is open), `dispatch` (the step's line could not be typed) | `kind`, `step`; `artifacts` for a gate; `pane`, `message` for a prompt; `ask`, `question` for a question; `error`, `message`, `pane`, `workspace` for a dispatch |
| `turn_ended_incomplete` | The turn ended and a file the step produces is missing, or was left by an earlier attempt and not written again. The next turn's end, or `workflow resume`, looks again | `step`, `attempt`, `missing`, `stale` |
| `failed_check` | The step failed and has no loop left | `step`, `attempt`, `cause` (`check` or `reported`), `exit_code`, `timed_out`, `log`, `error` (a check that could not be run, or was stopped), `summary`, `loops`, `attempts`, `max_attempts` |
| `pane_gone` | The run's pane, or its workspace, is not running | `step`, `pane`, `workspace`; when it was found while starting a step (stored), also `kind: "dispatch"`, `error` and `message` |

`pane_gone` and the `prompt` and `ask` kinds of `waiting_you` are read from tmux, the agent daemon and the question store when `status` runs; the others are stored in the run. A step past its `timeout` gets `flags: ["timed_out"]` and keeps running. A step that reads `running` with no reason while its pane's agent has ended its turn (the daemon shows it `idle`, or `done` for ten seconds) gets `flags: ["idle"]`: the turn ended and nothing decided the step (an interrupted turn, a daemon that was down, an `advance` that died). Run `workflow resume`, which decides the step as the turn's end would have.

`workflow resume` does what the reason calls for: asks for the lock again, runs a failed or undelivered step again, looks again at a step whose files were missing, and moves the run to the workspace's Claude pane (or `--pane`) when its own pane is gone. For a step that reads `running` it asks the daemon whether the pane's agent has ended its turn, and decides the step if it has. A resume that does nothing moves no pane and keeps no `--note`. It leaves a step an agent is working on, and a check that is still running, alone (outcome `unchanged`), and refuses a run at a gate (code `gate_waiting`). It keeps the run in its pane unless that pane is gone.

A run waiting for a lock needs no `resume`: the workspace's agent daemon asks again every 15 seconds.

A run file in `runs/` that can't be read as a run (not JSON, not readable, naming another id than its file's, or with a name that is not a run id, which no verb can name) is not shown; `status` names the file in `warnings`. The lock store still counts that run as going, so what it held stays held: free a lock with `workspace lock clear NAME`, or delete the file. So is one without a state for every step of its definition. Naming such a run to any verb answers `unknown_run` with the file in `details.path`.

## JSON output

`workflow run`, `resume`, `cancel`, `approve`, `reject` and `step done` print one [action document](README.json.md#actions). Its one result row has `workspace`, `outcome`, `reason` (the reason code, or `null`), `message`, and `run`, the run as `status` shows it:

```json
{"schema_version":1,"ok":true,"action":"workflow run","status":"ok",
 "results":[{"workspace":"api.worktree-pdf","outcome":"started","reason":null,"message":null,
   "run":{"id":"wr_2610041230559x3k","workflow":"rpiv","state":"running","current":{"step":"research","attempt":1,"state":"running","reason":null,"flags":[]}}}],
 "warnings":[],"summary":{"started":1}}
```

`outcome` is `started`, `resumed`, `unchanged` (a `resume` that did nothing: an agent is working on the step, or its check is still running; `message` says which, exit 0), `cancelled`, `approved`, `rejected` or `recorded` (`step done`). A run that waits (for a lock, at a gate) still has that outcome, with the reason code in `reason`. When a step's line could not be typed the outcome is `failed`, `status` is `failed` and the exit code is 1; the run exists, `message` says why, and `workflow resume` tries again. `run --dry-run` prints `status: "dry_run"` with a row of `workflow`, `step`, `pane` (`null` when the agent daemon is not running yet), `inputs` and `packs`. `step done`'s row has `run_id`, `step`, `attempt` and `reported` (`status`, `pass` or `fail`, and `summary`, as `step status` gives it) in place of `run`. `run_id` is always a run's id, in rows, events and error `details`; `run` is only the run object in an action row.

`workflow status --json`:

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
  "steps":[{"id":"research","title":"Research","state":"passed","attempts":1,"gate":null},
    {"id":"plan","title":"Plan","state":"passed","attempts":1,"gate":"approved"},
    {"id":"implement","title":"Implement","state":"passed","attempts":2,"gate":null},
    {"id":"verify","title":"Verify","state":"waiting","attempts":0,"gate":null}],
  "pane":"%19","task":"3f9a1c2e","inputs":{"task":"PROJ-101 invoice PDF export","spec":""},"loops":{"verify->implement":1},
  "artifacts_dir":"/src/api-pdf/.workflow/wr_2610041230559x3k",
  "events_path":"/Users/me/.local/state/workspace/.workflows/runs/wr_2610041230559x3k.events.jsonl"}],
 "warnings":[]}
```

- A run's `state` is `running`, `waiting`, `completed` or `cancelled` (`cancelled_by` is `cancel` or `kill`). A run with a reason reads `waiting`.
- A step's `state` is `pending`, `waiting` (not started: a lock, or a line that could not be typed), `running`, `checking` (its check is running), `passed` or `failed`. `gate` is `waiting`, `approved`, `rejected` or `null`.
- `warnings` are strings: a workspace's agent daemon did not answer, so a permission prompt would not show; a run will not move because its workspace has no agent daemon; a run file can't be read or shown.
- `events_path` is the run's own history, one JSON line per transition (`run_started`, `step_dispatched`, `step_reported`, `check_finished`, `step_passed`, `step_failed`, `step_looped`, `gate_waiting`, `gate_approved`, `gate_rejected`, `run_resumed`, `run_completed`, `run_cancelled`), each with `ts` and `type`.

`workflow show --json` prints `{"schema_version":1,"ok":true,"workflows":[...]}` (each `id`, `title`, `description`, `source` (`global` or `builtin`), `path`, `sha256`, and `problems`, empty for a valid file), or with an ID `{"workflow":{...}}`: the definition with defaults filled in, `steps` as a list in run order, plus `source`, `path` and `sha256`.

`step status --json` prints `{"schema_version":1,"ok":true,"step":{...}}` with `run_id`, `workflow`, `workspace`, `step`, `attempt`, `state`, `instructions`, `artifacts_dir`, `produces` (each `path`, `exists`, and `current`: written during this attempt), `check` (whether the step has one) and `reported` (`status` and `summary`, or `null`).

Failures print the [error envelope](README.json.md). Codes: `unknown_workflow`, `invalid_workflow`, `input_required`, `workflow_command_unset`, `no_agent_pane`, `pane_has_run`, `no_daemon`, `unknown_run`, `run_not_active`, `gate_not_waiting`, `gate_waiting`, `bound_pane`, `not_bound`, `step_not_running`, and `usage`.

## Events

Every change to a run writes one `workflow_changed` to the [event log](README.event-log.md), under the run's workspace, with `run_id`, `workflow`, `workspace`, `state`, `step` and `reason` (the stored reason code, or `null`). It says a run changed; refetch `workflow status --json`. A run's locks write `lock_wait_started`, `lock_acquired` and `lock_released` under the repository's project, with `run_id` in place of `pid`.

## Examples

```sh
workspace workflow show
workspace workflow show rpiv
workspace workflow run rpiv --name my-app.worktree-pdf --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --note "Keep the public API as it is."
workspace workflow status
workspace workflow status --json | jq '.runs[] | {id, step: .current.step, why: .current.reason.code}'
workspace workflow approve wr_2610041230559x3k --note "Skip the migration."
workspace workflow reject wr_2610041230559x3k --note "Too big; split it in two."
workspace workflow resume wr_2610041230559x3k --from implement
workspace workflow cancel wr_2610041230559x3k

# In the run's pane, for the agent:
workspace step status
workspace step done --status fail --summary "Two specs still fail in billing."
```

## Notes

- One run per pane: `run` refuses a pane another run is using (code `pane_has_run`).
- The runner types into the pane you may be using. A fresh step waits up to two minutes for the pane to go quiet before `/clear`; one that stays busy, or a daemon that does not answer within two and a half minutes, is reported as `waiting_you` (`dispatch`) and `resume` tries again.
- A turn's end is matched to its step only when the daemon saw that turn begin. One it did not see begin (the daemon was restarted in the middle of the turn, or was started before this version: run `workspace daemon restart` once after upgrading) counts for the step the run is on, as every end did before. A `context: continue` step's line is not typed into a pane whose agent is in the middle of a turn or at a permission prompt: the step waits as `waiting_you` (`dispatch`, error `pane_busy`), and `workflow resume` types it once the agent is done. A pane in which the daemon has seen no turn end (after Esc, after a `/clear` typed by hand, or in a workspace just launched) counts as busy until its screen has been still for `alerts.idle_after`; one prompt the agent finishes clears that at once.
- If a step's own turn's end is ever not counted, the step reads `running` with the `idle` flag once its pane is quiet, and `workflow resume` decides it.
- Everything a workflow reads and writes is UTF-8, whatever the locale of the process (cron and apps started by launchd have none; see [Text encoding](../README.md#text-encoding)): definitions, `prompt_file`s, run files, step files, and the `--note`, `--input` and `--summary` arguments. An argument that is not valid UTF-8 (a string cut in the middle of a character) is refused with a usage error before anything is done; a definition or `prompt_file` that is not is reported as a problem (`invalid_workflow`); a run file that is not counts as one that can't be read. A value put into a prompt (the branch, a path) that is not UTF-8 has its bad bytes replaced. The workspace's questions and tasks are read as UTF-8 too; if they can't be, `status` says so in `warnings` and goes on.
- A `workflow run` that is interrupted before its first step is under way leaves a run that waits (`waiting_you`, `dispatch`, error `not_started`); `workflow resume` starts it.
- A dev environment the run's agent started under `uses: [devenv]` is stopped by the runner when the run gives `devenv` up on the way into a step that doesn't use it. One still running when the run stops at a gate, on a failure or at its end keeps the lock until `workspace dev down` (see [`dev`](README.dev.md)).
- A run copies its definition when it starts, so editing the file changes the next run, not one in flight.
- `pipeline` is deprecated in favor of `workflow` and will be removed in a later release.
