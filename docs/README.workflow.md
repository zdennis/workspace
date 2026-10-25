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
workspace workflow status [RUN] [--name WORKSPACE] [--all] [--json]
workspace workflow events RUN [--since N] [--json]
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
| `workflow validate` | Check a definition's text, from a file or `-` for stdin, with the checks a definition on disk gets. Lists every problem at once and writes nothing; see [Validating a definition](#validating-a-definition) |
| `workflow add` | Save a definition, from a file or `-` for stdin, as `~/.config/workspace/workflows/ID.yml` after the checks `validate` runs. Refused with `workflow_exists` when that file is there; a preset of the same id is left alone and the copy shadows it. See [Adding a definition](#adding-a-definition) |
| `workflow update` | Replace your `ID.yml` with new text, from a file or `-` for stdin, only if the file still has the `--if-sha256` you read. A file that does not pass the checks can be replaced. Refused with `stale_workflow` when it changed, `builtin_workflow` for a preset with no file of yours. See [Updating a definition](#updating-a-definition) |
| `workflow remove` | Delete your `ID.yml` (a link itself, never its target). Asks first unless `--yes` or `--dry-run`; refused with `confirmation_required` under `--no-input`. A preset of the same id is in effect again. See [Removing a definition](#removing-a-definition) |
| `workflow run` | Start a run in a workspace (the current one, or `--name`). `--dry-run` checks the inputs, the project's commands, the packs and the pane, and starts nothing |
| `workflow status` | The runs still going, one workspace's (`--name`), finished ones too (`--all`), or one run. Each shows its step and, when it is not moving, [why](#where-a-run-is-stuck) |
| `workflow events` | A run's history (going or finished), one line per event, oldest first. `--since N` gives only the events after line N; at most 1000 at a time. See [Reading a run's events](#reading-a-runs-events) |
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
| `--source` | `show ID`: print the file's text, with its sha256 and problems, valid or not; see [Reading a definition's file](#reading-a-definitions-file) |
| `--since N` | `events`: only the events after line N of the run's history (a whole number, 0 or more; default 0) |
| `--id ID` | `validate`: check the text as this workflow id |
| `--all` | `status`: finished runs too |
| `--if-sha256 SHA` | `update`: the sha256 of the file's raw bytes, from `show ID --source` or `list`; required |
| `--dry-run` | `run`: report what would start and start nothing. `add`, `update`: run every check and write no definition (the workflows directory and `.ID.yml.lock` may still be created) |
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
| `uses` | Lock names the run holds for the step. `dev-env` is `devenv`; `edit` is refused (only the agent that edits can hold it). A step that uses `devenv` is not sent the `dev` pack, even when it is in the defaults or an `include:`: the run holds the environment for it |
| `on_fail` | `{goto: STEP, max: N}`: on failure go back to an earlier step, at most `N` times (default 1). `context:` overrides the target step's `context` for that jump |
| `context` | `fresh` (default): start the step in a new conversation. `continue`: keep the pane's conversation |
| `timeout` | How long the step may take before `status` flags it `timed_out`. Nothing is stopped |

Text in `instructions` and `prompt` may use `{{workspace}}`, `{{branch}}`, `{{artifacts}}` (the run's directory, `<checkout>/.workflow/<run>`), `{{run}}` and `{{inputs.NAME}}`. Any other placeholder is a problem in the definition. A definition with problems is reported with all of them at once (code `invalid_workflow`).

### Validating a definition

`workflow validate PATH` reads the file; `workflow validate -` reads stdin. It runs the same checks `show` and `run` do, reports every problem at once, and writes nothing (it does not touch `~/.config/workspace/workflows/`). It exits 0 when the text is valid and 1 with `invalid_workflow` when it is not. A file that is not UTF-8 text or not a YAML mapping fails the same way; a PATH that can't be read is a usage error.

The id the text is checked as is `--id`, else a string `id:` in the text, else the file's name without its extension, else `stdin` (for `-`, or a file name that is not an id). An `id:` that differs from `--id` is a problem. A relative `prompt_file:` is read from the file's directory for a PATH and from the current directory for `-`. The problems name the paths they looked at, never their contents.

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

### Reading a definition's file

`workflow show ID --source` answers the file itself, for an editor: the text exactly as stored, the `sha256` of its raw bytes and every problem the checks find. It works on a preset and on a global file that does not pass the checks (exit 0, where `show ID` fails with `invalid_workflow`), so a broken file can be loaded, fixed and saved. Without `--json` it prints the text alone and writes the problems to stderr. `--source` needs an ID.

### The `rpiv` preset

`rpiv` is the one workflow that ships: research (`research.md`), plan (the workspace plan, `IMPLEMENTATION_PLAN.md` in the notes directory, in the `implementation-plan` syntax, plus `plan.md` for the gate), which is only done once the plan file exists and has a task (its `status:` check reads `plan status --json`), implement (`implement.md`) and verify (`verify.md`). Verify holds `test-db`, so runs in worktrees of one repository verify one at a time; it is checked with the project's `commands.test`, and a failure goes back to implement up to three times in the same conversation. Its `max_attempts` is 10, which leaves room for those three trips and one rejected plan. A project with no `commands.test` is refused before anything starts (code `workflow_command_unset`):

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

`pane_gone` and the `prompt` and `ask` kinds of `waiting_you` are read from tmux, the agent daemon and the question store when `status` runs; the others are stored in the run. A step past its `timeout` gets `flags: ["timed_out"]` and keeps running. A step that reads `running` with no reason while its pane's agent has ended its turn (the daemon shows it `idle`, or `done` for ten seconds) gets `flags: ["idle"]`: the turn ended and nothing decided the step (an interrupted turn, a daemon that was down, an `advance` that died). The flag is withheld for 30 seconds after the attempt starts, because a pane reads idle for a moment after a dispatch. Run `workflow resume`, which decides the step as the turn's end would have.

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

`workflow show ID --source --json` prints `{"schema_version":1,"ok":true,"workflow":{...}}` with `id`, `source` (`global` or `builtin`), `path`, `text` (the file's text, or `null` when its bytes are not UTF-8), `sha256` (of the file's raw bytes, whatever they are) and `problems` (empty when the file is valid). When `problems` is empty the definition's own fields (as `show ID` gives them) are added to the same object.

`workflow validate --json` on a valid text prints `{"schema_version":1,"ok":true,"workflow":{...}}`: the definition with defaults filled in (as `show ID` gives it), plus `source` (`file`, or `stdin`), `path` (absolute, or `null` for stdin) and `sha256` of the text's bytes. On an invalid one it prints the error envelope with `code: "invalid_workflow"` and `details: {"workflow": ID, "path": PATH or null, "problems": [...]}`, and exits 1.

`workflow update --json` prints the same row with `outcome` `updated` (or `dry_run`) and the new `sha256`. Refusals print the error envelope: `invalid_workflow`, `unknown_workflow`, `builtin_workflow` (`details.workflow`), `stale_workflow` (`details.workflow`, `details.path`, `details.sha256` of the current file, or `null` when unreadable) or `usage`. For example `{"schema_version":1,"ok":false,"code":"stale_workflow","message":"The workflow file /home/me/.config/workspace/workflows/ship.yml changed: its sha256 is 9f2c..., not ab12.... Nothing was changed.","details":{"workflow":"ship","path":"/home/me/.config/workspace/workflows/ship.yml","sha256":"9f2c..."}}`.

`workflow remove --json` prints the same row with `outcome` `removed` (or `dry_run`), `workflow` and `path` (the file removed, or that would be). Refusals print the error envelope: `invalid_workflow`, `unknown_workflow`, `builtin_workflow`, `confirmation_required` or `usage`.

`workflow add --json` prints an [action document](README.json.md#actions) with one row: `outcome` `added` (or `dry_run`, with the document's `status` `dry_run`), `workspace` `null`, `workflow` (the id), `path` (the file written, or that would be) and `sha256` (of the text's bytes, as `show ID --source` will report it). Refusals print the error envelope: `invalid_workflow` (with `details.problems`), `workflow_exists` (`details.workflow`, `details.path`) or `usage`.

`workflow events --json` prints `{"schema_version":1,"ok":true,"run":ID,"events":[...],"truncated":false,"next_since":N,"warnings":[]}`. Each event is `{"n","ts","type", ...}`: `n` the line number from 1, then the line's own keys (`ts`, `type` and the event's details; `n` in a line is ignored). `next_since` is the last event's `n` when `truncated`, else the number of the last line read (or `--since` when nothing was read), so it is always the value to ask for next. For example, `workflow events wr_2610250930abcd --since 1 --json` on a run whose third line is not an object:

<!-- workflow-events-example -->
```json
{"schema_version":1,"ok":true,"run":"wr_2610250930abcd","events":[{"n":2,"ts":"2026-10-25T09:30:00Z","type":"step_dispatched","step":"research","attempt":1},{"n":4,"ts":"2026-10-25T09:30:00Z","type":"step_done","step":"research","attempt":1,"status":"pass"}],"truncated":false,"next_since":4,"warnings":["Line 3 of the history is not a JSON object; skipped."]}
```

`step status --json` prints `{"schema_version":1,"ok":true,"step":{...}}` with `run_id`, `workflow`, `workspace`, `step`, `attempt`, `state`, `instructions`, `artifacts_dir`, `produces` (each `path`, `exists`, and `current`: written during this attempt), `check` (whether the step has one) and `reported` (`status` and `summary`, or `null`).

Failures print the [error envelope](README.json.md). Codes: `unknown_workflow`, `invalid_workflow`, `workflow_exists`, `stale_workflow`, `builtin_workflow`, `input_required`, `workflow_command_unset`, `no_agent_pane`, `pane_has_run`, `no_daemon`, `unknown_run`, `run_not_active`, `gate_not_waiting`, `gate_waiting`, `bound_pane`, `not_bound`, `step_not_running`, and `usage`.

## Events

Every change to a run writes one `workflow_changed` to the [event log](README.event-log.md), under the run's workspace, with `run_id`, `workflow`, `workspace`, `state`, `step` and `reason` (the stored reason code, or `null`). It says a run changed; refetch `workflow status --json`. A run's locks write `lock_wait_started`, `lock_acquired` and `lock_released` under the repository's project, with `run_id` in place of `pid`.

## Examples

```sh
workspace workflow validate lib/workflows/rpiv.yml --json
cat draft.yml | workspace workflow validate - --id ship
workspace workflow add ship draft.yml --dry-run --json
cat draft.yml | workspace workflow add ship -
workspace workflow remove ship --yes
workspace workflow events wr_2610041230559x3k --since 40 --json
workspace workflow update ship draft.yml --if-sha256 "$(workspace workflow show ship --source --json | jq -r .sha256)"
workspace workflow show
workspace workflow show rpiv
workspace workflow show rpiv --source --json
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
