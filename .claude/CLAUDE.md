# Workspace CLI

A macOS CLI (Ruby) for managing tmuxinator-based development workspaces in iTerm2.

## Project Structure

- `bin/workspace` — Entry point (4 lines), calls `Workspace.build_cli.run(ARGV)`
- `lib/workspace.rb` — Module root, `build_cli` factory, error classes
- `lib/workspace/cli.rb` — CLI dispatch, OptionParser definitions, simple command methods
- `lib/workspace/config.rb` — Path constants and configuration
- `lib/workspace/config_schema.rb` — The one table of config keys: scope, settable, default, value parser, restart flag, doc text; readers, `config set/get/unset` and the docs take their key lists and checks from it
- `lib/workspace/config_schema_docs.rb` — Renders the schema into the generated blocks of `docs/README.config.md`; `script/generate-config-docs [--check]` runs it, and a spec fails on drift
- `lib/workspace/state.rb` — JSON-persisted session state
- `lib/workspace/git.rb` — Git and worktree operations
- `lib/workspace/which.rb` — Shared default PATH lookup for injectable `which:` collaborators
- `lib/workspace/doctor.rb` — Dependency checking
- `lib/workspace/tmux.rb` — Tmux session management
- `lib/workspace/project_config.rb` — Tmuxinator config generation
- `lib/workspace/project_catalog.rb` — Groups workspaces into projects (main checkout + worktrees) by the realpath of each checkout's git common dir, read from `.git` files; backs `projects`
- `lib/workspace/iterm.rb` — iTerm2 session/pane lifecycle (AppleScript)
- `lib/workspace/window_manager.rb` — iTerm2 window operations: find, focus, position, close
- `lib/workspace/window_layout.rb` — Window positioning math
- `lib/workspace/json_envelope.rb` — Builds the `--json` action and error documents (`ok`, `code`, `details`, `retry`); the CLI rescue funnel emits the errors, `CLI#run_action` the actions
- `lib/workspace/output_gate.rb` — The stdout every collaborator writes through; `--json` actions divert it to stderr so stdout holds one document
- `lib/workspace/error_codes.rb` — Registry of the stable error `code` values, mirrored in `docs/README.json.md`
- `lib/workspace/pane_locator.rb` — Strict pane resolver for `agent-run send`, `focus --pane` and `ask answer --deliver`: only a pane id or `window.pane`, and only a pane of the workspace's own tmux session
- `lib/workspace/commands/` — Complex command objects (launch, kill, focus, start, agent, ensure_agent, lock, dev, projects, capabilities, send, review, snapshot, daemon)
- `lib/workspace/work_coordinator_client.rb` — JSONL client for work-coordinator sockets
- `lib/workspace/pipeline_config.rb` — Reads per-project pipeline stage config from `~/.config/workspace/projects/<name>.yml`
- `lib/workspace/pipeline_state.rb` — In-flight work item tracking, disk-persisted to `~/.local/state/workspace/<name>/pipeline.json`
- `lib/workspace/sentinel_poller.rb` — Background poller watching tmux panes for `WORKSPACE_DONE:` sentinel
- `lib/workspace/session_monitor.rb` — Per-pane coding-agent and sub-agent state (working/idle/waiting), keyed on tmux pane id; fires alerts
- `lib/workspace/session_ledger.rb` — Flock-guarded append-only `ledger.jsonl` of SessionStart/SessionEnd (with pane slot), written by `session-event`
- `lib/workspace/alert_config.rb` — Reads a project's `alerts.notify` and `alerts.idle_after`
- `lib/workspace/notifier.rb` — Runs the notify command in the background with a timeout, details in `WORKSPACE_ALERT_*` env vars
- `lib/workspace/ask_store.rb` — Flock-guarded append-only store for `workspace ask` questions, one `asks.json` per workspace under its XDG state dir
- `lib/workspace/task_store.rb` — Flock-guarded one-file-per-task store under `~/.local/state/workspace/.tasks/`: `start` creates, `finish`/`kill` archive (newest 200 kept); the task id is `WORKSPACE_TASK` in panes
- `lib/workspace/pull_request_status.rb` — Read-only `gh pr view` for a checkout's branch (state, review decision, check counts); `gh` missing or failing is a fact, not an error
- `lib/workspace/transcript_summary.rb` — Reads the last main-thread assistant message from the tail of a Claude Code transcript
- `lib/workspace/process_tree.rb` — One-shot `ps` snapshot with parent/child lookups
- `lib/workspace/workspace_lineage.rb` — Resolves a workspace's parent project (marker, then git common dir); shared by locks, `dev`, `config set`, and `parent`
- `lib/workspace/lock_namespace.rb` — Resolves the shared lock namespace (git common dir) from a cwd
- `lib/workspace/lock_holder.rb` — Identifies the calling agent's pid/start time and checks holder/waiter liveness
- `lib/workspace/lock_store.rb` — Flock-guarded JSON lock store (acquire/release/status/clear), reaped on every op
- `lib/workspace/lock_config.rb` — Reads a project's `locks.idle_grace` (falls back to 5m with a warning)
- `lib/workspace/lock_idle_tracker.rb` — Marks an agent's lock idle/active from `session-event` hooks, for idle takeover
- `lib/workspace/agent_provider.rb` — Registry of coding-agent CLIs workspace can monitor
- `lib/workspace/agent_readiness.rb` — Waits for a coding agent's pane to be quiet and (if the provider declares one) match its ready pattern before `launch --prompt`/`start --prompt` send text
- `lib/workspace/hook_installer.rb` — Merges workspace's hooks into an agent's own settings file
- `lib/workspace/file_backup.rb` — Copies a file aside before workspace edits it
- `lib/workspace/dev_runner.rb` — The `dev __run` wrapper: holds the `devenv` lock while the dev command runs on the pane's TTY, forwarding stop signals once to its process group
- `lib/workspace/process_group_terminator.rb` — SIGTERM then SIGKILL for a lock holder's process group, after checking pid + start time
- `lib/workspace/process_holder_stopper.rb` — Stops a `kind: "process"` lock holder for `lock clear`/`dev down`, or keeps the lock naming it when the group can't be stopped
- `lib/workspace/dev_config.rb` — Reads a project's `dev:` block (`up`, `ready`, `stop_timeout`), as written by `workspace config set`
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

## Subcommands

init, doctor, launch, start, add, stop, kill, finish, relaunch, focus, list, status, whereis, agent, daemon, pipeline, sessions, review, snapshot, session-event, lock, dev, parent, projects, ask, capabilities

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
