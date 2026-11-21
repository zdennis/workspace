# Workspace CLI

A macOS CLI (Ruby) for managing tmuxinator-based development workspaces in iTerm2.

## Project Structure

Before editing, adding or relying on a file below, read its full entry in `docs/architecture/<subsystem>.md`. Find it with:

```
grep -n '^- `lib/workspace/foo.rb`' docs/architecture/*.md
```

New per-file detail goes there, never here.

### Workflow (`docs/architecture/workflow.md`)

- `lib/workspace/workflow_seed.rb` — Seeds the `task` text and guards inputs for `workflow start`.
- `lib/workspace/workflow_branch_inputs.rb` — Fills `task` and `pr` workflow inputs from the target checkout's branch.
- `lib/workspace/commands/workflow_start.rb` — `workflow start`: reads the ref and ticket, preflights and starts a run in a new or given workspace.
- `lib/workspace/workflow_inputs.rb` — Pure check of the inputs given to a workflow against its definition.
- `lib/workspace/workflow_alerts.rb` — Sends `alerts.workflow` notifications for newly set run states.
- `lib/workspace/run_liveness.rb` — Whether a workflow run is still alive, from its run file.
- `lib/workspace/run_resources.rb` — Holds a workflow step's `uses:` locks for the run.
- `lib/workspace/workflow_review_spec.rb` — Parses the `reviewers:` and step `review:` parts of a workflow definition.
- `lib/workspace/workflow_fan_out_spec.rb` — Checks a `fan_out` group's siblings for checkout contention: guards and `produces` overlap.
- `lib/workspace/workflow_definition.rb` — One workflow definition (YAML): checks every key, collects problems and fills defaults, `on_fail: stop` included.
- `lib/workspace/workflow_extends.rb` — Resolves a definition's `extends:` against its parent definitions.
- `lib/workspace/workflow_lint.rb` — `workflow validate`'s checks that need the person's setup, as warnings.
- `lib/workspace/workflow_defaults.rb` — Reads which workflow id config names for a ref kind.
- `lib/workspace/workflow_router.rb` — Picks a workflow for `workflow start --ref` from the ref kind and config.
- `lib/workspace/workflow_catalog.rb` — Finds workflow definitions by id across project, user and preset locations.
- `lib/workspace/workflow_project.rb` — Answers which project's workflow definitions a command reads first.
- `lib/workspace/workflow_run.rb` — `WorkflowRun`, a frozen value over a stored run hash, with steps and attempts; each step's slots kept under its own hash and read by `<key>_for`.
- `lib/workspace/workflow_run_store.rb` — Run files under `~/.local/state/workspace/.workflows/`; the one way a run changes.
- `lib/workspace/workflow_engine.rb` — Every transition of a run; delegates to the phase classes it is built from.
- `lib/workspace/workflow_transitions.rb` — The engine's rules over plain values: attempts, delivery, backoff, the default one-step failure loop, sweep marks and review limits.
- `lib/workspace/workflow_run_change.rb` — The one way the engine changes a run: lock, change, events, alerts and follow-ups.
- `lib/workspace/workflow_prompt.rb` — Composes and writes a step's (and a review round's) instructions.
- `lib/workspace/workflow_reported_status.rb` — The status line an agent ends its turn with, and a tolerant reader of it.
- `lib/workspace/workflow_starter.rb` — What starts a run: preflight, render and the first step.
- `lib/workspace/workflow_dispatch.rb` — What starts a step and types its line: locks, budget, attempt record, pane binding.
- `lib/workspace/workflow_progress.rb` — What follows a step's outcome: pass, gate, next step, finish, retry and review rounds.
- `lib/workspace/workflow_rejection.rb` — What a rejected review round hands the step's next attempt.
- `lib/workspace/workflow_round_rerun.rb` — A review round that runs again or does not run.
- `lib/workspace/workflow_review_summary.rb` — Writes a round's `summary.md` and its inbox item.
- `lib/workspace/workflow_evaluation.rb` — Decides a step whose agent's turn ended: guard, produces, proofs, status check and review.
- `lib/workspace/workflow_decisions.rb` — A person's commands on a run: approve, reject, resume, park, cancel.
- `lib/workspace/workflow_recovery.rb` — Wakes or puts right a run nothing else will move: tick and the sweep's acts.
- `lib/workspace/workflow_infra_retry.rb` — Restarts a step whose pane or agent is gone once its infra retry is due: claim, new pane, resume.
- `lib/workspace/workflow_step_check.rb` — `workflow check`: runs one step's `status:` command outside a run.
- `lib/workspace/workflow_expect_fail.rb` — `step expect-fail`: passes only when `commands.test` fails on the given tests, for fail-first proofs.
- `lib/workspace/workflow_simulator.rb` — `workflow simulate`: plays a script through a real engine over fakes.
- `lib/workspace/workflow_sim_script.rb` — Parses and checks a simulator script against a definition.
- `spec/support/preset_simulation.rb` — Parses a shipped preset, fills its inputs and masks a simulator transcript for the golden specs.
- `lib/workspace/workflow_panes.rb` — The run's pane: binding, the one typed line, and review-window handling.
- `lib/workspace/workflow_gate_note.rb` — The one resolver for a gate's note file.
- `lib/workspace/shell_safe_path.rb` — Lists characters a path can't hold inside steps' shell commands.
- `lib/workspace/workflow_deny.rb` — PreToolUse tripwire that blocks Bash commands a run's `deny` list matches.
- `lib/workspace/bash_command_pieces.rb` — Cuts a Bash command into the pieces a policy matches, and tells substitutions and file redirections.
- `lib/workspace/review_write_guard.rb` — PreToolUse tripwire that keeps review panes from writing outside the round directory.
- `lib/workspace/review_round_path.rb` — The one derivation of a reviewer's round directory and its link-safe walk.
- `lib/workspace/reflection_write_guard.rb` — PreToolUse tripwire that keeps a reflection pane to writing its run's `reflection.md`.
- `lib/workspace/workflow_review_revision.rb` — Computes a review round's revision digest.
- `lib/workspace/workflow_review_tally.rb` — Owns the verdict file format and tallies a round's verdicts.
- `lib/workspace/workflow_round_holder.rb` — The process a review round's `holder` names, and its liveness.
- `lib/workspace/workflow_review_round.rb` — Delivers a review round: opens or reuses the review window and types the instructions.
- `lib/workspace/workflow_review_orphans.rb` — Finds and closes left-over review windows.
- `lib/workspace/review_verdict_proof.rb` — Proves a verdict file was written by the review pane, from the hook event log.
- `lib/workspace/workflow_guard.rb` — Checks that a `guard:` step left the checkout alone; also review-round snapshots.
- `lib/workspace/workflow_require.rb` — Checks a step's `require:` proofs.
- `lib/workspace/workflow_produced.rb` — The one check of a step's `produces` file, plus safe hashing.
- `lib/workspace/transcript_usage.rb` — Token-usage rules: ledger session pick, transcript path check, per-line read, forward line scan and usage totals.
- `lib/workspace/workflow_attempt_record.rb` — What an attempt records about itself: hashes, head, outputs, session and usage.
- `lib/workspace/workflow_evidence.rb` — Copies prompts, check logs, outputs and verdicts into a run's evidence directory.
- `lib/workspace/workflow_log_tail.rb` — Formats a failed check's log tail and a reviewer's write-up as safe data blocks.
- `lib/workspace/workflow_attempts.rb` — The rows `workflow attempts` shows.
- `lib/workspace/workflow_reflection.rb` — Composes the instructions for a pane that looks back at a finished run and writes its `reflection.md`.
- `lib/workspace/commands/workflow_reflect.rb` — `workflow learn reflect`: starts a bound reflection pane for one finished run, or prints its existing `reflection.md`.
- `lib/workspace/workflow_trace.rb` — `WorkflowTrace`: a run's events as ordered transition rows with derived states, and tokens on each attempt's ending row.
- `lib/workspace/workflow_stats.rb` — `workflow stats`: per-step attempt and token statistics over a definition's runs.
- `lib/workspace/workflow_graph.rb` — The nodes and edges of one workflow definition, for `workflow graph`.
- `lib/workspace/workflow_graph_text.rb` — The edge labels and legend line the graph renderers share.
- `lib/workspace/workflow_graph_mermaid.rb` — Draws a workflow graph model as Mermaid `stateDiagram-v2` text.
- `lib/workspace/workflow_graph_dot.rb` — Draws a workflow graph model as Graphviz DOT.
- `lib/workspace/workflow_graph_ascii.rb` — Draws a workflow graph model as plain text boxes with a rail for loop edges.
- `lib/workspace/workflow_graph_states.rb` — Marks a workflow graph model with one run's node states, pass counts and loop counts.
- `lib/workspace/workflow_run_loader.rb` — The run loading `workflow stats` and `compare` share.
- `lib/workspace/workflow_compare.rb` — `workflow compare`: groups a workflow's runs by definition or pack version.
- `lib/workspace/workflow_insights.rb` — Joins stats, compare and run hashes into the sections `workflow insights` prints: hot steps, review themes, failures, holds and effects.
- `lib/workspace/workflow_audit.rb` — Checks recorded evidence against its stored copies.
- `lib/workspace/workflow_budget.rb` — Reads a run's token budget and spend.
- `lib/workspace/workflow_live_usage.rb` — Reads the running attempt's tokens so far, a capped, cached piece of its transcript at a time.
- `lib/workspace/workflow_deadline.rb` — Reads a run's `timeout:` and elapsed machine time.
- `lib/workspace/workflow_downtime.rb` — Records the time the workflow daemon was not running, from a heartbeat file and a span file.
- `lib/workspace/workflow_run_health.rb` — What `doctor` reports about runs and run locks, read only.
- `lib/workspace/workflow_sweep.rb` — `workflow sweep`: one pass over going runs to recover stalled or timed-out steps.
- `lib/workspace/workflow_review_sweep.rb` — The sweep's rows for a reviewing step and left-over review windows.
- `lib/workspace/workflow_sweep_rows.rb` — Helpers the two sweep classes share for building rows.
- `lib/workspace/workflow_sweep_actions.rb` — Turns a sweep's rows into the `next_actions` of `workflow sweep --json`.
- `lib/workspace/workflow_recover.rb` — `workflow recover`: after a reboot, restores workspaces whose going runs no person holds, restarts mid-turn steps (limited per run) and wakes runs between turns.
- `lib/workspace/sweep_schedule.rb` — The opt-in launchd entry that runs `workflow sweep`.
- `lib/workspace/workflow_check.rb` — Runs a step's `status:` command with a time limit, logging output.
- `lib/workspace/status_scope.rb` — The one rule for which workspaces a status command reports on.
- `lib/workspace/workflow_status.rb` — What `workflow status` shows, including live review and wait state.
- `lib/workspace/workflow_needs_me.rb` — Narrows status rows to the runs that wait for a person.
- `lib/workspace/workflow_workspace_facts.rb` — What `workflow status --table` says about each workspace now.
- `lib/workspace/workflow_nudger.rb` — The daemon's part that starts `workflow advance` when a bound pane's turn ends.
- `lib/workspace/workflow_config.rb` — Reads the global default workflow packs.
- `lib/workflows/` — The workflow presets that ship (rpiv, rpiv-auto-approve, rpiv-auto-approve-v2, pr-feedback, investigate, explore, explore-parallel, bugfix).
- `lib/workspace/commands/workflow.rb` — The `workflow` and `step` subcommands: shows definitions, starts a run in a workspace's agent pane, shows where runs stand, and lets a person move one (resume, cancel, approve, reject) or the run's own agent report on its step.
- `lib/workspace/workflow_argv.rb` — Turns the string of a `require: exec:` entry into an argument vector, checks it, and fills in its placeholders.
- `lib/workspace/workflow_exec_program.rb` — The one rule for whether the program of a `require: exec:` entry (argument 1 of its argv) can run.
- `lib/workspace/workflow_files.rb` — The one writer of a user's workflow definitions, `config.workflows_dir/ID.yml`.
- `lib/workspace/workflow_run_files.rb` — Lists the files a workflow run keeps, from the run's own JSON: each attempt's prompt and check and proof logs (when recorded) and each step's `produces` entries.
- `lib/workspace/workflow_source.rb` — The semantic parse of one `workflows.sources` entry.
- `lib/workspace/workflow_source_dirs.rb` — Answers the directories the catalog reads workflow sources from: one slot per entry of the global `workflows.sources`, in list order.
- `lib/workspace/workflow_source_fetcher.rb` — Gets the files of one `workflows.sources` entry.
- `lib/workspace/workflow_source_installer.rb` — Installs the `workflows.sources` entries: fetches each one into a staging directory (a local one is read in place), checks every `.yml` file in it through {WorkflowDefinition.parse} against a staged {WorkflowCatalog} whose layers are in the order a.

### Agent daemon (`docs/architecture/agentd.md`)

- `lib/workspace/agent_restart.rb` — The daemon's `restart_agent` worker: waits for a quiet pane, types `/clear`, then the prompt.
- `lib/workspace/agentd_parts.rb` — The frozen struct of parts the agent daemon builds per workspace.
- `lib/workspace/commands/agent.rb` — The agent daemon's command object: socket, parts and message handling.
- `lib/workspace/agentd_restart_desk.rb` — The daemon's side of `restart_agent`: validates, claims the pane and starts a restart.
- `lib/workspace/hook_fanout.rb` — Fans one workspace's hook events out to the daemon's watchers and desks.
- `lib/workspace/agentd_router.rb` — Routes an agent-protocol message type to its handler.
- `lib/workspace/agentd_socket_server.rb` — The agent daemon's Unix socket: claim, listen, serve and watch.
- `lib/workspace/pipeline_desk.rb` — The daemon's pipeline and work-coordinator traffic for one workspace.
- `lib/workspace/agent_message_client.rb` — Sends one message to a workspace's agent daemon over its Unix socket.
- `lib/workspace/work_coordinator_client.rb` — JSONL client for work-coordinator sockets.
- `lib/workspace/pipeline_config.rb` — Reads per-project pipeline stage config (pipeline is deprecated).
- `lib/workspace/pipeline_state.rb` — Disk-persisted in-flight work item tracking for pipelines.
- `lib/workspace/sentinel_poller.rb` — Background poller watching panes for the `WORKSPACE_DONE:` sentinel.
- `lib/workspace/spine_watcher.rb` — The daemon's watch of a workspace's `spine/` for changes.
- `lib/workspace/agent_recovery_desk.rb` — The daemon's recovery of a Claude Code agent whose turn ended on an API error.
- `lib/workspace/recovery_verdicts.rb` — Pure decisions for each stage of a recovery check.
- `lib/workspace/recovery_facts.rb` — Each read a recovery check makes, one named method per read.
- `lib/workspace/recovery_intake.rb` — Applies hook events to the recovery store's per-pane entries.
- `lib/workspace/recovery_confirmer.rb` — Confirms recovery entries from the monitor's scan.
- `lib/workspace/recovery_attempt_runner.rb` — Runs steps 2 to 5 of a recovery attempt: wait, resume, then type the message.
- `lib/workspace/recovery_outcomes.rb` — What comes of a recovery check or attempt: refusals, give-ups, inbox items and events.
- `lib/workspace/recovery_attempts.rb` — One recovery attempt from its claim to its end.
- `lib/workspace/recovery_entry.rb` — The entry-writing helpers more than one recovery part uses.
- `lib/workspace/agent_recovery_store.rb` — Flock-guarded `agent-recovery.json` with one entry per pane.
- `lib/workspace/agent_recovery_config.rb` — Reads `agent.recovery.enabled`.
- `lib/workspace/agent_stopper.rb` — Finds the Claude Code process in a pane and sends it SIGINT, nothing else.
- `lib/workspace/agent_resume_command.rb` — The one builder of the shell line that resumes a Claude Code session.
- `lib/workspace/recovery_stop_marker.rb` — A file marking that the daemon is about to stop an agent for recovery.
- `lib/workspace/restart_registry.rb` — The panes an agent daemon is restarting, one claim per pane id.
- `lib/workspace/restart_runner.rb` — Runs one `restart_agent` on its worker thread and reports the outcome.
- `lib/workspace/agent_recovery_steps.rb` — Picks the runner of steps 2 to 5 of a recovery attempt.
- `lib/workspace/agent_recovery_desk_factory.rb` — Builds the recovery desk for one workspace, or nil when disabled or not Claude Code.
- `lib/workspace/handoff_watcher.rb` — The daemon's follow-up for a `handoff check` prompt that landed and went nowhere.
- `lib/workspace/plan_paused.rb` — Whether the workspace's plan says `status: paused`.
- `lib/workspace/agent_status_desk.rb` — The daemon's side of `agent status request|post`.
- `lib/workspace/prompt_typer.rb` — The one careful typing sequence into a pane, run under the delivery lock.
- `lib/workspace/prompt_queue_store.rb` — Flock-guarded `prompt-queue.json` of prompts waiting for an idle pane.
- `lib/workspace/prompt_queue_desk.rb` — The daemon's side of `agent-run send --when-idle` and `--clear-first`.
- `lib/workspace/clear_confirmation.rb` — Decides whether a typed `/clear` took effect.
- `lib/workspace/commands/prompt_queue.rb` — `agent-run queue list|cancel`.
- `lib/workspace/session_ledger.rb` — Append-only ledger of agent SessionStart/SessionEnd events, used by `restore`.
- `lib/workspace/core/agent_protocol.rb` — The agent daemon's socket messages in one pure module.
- `spec/support/agentd_parts_helper.rb` — Spec helper that builds a `Commands::Agent` through the real builders.
- `lib/workspace/agent_snapshot_client.rb` — Asks one workspace's agent daemon for its session snapshot over the daemon's Unix socket, with a bound on how long it waits for the reply.
- `lib/workspace/agent_status_requests.rb` — The status requests one agent daemon has open: at most one per pane, each tied to the pane's id and the pid tmux started in it, and each expiring.
- `lib/workspace/agentd_config.rb` — Reads the `agentd:` block from a project's YAML config, as written by `workspace config set agentd.poll_interval <duration>`.
- `lib/workspace/commands/agent_status.rb` — `agent status request` and `agent status post`: asking an agent pane for a status line, and an agent answering.
- `lib/workspace/commands/handoff.rb` — `handoff check|new`: types a save-state prompt into a pane over its context threshold, then starts a fresh agent session.
- `lib/workspace/commands/hooks.rb` — `hooks uninstall --agent KIND`: takes workspace's hooks back out of a coding agent's own settings file, leaving the person's own hooks and every other key as they were.
- `lib/workspace/commands/restart_agent.rb` — Asks a workspace's agent daemon to restart the coding agent in one named pane: type `/clear`, confirm its context usage dropped, then type a prompt.
- `lib/workspace/commands/session_event.rb` — Receives one hook event from a coding agent and forwards it to that workspace's agent daemon.
- `lib/workspace/delivery_log.rb` — The file hook events the daemon never got are recorded in: one line each, newest last, so a hook that reaches no daemon is findable without --debug.
- `lib/workspace/handoff_config.rb` — Reads the `handoff:` block from a project's YAML config, as written by `workspace config set handoff.threshold <pct>` (and the two prompt override keys).
- `lib/workspace/hook_event_log.rb` — One agent daemon's high-rate log of hook events: `<dir>/<workspace>.jsonl`, one typed JSON line per tool call, permission request and its end, notification, sub-agent, session and prompt, plus the `agent_status` lines agents post (`agent status post`).
- `lib/workspace/hooks_config.rb` — Reads the global `codex.hooks.install` key, as written by `workspace config set`: whether `start` installs workspace's hooks into Codex's user-level `hooks.json`.
- `lib/workspace/tool_input_summary.rb` — The short, safe summary of a tool call's input that `tool_started` and `tool_finished` lines carry as `input`: the first line of a Bash command, the file a file tool works on, a search's pattern, a fetch's URL.
- `lib/workspace/commands/daemon.rb` — Reads and controls a workspace's agent daemon from outside it: whether it is answering and which process it is, the tail of its log, and a restart that stops it and starts a fresh one detached.
- `lib/workspace/commands/ensure_agent.rb` — Makes sure a workspace has an agent daemon (`agentd`) answering on its socket, starting one detached when it doesn't.
- `lib/workspace/daemon_watch.rb` — One stream of a workspace's workflow decision lines and its runs' events, oldest first, with one cursor that resumes both.
- `lib/workspace/permission_policy.rb` — Decides allow, ask or deny for an agent tool call from layered rules, deny first, matching each piece of a Bash command.

### Templates (`docs/architecture/template.md`)

- `lib/workspace/cli/template.rb` — `CLI::Template`, the `template` verb family parser, including `apply --relaunch`.
- `lib/workspace/template_selection.rb` — Picks the workspaces a multi-workspace `template` verb acts on (names, `--all`, `--project`, or the current one).
- `lib/workspace/template_status.rb` — Reports per workspace whether its tmuxinator config is current, stale, modified or untracked against today's render.
- `lib/workspace/template_apply.rb` — `template apply`: re-renders configs under startup locks with backups, dry run and rollback.
- `lib/workspace/template_adopt.rb` — `template adopt`: builds the render record for a config that has none, exactly or approximately.
- `lib/workspace/template_batch_files.rb` — The file steps that `TemplateApply` rollback and `template restore` share.
- `lib/workspace/commands/template_backups.rb` — `template backup`, `backups list|prune` and `restore` over tmuxinator backup batches.
- `lib/workspace/tmuxinator_backup_config.rb` — Reads the `tmuxinator.backups.keep` and `.max_age` retention settings.
- `lib/workspace/text_diff.rb` — `TextDiff`, a unified diff of two strings via `diff -u`.
- `lib/workspace/commands/template.rb` — `template` command object: list, show, render, validate, diff, new, edit, use, export, import, status and apply.
- `lib/workspace/core/template_variables.rb` — The one frozen table of tmuxinator template placeholders.
- `lib/workspace/template_variables_docs.rb` — Renders the placeholder table into `docs/README.template.md`.
- `lib/workspace/tmuxinator_config_writer.rb` — Writes tmuxinator configs and their render records atomically.
- `lib/workspace/tmuxinator_backup_store.rb` — Batches of tmuxinator config copies with manifests, listing and pruning.
- `lib/workspace/template_validator.rb` — Checks a tmuxinator template set without writing it.
- `lib/workspace/template_in_use.rb` — Finds which workspaces select a template set, to refuse replacing or deleting it.
- `lib/workspace/legacy_tmuxinator_templates.rb` — Shas of shipped tmuxinator templates, to tell an edited installed copy from a stock one.
- `lib/workspace/tmuxinator_template_config.rb` — Reads which tmuxinator template set a workspace selects.
- `lib/library/template/default/` — The built-in `default` tmuxinator template set.
- `lib/workspace/tmuxinator_report.rb` — Builds the document behind `workspace tmux show --json`: a workspace's tmuxinator file as session fields, windows and panes, with what each pane's command looks like and what tmux is running now.
- `lib/workspace/commands/update_pane_command.rb` — Updates a pane's shell command in a project's tmuxinator config file.

### CLI (`docs/architecture/cli.md`)

- `bin/workspace` — Entry point; calls `Workspace.build_cli.run(ARGV)`.
- `lib/workspace.rb` — Module root and the `build_cli` composition root, plus the public `build_agentd_parts`, `build_agent_daemon` and `build_workflow_engine` builders.
- `lib/workspace/cli.rb` — CLI dispatch, OptionParser definitions and simple command methods; routes verbs to family parsers.
- `lib/workspace/cli/invocation.rb` — `CLI::Invocation`, the frozen value of one run (streams, exit handler, flags, env).
- `lib/workspace/cli/common.rb` — `CLI::Common`, the shared output, exit, help, JSON-error and editor helpers.
- `lib/workspace/cli/names.rb` — `CLI::Names`, the workspace-name and working-directory helpers the CLI and families share.
- `lib/workspace/cli/launcher.rb` — `CLI::Launcher`, what every launching verb shares: settle names, compose packs, launch, make settings, run hooks.
- `lib/workspace/launch_hook_check.rb` — The read-only Note line `launch` prints when a checkout's on-PATH agents hold no current session hooks; installs nothing.
- `lib/workspace/cli/relauncher.rb` — `CLI::Relauncher`, the work of `relaunch`: stop, wait, launch again, and detach when the caller is inside the target.
- `lib/workspace/detached_spawn.rb` — `DetachedSpawn`, runs a command in its own session with output to a log, for a detached `relaunch`.
- `lib/workspace/cli/workflow.rb` — `CLI::Workflow`, the `workflow` and `step` verb family parser.
- `lib/workspace/cli/agent.rb` — `CLI::Agent`, the `agent`, `agentd`, `daemon`, `sessions` and `review` verb family parser.
- `lib/workspace/cli/agent_run.rb` — `CLI::AgentRun`, the `agent-run` and `handoff` verb family parser.
- `lib/workspace/cli/pipeline.rb` — `CLI::Pipeline`, the deprecated `pipeline` verb family.
- `lib/workspace/cli/plan_spine.rb` — `CLI::PlanSpine`, the `plan`, `spine`/`journey` and `goal` verb family parser.
- `lib/workspace/help_pages.rb` — Data-only help pages for the verbs that share one option parser.
- `lib/workspace/json_envelope.rb` — Builds the `--json` action and error documents.
- `lib/workspace/output_gate.rb` — The stdout every collaborator writes through; `--json` diverts it to stderr.
- `spec/support/cli_golden.rb` — Harness that runs the CLI in a throwaway HOME for golden help and error fixtures.
- `script/record-cli-golden` — Rewrites the CLI golden fixtures.
- `script/record-cli-coverage OUT` — Records the CLI specs' coverage of `commands/` files.
- `spec/support/cli_test_helpers.rb` — The CLI's spec fakes and `CLITestHelpers.build_cli`.
- `lib/workspace/help_json.rb` — `--help --json`: decides whether a command line truly asks for a help page in JSON, and turns the page text the command prints into one document, so the JSON and the text are the same words and cannot drift.

### Work queue (`docs/architecture/work-queue.md`)

- `lib/workspace/work_queue_history.rb` — Age-pruned `work-queue-history.jsonl` of finished queue items: append, filtered reads, id-prefix lookup and clear.
- `lib/workspace/work_queue_store.rb` — Flock-guarded `work-queue.json` of pending queue items: revision, toggle, pause, claims and one `transaction` for the advance pass.
- `lib/workspace/work_queue_starters.rb` — The `workflow` and `go` starters of a queue item, run in the queue workspace's checkout.
- `lib/workspace/work_queue_advance.rb` — One advance pass of a work queue: reconciles the current item from its run, then claims, starts and records the next.
- `lib/workspace/work_queue_desk.rb` — The agent daemon's part that starts `work-queue advance` after a turn ends and on its scan.
- `lib/workspace/commands/work_queue.rb` — `work-queue` verbs over a workspace's queue and history: add, list, show, skip, cancel, advance and the rest.
- `lib/workspace/cli/work_queue.rb` — `CLI::WorkQueue`, the `work-queue` (`wq`) verb family parser: checks each verb's flags, parses dates and wraps results as documents.

### Locks, plan, spine, inbox (`docs/architecture/locks-plan-spine-inbox.md`)

- `lib/workspace/spine_file.rb` — Reads one spine file (a stage or `goal.md`) without ever failing.
- `lib/workspace/spine_tree.rb` — Walks `spine/` in the notes dir into stages with roll-ups.
- `lib/workspace/spine_rollup.rb` — The one roll-up of a stage's children.
- `lib/workspace/commands/spine.rb` — `spine show`: read-only view of the spine, plus write helpers for `spine start`.
- `lib/workspace/spine_inferred.rb` — Infers stages when a workspace has no `spine/`, from plan, runs and pull request.
- `lib/workspace/commands/spine_start.rb` — `spine start`: refuses on file and pane state, writes the owner and types the brief.
- `lib/workspace/plan_file.rb` — Parser and the only writers of a workspace's `IMPLEMENTATION_PLAN.md`.
- `lib/workspace/plan_state.rb` — Derives the one plan state and the row `plan status` shows.
- `lib/workspace/plan_config.rb` — Reads a project's `plan.stall_seconds`.
- `lib/workspace/commands/plan.rb` — `plan status|path|show|init|pause|delete|start`.
- `lib/workspace/commands/plan_dispatch.rb` — `plan start`: launches or types into a pane, binds it and writes the task owner.
- `lib/workspace/plan_access.rb` — What the plan command objects share: file path, errors and status writes.
- `lib/workspace/alert_config.rb` — Reads a project's `alerts.notify` and `alerts.idle_after`.
- `lib/workspace/notifier.rb` — Runs the notify command in the background with a timeout.
- `lib/workspace/inbox_store.rb` — Flock-guarded JSON store of one inbox scope.
- `lib/workspace/commands/inbox.rb` — `inbox add|list|show|edit` and friends, with input checks.
- `lib/workspace/inbox_derived.rb` — The rows `inbox list --include-derived` works out and never stores.
- `lib/workspace/inbox_acks.rb` — The acked or snoozed derived inbox rows.
- `lib/workspace/ask_store.rb` — Append-only store for `workspace ask` questions.
- `lib/workspace/task_store.rb` — One-file-per-task store; `start` creates, `finish`/`kill` archive.
- `lib/workspace/lock_namespace.rb` — Resolves the shared lock namespace from a working directory.
- `lib/workspace/lock_holder.rb` — Identifies the calling agent's pid and start time and checks holder liveness.
- `lib/workspace/lock_store.rb` — Flock-guarded JSON lock store, including run locks.
- `lib/workspace/held_locks.rb` — The live locks the caller holds, for `promote`'s warning.
- `lib/workspace/bound_run.rb` — The run the calling pane is bound to.
- `lib/workspace/lock_config.rb` — Reads a project's `locks.idle_grace`.
- `lib/workspace/dev_session_release.rb` — On SessionEnd, starts the release of a dev lock the session held.
- `lib/workspace/lock_idle_tracker.rb` — Marks an agent's lock idle or active from hook events.
- `lib/workspace/dev_events.rb` — Writes dev start and stop events to the event log.
- `lib/workspace/dev_runner.rb` — The `dev __run` wrapper that holds the `devenv` lock while the dev command runs.
- `lib/workspace/process_group_terminator.rb` — SIGTERM then SIGKILL for a lock holder's process group, after identity checks.
- `lib/workspace/process_holder_stopper.rb` — Stops a process lock holder for `lock clear` and `dev down`.
- `lib/workspace/dev_config.rb` — Reads a project's `dev:` block.
- `lib/workspace/run_result_cleaner.rb` — Removes old run files in `~/.workspace-runs`.
- `lib/workspace/commands/ask.rb` — Records a question an unattended agent hits, along with the default it took, so the agent can keep going instead of blocking on a person.
- `lib/workspace/commands/dev.rb` — Starts, stops, and inspects a repository's single dev environment, guarded by the repo-wide `devenv` lock.
- `lib/workspace/commands/goal.rb` — `goal show [REF]` and `goal list`: where a goal is at each level (the goal, its journey stage, its workflow step, the agent's turn, the tool call), what it waits for and on whom.
- `lib/workspace/commands/lock.rb` — Coordinates agents sharing a resource (first: edits to a shared worktree) through one flock-guarded lock store per repository.
- `lib/workspace/commands/plan_task.rb` — `workspace plan task add|set-state|set-title|move`: changes one task line of a workspace's plan so people, agents and the app need not edit the Markdown by hand.
- `lib/workspace/commands/spine_init.rb` — `spine init`: copies a spine template (a library entry of kind `spine`) into the `spine/` folder of a workspace's notes directory, filling `{{WORKSPACE}}`, `{{BRANCH}}` and `{{TITLE}}`.
- `lib/workspace/goal_state.rb` — The goal's one `state`, who it waits on and the event that moves it on, from reads that already exist: the plan's own state ({Workspace::PlanState}, in the snapshot member's `plan.state`), the run's reason and flags ({Workspace::WorkflowStatus}), the pane's state.
- `lib/workspace/lock_audit_log.rb` — Append-only audit log for one lock namespace, written to `locks.jsonl` next to that namespace's `locks.json`.
- `lib/workspace/lock_enforcer.rb` — Denies an Edit/Write/MultiEdit/NotebookEdit tool call when this namespace's `edit` lock is held by another agent, and releases every lock this agent holds when its session ends or is cleared.
- `lib/workspace/lock_reaper.rb` — Reaps crashed lock holders and waiters from the session-monitor daemon, so `workspace lock status` and `workspace sessions` stop showing a dead agent's hold even when no lock op comes along to reap it.
- `lib/workspace/plan_progress_watcher.rb` — Watches one workspace's plan file and records `plan_progress` in the event log when its `## Tasks` checklist changes, however the file was edited (a plan verb, an agent, an editor).
- `lib/workspace/spine_config.rb` — Reads `spine.template` and `spine.auto`, as written by `workspace config set`: which spine template `spine init` and `start` use, and whether `start` runs `spine init` on its own.
- `lib/workspace/spine_evaluator.rb` — The verdict on a workspace's stages: a port of the app's `src/core/spine/model.ts`, so the CLI and the app judge a stage alike.
- `lib/workspace/spine_facts.rb` — What a workspace's stages are judged against: the plan file, the branch against its upstream, the pull request, the review agent and the panes, mapped into {SpineEvaluator::Facts} by the rules of the app's `src/core/spine/facts.ts`, so the CLI and the app read.
- `lib/workspace/spine_owner_report.rb` — Records `spine_changed` with `change: "owner_finished"` when the agent that owns a started stage ends its turn, so a reader can show "the stage's agent finished" without watching the pane.
- `lib/workspace/spine_writer.rb` — Rewrites frontmatter keys of one spine stage file: any set of `status`, `note` and `owner`, plus `updated` and `updated_by` on every write; a status change on a stage that has opted in to a check (it has a `check:` key) also resets `check` and drops the.

### Panes and session monitor (`docs/architecture/panes.md`)

- `lib/workspace/tmux.rb` — Tmux session and pane management.
- `lib/workspace/styled_screen.rb` — Parses a styled pane capture so faint suggestions can be told from typed drafts.
- `lib/workspace/typing_safety.rb` — The one test of whether text may be typed into a pane.
- `lib/workspace/idle_prompt_check.rb` — Says whether a pane's input box is empty and nothing is running.
- `lib/workspace/pane_locator.rb` — Strict pane resolver for `agent-run send`, `focus --pane` and `ask answer --deliver`.
- `lib/workspace/pane_bindings.rb` — `bindings.json`: which run, review or play each tmux pane works on.
- `lib/workspace/pane_dispatch.rb` — The pane steps `plan start` and `spine start` share: find, spawn, wait and type.
- `lib/workspace/question_closed_check.rb` — Proves from the screen that a question dialog has closed.
- `lib/workspace/session_monitor.rb` — Per-pane coding-agent and sub-agent state (working, idle, waiting); fires alerts.
- `lib/workspace/pane_events.rb` — The monitor's hook-event reducer over a pane hash.
- `lib/workspace/pane_states.rb` — The monitor's state rules as pure functions.
- `lib/workspace/pane_alerts.rb` — The monitor's alert rules and the one writer of alert marks.
- `lib/workspace/pane_screen_rules.rb` — The scan's screen rules: permission waits and closed questions.
- `lib/workspace/pane_scanner.rb` — The reads of the monitor's scan: pane details, process snapshot, history and refresh.
- `lib/workspace/pane_view.rb` — What `SessionMonitor#snapshot` shows: rows, document and caches.
- `lib/workspace/pane.rb` — One tmux pane of one session as the daemon's desks see it.
- `lib/workspace/pane_factory.rb` — Builds `Pane`s by id, listing panes only when needed.
- `lib/workspace/pane_locks.rb` — One delivery mutex per tmux pane id.
- `lib/workspace/session_monitor_builder.rb` — Builds the `SessionMonitor` for one workspace from the daemon's settings.
- `lib/workspace/process_tree.rb` — One-shot `ps` snapshot with parent and child lookups.
- `lib/workspace/agent_labels.rb` — Names the coding agent each tmux pane runs, by the label `workspace sessions` shows in its TITLE column ("Claude Code", "Codex").
- `lib/workspace/commands/capture.rb` — Reads a tmux pane's scrollback buffer and writes it to output.
- `lib/workspace/commands/sessions.rb` — Shows which panes in a workspace are running a coding agent, whether each is working, idle, or waiting on a person, and what sub-agents they have started.
- `lib/workspace/commands/wait_until_content.rb` — Polls a tmux pane's scrollback until it contains a target string, then execs a follow-up command so it replaces this process and owns the terminal (direct Ctrl-C, untouched STDIN/STDOUT/STDERR).
- `lib/workspace/session_workspace.rb` — The one map from a tmux session to the workspace whose agentd owns it.
- `lib/workspace/tmux_pane.rb` — Resolves a pane specification to a tmux pane index.
- `lib/workspace/transcript_label.rb` — Reads the title and last prompt Claude Code keeps in a session's transcript, so `sessions --json` can label a pane by what it is doing.
- `lib/workspace/scan_slot_limiter.rb` — Bounds how many session monitors scan at once, machine-wide.
- `lib/workspace/commands/layout.rb` — Saves, restores, and lists tmux pane layouts for workspace projects.
- `lib/workspace/commands/resize.rb` — Resizes tmux panes for a running workspace project.
- `lib/workspace/commands/statusline.rb` — `statusline`: Claude Code's `statusLine` command; records the pane's context reading and prints the status line.
- `lib/workspace/context_reasons.rb` — Shared reason strings and fix hint for a coding-agent pane whose context usage percentage can't be determined right now.
- `lib/workspace/context_store.rb` — Persists the most recent context-window reading for each tmux pane running `workspace statusline`, so `sessions --json` and `workspace handoff check` can report it without depending on Claude's status line having just rendered.
- `lib/workspace/statusline_renderer.rb` — Builds Claude Code's status line: model, directory, git branch, a context usage bar, session cost, and turn duration.
- `lib/workspace/commands/restore.rb` — Brings back the coding-agent panes a reboot or a tmux restart took: reads the session ledger, recreates each recorded agent pane that is gone (however it was made, including one split by hand), and types the resume line into it from the session's directory.
- `lib/workspace/commands/send.rb` — Types into one named pane of a workspace's tmux session, straight through tmux (no agent daemon needed): either literal text, or tmux key names such as `Escape` or `C-c`.
- `lib/workspace/commands/run.rb` — Sends a shell command to a specific pane in a running project's tmux session.

### Other (`docs/architecture/other.md`)

- `lib/workspace/config.rb` — Path constants and configuration.
- `lib/workspace/commands/notes.rb` — `notes dir`: the one answer to where a workspace's notes live; also opens the Notes view.
- `lib/workspace/commands/promote.rb` — `promote`: moves a main checkout's changes into a new worktree workspace.
- `lib/workspace/checkout_move.rb` — The git half of `promote`: stash, switch, `worktree add`, apply, with undo on failure.
- `lib/workspace/notes_carry.rb` — Moves the plan and spine and copies chosen notes into a new notes directory for `promote`.
- `lib/library/play/promote.md` — The `promote` instruction pack for the agent.
- `lib/workspace/core/` — The lowest layer: shared rules and tables that depend on nothing outside `core/`.
- `lib/workspace/core/id_patterns.rb` — Name rules shared across sub-systems (library names, workflow ids).
- `lib/workspace/core/config_schema.rb` — The one table of config keys: scope, default, parser, restart flag, docs.
- `lib/workspace/notes_dir.rb` — The one resolver for where a workspace's notes directory is.
- `lib/workspace/config_schema_docs.rb` — Renders the config schema into the generated blocks of `docs/README.config.md`.
- `lib/workspace/state.rb` — JSON-persisted session state.
- `lib/workspace/git.rb` — Git and worktree operations.
- `lib/workspace/name_migration.rb` — Renames a mixed-case workspace to lowercase before its daemon starts, under the startup lock.
- `lib/workspace/core/workspace_name.rb` — The workspace name rules: splitting, joining, normalizing and settling typed names.
- `lib/workspace/which.rb` — Shared default PATH lookup for injectable `which:` collaborators.
- `lib/workspace/doctor.rb` — Dependency and health checking, with `--fix` repairs.
- `lib/workspace/project_config.rb` — Tmuxinator config generation and rendering.
- `lib/workspace/project_catalog.rb` — Groups workspaces into projects (main checkout plus worktrees); backs `projects`.
- `lib/workspace/project_groups.rb` — Groups of repositories stored as hand-editable files.
- `lib/workspace/osascript_runner.rb` — Runs one AppleScript through `osascript` with a 5s limit.
- `lib/workspace/ui_app_probe.rb` — The read-only macOS question behind `ui status`: which app takes `workspace-ui://` links.
- `lib/workspace/commands/ui.rb` — `ui open` and `ui status`: build and open `workspace-ui://` links.
- `lib/workspace/iterm.rb` — iTerm2 session and pane lifecycle via AppleScript.
- `lib/workspace/focus_config.rb` — Reads the global `focus.chain` into window-tool steps.
- `lib/workspace/shell_init.rb` — The fixed text `shell-init zsh|bash` prints for an rc file.
- `lib/workspace/window_manager.rb` — iTerm2 window operations: find, focus, position, close.
- `lib/workspace/window_liveness.rb` — Whether iTerm still has each tracked workspace's recorded window.
- `lib/workspace/window_layout.rb` — Window positioning math.
- `lib/workspace/core/error_codes.rb` — Registry of the stable error `code` values.
- `lib/workspace/library_store.rb` — The files of one library scope, written atomically.
- `lib/workspace/library.rb` — Resolves a library reference across project, global and built-in scopes.
- `lib/workspace/recipe_file.rb` — Parses and checks a `recipe` library entry.
- `lib/workspace/library_installer.rb` — Copies a library agent or skill into a checkout's install directory.
- `lib/workspace/library_install_dirs.rb` — The one reader of the `library.install.*` directory keys.
- `lib/workspace/instruction_composer.rb` — Builds an agent's instructions from library packs and a workflow step's layers.
- `lib/workspace/notes_config.rb` — Reads a project's `notes.instructions` setting.
- `lib/workspace/main_agent.rb` — Which coding agent a project's main pane runs, read from its tmuxinator config.
- `lib/workspace/agent_commands.rb` — Reads `agent.kind` and `agent.commands.<kind>` through layered config.
- `lib/workspace/agent_executables.rb` — Read-only scan of PATH for each agent family's launchers.
- `lib/workspace/commands/agent_executables.rb` — `agent executables`: prints the launchers found and the effective program per kind.
- `lib/workspace/agent_command_check.rb` — What `config set agent.commands.<kind>` validates.
- `lib/workspace/agent_detector.rb` — Finds the coding agent in a pane, honoring configured program aliases.
- `lib/workspace/commands_config.rb` — Reads a project's `commands.test` and `commands.lint`.
- `lib/library/play/` — The built-in instruction packs, read through `Library#builtin_store`.
- `lib/workspace/commands/skills.rb` — `skills install|uninstall`: links the shipped skills into each agent harness.
- `lib/workspace/skill_harnesses.rb` — The four agent harnesses and their skills directories.
- `lib/workspace/skill_source.rb` — Where skill links point (Homebrew `opt` keg or the checkout), refusing linked worktrees.
- `lib/workspace/skill_links.rb` — Inspects, plans and writes the links of one skills directory.
- `lib/workspace/skills_state.rb` — `skills.json`, the record of declined harnesses.
- `lib/skills/` — The six shipped skills that `skills install` links.
- `script/check-skills` — Checks the skill files against the real CLI's commands, flags and error codes.
- `lib/workspace/commands/rename.rb` — `rename`: renames a stopped worktree workspace's branch, directory, name and session.
- `lib/workspace/rename_plan.rb` — The read-only half of `rename`: new names and every refusal.
- `lib/workspace/rename_journal.rb` — The journal that lets an interrupted `rename` be finished.
- `lib/workspace/workspace_store_rename.rb` — Renames everything keyed on a workspace's name; shared by `NameMigration` and `rename`.
- `lib/workspace/deferred_signals.rb` — Holds INT, TERM and HUP while multi-step operations run.
- `lib/workspace/commands/` — Complex command objects, one per verb or verb family.
- `lib/workspace/notes_setup.rb` — Sets up a new worktree's notes directory for `start` and `add`.
- `lib/workspace/start_ref.rb` — Classifies what `start` and `ticket show` are given (ticket, PR, issue, branch).
- `lib/workspace/ticket_source.rb` — Reads a ticket's or pull request's title and body through `gh` or `jira`.
- `lib/workspace/commands/go.rb` — `go`: picks a workflow for a ref or text and starts it in place or in a new workspace.
- `lib/workspace/ref_in_text.rb` — Finds pull request, issue and ticket references in a sentence.
- `lib/workspace/commands/go_task.rb` — The task path of `go --here "TEXT"`: adds a task to the running plan.
- `lib/workspace/protected_branch.rb` — Says whether a branch is the default or main checkout's, which `go` must not use.
- `lib/workspace/ssh_host_resolver.rb` — Resolves an ssh remote's host alias with `ssh -G`.
- `lib/workspace/commands/ticket.rb` — `ticket show`: looks up a ticket and its existing workspace.
- `lib/workspace/timed_process.rb` — Runs one command with a time limit and no prompt.
- `lib/workspace/commands/pull_request.rb` — `pr create`: finds or creates the branch's pull request.
- `lib/workspace/workspace_checkout.rb` — Resolves the workspace, checkout path and branch a command works on.
- `lib/workspace/commands/rebase.rb` — `rebase --onto local|update|remote`.
- `lib/workspace/commands/pr_feedback.rb` — `pr feedback`: read-only listing of a pull request's review feedback.
- `lib/workspace/commands/push.rb` — `push`: a safe push with lease rules and pull-request head checks.
- `lib/workspace/gh_pull_requests.rb` — `prune`'s reader of pull requests through `gh`.
- `lib/workspace/context_reader.rb` — Reads a pane's context-window use.
- `lib/workspace/pull_request_feedback.rb` — Read-only reader of a pull request's feedback through `gh`.
- `lib/workspace/pull_request_status.rb` — Read-only `gh pr view` for a branch's pull request.
- `lib/workspace/transcript_summary.rb` — Reads the last assistant message from a Claude Code transcript.
- `lib/workspace/core/workspace_lineage.rb` — Resolves a workspace's parent project from its marker or git common dir.
- `lib/workspace/git_exclude.rb` — Lists paths in a repository's `info/exclude`.
- `lib/workspace/core/agent_provider.rb` — Registry of coding-agent CLIs workspace can monitor.
- `lib/workspace/agent_readiness.rb` — Waits for an agent's pane to be quiet and ready before a prompt is sent.
- `lib/workspace/hook_installer.rb` — Merges workspace's hooks into an agent's settings file.
- `lib/workspace/file_backup.rb` — Copies a file aside before workspace edits it.
- `lib/workspace/prompt_input.rb` — Wraps input and refuses prompts under `--no-input`.
- `lib/workspace/core/duration.rb` — Parses duration strings like `5m` and `1h`.
- `lib/workspace/core/next_action.rb` — Builds the `{action, args, needs}` next-action entries that status documents carry.
- `lib/workspace/core/file_lock.rb` — Advisory `flock` on a sidecar lock file.
- `lib/workspace/core/atomic_file.rb` — Atomic file write through a temp file and rename.
- `lib/workspace/core/locked_json_file.rb` — Locked read-modify-write of a JSON file through `AtomicFile`.
- `lib/workspace/note_path.rb` — The one checker for a note path inside a notes dir.
- `spec/support/boundary_scan.rb` — Spec tooling that scans source text for constant references and process literals.
- `spec/support/boundary_rules.rb` — The dependency-direction rules the architecture guard spec enforces.
- `spec/support/boundary_allow.yml` — The allow-list of existing dependency-direction violations; it only shrinks.
- `spec/support/run_file_reads.rb` — Spec helper that reads and edits a stored workflow run as a mutable hash.
- `script/boundary-baseline` — Rewrites the dependency-direction allow-list from the current tree.
- `spec/unit/dependency_direction_spec.rb` — Checks the tree against the dependency-direction rules and the allow-list.
- `lib/workspace/terminal_text.rb` — The one escaper for text printed to a terminal.

- State tracked in `~/.workspace-state.json`
- Configs installed to `~/.config/tmuxinator/`
- `lib/workspace/bookkeeping_exclude.rb` — Keeps the files workspace writes for its own bookkeeping out of `git status` and review diffs: its `.workspace-backup-*` copies, and a settings file it created.
- `lib/workspace/branch_name_picker.rb` — Asks a headless coding agent for a short branch name for a piece of free text.
- `lib/workspace/byte_size.rb` — Parses byte sizes for config values: a byte count or a number with a KB, MB or GB suffix.
- `lib/workspace/commands/binding.rb` — Binds a tmux pane to a workflow run, a PR review or a library play, so the SessionStart hook can remind the agent in that pane of its subject after a restart, `/clear`, resume or compaction.
- `lib/workspace/commands/capabilities.rb` — Prints what this CLI can do, so a caller can ask instead of comparing version numbers.
- `lib/workspace/commands/claude.rb` — Deactivates and reactivates Claude in project tmux panes.
- `lib/workspace/commands/cleanup.rb` — Detects and removes zombie sessions from state.
- `lib/workspace/commands/config.rb` — Sets, reads, and unsets a config key by dotted key (`workspace config set/get/unset`), so callers don't need to hand-edit YAML.
- `lib/workspace/commands/finish.rb` — Finishes a worktree project: verifies its branch is clean and fully pushed (optionally opening a PR with `gh`), then removes it the same way Commands::Kill does.
- `lib/workspace/commands/focus.rb` — Brings a project's iTerm window to the front, optionally shaking or highlighting it.
- `lib/workspace/commands/groups.rb` — `projects group create|add|list|show`: named groups of repositories ({Workspace::ProjectGroups}).
- `lib/workspace/commands/instructions.rb` — `workspace instructions compose`: prints the instructions built from library packs for the pane and project it is run in.
- `lib/workspace/commands/kill.rb` — Kills a worktree-based workspace project by stopping its session, removing its git worktree, and cleaning up its tmuxinator config.
- `lib/workspace/commands/launch.rb` — `Commands::Launch`: creates a workspace's tmuxinator session and iTerm window, or reattaches to an existing one.
- `lib/workspace/commands/library.rb` — The `workspace library` verbs over named plays, prompts, recipes, agents and skills, in the global store or one project's.
- `lib/workspace/commands/lookup.rb` — Finds workspace project names by worktree path or branch name.
- `lib/workspace/commands/parent.rb` — Prints the parent workspace of the current (or given) workspace.
- `lib/workspace/commands/project_actions.rb` — Project-wide actions: one verb applied to every workspace in a project (a repository's main checkout plus its linked worktrees).
- `lib/workspace/commands/projects.rb` — Lists projects (each repository's main checkout plus its linked worktrees, with the workspaces (tmuxinator configs) that belong to it) and shows one project's local facts.
- `lib/workspace/commands/prune.rb` — Removes worktree-backed workspace projects whose associated GitHub PR is closed or merged.
- `lib/workspace/commands/remove.rb` — Deletes a plain project's generated files: its tmuxinator config, its project settings file and its state entry.
- `lib/workspace/commands/repair.rb` — Rebuilds workspace state from live iTerm windows.
- `lib/workspace/commands/review.rb` — Collects what a person needs to review a coding agent's finished work: `show` for one workspace, `list` for the workspaces of a project that are ready.
- `lib/workspace/commands/run_and_report.rb` — Runs a shell command as a Ruby subprocess, captures stdout/stderr/exit, stores the result via RunResultStore, and returns the RunResult.
- `lib/workspace/commands/snapshot.rb` — Prints everything a UI polls for in one document: every project (or the named workspaces), each member's running state, git facts, agent panes, open questions and pipeline entries, plus the repo-wide locks and dev environment.
- `lib/workspace/commands/start.rb` — Creates a git worktree and launches it as a workspace project.
- `lib/workspace/commands/stop.rb` — Stops workspace projects and their tmux sessions.
- `lib/workspace/config_file.rb` — Reads one config YAML file for `config show/validate --json`, reporting a file that can't be parsed as data (message, line, column) instead of raising, and recording where each key sits so a problem can point at it.
- `lib/workspace/config_report.rb` — Builds the documents behind `workspace config show --json` and `workspace config validate --json`: every {ConfigSchema} key with the value a workspace reads and the layer it comes from, and the problems in the files that workspace reads.
- `lib/workspace/core/config_layering.rb` — The one rule for which config layer a key is read from: the order the layers are consulted in and which one wins.
- `lib/workspace/core/config_resolver.rb` — Reads config keys through the layering rule ({ConfigLayering}) for the readers that act on config.
- `lib/workspace/core/logger.rb` — Minimal debug logger for the workspace CLI.
- `lib/workspace/launch_mode.rb` — Decides whether `launch`, `start` and `doctor` run headless: plain tmux sessions started in the background, with no iTerm2, AppleScript or window-tool involved.
- `lib/workspace/project_agents.rb` — Turns an agent daemon's session snapshot into the compact per-workspace agent facts `workspace projects show` reports.
- `lib/workspace/project_detector.rb` — Detects the current workspace project from the working directory.
- `lib/workspace/project_facts.rb` — Gathers the per-member and per-project facts `workspace projects show` reports: running and headless state, open asks, pipeline entries, the repo-wide locks, the dev environment and each running workspace's agent states.
- `lib/workspace/project_settings.rb` — Reads and writes per-project YAML configuration from ~/.config/workspace/projects/.
- `lib/workspace/push_failure.rb` — Turns the stderr of a failed `git push` into a {Workspace::Error} with a stable code, `details.permanent`, and, for a temporary failure, a `retry` hint.
- `lib/workspace/run_result.rb` — Immutable `RunResult` struct (uuid, project, command, status, stdout, stderr, times) for a watched or direct run.
- `lib/workspace/run_result_store.rb` — Reads and writes run results to ~/.workspace-runs/.
- `lib/workspace/start_file_copies.rb` — Copies the parent project's `start.copy_files` — gitignored config files such as `.env` or `config/database.yml` — from the main checkout into a worktree, once, when `start` sets the worktree up.
- `lib/workspace/version.rb` — `Workspace::VERSION`, the release version string.
- `lib/workspace/warn.rb` — Writes warning messages, colorizing them yellow when the destination is a terminal.
- `lib/workspace/event_log.rb` — Append-only JSONL event log of workspace state and agent activity; the state file is replayed from it.
- `lib/workspace/event_stream.rb` — Reads the lifecycle event log and every agent daemon's hook event file as one stream, and keeps the cursor that resumes it.
- `lib/workspace/events_config.rb` — Reads the global `events:` block, as written by `workspace config set`.
- `lib/workspace/commands/events.rb` — `workspace events`: the lifecycle event log and every agent daemon's hook event file, read as one stream (see {Workspace::EventStream}).
- `lib/workspace/hook_runner.rb` — Executes hook scripts defined in project configuration.
- `lib/workspace/delivery_facts.rb` — Where a branch's commits have got to, from local git only (no fetch, no `gh`): pushed to its upstream, and on the default branch by {Workspace::Git#branch_vs_base}'s one rule.
- `lib/workspace/liveness.rb` — Answers "is this workspace's tmux session still there?" for tracked projects, so `list` and `status` can tell a running workspace from a stale state-file entry.
- `lib/workspace/commands/init.rb` — Sets up workspace: creates the config directories, the global config and the agent hooks.
- `lib/workspace/commands/tile.rb` — Tiles all active windows for a project (base + worktrees) across the screen.
- `lib/workspace/window_positions.rb` — Where each workspace's window last sat, one `window.json` per workspace in its state directory, so a later launch can put the window back.

## Key Details

- No runtime gems/dependencies beyond Ruby stdlib (`optparse`, `open3`, `json`, `fileutils`)
- Constructor injection throughout: `Workspace.build_cli` assembles the dependency graph
- Uses AppleScript for iTerm2 automation
- Uses `window-tool` binary for window positioning
- Templates use `{{PLACEHOLDER}}` syntax for variable substitution
- `lib/workspace.rb` sets `Encoding.default_external` to UTF-8 when it is loaded, so file reads and captured command output are UTF-8 whatever the locale; ARGV and ENV values keep the locale's tag

## Subcommands

init, doctor, launch, start, add, stop, kill, finish, relaunch, restore, focus, list, status, whereis, shell-init, agent, daemon, pipeline, sessions, review, snapshot, session-event, lock, dev, parent, notes, plan, ticket, skills, spine, pr, rebase, push, promote, go, projects, ask, inbox, capabilities, ui, binding, library, instructions, workflow, step, rename, template

## Adding a Subcommand

1. Create `lib/workspace/commands/foo.rb` with a `call` method (or keep it inline in CLI for simple commands)
2. Add `cmd_foo` method in CLI that parses options with OptionParser and delegates
3. Add case branch in `CLI#run`
4. Wire dependencies in `Workspace.build_cli` if using a command object
5. Add `require_relative` in `workspace.rb`
6. Add help text to `main_help` in CLI
7. A new file gets one line (≤300 chars, one sentence) under the matching `###` heading in Project Structure and its full entry in `docs/architecture/<subsystem>.md`

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
- Tests use RSpec, run with `bundle exec rspec`. Serial is the default. CI runs the whole suite on every push; locally, a change runs only the specs it can break (see "Running specs for a change").
- `script/parallel-spec [ARGS...]` runs the suite in parallel with parallel_tests (one process per performance core; about 44s against 232s serial). Each process gets its own short `HOME` and `XDG_*` directory under `/tmp`, and SimpleCov results merge into `coverage/`. Only a whole-suite run (no arguments) uses and refreshes the timings in `tmp/parallel_runtime_rspec.log` (untracked); with arguments, or before a log exists, files are grouped by size. Extra arguments go to `parallel_rspec`.
- Lint with `bundle exec standardrb lib/ spec/`
- `bin/` is for project executables (the public interface) — only `bin/workspace` belongs here
- `script/` is for project-specific dev scripts and tooling (e.g., test helpers, one-off utilities)

### Test organization

Every spec sits in one tier directory, which mirrors `lib/`: `spec/unit/workspace/...`, `spec/integration/workspace/...` or `spec/system/workspace/...` (a spec of the spec tooling itself, such as `spec/unit/spawn_guard_spec.rb`, sits directly under its tier). `spec_helper.rb`, `spec/support/` and `spec/fixtures/` are shared and stay at the top of `spec/`. Reach repo files through `PROJECT_ROOT` (set in `spec_helper.rb`), never through `__dir__`, so a spec can move between tiers.

Shared fakes of the adapters live in `spec/support/fakes/`: `FakeTmux` (for `Tmux`; it replaced `CLITestHelpers::FakeTmux` and the per-spec restart, liveness and sentinel tmux fakes) and `FakeGit` (for `Git`). `spec/unit/fake_contract_spec.rb` holds each to its real class by the accepts-every-call rule in `spec/support/fake_contract.rb` (same required positionals, every real keyword accepted by name or `**`, nothing extra required); a section that adds a shared fake adds one `describe` block there.

Place a new spec by the first rule that fits:

1. It starts any process (`system`, backticks, `Open3`, `spawn`, `fork`, `IO.popen`, `PTY.spawn`, a real `git`, `tmux`, `osascript`, `ruby`, `sh`), even once or from a thread: **system**.
2. It wires two or more real Workspace classes that each have behaviour (a command object over a real tmpdir-backed store, the CLI over real collaborators): **integration**.
   A spec whose collaborators are all doubles, fakes or plain value objects is not integration: when in doubt between the two, pick unit.
3. Otherwise, one class with doubles, fakes or injected runners: **unit**. Unit specs must be fast.

- Temporary directories are not external: unit and integration specs may read and write under `Dir.mktmpdir`.
- A stubbed process call (`allow(Open3).to receive(...)`, an injected runner lambda) starts nothing and is fine in any tier. `and_call_original` on a process call does start one, so that spec is system.
- When a unit-shaped spec needs a few examples that start a process, put those examples in a separate file under `spec/system/` instead of moving the whole file.
- A helper that memoizes a fixture built by running git, such as `RepoTemplate` in `spec/support/repo_template.rb`, is for system specs only: whether it spawns depends on which spec asked first.
- Run one tier with `bundle exec rspec spec/unit` (seconds), `spec/integration`, or `spec/system`. The whole suite runs in CI; "Running specs for a change" says what to run locally.

`spec/support/spawn_guard.rb` enforces the rule. The tier comes from the directory as `type:` metadata, and a `type:` written on a group wins. In a unit or integration example every spawn point is blocked (`SpawnGuard::Violation`, an `Exception`, so `rescue => e` does not catch it) and recorded, and the example fails afterwards even if the code under test caught it with `rescue Exception`. Threads the example starts are checked too. Spawns at load time, in `before(:context)`, or in a thread that outlives its example are not checked, so do not write them. A spec that trips the guard moves to `spec/system/`; there are no exemptions.

### Running specs for a change

Do not run the whole suite while working or before a commit. GitHub Actions runs the whole suite and `standardrb` on every branch push (`.github/workflows/ci.yml`). Locally, run the specs the change can break:

1. List the change set: `git diff --name-only main...HEAD` plus `git status --short` (uncommitted and untracked files).
2. Run every changed or new spec file, and the specs that mirror each changed `lib/` file: `lib/workspace/foo.rb` maps to `spec/*/workspace/foo_spec.rb` and `spec/*/workspace/foo_*_spec.rb` (split and adversarial files share the prefix); `lib/workspace/commands/foo.rb` maps to `spec/*/workspace/commands/foo*_spec.rb`.
3. Find the integration and system specs at risk. Take the constants each changed `lib/` file defines and grep for them: `grep -rlw WorkflowEngine spec/integration spec/system`. Then go one level out: grep `lib/` for the constant to find its direct callers, and grep the integration and system specs for those callers' constants. When the change alters a method signature, a `--json` field, an error code, printed text another class parses, or a file format, follow every caller, not one level. A change inside one private method's body needs only the first level.
4. Some files reach many commands:
   - `lib/workspace/cli.rb`, `help_pages.rb`, `json_envelope.rb`, `output_gate.rb`, `error_codes.rb`, or `build_cli` in `lib/workspace.rb`: add `spec/system/workspace/cli_spec.rb`, `spec/system/workspace_spec.rb`, and the specs that build the CLI (`grep -rlE 'build_cli|CLI\.new' spec/integration spec/system`).
   - A new, renamed or removed verb (a `SUBCOMMANDS` list in `cli.rb` or `cli/*.rb`): also `lib/workspace/shell_init.rb`'s completion word lists and `spec/system/workspace/shell_init_spec.rb`.
   - A file in `spec/support/`: every spec that uses the helper (grep its name).
   - A changed public method signature: `spec/unit/fake_contract_spec.rb`, which holds the spec fakes to the real classes' parameters.
   - A new or changed spec file: add `spec/unit/no_peeking_spec.rb`, which reads every spec as text.
   - `lib/library/play/`, `lib/workflows/`, `lib/templates/`: grep the specs for the pack, preset or template name. `lib/skills/`: also run `script/check-skills`.
   - A new, renamed or removed `lib/` file, or a change to `.claude/CLAUDE.md` or `docs/architecture/`: run `spec/unit/claude_md_size_spec.rb`.
   - Code that a spec runs in a separate `ruby` (or another program that loads gems): also run those system specs with the bundle in its own path, as CI does (`bundler-cache` installs to `vendor/bundle`), so a gem outside the Gemfile cannot load by luck: `BUNDLE_PATH=/tmp/ci-bundle bundle install && BUNDLE_PATH=/tmp/ci-bundle bundle exec rspec FILE...`.
   - `docs/` alone: no specs, unless a spec reads the file (grep `spec/` for its name). For `docs/README.config.md` run `script/generate-config-docs --check`.
5. Run the set in one command: `bundle exec rspec FILE...`, or `script/parallel-spec FILE...` past about 20 files. Lint the changed Ruby files: `bundle exec standardrb FILE...`.
6. Composition-root specs build real collaborators and so exercise their wiring, not just the changed class: when a changed `lib/` file's constant is a collaborator a builder wires (`build_cli`, `build_agentd_parts`, `build_workflow_engine` in `lib/workspace.rb`), also run the matching builder spec (`grep -rl 'build_agentd_parts\|build_workflow_engine\|build_cli' spec/unit spec/integration`).
7. Run the whole suite locally (`script/parallel-spec` with no arguments) only when the change can reach everything: `spec/spec_helper.rb`, `spec/support/spawn_guard.rb`, `Gemfile`, `Gemfile.lock`, `.rspec`, `lib/workspace.rb` outside `build_cli` (requires, encoding), a rename or move across many files, or when the person asks.
8. Report which specs ran and why each was picked. When CI fails on a spec the selection missed, fix the failure and add the rule that would have caught it to this section.

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

- `testing-craftsperson.md` — Test coverage, the specs the change can break (see "Running specs for a change"), and `standardrb` on the changed files; pick it for almost every code change
- `staff-engineer.md` — Architecture and complexity
- `ai-agent-operator.md` — Automation and scriptability (`--json`, exit codes, machine-read output)
- `power-user.md` — Edge cases and extensibility
- `new-user.md` — UX and discoverability (help text, errors, human output)
- `dependency-injection-expert.md` — Constructor injection and `build_cli`
- `ddd-hexagonal-expert.md` — Domain boundaries and adapters

All review agents that run must pass before committing. Address any concerns raised before proceeding.
