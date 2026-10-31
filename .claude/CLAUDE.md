# Workspace CLI

A macOS CLI (Ruby) for managing tmuxinator-based development workspaces in iTerm2.

## Project Structure

- `bin/workspace` — Entry point (4 lines), calls `Workspace.build_cli.run(ARGV)`
- `lib/workspace.rb` — Module root, `build_cli` factory, error classes
- `lib/workspace/cli.rb` — CLI dispatch, OptionParser definitions, simple command methods
- `lib/workspace/config.rb` — Path constants and configuration
- `lib/workspace/commands/notes.rb` — `notes dir`: the one answer to where a workspace's notes are, through `NotesDir`; `--create` makes the directory and lists it in `info/exclude`; `workspace ui open notes [WS] [--path REL]` sends the person to the Notes view, or one note, through `Commands::Ui` (`workspace-ui://notes/<ws>[/<rel>]`; `--path` is checked by `NotePath.resolve`, refused as `invalid_note_path`)
- `lib/workspace/commands/promote.rb` — `promote [BRANCH] [--name WS] [--dry-run] [--json]`: moves a main checkout's changes and branch commits into a new `.worktrees/<branch>` through `CheckoutMove`, makes it a workspace through `start` (no launch, plan or spine), carries notes through `NotesCarry`, then makes the spine and plan asked for and not carried; refuses `agent_working` (the caller's `$TMUX_PANE` aside); writes `workspace_promoted`; docs in `docs/README.promote.md`
- `lib/workspace/checkout_move.rb` — The git half of `promote`: checks (`plan`, read-only), one tagged stash pinned to `refs/workspace/promote/<id>`, switch, `worktree add`, `stash apply --index` checked against trees recorded before; a failure is undone in reverse (`move_failed`) or kept under the ref (`move_incomplete`)
- `lib/workspace/notes_carry.rb` — Moves `IMPLEMENTATION_PLAN.md` and `spine/` (the old ones renamed `.moved-<time>`) and copies each `--carry-note` into the new notes directory, never over a file; problems are warnings
- `lib/library/play/promote.md` — The `promote` pack: tell the person what moves, run promote, seed the spine and plan, write `HANDOFF.md`, start the agent, stop
- `lib/workspace/config_schema.rb` — The one table of config keys: scope, settable, default, value parser, restart flag, doc text; readers, `config set/get/unset` and the docs take their key lists and checks from it
- `lib/workspace/notes_dir.rb` — The one resolver for where a workspace's notes go: its own `notes.dir`, else the directory the project's `notes.default_dir` rule computes, else (a linked worktree) the main checkout workspace's effective notes dir plus the sanitized branch (`tmp/workspace-notes` in the checkout when unset); `config show --json` reports it as `effective_path`
- `lib/workspace/config_schema_docs.rb` — Renders the schema into the generated blocks of `docs/README.config.md`; `script/generate-config-docs [--check]` runs it, and a spec fails on drift
- `lib/workspace/state.rb` — JSON-persisted session state
- `lib/workspace/git.rb` — Git and worktree operations
- `lib/workspace/name_migration.rb` — Renames a mixed-case workspace (and its worktree workspaces) to lowercase before its agentd starts, under the startup lock: tmux session, configs, run files, state dir, inbox files, state key, marker, tmuxinator config last (held back while any step failed); a failed step is a warning in the daemon log; writes `workspace_renamed`. `EnsureAgent` calls `#call` under its startup lock (keyed on the lowercase name); `launch` and a foreground `agentd` call `#call_locked`
- `lib/workspace/which.rb` — Shared default PATH lookup for injectable `which:` collaborators
- `lib/workspace/doctor.rb` — Dependency checking; warns on a paused plan whose owner pane is working and on a `[~]` task in a workspace with no session; checks the configured command's program on PATH; reports each tmuxinator config whose agent pane runs another command than `agent.commands.<kind>` (`agent-pane-command`), and `--fix` rewrites that pane through `ProjectConfig#rewrite_agent_pane` after a `FileBackup`; checks the skill links (`skills-<harness>` rows) through `Commands::Skills#health`, and `--fix` repairs them through `#repair`
- `lib/workspace/tmux.rb` — Tmux session management
- `lib/workspace/project_config.rb` — Tmuxinator config generation
- `lib/workspace/project_catalog.rb` — Groups workspaces into projects (main checkout + worktrees) by the realpath of each checkout's git common dir, read from `.git` files; backs `projects`
- `lib/workspace/project_groups.rb` — Groups of repositories (`group:<slug>` ids), one hand-editable file each at `~/.config/workspace/groups/<slug>.yml`; members keyed by the realpath of the git common dir, at most one group per repository, a gone repository reads `exists: false`; writes under one flock through a temp file and rename; `#group_for_project` is the lookup by project id. `Commands::Groups` is `projects group create|add|list`; `projects stop`/`kill` refuse a `group:` id. `ProjectCatalog` knows nothing of groups
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
- `lib/workspace/recipe_file.rb` — Parses and checks a `recipe` library entry (YAML: `plays`, `packs`, `agents`, `skills`, `agent_kind`, `prompt`, `description`), listing every problem under `invalid_recipe`; `Library#recipe` reads one, `start --recipe` fills in the flags not given, and `library add`/`update` refuse a bad one
- `lib/workspace/library_installer.rb` — Copies a library agent or skill into a checkout's install directory (`.claude/agents/` and `.claude/skills/` unless configured), never over a tracked path, and lists it in the common dir's `info/exclude`; `#install_user` copies to the user-level directory (no git)
- `lib/workspace/library_install_dirs.rb` — The one reader of the `library.install.{skills,agents,user_skills,user_agents}_dir` keys (project over global over default), read when a command runs; `LibraryInstaller` and `Commands::Library` get their directories only from it
- `lib/workspace/instruction_composer.rb` — Builds an agent's instructions from library packs under a heading per pack, and a workflow step's four layers (default packs, workflow, step, attempt); adds the pane's binding after `binding` and the project's `commands.test`/`commands.lint` after `commits`; `#start_packs`/`#compose_start` list and compose what `start` and `launch` send with the first prompt (the automatic `notes` pack, the `dev` pack when the project sets `dev.up`, then `--pack` names; `compose(skip:)` leaves a pack out of a workflow step)
- `lib/workspace/notes_config.rb` — Reads a project's `notes.instructions` (false turns the automatic `notes` pack off for `start` and `launch`)
- `lib/workspace/main_agent.rb` — Which coding agent a project's main agent pane runs (`claude`, `codex`, ..., or `none`), read from the panes of its tmuxinator config; `InstructionComposer` uses it to send the `handoff` pack to Claude Code and Codex only
- `lib/workspace/agent_commands.rb` — Reads `agent.kind` and `agent.commands.<kind>` through `ConfigResolver` (global, project, worktree): the effective agent kind, the command for a kind (default the provider's executable) `#executable_for` (the program that must be on PATH; the global layer alone for a nil workspace), `#names_for`, the program names that count as that agent, and `#aliases_for`/`#detector`; a bad stored value falls back to the default
- `lib/workspace/agent_executables.rb` — Read-only scan of `PATH` for each agent family's launchers (`<exe>` or `<exe>-suffix`, matched whole, never a bare prefix), with `shadowed` paths, configured commands not on PATH, and the `effective` program per kind; capped at 200 rows
- `lib/workspace/commands/agent_executables.rb` — `agent executables [--kind KIND] [--name WS] [--json]`: resolves the workspace, checks the kind (`unknown_agent_kind`), prints text or the `--json` document
- `lib/workspace/agent_command_check.rb` — What `config set agent.commands.<kind>` checks: an absolute path must exist and be an executable file (`agent_command_not_executable`); a bare name not on PATH or off-family is a warning
- `lib/workspace/agent_detector.rb` — `AgentDetector`, one workspace's way to find the coding agent in a pane: `AgentProvider.detect` plus the configured program names as aliases; `AgentCommands#detector` builds it for the session monitor, readiness checks, pane label searches and `restore`
- `lib/workspace/commands_config.rb` — Reads a project's `commands.test` and `commands.lint`
- `lib/library/play/` — The built-in instruction packs (`binding`, `orchestrator`, `commits`, `review`, `notes`, `handoff`, `dev`, `implementation-plan`, `research`, `report`, `plan-review`, `spine`, `promote`), read through `Library#builtin_store`; the `research` pack ends by adding a `note` inbox item (`inbox add --note`) and printing the note link from `ui open notes --path`; the `plan-review` pack reviews the plan, writes `plan-review.md` and posts an inbox item under `plan-review:WS:blocking` or `plan-review:WS:passed`
- `lib/workspace/commands/skills.rb` — `skills install [--install-all] [--dry-run] [--json]` (`confirmation_required` under `--no-input` when it would ask) and `skills uninstall [--dry-run] [--json]` (docs in `docs/README.skills.md`): links the four `lib/skills/<name>` directories into each chosen harness's skills directory (and `~/.agents/skills` when it exists, never created); one question through `Prompt.ask` for the harnesses found and not yet linked or declined (the ones left out are recorded as declined; end of input installs nothing and records nothing; `--install-all` asks nothing and clears declines); exit 1 when anything is refused or failed; codes `skill_path_exists`, `skill_link_foreign`, `skill_link_failed`, `skill_source_worktree`, `skills_source_missing`, `no_harness_found`. `#health` and `#repair` serve `doctor`: one `skills-<harness>` row per harness found and not declined (`ok`, `missing`, `dangling`, `conflict`), and `--fix` links the missing or dangling ones without replacing anything
- `lib/workspace/skill_harnesses.rb` — The four harnesses (Claude Code, Codex, Pi, OpenCode) with their skills directories (`CODEX_HOME` honoured); found by program on PATH or config directory; `~/.agents/skills` only when it exists
- `lib/workspace/skill_source.rb` — Where the links point: the Homebrew `opt` path, else the checkout's realpath; a linked worktree is refused (`skill_source_worktree`, read from `.git` and `commondir` alone, so no HOME, PATH or git call)
- `lib/workspace/skill_links.rb` — Inspects, plans and writes the four links of one skills directory: all four or none, a temp link renamed into place, an identical real directory moved to `skill-backups`, anything else refused with its `mv`; `#ours?` and `#removal_steps` serve `uninstall`
- `lib/workspace/skills_state.rb` — `skills.json` (`{"declined": []}`), flock-guarded, temp file and rename; a corrupt file reads as empty
- `lib/skills/` — The four shipped skills (`workspace`, `workspace-agent-run`, `workspace-inbox`, `workspace-lifecycle`; each a directory with `SKILL.md`), what `skills install` links; `libexec.install "lib"` in the Homebrew formula ships them
- `script/check-skills` — Checks the skill files in `lib/skills` against the real CLI: each command, subcommand and `--flag` against `--help` (run in an empty temp HOME) and each error code against `error_codes.rb`; exit 1 on a mismatch
- `lib/workspace/commands/` — Complex command objects (launch, kill, focus, start, agent, ensure_agent, lock, dev, notes, plan, pull_request, rebase, push, projects, capabilities, send, review, restore, snapshot, daemon, ui, binding, library, instructions, workflow, skills)
- `lib/workspace/notes_dir.rb` — The one resolver for a workspace's notes directory: its own `notes.dir`, else the project's `notes.default_dir` rule, else `tmp/workspace-notes` in the checkout; `Commands::Notes#info` returns the answer as a Hash (`dir` prints it) and `#files_inside_worktree` counts the files `kill` and `finish` would delete
- `lib/workspace/notes_setup.rb` — Fixes a new worktree's notes directory for `start` and `add`: writes the computed path as the worktree's own `notes.dir` (never over an existing value), makes the directory and its `info/exclude` line; every problem comes back as a warning, never an error
- `lib/workspace/spine_file.rb` — One spine file (a stage file or `goal.md`) read without following links, never failing: `PlanFile`'s frontmatter dialect plus `[a, b]` and indented `- a` lists, status aliases to the six canonical values, the `## Done when` checklist, `revision` (short SHA-256 of all bytes), `key_span`/`frontmatter_lines` for `spine set`, `check` (the opt-in and verdict that `spine verify` writes), warnings with codes
- `lib/workspace/spine_tree.rb` — Walks `spine/` in the notes dir (`<number>-<id>.md` stages, a folder named like a stage file for sub-stages, to 3 levels; the 64/24/96 limits); `Stage` holds the file, children, `rollup` and the dependency checks; `#find(path)`, `#to_h` is the `spine show --json` document
- `lib/workspace/spine_rollup.rb` — The one roll-up of a stage's children (`model.ts` `rollUp`) over each child's effective state (a folder-only child takes its own roll-up): `status` (all skipped is `skipped`), `done`, `total`, `counts` with `disputed`; `SpineTree::Stage#rollup` calls it
- `lib/workspace/commands/spine.rb` — `spine show [WS] [--name WS] [--json]`: the notes dir through `Commands::Notes#info`, then `SpineTree`; read-only, a bad file is a warning, never an error; `#stage!` and `#write_one` (one write under the spine lock, after a caller check) serve `spine start`
- `lib/workspace/spine_inferred.rb` — Port of the app's `inferred.ts`: with no `spine/`, `spine show --evaluate` lists Research to Ship (Ship for a linked worktree) under `inferred`, from the plan, the workspace's runs still going (a run with a research/plan/implement/verify step outranks the plan), the review agent and the pull request; `.stages` is the pure rules, `#infer` adds the run files and the checkout layout to `SpineFacts`' one read
- `lib/workspace/commands/spine_start.rb` — `spine start [WS] PATH [--pane P \| --spawn KIND] [--play REF] [--if-revision REV]`: refuses from the file (`stage_done`, `stage_waiting` by file statuses, `stale_revision`) and the panes (`stage_owned`, `pane_busy`) through `PaneDispatch`, then writes `in_progress` and the owner under the spine lock, types the brief (play, `spine` pack, stage path and file), binds the pane; only a failed delivery leaves the file written, with a reset hint
- `lib/workspace/plan_file.rb` — The parser for a workspace's `IMPLEMENTATION_PLAN.md` (`PlanFile.parse(text)`, `PlanFile.read(path)`; nil when the file is missing): frontmatter, the `- [S] ID Title` tasks under `## Tasks`, `counts`, `percent`, `current`, `warnings`; it never fails. `PlanFile.set_status`, `.set_owner_pane` and `.set_task` are the only writers of the file: one frontmatter line, or one task line's box and `<!-- owner: %N -->` comment, through a temp file and rename, with one re-read and retry
- `lib/workspace/plan_state.rb` — `PlanState#derive` picks the one plan `state` (`empty`, `done`, `paused`, `stopped`, `waiting`, `working`, `blocked`, `stalled`, `idle`) from the parsed plan and the facts; `#row` builds the row `plan status --json` and, minus `tasks`, each member's `plan` in `snapshot` (from the snapshot's own reads)
- `lib/workspace/plan_config.rb` — Reads a project's `plan.stall_seconds`
- `lib/workspace/start_ref.rb` — What `start` and `ticket show` make of a ref (JIRA key or URL, pull request, issue, branch): its `kind`, `key` and `branch`, and `#project` for the project a worktree would join (the parent repo from inside a linked worktree)
- `lib/workspace/ticket_source.rb` — Reads a ticket's title (one line), body (64 KB cap) and URL, and a pull request's `cross_repository` (nil unless a boolean), with `gh` (pull request, issue) or `jira` (`jira issue view KEY --raw`) within 10s; a missing tool, a timeout or a failure is `ticket_source_unavailable`, an unknown ticket `ticket_not_found`; a branch runs nothing
- `lib/workspace/commands/workflow_start.rb` — `workflow start ID [REF | --prompt]`: reads the ref and ticket, seeds inputs and preflights (the tree of a reused or adopted checkout too, and the planned path of a new worktree for `unsafe_checkout_path`) before `start` makes anything; refuses `fork_pull_request` first (`details.reason`): a pull request unless `cross_repository` is exactly false and its base is origin's or upstream's repository (an unreadable one always refused), a reused, adopted or local branch whose git config tracks another repository, or a `pr-N` branch holding another pull request (its `branch.pr-N.workspace-pr`, else a `#N` read); a bare `#N` is checked out as the `owner/repo#N` that `gh pr view` read
- `lib/workspace/ssh_host_resolver.rb` — `ssh -G NAME` (5s, plain hostname tokens only, never a shell) for the real host behind an ssh remote's host alias; `WorkflowStart` compares remotes through it and `Git#remote_effective_url` (insteadOf applied, no network)
- `lib/workspace/commands/ticket.rb` — `ticket show REF [--name WS] [--json]`: the lookup, plus the workspace that already exists for the ref's branch; writes nothing
- `lib/workspace/timed_process.rb` — Runs one command with a time limit and no prompt (`GH_PROMPT_DISABLED`, `GIT_TERMINAL_PROMPT`), in its own process group that is stopped on timeout; `TicketSource.run`, `PullRequestStatus` and `Commands::PullRequest` run `gh` and `git` through it
- `lib/workspace/commands/pull_request.rb` — `pr create [--name WS] [--draft] [--json]`: the branch's existing pull request, else a push (no upstream) and `gh pr create --fill`; refuses `nothing_to_push` and `gh_unavailable`. `#find_or_create` is the look-up-or-create step alone, which `Commands::Finish` calls for `--pr`
- `lib/workspace/workspace_checkout.rb` — The workspace, checkout path and branch a command works on (`--name`, else the workspace of the working directory; refuses a detached HEAD); `rebase` and `push` use it
- `lib/workspace/commands/rebase.rb` — `rebase --onto local|update|remote [--name WS] [--json]`: refuses dirty tracked files (`dirty_worktree`) and a stopped rebase (`rebase_in_progress`), never stashes the workspace's own changes, aborts its own conflicted rebase; `update` moves the local default branch up to origin's first (stashing and restoring a dirty checkout of it); outcomes `rebased`, `up_to_date`, `conflict`, `default_not_updated`
- `lib/workspace/commands/pr_feedback.rb` — `pr feedback [--name WS] [--all] [--json]`: `WorkspaceCheckout`, then `PullRequestFeedback`; leaves out resolved threads (unless `--all`) and threads whose comments were all minimized, cuts bodies at 4,000 characters, maps `totals` to `counts`; text output escapes control, bidi and zero-width characters; read-only
- `lib/workspace/commands/push.rb` — `push [--name WS] [--json]`: `-u` with no upstream, a plain push when only the branch has new commits, `--force-with-lease=refs/heads/<dest>:<sha>` on the compared upstream commit only when the branch's reflog shows it once held every upstream-only commit, else `push_rejected`; a `pr-N` branch tracking `origin/<head>` goes to `<head>` only after `PullRequestStatus#head` confirms the pull request is open, same-repo, headed at that branch of origin (fetch and push URLs) and at the fetched sha, else `push_rejected` with `details.pr_check` (`gh_missing`, `not_logged_in`, `gh_failed` not permanent; a gh timeout has `timed_out` and a retry); `Git#push` (`dest:`, `lease:`, source always `refs/heads/<branch>`) is the one push, which `PullRequest` uses too (`Git` takes a `runner:` for its time-limited calls)
- `lib/workspace/commands/plan.rb` — `plan status|path|show|init|pause|delete`; `#rows(names:, all:)` returns the rows, gathering the session, the owner pane's state and the open questions; `#start` is given a `launch:` callable by the CLI (launching is `CLI#launch_projects`) and otherwise types into the main agent pane and binds it to the play; `#start_task` sends one task to a named pane, a pane it splits and starts an agent in (`--spawn`: `MainAgent#spawn_command` picks the command, through `Commands::Run` and `AgentReadiness#wait(only_pane:)`), its owner or the main pane, then writes the owner onto the task line; `#pause(interrupt: true)` presses `AgentProvider#interrupt_keys` in the working owner panes; every change records `plan_changed`
- `lib/workspace/commands/plan_dispatch.rb` — `plan start [--task]` (launch, or type into a pane, bind it, write the owner onto the task line) and `#interrupt_owners` for `pause --interrupt`; `build_cli` wires it to `Commands::Plan` and the CLI
- `lib/workspace/pane_dispatch.rb` — The pane steps `plan start` and `spine start` share: the daemon's panes (`no_daemon`), the main agent pane, the `pane_busy` and `no_agent_pane` refusals, `#spawn` (split, start the agent, wait for that pane), typing, and `#bind_play` (keeps a run or review binding, adds packs to a play binding)
- `lib/workspace/plan_access.rb` — What the plan command objects share: the plan file's path, `no_plan`/`plan_done`, the `status:` write and `plan_changed`
- `lib/workspace/work_coordinator_client.rb` — JSONL client for work-coordinator sockets
- `lib/workspace/pipeline_config.rb` — (`pipeline` is deprecated in favor of `workflow`) Reads per-project pipeline stage config from `~/.config/workspace/projects/<name>.yml`
- `lib/workspace/pipeline_state.rb` — In-flight work item tracking, disk-persisted to `~/.local/state/workspace/<name>/pipeline.json`
- `lib/workspace/sentinel_poller.rb` — Background poller watching tmux panes for `WORKSPACE_DONE:` sentinel
- `lib/workspace/spine_watcher.rb` — agentd's watch of a workspace's `spine/` (stat polling, settle, baseline like `PlanProgressWatcher`): logs `spine_changed` for status/note changes and `added`/`removed` stage files made any way; skips a change whose revision is the newest `spine set` line for that path in the event log (`EventLog#recent`)
- `lib/workspace/agent_recovery_desk.rb` — The daemon's recovery of a Claude Code agent whose turn ended on an API error (`turn_failed`): queues hook events for one worker, confirms the failure against the transcript after 30s, `#check` answers `:go`/`:defer`/`:clear`/`:never`; the first attempt of an outage types a message at the live prompt, the later ones stop the agent with one SIGINT, type the resume command and a message; gives up with one inbox item (`attempts_exhausted`, `not_retryable`, `cannot_restart`, `fresh_conversation`, `deferred`, `unconfirmed`); writes `agent_recovery_attempt` and `agent_recovery_gave_up`; docs in `docs/README.agentd.md`
- `lib/workspace/agent_recovery_store.rb` — Flock-guarded `agent-recovery.json` per workspace: one entry per pane (phase, attempts, error, session, agent pid), the 12-attempt schedule (`MAX_ATTEMPTS`, waits 60s doubling to 900s), temp file and rename; `#update` always yields the entry
- `lib/workspace/agent_recovery_config.rb` — Reads `agent.recovery.enabled` (global, project, worktree; default true) for the daemon, once at its start; a bad stored value falls back to the default with a warning
- `lib/workspace/agent_stopper.rb` — Finds the Claude Code process in a pane and sends it SIGINT, nothing else (any other signal starts a new conversation in a `claude ... || claude` pane); checks pid and start time, refuses an agent whose process group doesn't hold the terminal (`#foreground?`), and says whether the pane is clear (`#pane_clear?`)
- `lib/workspace/agent_resume_command.rb` — The one builder of the shell line that resumes a Claude Code session (the pane's configured command, `--resume ID`, the carried flags), shared by `restore` and the recovery desk; a value that isn't a session id never reaches a command line
- `lib/workspace/recovery_stop_marker.rb` — A file per session id saying the daemon is about to stop that agent for a recovery, so the SessionEnd it causes doesn't stop the dev server (`DevSessionRelease` checks it); expires after 5 minutes
- `lib/workspace/session_monitor.rb` — Per-pane coding-agent and sub-agent state (working/idle/waiting), keyed on tmux pane id; fires alerts
- `lib/workspace/agent_status_desk.rb` — The daemon's side of `agent status request|post`: `TypingSafety` (`typing_safety.rb`) decides whether a pane can take typed text, `AgentStatusRequests` (`agent_status_requests.rb`) holds one expiring request per pane tied to its pid, and each post is an `agent_status` line in the `HookEventLog`; `Commands::AgentStatus` is the CLI side
- `lib/workspace/prompt_typer.rb` — The one careful typing sequence (check, paste without Enter, check the input line holds the text or Claude Code's paste placeholder, Enter), run under the daemon's delivery lock; `AgentStatusDesk` and `PromptQueueDesk` type through it
- `lib/workspace/prompt_queue_store.rb` — Flock-guarded `prompt-queue.json` per workspace (beside `asks.json`): the prompts `agent-run send --when-idle` queued, at most 8 per pane; `claim` (reaps abandoned `delivering` entries), `proceed` and `start_paste` (honor `cancel_requested`), `rebind_session` (after a queued clear), `finish` (`delivered` sets the pane's durable `last_delivered_at`), `cancel`; `SessionMonitor#fresh_since` is the readiness `claim` compares with it
- `lib/workspace/prompt_queue_desk.rb` — The daemon's side of `agent-run send --when-idle` and `--clear-first` (`prompt_send`): refuses `not_an_agent`, `clear_unsupported` (not Claude Code in hook mode), `unsupported_agent` (no `ready_pattern`), `pane_waiting`, `queue_full`; `#deliver_next` is the one routine that types queued text (claim, 2s quiet, re-check under the delivery lock, `start_paste`, `PromptTyper`, finish), started by the send, a main-agent Stop (`#session_event`) and the monitor's scan (`SessionMonitor#on_scan`); a `clear_first` entry claims the pane in agentd's `@restarts`, types the clear and waits 15s for a SessionStart with source `clear` (else `clear_unconfirmed`); `when_idle: false` withdraws an entry that would wait (`pane_busy`); drop rules and `prompt_queued`/`prompt_dequeued` events
- `lib/workspace/clear_confirmation.rb` — `ClearConfirmation.check(facts, cleared_at)`: `[:confirmed, started]`, `[:voided, nil]` or `[:pending, nil]` for a typed `/clear`, from a SessionStart with source `clear` and the prompt times in `SessionMonitor#delivery_facts`; shared by `PromptQueueDesk#wait_for_clear` and `AgentRestart#session_cleared?`
- `lib/workspace/commands/prompt_queue.rb` — `agent-run queue list [--name WS] [--pane P] [--json]` and `queue cancel --id ID [--name WS] [--json]`: read and write `prompt-queue.json` through `PromptQueueStore` with no daemon; list rows (`pane_id`, `position`, `state`, 200-character `preview`, `length`) grouped by pane; cancel answers the full text, uses `cancel_requested` for a claimed entry not yet pasted, refuses `unknown_id` (`details.state: delivering` once pasting), searches every workspace's queue without `--name`, writes `prompt_dequeued` outcome `cancelled`
- `lib/workspace/context_reader.rb` — A pane's context use: the status-line reading, a `context.pattern` scrape, or, when given the pane's agent kind, a scrape by `context.patterns` or the provider's own pattern (Codex)
- `lib/workspace/session_ledger.rb` — Flock-guarded append-only `ledger.jsonl` of SessionStart/SessionEnd (with pane slot, tmux server pid and window layout), written by `session-event`; `#slots_for` streams it into the latest session per pane slot for `restore`; `#open_session_for` names the session open in a pane, which `dev up` records as `started_by`
- `lib/workspace/alert_config.rb` — Reads a project's `alerts.notify` and `alerts.idle_after`
- `lib/workspace/notifier.rb` — Runs the notify command in the background with a timeout, details in `WORKSPACE_ALERT_*` env vars
- `lib/workspace/inbox_store.rb` — Flock-guarded JSON file of one inbox scope (workspace, project or global) under `~/.local/state/workspace/.inbox/`; `add`, `upsert` (by `dedupe_key`), `list`, `find`, `update`, `transition`/`transition_by_key`; a passed snooze or expiry reads as `open`/`dismissed` without writing
- `lib/workspace/commands/inbox.rb` — `inbox add|list|show|edit`: `add --link-run` stamps `links.step`/`links.attempt` from the run (`WorkflowRunStore#find`, null with a stderr line when the run isn't going in the item's workspace); `list --include-derived` marks each derived gate row `covered_by`; `add --note REL` (or `--from-json` `note`) points an item at a note in the workspace's notes dir, checked by `NotePath`; scope resolution (`--name`, `--project`, `--global`, else the cwd's workspace), input checks that refuse control characters and over-long or non-https text (`invalid_inbox_item`), and output with control characters escaped; stores come from an injected `store_factory`
- `lib/workspace/inbox_derived.rb` — The rows `inbox list --include-derived` works out and never stores: open asks, waiting panes (daemons read in parallel, each bounded), blocked or stalled plans, workflow gates and stuck locks, by workspace-ui's queue rules; a source that fails is a warning and no rows
- `lib/workspace/inbox_acks.rb` — `.inbox/acks.json`: the derived rows acked or snoozed (`{id, fingerprint, acked_at[, until]}`), written like a scope file; `#filter` leaves out a row whose id and fingerprint match a live entry, writes drop old acks (30 days) and passed snoozes; `Commands::Inbox#ack`/`#snooze` read the current derived rows for the fingerprint
- `lib/workspace/ask_store.rb` — Flock-guarded append-only store for `workspace ask` questions, one `asks.json` per workspace under its XDG state dir
- `lib/workspace/task_store.rb` — Flock-guarded one-file-per-task store under `~/.local/state/workspace/.tasks/`: `start` creates, `finish`/`kill` archive (newest 200 kept); the task id is `WORKSPACE_TASK` in panes
- `lib/workspace/pull_request_feedback.rb` — Read-only reader of a checkout's pull request feedback through two `gh` calls (`gh pr view`, one GraphQL query; capped sizes, each reported in `truncated`); backs `pr feedback`
- `lib/workspace/pull_request_status.rb` — Read-only `gh pr view` for a checkout's branch (state, review decision, check counts); `#head(path, number:, repo:)` reads a numbered pull request's head (state, fork flag, branch, sha, repository) for `push`; `.github_repo` parses an origin URL with `PullRequestFeedback`'s strict patterns; `gh` missing or failing is a fact, not an error
- `lib/workspace/transcript_summary.rb` — Reads the last main-thread assistant message from the tail of a Claude Code transcript
- `lib/workspace/process_tree.rb` — One-shot `ps` snapshot with parent/child lookups
- `lib/workspace/workspace_lineage.rb` — Resolves a workspace's parent project (marker, then git common dir); shared by locks, `dev`, `config set`, and `parent`
- `lib/workspace/lock_namespace.rb` — Resolves the shared lock namespace (git common dir) from a cwd
- `lib/workspace/lock_holder.rb` — Identifies the calling agent's pid/start time and checks holder/waiter liveness; `#run_alive?` asks `RunLiveness` about a run holder
- `lib/workspace/lock_store.rb` — Flock-guarded JSON lock store (acquire/release/status/clear), reaped on every op; `#acquire_run`/`#release_run` hold locks for a workflow run (`kind: "run"`, keyed on the run id, exempt from `release_all`, taken in sorted order), and `#delegate`/`#end_delegate`/`#keep_delegate` record the dev wrapper working under a run's hold; `LockStore.run?` is the one check for a run record
- `lib/workspace/run_liveness.rb` — A run is alive while `~/.local/state/workspace/.workflows/runs/<id>.json` exists and its `state` is not `completed`, `failed` or `cancelled`
- `lib/workspace/run_resources.rb` — Holds a workflow step's `uses:` for the run: resolves the names (`dev-env` is `devenv`, `edit` is refused), acquires through `LockStore#acquire_run` without blocking, releases; `WorkflowEngine` is its caller
- `lib/workspace/workflow_definition.rb` — One workflow definition (YAML): checks every key, an input's `pattern:` (whole-value regexp, compiled and at most 300 characters; `WorkflowEngine#check_input_patterns` (called by `check_inputs`) refuses a set value that misses it as `invalid_input`), collects every problem (`invalid_workflow`), fills defaults (a step's `guard:` is `unchanged` or `config`); `#to_h` is the copy a run keeps; `.render` fills `{{placeholders}}`
- `lib/workspace/workflow_catalog.rb` — Finds a definition by id: `~/.config/workspace/workflows/`, then the presets in `lib/workflows/` (`rpiv`, `rpiv-auto-approve`, `pr-feedback`, `investigate`)
- `lib/workspace/workflow_run_store.rb` — Run files under `~/.local/state/workspace/.workflows/`: `runs/<id>.json` and `<id>.events.jsonl` while a run is going (what `RunLiveness` reads), `archive/` once finished; `#update` is the one way a run changes, under the run's own flock
- `lib/workspace/workflow_engine.rb` — Every transition of a run: `start` (records `base_sha` and `base_guard` through `WorkflowGuard`), `preflight(tree:)` (`dirty_worktree` for a `guard: unchanged` definition on an unclean checkout), the guard run in `evaluate` before `produces`, `details.code`/`code_source` on every `failed_check`, a rejected gate kept for its first rerun, `turn_ended` (derived done: files exist, check passes), `report`, `approve`, `reject`, `resume`, `cancel`, `tick`, `workspace_killed`; stores the reasons `waiting_lock`, `waiting_you`, `turn_ended_incomplete`, `failed_check`; emits `workflow_changed` and the run's lock events
- `lib/workspace/workflow_panes.rb` — The run's pane: default Claude pane from the daemon, binding through `Commands::Binding`, and the one typed line (`restart_agent` for a fresh conversation, `Tmux#deliver` to continue)
- `lib/workspace/workflow_gate_note.rb` — The one resolver for a gate's note: the gated step's first `produces` file names it on its first line (`note: <file>`), a plain file name in the workspace's notes directory (through `NotePath`), a regular file and not a link; answers `name`, `path` and the `sha256` of the bytes read now, nil with no `note:` line, `gate_note_unreadable` when the named file can't be read; `workflow approve` (which records the hash) and `workflow status` (`gate_file`) both call it
- `lib/workspace/shell_safe_path.rb` — `ShellSafePath.unsafe_characters`: the characters (quotes, backtick, dollar, backslash, control and invisible) a path can't hold inside the steps' shell commands; shared by `WorkflowEngine`'s checkout-path check (`unsafe_checkout_path`) and `WorkflowGateNote`
- `lib/workspace/workflow_guard.rb` — The engine's check that a `guard:` step left the checkout alone: `#base` (HEAD and a snapshot of the repository config, hooks directory and hidden-file flags, stored in the run as `base_sha`/`base_guard`) and `#check(worktree, run, scope)`, the first of `no_commit`, `head_moved`, `operation_in_progress`, `config_changed`, `hooks_changed`, `hidden_changed`, `tracked_changed` (scope `config` checks the config, hooks and hidden flags only); every git call ignores the global and system config, drops `GIT_*`, and runs with fsmonitor and hooks off; never raises
- `lib/workspace/workflow_check.rb` — Runs a step's `status:` command in the checkout with a time limit, output to a log; `env:` adds `WORKSPACE_RUN_ID`, `WORKSPACE_RUN_ARTIFACTS` and `WORKSPACE_RUN_BASE_SHA`
- `lib/workspace/workflow_status.rb` — What `workflow status` shows: the stored run plus what is read at the time (`pane_gone`, a permission prompt or open ask as `waiting_you`, the `timed_out` flag), `base_sha`, and each reason's `actions` (only `cancel` for a guard code a resume can't get past)
- `lib/workspace/workflow_nudger.rb` — The daemon's part: starts `workspace workflow advance` as its own process when a turn ends in a bound pane, and on a timer for runs waiting on a lock
- `lib/workspace/workflow_config.rb` — Reads the global `workflows.defaults.include` (the default packs)
- `lib/workspace/git_exclude.rb` — Lists a path in a repository's `info/exclude` (`#add`) or reads whether it is listed (`#listed?`); keeps `.workflow/` and the notes directory out of `git status`
- `lib/workflows/` — The workflow presets that ship (`rpiv.yml`; `rpiv-auto-approve.yml`: `rpiv` with a `plan_review` step, three reviewer sub-agents of whom the skeptic and one other must approve, in place of the plan gate; `pr-feedback.yml`: a gated `triage` that writes a note and posts a `review_request`, then `fix`, which commits the approved fixes and drafts `## Replies` in the note, never posting or pushing; `investigate.yml`: `reproduce` and `diagnose` (gate `approve`, `guard: unchanged`) write `repro.md` and a note, then `fix` (`guard: config`, `test-db`) commits a regression test and the approved fix with hooks off, never pushing, posting or rerunning CI)
- `lib/workspace/held_locks.rb` — The live locks of a repository the caller holds (its agent's pid and start time, a process lock from its pane, its bound run's), for `promote`'s `locks_held` warning; every live lock with `own: false` when the caller cannot be told
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
- `lib/workspace/note_path.rb` — `NotePath`: the one checker for a note path inside a notes dir, an ASCII subset of workspace-ui's `noteSegments`; `.segments` checks the shape only, `.resolve` also needs the real path to equal the dir's real path plus the path (no symlinks, no case mismatch, `.md`/`.markdown` file), every `SystemCallError` a `Refused`; advisory, workspace-ui checks again; `.url_path` joins segments. Shared fixture `spec/fixtures/note_paths.json`
- `lib/workspace/terminal_text.rb` — `TerminalText.escape(text, keep_tabs: false)`: the one escaper for text printed to a terminal (`inbox`, `agent-run queue list`, `pr feedback`): C0/C1 controls, line separators, bidi controls and zero-width characters as `\n`, `\e`, `\r`, `\t` or `\uXXXX`, invalid UTF-8 scrubbed; the source writes the invisible characters as escapes
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

init, doctor, launch, start, add, stop, kill, finish, relaunch, restore, focus, list, status, whereis, agent, daemon, pipeline, sessions, review, snapshot, session-event, lock, dev, parent, notes, plan, ticket, skills, spine, pr, rebase, push, promote, projects, ask, inbox, capabilities, ui, binding, library, instructions, workflow, step

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
- Tests use RSpec, run with `bundle exec rspec`. Serial is the default and the pre-commit gate.
- `script/parallel-spec [ARGS...]` runs the suite in parallel with parallel_tests (one process per performance core; about 44s against 232s serial). Each process gets its own short `HOME` and `XDG_*` directory under `/tmp`, and SimpleCov results merge into `coverage/`. Only a whole-suite run (no arguments) uses and refreshes the timings in `tmp/parallel_runtime_rspec.log` (untracked); with arguments, or before a log exists, files are grouped by size. Extra arguments go to `parallel_rspec`.
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
