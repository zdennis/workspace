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
workspace workflow start ID [REF | --prompt TEXT] [--branch BRANCH] [--slug] [--base REF] [--input KEY=VALUE]... [--note TEXT]
                         [--agent-kind KIND] [--[no-]headless] [--prompt-timeout DURATION] [--dry-run] [--json]
workspace workflow status [RUN] [--name WORKSPACE] [--all] [--json]
workspace workflow events RUN [--since N] [--json]
workspace workflow files RUN [--json]
workspace workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--json]
workspace workflow cancel RUN [--json]
workspace workflow approve RUN [--step STEP [--attempt N]] [--note-sha256 HEX] [--note TEXT] [--json]
workspace workflow reject RUN --note TEXT [--step STEP [--attempt N]] [--to STEP] [--json]

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
| `workflow run` | Start a run in a workspace (the current one, or `--name`). `--dry-run` checks the inputs, the project's commands, the packs and the pane, and starts nothing |
| `workflow start` | Make a workspace from a ticket, pull request, issue or branch `REF`, or from `--prompt TEXT`, wait for its coding agent and run the workflow in it. `--dry-run` checks everything and makes nothing. See [Starting from a ticket or a prompt](#starting-from-a-ticket-or-a-prompt) |
| `workflow status` | The runs still going, one workspace's (`--name`), finished ones too (`--all`), or one run. Each shows its step and, when it is not moving, [why](#where-a-run-is-stuck) |
| `workflow events` | A run's history (going or finished), one line per event, oldest first. `--since N` gives only the events after line N; at most 1000 at a time. See [Reading a run's events](#reading-a-runs-events) |
| `workflow files` | The files a run keeps: each attempt's prompt and check log and each step's `produces` entries, with whether each exists and its size. Reads file metadata only; a link is reported, never followed. See [Reading a run's files](#reading-a-runs-files) |
| `workflow resume` | Get a run going again; `--from STEP` starts again at that step. Refused with `--from` at a waiting gate from a pane a run is bound to |
| `workflow cancel` | End a run and release what it holds |
| `workflow approve` | Pass a gate. Refused from a pane a run is bound to, and from a process under the run's own pane, so an agent doesn't approve its own plan by mistake. Records the gate's note when it names one. See [Passing a gate](#passing-a-gate) |
| `workflow reject` | Turn a gate down: the gated step, or an earlier one named with `--to`, runs again with the note in its instructions. Refused where `approve` is |
| `step done` | For the agent: record what it says about its step, then end the turn. Optional |
| `step status` | For the agent: which run, step and attempt its pane is on, and whether the files the step must leave exist |

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | `run`: the workspace to run in. `status`: only this workspace's runs |
| `--input KEY=VALUE` | `run`, `start`: a value for one of the workflow's inputs (repeatable) |
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
| `--since N` | `events`: only the events after line N of the run's history (a whole number, 0 or more; default 0) |
| `--id ID` | `validate`: check the text as this workflow id |
| `--all` | `status`: finished runs too |
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
3. types one line into the pane, `Read <file> and follow it.` A step starts in a fresh conversation (the agent daemon types `/clear` first, as [`agent-run restart`](README.agent-run.md) does) unless it says `context: continue`.

A step is done when the agent's turn ends in the bound pane, every file the step `produces:` has been written during this attempt, and its `status:` check passes. The check runs through `sh -c` in the checkout with three environment variables: `WORKSPACE_RUN_ID`, `WORKSPACE_RUN_ARTIFACTS` (the run's `.workflow/<run>` directory) and `WORKSPACE_RUN_BASE_SHA` (the checkout's HEAD when the run started; empty on an unborn branch or for a run made before it was recorded). They are environment variables, never placeholders rendered into the command, so no input text reaches the shell. A file an earlier attempt left (before a reject, a `resume --from` or a loop back) does not count until the step writes it again; its instructions say so. The workspace's agent daemon ([`agentd`](README.agentd.md)) sees the turn end and decides the step; `workflow run` starts the daemon if none is running. The daemon says when the turn that ended began (the prompt that started it), and the end of a turn that began before the step's attempt did decides nothing: if you were talking to the agent in the run's pane when a step was started (at a gate, say), the end of that conversation does not pass the step. The step's own turn's end does. The agent never has to report: `step done` only adds its own word, and `step done --status fail` fails the step at the turn's end without running the check.

- A step with `gate: approve` waits for `workflow approve` once it has passed. The run holds no lock while it waits. See [Passing a gate](#passing-a-gate).
- A step that fails (its check exits non-zero or runs past its time limit, or the agent reported `fail`) goes back to the step its `on_fail: {goto, max}` names, at most `max` times, and never once the run has made `max_attempts` attempts across all its steps. The step it goes back to is told what failed. After that the run stops and waits for you.
- When the last step passes, the run is `completed`, its locks are released and its pane is unbound.
- A check still running when its run is cancelled, killed or moved to another step is stopped within a few seconds, so it doesn't go on using the test database beside the lock's next holder.

`.workflow/` is listed in the repository's `info/exclude` (the common dir's, for a linked worktree), so the checkout stays clean and `.gitignore` is not touched. Run state lives outside the checkout, in `~/.local/state/workspace/.workflows/` (`$XDG_STATE_HOME`): `runs/<run>.json` and `runs/<run>.events.jsonl` while a run is going, `archive/` once it has finished (the newest 200 are kept).

Killing a workspace ([`kill`](README.kill.md), [`finish`](README.finish.md), `projects kill`) cancels its runs. Stopping one leaves its runs as they are: `status` shows `pane_gone`, and `workflow resume` after a relaunch moves the run to the workspace's Claude pane. A run of a stopped workspace keeps the locks it holds and its place in a queue, and takes a lock that frees while nobody can start its step: its workspace's agent daemon is what moves it. `status` warns about such a run; the ways out are `workflow cancel`, relaunching the workspace and `workflow resume`, or `workspace lock clear NAME`. [`restore`](README.restore.md) carries a run's binding to the pane it recreates, so the run goes on there.

## Starting from a ticket or a prompt

`workflow start ID [REF | --prompt TEXT]` is `start` and `workflow run` in one step, for work that has no workspace yet. `workflow run` needs a workspace; `start` makes one. It takes a `REF`, `--prompt`, or both, not neither; `--name` and `--pane` are refused, because the run goes in the new workspace's own agent pane.

1. It reads the `REF` as [`start`](README.start.md) does (a JIRA key or URL, a pull request, an issue or a branch) and, for a ticket, reads its title (folded onto one line), body and URL with `gh` or `jira`; for a pull request, also `isCrossRepository`. A pull request from a fork is refused here (below).
2. It picks the branch. With a `REF` it is the ref's own: the JIRA key (plus the title's words with `--slug`), `issue-<n>` for an issue, `pr-<n>` for a pull request, a plain branch as given. With only `--prompt` it is `--branch`, else the prompt's words with no prefix (`add a hello script` is `add-a-hello-script`). A prompt with no letters or digits is a usage error asking for `--branch`. `--branch` is only for a `--prompt`; with a `REF` it is a usage error.
3. It seeds the definition's inputs. `task` is `KEY: title (url)` for a ticket, the prompt text for a prompt, and the ticket line then the prompt when both are given. `spec` is the path of the ticket body, written to `.workflow/tickets/<key>.md` in the new checkout (listed in `info/exclude`), and only when the ticket has a body. Only inputs the definition declares are seeded, and an `--input` you give always wins.
4. It runs the checks `workflow run` makes (`input_required`, `workflow_command_unset`, `invalid_input`) against the project's main checkout, so a refusal leaves nothing behind. For a workspace it reuses, it also checks that checkout's tree: a workflow with a `guard: unchanged` step refuses a dirty one with `dirty_worktree`, before any agent starts. A checkout it makes starts clean and is not checked.
5. It makes the workspace as `start` does, with no confirmation, no play, no packs and no spine (the run's steps send their own instructions), waits for the coding agent (`--prompt-timeout`), and starts the run in that pane.

A ticket that cannot be read is refused (`ticket_not_found`, `ticket_source_unavailable`) when it was the only source of `task`; with `--prompt` or `--input task=` it is a warning and the run goes on without it. A pull request that cannot be read is always refused, since it can't be checked for a fork. A branch derived from `--prompt` that already exists, locally, on `origin`, or as `.worktrees/<branch>`, is refused with `branch_exists`: pass `--branch NAME` to use it, or another name. `workflow start` needs Claude Code as the workspace's agent (`--agent-kind`, else `agent.kind`); any other kind is refused with `workflow_needs_claude` before anything is made. A workspace that already exists for a `REF`, or for a `--branch` you named, is reused, as `start` does (`would_create` is `false` in the dry run, and `path` is where a branch checked out in another worktree lives), and the run starts in its agent pane.

`workflow start` never checks out a fork's code or starts an agent in it, for any workflow: an agent that starts in a checkout loads its `CLAUDE.md` and `.claude/settings.json` hooks. It refuses with `fork_pull_request`, before any worktree, check or agent, also under `--dry-run`. `details.reason` says which rule refused, `details.next` holds the `workspace start` command to use only if you trust the code, and the refusal is permanent: running it again gives the same answer.

- A pull request `REF` passes only when `gh` says `isCrossRepository` is `false` and the pull request's base (the `host/owner/repo` of its URL) is `origin`'s or `upstream`'s repository, as configured in the project. A remote written as a git `url.<base>.insteadOf` short form is read as git expands it, and an ssh remote's host alias (such as `git@github-work:o/r.git`) as `ssh -G` reports its `hostname`; a name ssh can't resolve, or one that resolves to another host, is compared as written and so refused. `details.reason`: `cross_repository` (from a fork), `unknown_cross_repository` (no boolean in `gh`'s answer, as from an old GitHub Enterprise Server), `other_base_repository` (another repository's pull request, such as `attacker/evil#1`, a bare `#N` that `gh repo set-default` resolves elsewhere, or a URL that isn't that pull request's). `details.pr`, `details.url`, `details.cross_repository`. A pull request that can't be read keeps the read's code.
- A branch it would reuse or adopt, or a local branch with no worktree that `start` would check out, is refused when its git config tracks another repository (read with no network): `branch.<name>.merge` under `refs/pull/` (`pull_ref`), a `branch.<name>.remote` that is a URL (`url_remote`) or names no configured remote (`unknown_remote`), or a remote whose `host/owner/repo` is neither `origin`'s nor `upstream`'s (`other_repository`; a local path or relative remote counts as another). `details.branch`, `details.path` (the project's root for a branch with no worktree).
- A `pr-<n>` branch (or one tracking the local `pr-<n>`) must hold the pull request being started. `start` records the pull request it checked out as `branch.pr-<n>.workspace-pr` (`owner/repo#n`, when the ref named the repository, as `workflow start` always does); another recorded pull request is `other_pull_request`. With no record, `#n` (or the recorded one, for a branch `REF`) is read with `gh` and must pass the pull request rules above, and be the same pull request (`other_pull_request` otherwise), since `start '#n'` drops a fork's upstream and git config can't tell. A read that fails keeps its code (`ticket_not_found`, `ticket_source_unavailable`) with `details.branch` and `details.path`.

Tracking config is a proxy for where a branch's code came from, not proof: a branch fetched by hand with no upstream (`git fetch alice feature:feature`) can't be told apart from your own. GitHub Enterprise Server pull request URLs are not refs `start` reads (they are refused as invalid branch names); use `#N` from a checkout of that repository.

If you trust the code, `workspace start '#N'` (or `workspace start BRANCH`) makes or adopts the workspace, and `workspace workflow run ID` in it starts the workflow. Its agent then starts in that code and loads its `CLAUDE.md` and `.claude/settings.json` hooks. For a bare `#N`, the checkout names the repository `gh pr view` answered from (`owner/repo#N`), so it can't check out another remote's pull request than the one checked; on another host than github.com it stays `#N`, which `gh` resolves from the same repository config.

Once the workspace exists, a failure never removes it. The error keeps its code and gains `details.workspace`, `details.path` and `details.next`, an array holding one command: the `workflow run` command with the same inputs and note, which starts the workflow in that workspace by hand. This covers `agent_not_ready` (the agent was not ready in time) and a refusal from the run itself such as `pane_has_run`, and `start_failed` (the session did not start). A failure inside `start` itself, once the checkout exists, carries `details.path` and a `next` that is `cd PATH && workspace workflow run ...`, as the workspace name is not known.

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
| `guard` | `unchanged` or `config`: the engine checks the checkout when the agent's turn ends (see [The guard](#the-guard)) |
| `uses` | Lock names the run holds for the step. `dev-env` is `devenv`; `edit` is refused (only the agent that edits can hold it). A step that uses `devenv` is not sent the `dev` pack, even when it is in the defaults or an `include:`: the run holds the environment for it |
| `on_fail` | `{goto: STEP, max: N}`: on failure go back to an earlier step, at most `N` times (default 1). `context:` overrides the target step's `context` for that jump |
| `context` | `fresh` (default): start the step in a new conversation. `continue`: keep the pane's conversation |
| `timeout` | How long the step may take before `status` flags it `timed_out`. Nothing is stopped |

Text in `instructions` and `prompt` may use `{{workspace}}`, `{{branch}}`, `{{artifacts}}` (the run's directory, `<checkout>/.workflow/<run>`), `{{run}}` and `{{inputs.NAME}}`. Any other placeholder is a problem in the definition. A definition with problems is reported with all of them at once (code `invalid_workflow`).

### Validating a definition

`workflow validate PATH` reads the file; `workflow validate -` reads stdin. It runs the same checks `show` and `run` do, reports every problem at once, and writes nothing (it does not touch `~/.config/workspace/workflows/`). It exits 0 when the text is valid and 1 with `invalid_workflow` when it is not. A file that is not UTF-8 text or not a YAML mapping fails the same way; a PATH that can't be read is a usage error.

The id the text is checked as is `--id`, else a string `id:` in the text, else the file's name without its extension, else `stdin` for `-`, or `file` for a file whose name is not an id. An `id:` that differs from `--id` is a problem. A relative `prompt_file:` is read from the file's directory for a PATH and from the current directory for `-`. The problems name the paths they looked at, never their contents.

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

### Reading a run's files

`workflow files RUN` lists the files a run keeps, going or finished, from the run's own record: for each attempt its prompt (`prompt`) and, when a check ran, its log (`check_log`), and for each step each file it `produces`. It reads file metadata only and writes nothing. An unknown run is refused with `unknown_run`.

A file that is not there is listed with `exists` false and `bytes` null. A symlink is listed with `exists` true, `bytes` null and `link` true: it is never followed, so its target's size is never shown. A path that is not inside the run's artifacts directory (after resolving `..`, or through a linked directory) is left out. A run recorded before artifacts directories were kept uses `<checkout>/.workflow/<RUN>`; a run with neither answers `artifacts_dir` null and no files.

### Reading a definition's file

`workflow show ID --source` answers the file itself, for an editor: the text exactly as stored, the `sha256` of its raw bytes and every problem the checks find. It works on a preset and on a global file that does not pass the checks (exit 0, where `show ID` fails with `invalid_workflow`), so a broken file can be loaded, fixed and saved. Without `--json` it prints the text alone and writes the problems to stderr. `--source` needs an ID.

### The `rpiv` preset

`rpiv` is a workflow that ships (with [`rpiv-auto-approve`](#the-rpiv-auto-approve-preset), [`pr-feedback`](#the-pr-feedback-preset) and [`investigate`](#the-investigate-preset)): research (`research.md`), plan (the workspace plan, `IMPLEMENTATION_PLAN.md` in the notes directory, in the `implementation-plan` syntax, plus `plan.md` for the gate), which is only done once the plan file exists and has a task (its `status:` check reads `plan status --json`), implement (`implement.md`) and verify (`verify.md`). Verify holds `test-db`, so runs in worktrees of one repository verify one at a time; it is checked with the project's `commands.test`, and a failure goes back to implement up to three times in the same conversation. Its `max_attempts` is 10, which leaves room for those three trips and one rejected plan. A project with no `commands.test` is refused before anything starts (code `workflow_command_unset`):

```sh
workspace config set commands.test "bundle exec rspec"
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export"
```

### The `rpiv-auto-approve` preset

`rpiv-auto-approve` is `rpiv` with no gate, for a run no person watches. A `plan_review` step takes the gate's place: the agent starts three reviewer sub-agents (supportive, skeptical and implementer) and writes `plan-approval.md` with the plan's revision and each verdict. Its check passes only when the skeptic and at least one other approved and the revision is still the plan's, so the skeptic can't be outvoted. A rejection goes back to `plan` in the same conversation, so the agent that wrote the plan looks for an approach that meets every reviewer's concerns and it is reviewed again, at most nine times; a tenth rejection stops the run as `failed_check`. Use `workflow resume --from plan` from there, which allows one more round, in a fresh conversation: a plain `resume` reviews the same plan again. The run stops where `rpiv` does, on a verified branch, and pushes nothing.

The check reads what the step's agent wrote; it can't prove the reviewers ran, so this is a review, not a security boundary. The reviewers need a harness with sub-agents, and a permission prompt in the pane still stops the run as `waiting_you`.

```sh
workspace workflow start rpiv-auto-approve --prompt "add a retry to the uploader"
```

### The `pr-feedback` preset

`pr-feedback` triages a pull request's review feedback, waits for you, then makes the approved fixes. It has two steps and never posts to GitHub and never pushes.

- `triage` (gate `approve`, 30m) runs `workspace pr feedback --json`, reads the code each thread points at and the tail of each failing check's log, and writes a note `<date>-pr-<n>-feedback.md` in the notes directory: the counts of fix, answer, decline and needs-you with the head SHA read, then one `### F<k>` section per item with its source, author, a quoted excerpt, the verdict and the planned change. Only an item from a `trusted` author can be a fix. It writes `triage.md` (first line `note: <file name>`, the gate's note) and posts one `review_request` inbox item linked to the run (`--dedupe-key pr-feedback:RUN`, expiring in 168h). It stops with only `triage.md` when `inputs.pr` differs from the branch's pull request, or the pull request comes from a fork.
- `fix` (`context: fresh`, 2h) first checks the approved note's sha256 (see [Passing a gate](#passing-a-gate)) and stops with no commits when it differs. It records `origin/<head>` before and after, commits the items marked fix, appends `## Replies` to the note (grammar in [README.pr.md](README.pr.md#drafted-replies)), writes `fix.md`, marks the triage item done and posts a second `review_request` (`pr-feedback-fix:RUN`). Its last message names `workspace push` as your next step.

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

The task is never rendered into the instructions: the agent reads it as a JSON string from `workflow status --json` (`inputs.task`), so no title or prompt can break out of it. Ticket and pull request bodies, comments, check names and log lines are data: the instructions limit where a command's arguments may come from, forbid posting, pushing, rerunning CI and `workflow approve|reject|resume`, and ask for token-shaped text to be replaced with `[redacted]` before it reaches the note. Raw logs stay in the run's artifacts directory.

- `reproduce` (`guard: unchanged`, 45m) stops with `repro.md` (first line `stopped: <reason>`), a `note` inbox item (`investigate-stop:RUN`) and `step done --status fail --code <reason>` for `no_input`, `pr_mismatch`, `fork`, `run_not_found`, `run_not_finished` or `run_mismatch` (the run's commit is neither the pull request's head nor an ancestor of HEAD). Otherwise it reads the failed log (capped at 5 MB, with the exit status kept), reproduces the failure locally and writes `repro.md` and a reproduction as a new file. A stop item from an earlier attempt is marked done when it does not stop.
- `diagnose` (`guard: unchanged`, gate `approve`, 60m, same conversation) writes the note `<subject>-investigation-<run>.md` in the notes directory: `## Answer` (the cause, `head_sha`, `reproduced`, `ci_verdict` of `branch`, `main`, `flaky`, `infra` or `unknown`, `confidence`, and `If you approve:`), `## Fix options` (one marked `(recommended)`), `## Evidence` and `## Not checked`. It writes `diagnosis.md` (first line `note: <file name>`, the gate's note) and posts one `review_request` item (`investigate:RUN`, 168h).
- `fix` (`guard: config`, `context: fresh`, 2h, holds `test-db`) stops with `fix.md` and a code (`no_note`, `note_changed`, `fix_head_moved`, `fix_dirty_tree`, `workflow_files_visible`) when the approved note's hash, HEAD, the tracked tree or the `.workflow/` exclude no longer match. Its plan is only the note's `If you approve:` line and recommended option, changed by your approval comment. It commits a regression test and then the fix with hooks off (`core.hooksPath=/dev/null`, staging by path), through the `commits` pack's test and lint commands, appends `## Fix` to the note, marks the diagnosis item done and posts `investigate-fix:RUN`. Its last message names `workspace push` (or `workspace pr create`).

Approve with a note to change the plan ("approve, but use option B"), or reject with a hint and `diagnose` writes the note again, keeping the earlier answer under `## Rejected (attempt N)`. A stop code is a word the agent chose (`details.code` with `code_source` `agent`); a guard code (`head_moved`, `tracked_changed`, ...) is the engine's. Commit in the workspace while the gate waits and `fix` stops with `fix_head_moved`; `base_sha` in `workflow status --json` shows what HEAD should be. The guard bounds HEAD, the tracked tree and git's own files, not the machine: an agent talked into running something before the gate can do what your account can, so use it on code you would run anyway. `workflow run` never refuses a fork pull request; `reproduce` stops with `fork` (`workflow start` refuses it first, `fork_pull_request`).

A workflow's steps can hand the agent shell commands that hold the run's artifacts path, which lies under the checkout. `workflow run` (also `--dry-run`) and `workflow start` therefore refuse a checkout whose path holds a quote, a backtick, a dollar sign, a backslash, a control character or an invisible one (zero-width, bidi, U+2028, U+2029), with `unsafe_checkout_path` (`details.characters` names them, `details.path_kind` says `checkout` or `notes directory`; spaces and non-ASCII letters are fine). `workflow start` works out the path of a worktree it would create (`.worktrees/<branch>`) before anything is made, so a new unsafe path is refused first, also with `--dry-run`: no worktree, check or agent. The notes directory is held to the same rule for a workflow with a gate, since the fix step is handed the note's path (a branch name can reach it); the gate note is checked again when it is read. The refusal applies to every workflow, so a home directory like `/Users/o'brien` blocks them all.

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

Every `failed_check` reason has `details.code` and `details.code_source`. `engine` codes are a closed set: the guard codes above, `check_failed` (a `status:` command exited non-zero), `check_timed_out`, `check_error` (the check could not run, or the project's command is unset) and `reported` (`step done --status fail` with no `--code`). For a guard failure `details.guard` repeats `code`, `details.paths` is `[]` except for `tracked_changed`, and `head_moved` also has `base_sha` and `head`. A run stored before these keys existed has no `code` or `code_source` on its stored reasons. `step done --code` refuses the engine's words. An `agent` code is the word the agent gave with `step done --code`, stored as `reported.code`: a word it chose, which each workflow documents for itself. A client maps it to words, never to actions. `details.summary` stays free text, and `details.error` (why a check has no exit code) is not a code.

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
- Otherwise the caller supplies one value per entry of `needs` (`name`, `flag`) and appends it after `args`: the flag then the value, or `--` then the value when `flag` is `null`. `workflow reject` needs `{"name":"note","flag":"--note"}` and `ask answer` needs `{"name":"answer","flag":null}`. No placeholder is ever in `args`; the text output shows one for a person (`workspace workflow reject RUN --note NOTE`).

| Code | Meaning | `details` |
|---|---|---|
| `waiting_lock` | Queued for a lock a step uses | `resource`, `step`, `position`, `total`, `holder` (`kind`; `run_id`, `step`, `workspace`, `worktree` for a run; `pid` and `worktree` for an agent or a dev environment, `kind: "process"`, which adds `dev down` to `actions`) |
| `waiting_you` | A person is needed. `kind` says for what: `gate` (a passed step waits for approval), `prompt` (the pane shows a permission prompt), `ask` (a question asked from the run's pane with [`ask`](README.ask.md) is open), `dispatch` (the step's line could not be typed), `delivery` (the process typing the step's line stopped before the agent daemon answered, and the pane's agent has ended its turn: it may never have had the line) | `kind`, `step`; `artifacts`, `gate_file` and `gate_file_error` (see [Passing a gate](#passing-a-gate)) for a gate; `pane`, `message` for a prompt; `ask`, `question` for a question; `error`, `message`, `pane`, `workspace` for a dispatch; `attempt`, `pane`, `workspace` for a delivery |
| `turn_ended_incomplete` | The turn ended and a file the step produces is missing, or was left by an earlier attempt and not written again. The next turn's end, or `workflow resume`, looks again. A fresh one is hidden for its first 10 seconds and while the pane is working (the run reads `running`, with no reason), so a real stop can show up to 10 seconds late: a task that settled just before the turn ended starts a new turn on its own. After 90 minutes of a hold (below) it is stored in place of `turn_ended_background`, with `background_tasks` | `step`, `attempt`, `missing`, `stale`; `background_tasks` (`id`, `type`) after a hold ran out |
| `turn_ended_background` | The turn ended with background tasks still listed (sub-agents, shells, monitors) and a file the step produces is missing. Each task that ends starts another turn, so this is not a stop. `workflow status` never shows it: the run reads `running` with no reason and `flags: ["background_work"]`. Only the event log's `workflow_changed` carries the code | `step`, `attempt`, `missing`, `stale`, `tasks` (`id`, `type`) |
| `failed_check` | The step failed and has no loop left | `step`, `attempt`, `cause` (`check`, `reported` or `guard`), `code`, `code_source`, `guard` and `paths` (a guard failure), `exit_code`, `timed_out`, `log`, `error` (a check that could not be run, or was stopped), `summary`, `loops`, `attempts`, `max_attempts` |
| `pane_gone` | The run's pane, or its workspace, is not running | `step`, `pane`, `workspace`; when it was found while starting a step (stored), also `kind: "dispatch"`, `error` and `message` |

`pane_gone` and the `prompt`, `ask` and `delivery` kinds of `waiting_you` are read from tmux, the agent daemon and the question store when `status` runs; the others are stored in the run. A step past its `timeout` gets `flags: ["timed_out"]` and keeps running. A step that reads `running` with no reason while its pane's agent has ended its turn (the daemon shows it `idle`, or `done` for ten seconds) gets `flags: ["idle"]`: the turn ended and nothing decided the step (an interrupted turn, a daemon that was down, an `advance` that died). The flag is withheld for 30 seconds after the attempt starts, because a pane reads idle for a moment after a dispatch. Run `workflow resume`, which decides the step as the turn's end would have.

A turn that ends with background tasks listed does not stop the run. Claude Code 2.1.145 and later list them in the `Stop` hook input (`background_tasks`, each with a `type` and an `id`); `session-event` forwards only the types `subagent`, `workflow`, `shell`, `monitor`, `MCP task` and `cloud session` and ids of word characters and dashes, and the daemon passes them to `workflow advance` as `--background-task TYPE:ID` (repeatable; internal, not meant to be typed). If files the step produces are still missing, the run stores `turn_ended_background` and keeps `running`; files present, or a step reported failed, decide the step as before. A hold lasts 90 minutes from the last `Stop` that listed tasks. After that the daemon's timer turns it into `turn_ended_incomplete`, with the tasks named in the notice, so a task that never ends or an agent that died cannot hide a stopped run for good; with no daemon running nothing ends the hold, but the run then reads `stuck` in `workspace goal`. Codex and older Claude Code versions send no list and behave as before. A held run has no reason and no `idle` flag, so workspace-ui offers no Resume; a person who knows the agent is dead runs `workspace workflow resume RUN`, which acts on a held run.

A step's attempt is stored, running and bound to its pane, before its line is typed; the line is typed after the run's lock is given up, because the agent daemon may take up to two and a half minutes to answer a fresh-conversation step. A process that dies meanwhile (a `workflow run` that is killed) leaves a run whose next turn's end decides the step as usual. While the line may still be on its way (the daemon's time limit plus a minute after the attempt starts) the step gets `flags: ["delivering"]` instead of `idle`, and `resume` leaves it alone (outcome `unchanged`), so two resumes never type it twice; only `--from` or `--pane` types it again then. After that, a pane whose agent has ended its turn reads `waiting_you` with kind `delivery`: look at the pane, then `workflow resume` decides the step from its files and check as a turn's end would, and `workflow resume --from STEP` types it again in a new attempt.

`workflow resume` does what the reason calls for: asks for the lock again, runs a failed or undelivered step again, looks again at a step whose files were missing, and moves the run to the workspace's Claude pane (or `--pane`) when its own pane is gone. For a step that reads `running` it asks the daemon whether the pane's agent has ended its turn, and decides the step if it has. A resume that does nothing moves no pane and keeps no `--note`. It leaves a step an agent is working on, a step whose line is still on its way, and a check that is still running, alone (outcome `unchanged`), and refuses a run at a gate (code `gate_waiting`). It keeps the run in its pane unless that pane is gone.

A run waiting for a lock needs no `resume`: the workspace's agent daemon asks again every 15 seconds.

A turn that ends on an API error does not end the step: while the pane's agent shows `turn_failed` in [`sessions --json`](README.sessions.md), `workflow resume` (without `--pane`) leaves the run as it is, and the step stays running. The agent daemon [recovers the agent](README.agentd.md#recovering-from-an-api-error) and the step goes on when a turn completes. A new prompt typed in the pane clears the failed turn too, and so does `workflow resume --pane PANE`, which sends the step to that pane again. While the failed agent is gone and the pane shows a shell (the daemon stopped it to restart it), that send is refused as `pane_busy`: wait for the resumed agent.

A run file in `runs/` that can't be read as a run (not JSON, not readable, naming another id than its file's, or with a name that is not a run id, which no verb can name) is not shown; `status` names the file in `warnings`. The lock store still counts that run as going, so what it held stays held: free a lock with `workspace lock clear NAME`, or delete the file. So is one without a state for every step of its definition. Naming such a run to any verb answers `unknown_run` with the file in `details.path`.

## JSON output

`workflow run`, `start`, `resume`, `cancel`, `approve`, `reject` and `step done` print one [action document](README.json.md#actions). Its one result row has `workspace`, `outcome`, `reason` (the reason code, or `null`), `message`, and `run`, the run as `status` shows it:

```json
{"schema_version":1,"ok":true,"action":"workflow run","status":"ok",
 "results":[{"workspace":"api.worktree-pdf","outcome":"started","reason":null,"message":null,
   "run":{"id":"wr_2610041230559x3k","workflow":"rpiv","state":"running","current":{"step":"research","attempt":1,"state":"running","reason":null,"flags":[]}}}],
 "warnings":[],"summary":{"started":1}}
```

`outcome` is `started`, `resumed`, `unchanged` (a `resume` that did nothing: an agent is working on the step, its line is still on its way, or its check is still running; `message` says which, exit 0), `cancelled`, `approved`, `rejected` or `recorded` (`step done`). A run that waits (for a lock, at a gate) still has that outcome, with the reason code in `reason`. When a step's line could not be typed the outcome is `failed`, `status` is `failed` and the exit code is 1; the run exists, `message` says why, and `workflow resume` tries again. `workflow start` prints the same action document; its row is the `run` row merged with `branch`, `path`, `created`, `task`, `ticket` (`key`, `title`, `url`; `null` when none was read) and `warnings`. `start --dry-run` prints `status: "dry_run"` with a row of `workflow`, `step`, `project`, `branch`, `path`, `would_create` (`false` when an existing workspace would be reused), `inputs`, `packs`, `warnings` and `ticket`. `run --dry-run` prints `status: "dry_run"` with a row of `workflow`, `step`, `pane` (`null` when the agent daemon is not running yet), `inputs` and `packs`. `step done`'s row has `run_id`, `step`, `attempt` and `reported` (`status`, `pass` or `fail`, and `summary`, as `step status` gives it) in place of `run`. `run_id` is always a run's id, in rows, events and error `details`; `run` is only the run object in an action row.

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
- A step's `state` is `pending`, `waiting` (not started: a lock, or a line that could not be typed), `running`, `checking` (its check is running), `passed` or `failed`. `gate` is `waiting`, `approved`, `rejected` or `null`. `gate_file` is `{path, sha256}` as approve recorded it, or `null`; `note_changed` is true when that note's bytes differ now (see [Passing a gate](#passing-a-gate)).
- `warnings` are strings: a workspace's agent daemon did not answer, so a permission prompt would not show; a run will not move because its workspace has no agent daemon; a run file can't be read or shown.
- `events_path` is the run's own history, one JSON line per transition (`run_started`, `step_dispatching` (the attempt is stored and its line about to be typed), `step_dispatched` (the daemon answered; `delivered` says whether the line landed), `step_reported`, `check_finished`, `step_passed`, `step_failed`, `step_looped`, `gate_waiting`, `gate_approved` and `gate_rejected` (with `note` when the person gave one; `gate_approved` with `sha256` when it recorded a note), `run_resumed`, `run_completed`, `run_cancelled`), each with `ts` and `type`.

`workflow show --json` prints `{"schema_version":1,"ok":true,"workflows":[...]}` (each `id`, `title`, `description`, `source` (`global` or `builtin`), `path`, `sha256`, and `problems`, empty for a valid file), or with an ID `{"workflow":{...}}`: the definition with defaults filled in, `steps` as a list in run order, plus `source`, `path` and `sha256`.

`workflow show ID --source --json` prints `{"schema_version":1,"ok":true,"workflow":{...}}` with `id`, `source` (`global` or `builtin`), `path`, `text` (the file's text, or `null` when its bytes are not UTF-8), `sha256` (of the file's raw bytes, whatever they are) and `problems` (empty when the file is valid). When `problems` is empty the definition's own fields (as `show ID` gives them) are added to the same object.

`workflow validate --json` on a valid text prints `{"schema_version":1,"ok":true,"workflow":{...}}`: the definition with defaults filled in (as `show ID` gives it), plus `source` (`file`, or `stdin`), `path` (absolute, or `null` for stdin) and `sha256` of the text's bytes. On an invalid one it prints the error envelope with `code: "invalid_workflow"` and `details: {"workflow": ID, "path": PATH or null, "problems": [...]}`, and exits 1.

`workflow update --json` prints the same row with `outcome` `updated` (or `dry_run`) and the new `sha256`. Refusals print the error envelope: `invalid_workflow`, `unknown_workflow`, `builtin_workflow` (`details.workflow`), `stale_workflow` (`details.workflow`, `details.path`, `details.sha256` of the current file, or `null` when unreadable) or `usage`. For example `{"schema_version":1,"ok":false,"error":"The workflow file /home/me/.config/workspace/workflows/ship.yml changed: its sha256 is 9f2c..., not ab12.... Nothing was changed.","details":{"workflow":"ship","path":"/home/me/.config/workspace/workflows/ship.yml","sha256":"9f2c..."}}`.

`workflow remove --json` prints the same row with `outcome` `removed` (or `dry_run`), `workflow` and `path` (the file removed, or that would be). Refusals print the error envelope: `invalid_workflow` (an id that could not be a file name, or a directory at the path), `unknown_workflow`, `builtin_workflow`, `confirmation_required` or `usage`.

`workflow add --json` prints an [action document](README.json.md#actions) with one row: `outcome` `added` (or `dry_run`, with the document's `status` `dry_run`), `workspace` `null`, `workflow` (the id), `path` (the file written, or that would be) and `sha256` (of the text's bytes, as `show ID --source` will report it). Refusals print the error envelope: `invalid_workflow` (with `details.problems`), `workflow_exists` (`details.workflow`, `details.path`) or `usage`.

`workflow events --json` prints `{"schema_version":1,"ok":true,"run":ID,"events":[...],"truncated":false,"next_since":N,"warnings":[]}`. Each event is `{"n","ts","type", ...}`: `n` the line number from 1, then the line's own keys (`ts`, `type` and the event's details; `n` in a line is ignored). A `gate_approved` or `gate_rejected` line has `note`, the text given to `approve --note` or `reject --note`, and no `note` key when there was none. In text output a value holding a line break or other control character is printed as a JSON string, so each event stays on one line. `next_since` is the last event's `n` when `truncated`, else the number of the last line read (or `--since` when nothing was read), so it is always the value to ask for next. For example, `workflow events wr_2610250930abcd --since 1 --json` on a run whose third line is not an object:

<!-- workflow-events-example -->
```json
{"schema_version":1,"ok":true,"run":"wr_2610250930abcd","events":[{"n":2,"ts":"2026-10-25T09:30:00Z","type":"step_dispatched","step":"research","attempt":1},{"n":4,"ts":"2026-10-25T09:30:00Z","type":"step_done","step":"research","attempt":1,"status":"pass"}],"truncated":false,"next_since":4,"warnings":["Line 3 of the history is not a JSON object; skipped."]}
```

`workflow files --json` prints `{"schema_version":1,"ok":true,"run":ID,"artifacts_dir":PATH,"files":[...]}`. Each file is `{"path","kind","step","attempt","exists","bytes"}` plus `"link":true` for a symlink: `path` is absolute; `kind` is `prompt`, `check_log` or `produces`; `attempt` is the attempt number, or `null` for `produces`; `bytes` is `null` when the file is missing, a link or not a regular file. For example, on a run whose first step has one attempt, a `produces` file that is there, one that is missing and one that is a symlink:

<!-- workflow-files-example -->
```json
{"schema_version":1,"ok":true,"run":"wr_2610250930abcd","artifacts_dir":"/work/app/.workflow/wr_2610250930abcd","files":[{"path":"/work/app/.workflow/wr_2610250930abcd/steps/research.1.prompt.md","kind":"prompt","step":"research","attempt":1,"exists":true,"bytes":12},{"path":"/work/app/.workflow/wr_2610250930abcd/steps/research.1.check.log","kind":"check_log","step":"research","attempt":1,"exists":true,"bytes":3},{"path":"/work/app/.workflow/wr_2610250930abcd/research.md","kind":"produces","step":"research","attempt":null,"exists":true,"bytes":11},{"path":"/work/app/.workflow/wr_2610250930abcd/plan.md","kind":"produces","step":"research","attempt":null,"exists":false,"bytes":null},{"path":"/work/app/.workflow/wr_2610250930abcd/notes.md","kind":"produces","step":"research","attempt":null,"exists":true,"bytes":null,"link":true}]}
```

`step status --json` prints `{"schema_version":1,"ok":true,"step":{...}}` with `run_id`, `workflow`, `workspace`, `step`, `attempt`, `state`, `instructions`, `artifacts_dir`, `produces` (each `path`, `exists`, and `current`: written during this attempt), `check` (whether the step has one) and `reported` (`status` and `summary`, or `null`).

Failures print the [error envelope](README.json.md). Codes: `unknown_workflow`, `invalid_workflow`, `workflow_exists`, `stale_workflow`, `builtin_workflow`, `input_required`, `workflow_command_unset`, `invalid_input`, `dirty_worktree` (`workflow run`, `run --dry-run`, and `workflow start` into a reused workspace, for a `guard: unchanged` step), `fork_pull_request` (`workflow start`), `no_agent_pane`, `pane_has_run`, `no_daemon`, `unknown_run`, `run_not_active`, `gate_not_waiting`, `gate_waiting`, `bound_pane`, `not_bound`, `step_not_running`, and `usage`.

## Events

Every change to a run writes one `workflow_changed` to the [event log](README.event-log.md), under the run's workspace, with `run_id`, `workflow`, `workspace`, `state`, `step` and `reason` (the stored reason code, or `null`). It says a run changed; refetch `workflow status --json`. A hold (`turn_ended_background`) writes one line on entering, with `state` `running`, and none for its later Stops. A run's locks write `lock_wait_started`, `lock_acquired` and `lock_released` under the repository's project, with `run_id` in place of `pid`.

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
workspace workflow run rpiv --name my-app.worktree-pdf --input task="PROJ-101 invoice PDF export" --dry-run
workspace workflow run rpiv --input task="PROJ-101 invoice PDF export" --note "Keep the public API as it is."
workspace workflow start rpiv PROJ-101 --dry-run --json
workspace workflow start rpiv PROJ-101 --slug --base main
workspace workflow start rpiv --prompt "add a hello script" --headless
workspace workflow status
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

- One run per pane: `run` refuses a pane another run is using (code `pane_has_run`).
- The runner types into the pane you may be using. A fresh step waits up to two minutes for the pane to go quiet before `/clear`; one that stays busy, or a daemon that does not answer within two and a half minutes, is reported as `waiting_you` (`dispatch`) and `resume` tries again.
- A turn's end is matched to its step only when the daemon saw that turn begin. One it did not see begin (the daemon was restarted in the middle of the turn, or was started before this version: run `workspace daemon restart` once after upgrading) counts for the step the run is on, as every end did before. A `context: continue` step's line is not typed into a pane whose agent is in the middle of a turn or at a permission prompt: the step waits as `waiting_you` (`dispatch`, error `pane_busy`), and `workflow resume` types it once the agent is done. A pane in which the daemon has seen no turn end (after Esc, after a `/clear` typed by hand, or in a workspace just launched) counts as busy until its screen has been still for `alerts.idle_after`; one prompt the agent finishes clears that at once.
- If a step's own turn's end is ever not counted, the step reads `running` with the `idle` flag once its pane is quiet, and `workflow resume` decides it.
- Everything a workflow reads and writes is UTF-8, whatever the locale of the process (cron and apps started by launchd have none; see [Text encoding](../README.md#text-encoding)): definitions, `prompt_file`s, run files, step files, and the `--note`, `--input` and `--summary` arguments. An argument that is not valid UTF-8 (a string cut in the middle of a character) is refused with a usage error before anything is done; a definition or `prompt_file` that is not is reported as a problem (`invalid_workflow`); a run file that is not counts as one that can't be read. A value put into a prompt (the branch, a path) that is not UTF-8 has its bad bytes replaced. The workspace's questions and tasks are read as UTF-8 too; if they can't be, `status` says so in `warnings` and goes on.
- A `workflow run` that is interrupted before its first step is under way leaves a run that waits (`waiting_you`, `dispatch`, error `not_started`); `workflow resume` starts it.
- A dev environment the run's agent started under `uses: [devenv]` is stopped by the runner when the run gives `devenv` up on the way into a step that doesn't use it. One still running when the run stops at a gate, on a failure or at its end keeps the lock until `workspace dev down` (see [`dev`](README.dev.md)).
- A run copies its definition when it starts, so editing the file changes the next run, not one in flight.
- `pipeline` is deprecated in favor of `workflow` and will be removed in a later release.
