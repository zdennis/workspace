# Workspace CLI

A macOS CLI (Ruby) for managing tmuxinator-based development workspaces in iTerm2.

## Project Structure

- `bin/workspace` — Entry point (4 lines), calls `Workspace.build_cli.run(ARGV)`
- `lib/workspace.rb` — Module root, `build_cli` factory, error classes
- `lib/workspace/cli.rb` — CLI dispatch, OptionParser definitions, simple command methods
- `lib/workspace/config.rb` — Path constants and configuration
- `lib/workspace/commands/notes.rb` — `notes dir`: the one answer to where a workspace's notes are, through `NotesDir`; `--create` makes the directory and lists it in `info/exclude`; `workspace ui open notes [WS]` sends the person to the Notes view through `Commands::Ui` (`workspace-ui://notes/<ws>`)
- `lib/workspace/config_schema.rb` — The one table of config keys: scope, settable, default, value parser, restart flag, doc text; readers, `config set/get/unset` and the docs take their key lists and checks from it
- `lib/workspace/notes_dir.rb` — The one resolver for where a workspace's notes go: its own `notes.dir`, else the directory the project's `notes.default_dir` rule computes (`tmp/workspace-notes` in the checkout when unset); `config show --json` reports it as `effective_path`
- `lib/workspace/config_schema_docs.rb` — Renders the schema into the generated blocks of `docs/README.config.md`; `script/generate-config-docs [--check]` runs it, and a spec fails on drift
- `lib/workspace/state.rb` — JSON-persisted session state
- `lib/workspace/git.rb` — Git and worktree operations
- `lib/workspace/which.rb` — Shared default PATH lookup for injectable `which:` collaborators
- `lib/workspace/doctor.rb` — Dependency checking; warns on a paused plan whose owner pane is working and on a `[~]` task in a workspace with no session
- `lib/workspace/tmux.rb` — Tmux session management
- `lib/workspace/project_config.rb` — Tmuxinator config generation
- `lib/workspace/project_catalog.rb` — Groups workspaces into projects (main checkout + worktrees) by the realpath of each checkout's git common dir, read from `.git` files; backs `projects`
- `lib/workspace/osascript_runner.rb` — Runs one AppleScript through `osascript` with a 5s limit; past it the process group is stopped and the answer is empty with `timed_out`; `ITerm` and `WindowManager#close_window` go through it
- `lib/workspace/iterm.rb` — iTerm2 session/pane lifecycle (AppleScript); `#last_call_timed_out?` says iTerm2 did not answer, which `stop` turns into a warning
- `lib/workspace/window_manager.rb` — iTerm2 window operations: find, focus, position, close
- `lib/workspace/window_liveness.rb` — Whether iTerm still has each tracked workspace's recorded window (one `live_window_ids` call, none when all are headless); nil for headless or when the list can't be read; backs `window_alive` in `status --json`, `list --liveness --json` and `cleanup`
- `lib/workspace/window_layout.rb` — Window positioning math
- `lib/workspace/json_envelope.rb` — Builds the `--json` action and error documents (`ok`, `code`, `details`, `retry`); the CLI rescue funnel emits the errors, `CLI#run_action` the actions
- `lib/workspace/output_gate.rb` — The stdout every collaborator writes through; `--json` actions divert it to stderr so stdout holds one document
- `lib/workspace/error_codes.rb` — Registry of the stable error `code` values, mirrored in `docs/README.json.md`
- `lib/workspace/pane_locator.rb` — Strict pane resolver for `agent-run send`, `focus --pane` and `ask answer --deliver`: only a pane id or `window.pane`, and only a pane of the workspace's own tmux session
- `lib/workspace/pane_bindings.rb` — `bindings.json`: tmux pane id to the run, review or play it works on, with the session it was made in and the `packs` its agent was sent; `session-event` prints it, and the packs composed again, as `additionalContext` on SessionStart; `#move` carries bindings to the panes `restore` resumes in
- `lib/workspace/library_store.rb` — The files of one library scope (`<kind>/<name>.md`, or a `skill/<name>/` directory holding `SKILL.md`; a copy or a symlink), written through a temp file or directory and rename
- `lib/workspace/library.rb` — Resolves a library `REF` across scopes; `#stores` is the one lookup order (project, global, then the built-in store `lib/library/`); `#pack` looks an instruction pack up built-in first; `#play` checks the play `start --play`/`launch --play` point the agent at; `#copyable` checks a `start --agent`/`--skill` entry
- `lib/workspace/library_installer.rb` — Copies a library agent or skill into a checkout's `.claude/agents/` or `.claude/skills/`, never over a tracked path, and lists it in the common dir's `info/exclude`
- `lib/workspace/instruction_composer.rb` — Builds an agent's instructions from library packs under a heading per pack, and a workflow step's four layers (default packs, workflow, step, attempt); adds the pane's binding after `binding` and the project's `commands.test`/`commands.lint` after `commits`; `#start_packs`/`#compose_start` list and compose what `start` and `launch` send with the first prompt (the automatic `notes` pack, the `dev` pack when the project sets `dev.up`, then `--pack` names; `compose(skip:)` leaves a pack out of a workflow step)
- `lib/workspace/notes_config.rb` — Reads a project's `notes.instructions` (false turns the automatic `notes` pack off for `start` and `launch`)
- `lib/workspace/main_agent.rb` — Which coding agent a project's main agent pane runs (`claude`, `codex`, ..., or `none`), read from the panes of its tmuxinator config; `InstructionComposer` uses it to send the `handoff` pack to Claude Code and Codex only
- `lib/workspace/commands_config.rb` — Reads a project's `commands.test` and `commands.lint`
- `lib/library/play/` — The built-in instruction packs (`binding`, `orchestrator`, `commits`, `review`, `notes`, `handoff`, `dev`, `implementation-plan`), read through `Library#builtin_store`
- `lib/workspace/commands/` — Complex command objects (launch, kill, focus, start, agent, ensure_agent, lock, dev, notes, plan, pull_request, rebase, push, projects, capabilities, send, review, restore, snapshot, daemon, ui, binding, library, instructions, workflow)
- `lib/workspace/notes_dir.rb` — The one resolver for a workspace's notes directory: its own `notes.dir`, else the project's `notes.default_dir` rule, else `tmp/workspace-notes` in the checkout; `Commands::Notes#info` returns the answer as a Hash (`dir` prints it) and `#files_inside_worktree` counts the files `kill` and `finish` would delete
- `lib/workspace/notes_setup.rb` — Fixes a new worktree's notes directory for `start` and `add`: writes the computed path as the worktree's own `notes.dir` (never over an existing value), makes the directory and its `info/exclude` line; every problem comes back as a warning, never an error
- `lib/workspace/plan_file.rb` — The parser for a workspace's `IMPLEMENTATION_PLAN.md` (`PlanFile.parse(text)`, `PlanFile.read(path)`; nil when the file is missing): frontmatter, the `- [S] ID Title` tasks under `## Tasks`, `counts`, `percent`, `current`, `warnings`; it never fails. `PlanFile.set_status` and `.set_owner_pane` are the only writers of the file: one frontmatter line, through a temp file and rename, with one re-read and retry
- `lib/workspace/plan_state.rb` — `PlanState#derive` picks the one plan `state` (`empty`, `done`, `paused`, `stopped`, `waiting`, `working`, `blocked`, `stalled`, `idle`) from the parsed plan and the facts; `#row` builds the row `plan status --json` and, minus `tasks`, each member's `plan` in `snapshot` (from the snapshot's own reads)
- `lib/workspace/plan_config.rb` — Reads a project's `plan.stall_seconds`
- `lib/workspace/start_ref.rb` — What `start` and `ticket show` make of a ref (JIRA key or URL, pull request, issue, branch): its `kind`, `key` and `branch`, and `#project` for the project a worktree would join (the parent repo from inside a linked worktree)
- `lib/workspace/ticket_source.rb` — Reads a ticket's title, body (64 KB cap) and URL with `gh` (pull request, issue) or `jira` (`jira issue view KEY --raw`) within 10s; a missing tool, a timeout or a failure is `ticket_source_unavailable`, an unknown ticket `ticket_not_found`; a branch runs nothing
- `lib/workspace/commands/ticket.rb` — `ticket show REF [--name WS] [--json]`: the lookup, plus the workspace that already exists for the ref's branch; writes nothing
- `lib/workspace/timed_process.rb` — Runs one command with a time limit and no prompt (`GH_PROMPT_DISABLED`, `GIT_TERMINAL_PROMPT`), in its own process group that is stopped on timeout; `TicketSource.run`, `PullRequestStatus` and `Commands::PullRequest` run `gh` and `git` through it
- `lib/workspace/commands/pull_request.rb` — `pr create [--name WS] [--draft] [--json]`: the branch's existing pull request, else a push (no upstream) and `gh pr create --fill`; refuses `nothing_to_push` and `gh_unavailable`. `#find_or_create` is the look-up-or-create step alone, which `Commands::Finish` calls for `--pr`
- `lib/workspace/workspace_checkout.rb` — The workspace, checkout path and branch a command works on (`--name`, else the workspace of the working directory; refuses a detached HEAD); `rebase` and `push` use it
- `lib/workspace/commands/rebase.rb` — `rebase --onto local|update|remote [--name WS] [--json]`: refuses dirty tracked files (`dirty_worktree`) and a stopped rebase (`rebase_in_progress`), never stashes the workspace's own changes, aborts its own conflicted rebase; `update` moves the local default branch up to origin's first (stashing and restoring a dirty checkout of it); outcomes `rebased`, `up_to_date`, `conflict`, `default_not_updated`
- `lib/workspace/commands/push.rb` — `push [--name WS] [--json]`: `-u` with no upstream, a plain push when only the branch has new commits, `--force-with-lease` only when the branch's reflog shows it once held every upstream-only commit, else `push_rejected`; `Git#push` is the one push, which `PullRequest` uses too (`Git` takes a `runner:` for its time-limited calls)
- `lib/workspace/commands/plan.rb` — `plan status|path|show|init|start|pause|delete`; `#rows(names:, all:)` returns the rows, gathering the session, the owner pane's state and the open questions; `#start` is given a `launch:` callable by the CLI (launching is `CLI#launch_projects`) and otherwise types into the main agent pane and binds it to the play; every change records `plan_changed`
- `lib/workspace/work_coordinator_client.rb` — JSONL client for work-coordinator sockets
- `lib/workspace/pipeline_config.rb` — (`pipeline` is deprecated in favor of `workflow`) Reads per-project pipeline stage config from `~/.config/workspace/projects/<name>.yml`
- `lib/workspace/pipeline_state.rb` — In-flight work item tracking, disk-persisted to `~/.local/state/workspace/<name>/pipeline.json`
- `lib/workspace/sentinel_poller.rb` — Background poller watching tmux panes for `WORKSPACE_DONE:` sentinel
- `lib/workspace/session_monitor.rb` — Per-pane coding-agent and sub-agent state (working/idle/waiting), keyed on tmux pane id; fires alerts
- `lib/workspace/context_reader.rb` — A pane's context use: the status-line reading, a `context.pattern` scrape, or, when given the pane's agent kind, a scrape by `context.patterns` or the provider's own pattern (Codex)
- `lib/workspace/session_ledger.rb` — Flock-guarded append-only `ledger.jsonl` of SessionStart/SessionEnd (with pane slot, tmux server pid and window layout), written by `session-event`; `#slots_for` streams it into the latest session per pane slot for `restore`; `#open_session_for` names the session open in a pane, which `dev up` records as `started_by`
- `lib/workspace/alert_config.rb` — Reads a project's `alerts.notify` and `alerts.idle_after`
- `lib/workspace/notifier.rb` — Runs the notify command in the background with a timeout, details in `WORKSPACE_ALERT_*` env vars
- `lib/workspace/inbox_store.rb` — Flock-guarded JSON file of one inbox scope (workspace, project or global) under `~/.local/state/workspace/.inbox/`; `add`, `upsert` (by `dedupe_key`), `list`, `find`, `update`, `transition`/`transition_by_key`; a passed snooze or expiry reads as `open`/`dismissed` without writing
- `lib/workspace/commands/inbox.rb` — `inbox add|list|show|edit`: scope resolution (`--name`, `--project`, `--global`, else the cwd's workspace), input checks that refuse control characters and over-long or non-https text (`invalid_inbox_item`), and output with control characters escaped; stores come from an injected `store_factory`
- `lib/workspace/inbox_derived.rb` — The rows `inbox list --include-derived` works out and never stores: open asks, waiting panes (daemons read in parallel, each bounded), blocked or stalled plans, workflow gates and stuck locks, by workspace-ui's queue rules; a source that fails is a warning and no rows
- `lib/workspace/ask_store.rb` — Flock-guarded append-only store for `workspace ask` questions, one `asks.json` per workspace under its XDG state dir
- `lib/workspace/task_store.rb` — Flock-guarded one-file-per-task store under `~/.local/state/workspace/.tasks/`: `start` creates, `finish`/`kill` archive (newest 200 kept); the task id is `WORKSPACE_TASK` in panes
- `lib/workspace/pull_request_status.rb` — Read-only `gh pr view` for a checkout's branch (state, review decision, check counts); `gh` missing or failing is a fact, not an error
- `lib/workspace/transcript_summary.rb` — Reads the last main-thread assistant message from the tail of a Claude Code transcript
- `lib/workspace/process_tree.rb` — One-shot `ps` snapshot with parent/child lookups
- `lib/workspace/workspace_lineage.rb` — Resolves a workspace's parent project (marker, then git common dir); shared by locks, `dev`, `config set`, and `parent`
- `lib/workspace/lock_namespace.rb` — Resolves the shared lock namespace (git common dir) from a cwd
- `lib/workspace/lock_holder.rb` — Identifies the calling agent's pid/start time and checks holder/waiter liveness; `#run_alive?` asks `RunLiveness` about a run holder
- `lib/workspace/lock_store.rb` — Flock-guarded JSON lock store (acquire/release/status/clear), reaped on every op; `#acquire_run`/`#release_run` hold locks for a workflow run (`kind: "run"`, keyed on the run id, exempt from `release_all`, taken in sorted order), and `#delegate`/`#end_delegate`/`#keep_delegate` record the dev wrapper working under a run's hold; `LockStore.run?` is the one check for a run record
- `lib/workspace/run_liveness.rb` — A run is alive while `~/.local/state/workspace/.workflows/runs/<id>.json` exists and its `state` is not `completed`, `failed` or `cancelled`
- `lib/workspace/run_resources.rb` — Holds a workflow step's `uses:` for the run: resolves the names (`dev-env` is `devenv`, `edit` is refused), acquires through `LockStore#acquire_run` without blocking, releases; `WorkflowEngine` is its caller
- `lib/workspace/workflow_definition.rb` — One workflow definition (YAML): checks every key, collects every problem (`invalid_workflow`), fills defaults; `#to_h` is the copy a run keeps; `.render` fills `{{placeholders}}`
- `lib/workspace/workflow_catalog.rb` — Finds a definition by id: `~/.config/workspace/workflows/`, then the presets in `lib/workflows/` (`rpiv`)
- `lib/workspace/workflow_run_store.rb` — Run files under `~/.local/state/workspace/.workflows/`: `runs/<id>.json` and `<id>.events.jsonl` while a run is going (what `RunLiveness` reads), `archive/` once finished; `#update` is the one way a run changes, under the run's own flock
- `lib/workspace/workflow_engine.rb` — Every transition of a run: `start`, `turn_ended` (derived done: files exist, check passes), `report`, `approve`, `reject`, `resume`, `cancel`, `tick`, `workspace_killed`; stores the reasons `waiting_lock`, `waiting_you`, `turn_ended_incomplete`, `failed_check`; emits `workflow_changed` and the run's lock events
- `lib/workspace/workflow_panes.rb` — The run's pane: default Claude pane from the daemon, binding through `Commands::Binding`, and the one typed line (`restart_agent` for a fresh conversation, `Tmux#deliver` to continue)
- `lib/workspace/workflow_check.rb` — Runs a step's `status:` command in the checkout with a time limit, output to a log
- `lib/workspace/workflow_status.rb` — What `workflow status` shows: the stored run plus what is read at the time (`pane_gone`, a permission prompt or open ask as `waiting_you`, the `timed_out` flag) and each reason's `actions`
- `lib/workspace/workflow_nudger.rb` — The daemon's part: starts `workspace workflow advance` as its own process when a turn ends in a bound pane, and on a timer for runs waiting on a lock
- `lib/workspace/workflow_config.rb` — Reads the global `workflows.defaults.include` (the default packs)
- `lib/workspace/git_exclude.rb` — Lists a path in a repository's `info/exclude` (`#add`) or reads whether it is listed (`#listed?`); keeps `.workflow/` and the notes directory out of `git status`
- `lib/workflows/` — The workflow presets that ship (`rpiv.yml`)
- `lib/workspace/bound_run.rb` — The run the calling pane is bound to (a non-stale `kind: run` binding of `$TMUX_PANE`); lets `dev up` and `lock acquire` tell the run's own agent from anyone else
- `lib/workspace/lock_config.rb` — Reads a project's `locks.idle_grace` (falls back to 5m with a warning)
- `lib/workspace/dev_session_release.rb` — On a `session-event` SessionEnd (never reason `clear`), finds a `devenv` lock record whose `started_by.session_id` is the session by reading the lock files, then starts `workspace dev __release SESSION` as its own process; `Commands::Dev#release_for_session` does the stop (unless `dev.release_on_session_end` is false, or anything cannot be read)
- `lib/workspace/lock_idle_tracker.rb` — Marks an agent's lock idle/active from `session-event` hooks, for idle takeover
- `lib/workspace/agent_provider.rb` — Registry of coding-agent CLIs workspace can monitor; says which ones handoff may clear (`restartable?`, `clear_command`) and how a pane without a status line has its context read (`context_pattern`, Codex's `N% context left`)
- `lib/workspace/agent_readiness.rb` — Waits for a coding agent's pane to be quiet and (if the provider declares one) match its ready pattern before `launch --prompt`/`start --prompt` send text
- `lib/workspace/hook_installer.rb` — Merges workspace's hooks into an agent's own settings file
- `lib/workspace/file_backup.rb` — Copies a file aside before workspace edits it
- `lib/workspace/dev_events.rb` — Writes `dev_started` and `dev_stopped` (reasons `down`, `exit`, `reaped`, `forced`) to the event log; `DevRunner` writes the start and an exit on its own, `Commands::Dev` the stops it makes, and `LockStore`'s `on_reap` hook reports a dead wrapper to the agent daemon's `LockReaper`
- `lib/workspace/dev_runner.rb` — The `dev __run` wrapper: holds the `devenv` lock while the dev command runs on the pane's TTY, forwarding stop signals once to its process group; started from a run's pane while that run holds the lock, it is the run's delegate instead
- `lib/workspace/process_group_terminator.rb` — SIGTERM then SIGKILL for a lock holder's process group, after checking pid + start time
- `lib/workspace/process_holder_stopper.rb` — Stops a `kind: "process"` lock holder for `lock clear`/`dev down`, or keeps the lock naming it when the group can't be stopped; `#stop_group` does the stop alone, for a run's delegate
- `lib/workspace/dev_config.rb` — Reads a project's `dev:` block (`up`, `ready`, `stop_timeout`; `#configured?` and `#instructions?` decide the automatic `dev` pack), as written by `workspace config set`
- `lib/workspace/run_result_cleaner.rb` — Removes run files in `~/.workspace-runs` older than 7 days, never an in-progress run or a live session's; swept at most hourly from `RunResultStore#write`
- `lib/workspace/prompt_input.rb` — `PromptInput` wraps the input stream and refuses prompts under `--no-input`/`WORKSPACE_NO_INPUT`; `Prompt.ask` is how every prompt site reads an answer
- `lib/workspace/duration.rb` — Parses duration strings (`"20"`, `"5m"`, `"1h"`) shared by dev/lock config and CLI options
- `lib/templates/workspace.project-template.yml` — Tmuxinator template for standard projects
- `lib/templates/workspace.project-worktree-template.yml` — Tmuxinator template for git worktree projects
- State tracked in `~/.workspace-state.json`
- Configs installed to `~/.config/tmuxinator/`

## Key Details

- No runtime gems/dependencies beyond Ruby stdlib (`optparse`, `open3`, `json`, `fileutils`)
- Constructor injection throughout: `Workspace.build_cli` assembles the dependency graph
- Uses AppleScript for iTerm2 automation
- Uses `window-tool` binary for window positioning
- Templates use `{{PLACEHOLDER}}` syntax for variable substitution
- `lib/workspace.rb` sets `Encoding.default_external` to UTF-8 when it is loaded, so file reads and captured command output are UTF-8 whatever the locale; ARGV and ENV values keep the locale's tag

## Subcommands

init, doctor, launch, start, add, stop, kill, finish, relaunch, restore, focus, list, status, whereis, agent, daemon, pipeline, sessions, review, snapshot, session-event, lock, dev, parent, notes, plan, ticket, pr, rebase, push, projects, ask, inbox, capabilities, ui, binding, library, instructions, workflow, step

## Adding a Subcommand

1. Create `lib/workspace/commands/foo.rb` with a `call` method (or keep it inline in CLI for simple commands)
2. Add `cmd_foo` method in CLI that parses options with OptionParser and delegates
3. Add case branch in `CLI#run`
4. Wire dependencies in `Workspace.build_cli` if using a command object
5. Add `require_relative` in `workspace.rb`
6. Add help text to `main_help` in CLI

## State File (~/.workspace-state.json)

```json
{
  "project-name": {
    "unique_id": "iTerm session UUID (written by Launch after pane creation)",
    "iterm_window_id": 123
  }
}
```

- Written by: Launch (after pane creation and window discovery)
- Consumed by: Launch (reattach), Kill, Focus, List, Status
- Loaded explicitly via `@state.load`; saved via `@state.save`
- Silently resets to `{}` on corrupt JSON

## External Dependencies

- **tmux / tmuxinator**: Session management (required)
- **window-tool**: Screen geometry and window positioning (required) — https://github.com/zdennis/window-tool
- **gh**: GitHub CLI for PR checkout (`gh pr checkout --worktree`) in `start` (optional)
- **ascii-banner**: Cosmetic banner in launcher pane (optional)
- **git**: Version control operations (required)
- **iTerm2**: Terminal emulator, controlled via AppleScript (required)

## Dependency Injection

- All collaborators are injected via keyword arguments in `initialize`
- `Workspace.build_cli` is the sole composition root — all object construction happens there
- Command objects are pre-built in `build_cli` and passed to CLI; CLI never constructs commands
- IO streams (`output:`, `error_output:`, `input:`) are injectable on every class that produces output
- `exit_handler:` is injectable on CLI (defaults to `Kernel`, tests use `FakeExitHandler`)
- `ProjectDetector` is shared between CLI and Stop for working-directory detection
- `File`, `Open3`, `YAML` are called directly (not wrapped) — test with stubs or temp dirs
- No DI container or framework needed — the dependency graph fits in a single factory method

## Conventions

- Follow existing code style (methods, snake_case, minimal abstraction)
- Composition over inheritance, no modules for private method grouping
- Command objects receive parsed values, never ARGV
- Only `CLI#run` calls `exit`; everything else raises `Workspace::Error` or `Workspace::UsageError`
- IO injection: classes accept `output:`, `error_output:`, `input:` for testability
- YARD docs on all public classes and methods
- Tests use RSpec, run with `bundle exec rspec`
- Lint with `bundle exec standardrb lib/ spec/`
- `bin/` is for project executables (the public interface) — only `bin/workspace` belongs here
- `script/` is for project-specific dev scripts and tooling (e.g., test helpers, one-off utilities)

## Orchestration

The main interactive session is an **orchestrator**, not an implementer. Its job is
to hold the plan, decide what happens next, and report results — not to read every
file itself. Delegate the work to sub-agents via the Agent tool, and keep the
conversation for decisions the user needs to make.

Delegate when a task means reading across several files, running a broad search,
reviewing a diff, or doing work that is independent of other work in flight. Launch
independent agents in a single message so they run concurrently. Do not delegate a
single-fact lookup when the file and symbol are already known — that costs more than
it saves.

### Choose the model deliberately

Pass `model:` on every Agent call. The default is not always right, and an
oversized model on a mechanical task is pure cost.

- **haiku** — mechanical and well-specified: file lookups, running a known command,
  collecting output, simple edits with an exact target.
- **sonnet** — the default for real work: implementing a described change, writing
  tests, focused review, multi-file search that needs judgment.
- **opus** — reserve for genuine difficulty: architecture decisions, subtle
  debugging, work where being wrong is expensive and hard to detect.

Balance cost against the value of the answer. Most delegated work is sonnet; reach
for opus when the task is hard, not when it is important.

### Agents must be terse

Instruct every sub-agent to report only the essentials. A sub-agent's response
should be the conclusion and the evidence needed to trust it — nothing else.

- No preamble, no restating the task, no narration of what it is about to do.
- No file dumps. Cite `file_path:line_number` instead of pasting the code.
- No summary of work already described. If it changed three files, say which three
  and what changed, in one line each.
- Report failures plainly, with the error, rather than describing the attempt.

Put this instruction in the agent's prompt. The orchestrator relays what matters to
the user; a verbose sub-agent report is cost paid for context the user never sees.

## Analysis and Research Output (Pyramid Principle)

When performing analysis, evaluation, or research — whether directly or via agent teams — always structure output using the Pyramid Principle (Barbara Minto):

1. **Lead with the answer.** State the verdict/recommendation in 1-2 sentences at the very top.
2. **Follow with a compact recommendation list.** Actionable items, ordered by value, before any supporting detail.
3. **Then provide the detailed analysis.** Supporting evidence, trade-offs, and methodology come after the recommendations.

The reader should be able to stop reading after the first two sections and have the full picture. Details are there for those who want to dive deeper.

This applies to: architecture reviews, agent team reports, research notes, Obsidian project notes, and any written analysis saved to files.

## Feature Requests

Feature requests are tracked in `.worktrees/feature-requests/FEATURE_REQUESTS.md`, which is a git worktree checked out to the orphan `feature-requests` branch. This branch has no shared history with `main` and never merges.

- **File path:** `.worktrees/feature-requests/FEATURE_REQUESTS.md`
- **Read/edit:** Use the Read/Edit tools directly on the file at its worktree path
- **Commit changes:** Run git commands with `-C .worktrees/feature-requests` (e.g., `git -C .worktrees/feature-requests add -A && git -C .worktrees/feature-requests commit -m "Add request"`)
- **Push:** `git -C .worktrees/feature-requests push`
- **Quick view:** `script/feature-requests`

When the user asks to capture, add, view, list, or look up feature requests, always use this worktree. Never create feature request files on `main` or any feature branch.

## Pre-commit Requirements

Before every commit, run up to 3 review agents from `.claude/agents/` that best fit the change, in parallel, one Agent call each (never combine lenses into one agent). Each agent should only review files changed in the current commit. Pass this context when launching each agent.

- `testing-craftsperson.md` — Test coverage, `bundle exec rspec`, and `bundle exec standardrb lib/ spec/`; pick it for almost every code change
- `staff-engineer.md` — Architecture and complexity
- `ai-agent-operator.md` — Automation and scriptability (`--json`, exit codes, machine-read output)
- `power-user.md` — Edge cases and extensibility
- `new-user.md` — UX and discoverability (help text, errors, human output)
- `dependency-injection-expert.md` — Constructor injection and `build_cli`
- `ddd-hexagonal-expert.md` — Domain boundaries and adapters

All review agents that run must pass before committing. Address any concerns raised before proceeding.
