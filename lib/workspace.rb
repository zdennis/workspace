require "optparse"
require "json"
require "fileutils"
require "time"

# Every file workspace reads and every command's output it captures is UTF-8,
# whatever the locale of the process: with none (cron, an app started by
# launchd, `env -i`) Ruby would tag that text US-ASCII, and the first
# non-ASCII character in a state file, a template or a branch name would
# raise. Set here, when the library is loaded, so `bin/workspace`, the daemon
# it starts and `script/` all get it before anything is read. It does not
# touch text that is already in the process: arguments and environment
# values keep the locale's tag. Bytes that are not UTF-8 are still not UTF-8,
# and fail where they are parsed.
unless Encoding.default_external == Encoding::UTF_8
  # Ruby warns about the assignment when warnings are on; it is meant.
  verbose = $VERBOSE
  $VERBOSE = nil
  Encoding.default_external = Encoding::UTF_8
  $VERBOSE = verbose
end

require_relative "workspace/errors"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
module Workspace
end

require_relative "workspace/version"
require_relative "workspace/help_pages"
require_relative "workspace/help_json"
require_relative "workspace/core/error_codes"
require_relative "workspace/output_gate"
require_relative "workspace/json_envelope"
require_relative "workspace/push_failure"
require_relative "workspace/prompt_input"
require_relative "workspace/warn"
require_relative "workspace/core/id_patterns"
require_relative "workspace/core/template_variables"
require_relative "workspace/core/logger"
require_relative "workspace/config"
require_relative "workspace/core/permission_rules"
require_relative "workspace/core/config_schema"
require_relative "workspace/config_schema_docs"
require_relative "workspace/template_variables_docs"
require_relative "workspace/core/config_layering"
require_relative "workspace/event_log"
require_relative "workspace/tool_input_summary"
require_relative "workspace/hook_event_log"
require_relative "workspace/agent_status_requests"
require_relative "workspace/typing_safety"
require_relative "workspace/idle_prompt_check"
require_relative "workspace/question_closed_check"
require_relative "workspace/prompt_typer"
require_relative "workspace/agent_status_desk"
require_relative "workspace/event_stream"
require_relative "workspace/daemon_watch"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/which"
require_relative "workspace/watch_loop"
require_relative "workspace/skill_harnesses"
require_relative "workspace/skill_source"
require_relative "workspace/detached_spawn"
require_relative "workspace/skills_state"
require_relative "workspace/skill_links"
require_relative "workspace/agent_command_check"
require_relative "workspace/launch_mode"
require_relative "workspace/doctor"
require_relative "workspace/styled_screen"
require_relative "workspace/tmux"
require_relative "workspace/tmux_pane"
require_relative "workspace/pane"
require_relative "workspace/pane_factory"
require_relative "workspace/pane_locator"
require_relative "workspace/pane_bindings"
require_relative "workspace/library_store"
require_relative "workspace/recipe_file"
require_relative "workspace/legacy_tmuxinator_templates"
require_relative "workspace/library"
require_relative "workspace/library_install_dirs"
require_relative "workspace/library_installer"
require_relative "workspace/agent_commands"
require_relative "workspace/agent_executables"
require_relative "workspace/agent_detector"
require_relative "workspace/agent_stopper"
require_relative "workspace/commands_config"
require_relative "workspace/notes_config"
require_relative "workspace/spine_config"
require_relative "workspace/tmuxinator_template_config"
require_relative "workspace/template_validator"
require_relative "workspace/template_in_use"
require_relative "workspace/text_diff"
require_relative "workspace/main_agent"
require_relative "workspace/instruction_composer"
require_relative "workspace/tmuxinator_config_writer"
require_relative "workspace/tmuxinator_backup_store"
require_relative "workspace/tmuxinator_backup_config"
require_relative "workspace/project_config"
require_relative "workspace/protected_branch"
require_relative "workspace/osascript_runner"
require_relative "workspace/ui_app_probe"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_positions"
require_relative "workspace/window_layout"
require_relative "workspace/project_settings"
require_relative "workspace/core/config_resolver"
require_relative "workspace/config_file"
require_relative "workspace/config_report"
require_relative "workspace/tmuxinator_report"
require_relative "workspace/session_workspace"
require_relative "workspace/delivery_log"
require_relative "workspace/process_tree"
require_relative "workspace/agent_daemon_stopper"
require_relative "workspace/liveness"
require_relative "workspace/window_liveness"
require_relative "workspace/agent_readiness"
require_relative "workspace/agent_restart"
require_relative "workspace/core/workspace_lineage"
require_relative "workspace/ref_in_text"
require_relative "workspace/start_ref"
require_relative "workspace/timed_process"
require_relative "workspace/branch_name_picker"
require_relative "workspace/ssh_host_resolver"
require_relative "workspace/tty_processes"
require_relative "workspace/gateway_window_match"
require_relative "workspace/gateway_window_closer"
require_relative "workspace/workspace_checkout"
require_relative "workspace/ticket_source"
require_relative "workspace/project_catalog"
require_relative "workspace/status_scope"
require_relative "workspace/template_selection"
require_relative "workspace/template_status"
require_relative "workspace/template_batch_files"
require_relative "workspace/template_apply"
require_relative "workspace/template_adopt"
require_relative "workspace/project_groups"
require_relative "workspace/agent_snapshot_client"
require_relative "workspace/agent_message_client"
require_relative "workspace/project_agents"
require_relative "workspace/project_facts"
require_relative "workspace/core/next_action"
require_relative "workspace/core/duration"
require_relative "workspace/core/agent_protocol"
require_relative "workspace/core/file_lock"
require_relative "workspace/core/atomic_file"
require_relative "workspace/core/locked_json_file"
require_relative "workspace/terminal_text"
require_relative "workspace/note_path"
require_relative "workspace/shell_safe_path"
require_relative "workspace/byte_size"
require_relative "workspace/events_config"
require_relative "workspace/dev_config"
require_relative "workspace/lock_namespace"
require_relative "workspace/bound_run"
require_relative "workspace/held_locks"
require_relative "workspace/run_liveness"
require_relative "workspace/lock_holder"
require_relative "workspace/lock_audit_log"
require_relative "workspace/lock_store"
require_relative "workspace/lock_config"
require_relative "workspace/lock_idle_tracker"
require_relative "workspace/recovery_stop_marker"
require_relative "workspace/dev_session_release"
require_relative "workspace/lock_reaper"
require_relative "workspace/lock_enforcer"
require_relative "workspace/notifier"
require_relative "workspace/alert_config"
require_relative "workspace/workflow_alerts"
require_relative "workspace/agent_recovery_config"
require_relative "workspace/claude_trust_config"
require_relative "workspace/agentd_config"
require_relative "workspace/handoff_config"
require_relative "workspace/context_reasons"
require_relative "workspace/context_store"
require_relative "workspace/context_reader"
require_relative "workspace/statusline_renderer"
require_relative "workspace/ask_store"
require_relative "workspace/prompt_queue_store"
require_relative "workspace/hang_guard_counter"
require_relative "workspace/work_queue_history"
require_relative "workspace/work_queue_store"
require_relative "workspace/work_queue_starters"
require_relative "workspace/work_queue_advance"
require_relative "workspace/work_queue_desk"
require_relative "workspace/pane_locks"
require_relative "workspace/prompt_queue_desk"
require_relative "workspace/agent_recovery_store"
require_relative "workspace/restart_registry"
require_relative "workspace/restart_runner"
require_relative "workspace/session_monitor_builder"
require_relative "workspace/agent_recovery_steps"
require_relative "workspace/recovery_verdicts"
require_relative "workspace/recovery_facts"
require_relative "workspace/recovery_entry"
require_relative "workspace/recovery_intake"
require_relative "workspace/recovery_confirmer"
require_relative "workspace/recovery_attempt_runner"
require_relative "workspace/recovery_outcomes"
require_relative "workspace/recovery_attempts"
require_relative "workspace/agent_recovery_desk"
require_relative "workspace/agent_recovery_desk_factory"
require_relative "workspace/inbox_store"
require_relative "workspace/inbox_derived"
require_relative "workspace/inbox_acks"
require_relative "workspace/task_store"
require_relative "workspace/pull_request_status"
require_relative "workspace/pull_request_feedback"
require_relative "workspace/transcript_summary"
require_relative "workspace/session_ledger"
require_relative "workspace/transcript_label"
require_relative "workspace/pane_events"
require_relative "workspace/pane_states"
require_relative "workspace/pane_alerts"
require_relative "workspace/pane_screen_rules"
require_relative "workspace/pane_scanner"
require_relative "workspace/pane_view"
require_relative "workspace/session_monitor"
require_relative "workspace/clear_confirmation"
require_relative "workspace/scan_slot_limiter"
require_relative "workspace/core/agent_provider"
require_relative "workspace/agent_labels"
require_relative "workspace/pane_dispatch"
require_relative "workspace/file_backup"
require_relative "workspace/process_group_terminator"
require_relative "workspace/process_holder_stopper"
require_relative "workspace/dev_events"
require_relative "workspace/dev_runner"
require_relative "workspace/run_resources"
require_relative "workspace/git_exclude"
require_relative "workspace/deferred_signals"
require_relative "workspace/checkout_move"
require_relative "workspace/notes_dir"
require_relative "workspace/shell_init"
require_relative "workspace/notes_setup"
require_relative "workspace/start_file_copies"
require_relative "workspace/plan_file"
require_relative "workspace/plan_paused"
require_relative "workspace/notes_carry"
require_relative "workspace/spine_file"
require_relative "workspace/spine_rollup"
require_relative "workspace/spine_evaluator"
require_relative "workspace/spine_facts"
require_relative "workspace/spine_inferred"
require_relative "workspace/spine_tree"
require_relative "workspace/spine_writer"
require_relative "workspace/plan_state"
require_relative "workspace/plan_access"
require_relative "workspace/plan_progress_watcher"
require_relative "workspace/spine_owner_report"
require_relative "workspace/spine_watcher"
require_relative "workspace/handoff_watcher"
require_relative "workspace/hooks_config"
require_relative "workspace/plan_config"
require_relative "workspace/workflow_config"
require_relative "workspace/workflow_source_dirs"
require_relative "workspace/workflow_source_fetcher"
require_relative "workspace/workflow_source_installer"
require_relative "workspace/focus_config"
require_relative "workspace/workflow_defaults"
require_relative "workspace/workflow_branch_inputs"
require_relative "workspace/workflow_seed"
require_relative "workspace/workflow_log_tail"
require_relative "workspace/workflow_extends"
require_relative "workspace/workflow_imports"
require_relative "workspace/review_round_path"
require_relative "workspace/workflow_review_spec"
require_relative "workspace/workflow_fan_out_spec"
require_relative "workspace/workflow_definition"
require_relative "workspace/workflow_argv"
require_relative "workspace/workflow_exec_program"
require_relative "workspace/workflow_lint"
require_relative "workspace/workflow_catalog"
require_relative "workspace/workflow_source"
require_relative "workspace/workflow_router"
require_relative "workspace/workflow_files"
require_relative "workspace/workflow_project"
require_relative "workspace/workflow_run"
require_relative "workspace/workflow_run_store"
require_relative "workspace/bash_command_pieces"
require_relative "workspace/permission_policy"
require_relative "workspace/permission_policy_config"
require_relative "workspace/permission_escalation_desk"
require_relative "workspace/workflow_deny"
require_relative "workspace/review_write_guard"
require_relative "workspace/reflection_write_guard"
require_relative "workspace/workflow_run_files"
require_relative "workspace/workflow_check"
require_relative "workspace/workflow_step_check"
require_relative "workspace/workflow_expect_fail"
require_relative "workspace/workflow_guard"
require_relative "workspace/workflow_require"
require_relative "workspace/workflow_produced"
require_relative "workspace/review_verdict_proof"
require_relative "workspace/workflow_review_tally"
require_relative "workspace/transcript_usage"
require_relative "workspace/workflow_attempt_record"
require_relative "workspace/workflow_budget"
require_relative "workspace/workflow_live_usage"
require_relative "workspace/workflow_deadline"
require_relative "workspace/workflow_downtime"
require_relative "workspace/workflow_evidence"
require_relative "workspace/workflow_attempts"
require_relative "workspace/workflow_reflection"
require_relative "workspace/workflow_audit"
require_relative "workspace/workflow_panes"
require_relative "workspace/workflow_gate_note"
require_relative "workspace/workflow_inputs"
require_relative "workspace/workflow_transitions"
require_relative "workspace/workflow_review_revision"
require_relative "workspace/workflow_run_change"
require_relative "workspace/workflow_reported_status"
require_relative "workspace/workflow_prompt"
require_relative "workspace/workflow_dispatch"
require_relative "workspace/workflow_round_holder"
require_relative "workspace/workflow_review_round"
require_relative "workspace/workflow_review_orphans"
require_relative "workspace/workflow_rejection"
require_relative "workspace/workflow_round_rerun"
require_relative "workspace/workflow_review_summary"
require_relative "workspace/workflow_progress"
require_relative "workspace/workflow_evaluation"
require_relative "workspace/workflow_decisions"
require_relative "workspace/workflow_recovery"
require_relative "workspace/workflow_infra_retry"
require_relative "workspace/workflow_starter"
require_relative "workspace/workflow_engine"
require_relative "workspace/workflow_status"
require_relative "workspace/workflow_needs_me"
require_relative "workspace/workflow_run_loader"
require_relative "workspace/workflow_stats"
require_relative "workspace/workflow_trace"
require_relative "workspace/workflow_graph"
require_relative "workspace/workflow_graph_text"
require_relative "workspace/workflow_graph_mermaid"
require_relative "workspace/workflow_graph_dot"
require_relative "workspace/workflow_graph_ascii"
require_relative "workspace/workflow_graph_states"
require_relative "workspace/workflow_compare"
require_relative "workspace/workflow_insights"
require_relative "workspace/workflow_sim_script"
require_relative "workspace/workflow_simulator"
require_relative "workspace/workflow_run_health"
require_relative "workspace/workflow_sweep_rows"
require_relative "workspace/workflow_sweep_actions"
require_relative "workspace/workflow_review_sweep"
require_relative "workspace/workflow_sweep"
require_relative "workspace/workflow_recover"
require_relative "workspace/sweep_schedule"
require_relative "workspace/workflow_workspace_facts"
require_relative "workspace/workflow_nudger"
require_relative "workspace/bookkeeping_exclude"
require_relative "workspace/hook_installer"
require_relative "workspace/claude_trust"
require_relative "workspace/launch_hook_check"
require_relative "workspace/hook_runner"
require_relative "workspace/core/workspace_name"
require_relative "workspace/workspace_store_rename"
require_relative "workspace/name_migration"
require_relative "workspace/rename_plan"
require_relative "workspace/rename_journal"
require_relative "workspace/project_detector"
require_relative "workspace/commands/sessions"
require_relative "workspace/commands/session_event"
require_relative "workspace/commands/hooks"
require_relative "workspace/commands/init"
require_relative "workspace/commands/claude"
require_relative "workspace/commands/launch"
require_relative "workspace/commands/kill"
require_relative "workspace/commands/pull_request"
require_relative "workspace/commands/rebase"
require_relative "workspace/commands/push"
require_relative "workspace/commands/pr_feedback"
require_relative "workspace/commands/promote"
require_relative "workspace/commands/rename"
require_relative "workspace/commands/finish"
require_relative "workspace/commands/focus"
require_relative "workspace/commands/start"
require_relative "workspace/commands/stop"
require_relative "workspace/commands/tile"
require_relative "workspace/commands/resize"
require_relative "workspace/commands/layout"
require_relative "workspace/commands/repair"
require_relative "workspace/commands/cleanup"
require_relative "workspace/gh_pull_requests"
require_relative "workspace/commands/prune"
require_relative "workspace/commands/remove"
require_relative "workspace/commands/lookup"
require_relative "workspace/commands/update_pane_command"
require_relative "workspace/commands/run"
require_relative "workspace/commands/send"
require_relative "workspace/commands/prompt_queue"
require_relative "workspace/commands/work_queue"
require_relative "workspace/commands/capture"
require_relative "workspace/commands/lock"
require_relative "workspace/commands/dev"
require_relative "workspace/commands/capabilities"
require_relative "workspace/commands/parent"
require_relative "workspace/commands/notes"
require_relative "workspace/commands/plan_dispatch"
require_relative "workspace/commands/plan_task"
require_relative "workspace/commands/plan"
require_relative "workspace/commands/ticket"
require_relative "workspace/commands/skills"
require_relative "workspace/delivery_facts"
require_relative "workspace/goal_state"
require_relative "workspace/commands/goal"
require_relative "workspace/commands/template"
require_relative "workspace/commands/template_backups"
require_relative "workspace/commands/spine"
require_relative "workspace/commands/spine_init"
require_relative "workspace/commands/spine_start"
require_relative "workspace/commands/projects"
require_relative "workspace/commands/groups"
require_relative "workspace/commands/review"
require_relative "workspace/agent_resume_command"
require_relative "workspace/commands/restore"
require_relative "workspace/commands/snapshot"
require_relative "workspace/commands/events"
require_relative "workspace/commands/project_actions"
require_relative "workspace/commands/config"
require_relative "workspace/commands/statusline"
require_relative "workspace/commands/restart_agent"
require_relative "workspace/commands/agent_status"
require_relative "workspace/commands/agent_executables"
require_relative "workspace/commands/ensure_agent"
require_relative "workspace/commands/daemon"
require_relative "workspace/commands/ui"
require_relative "workspace/commands/binding"
require_relative "workspace/commands/library"
require_relative "workspace/commands/instructions"
require_relative "workspace/commands/workflow"
require_relative "workspace/commands/workflow_reflect"
require_relative "workspace/commands/workflow_start"
require_relative "workspace/commands/go"
require_relative "workspace/commands/go_task"
require_relative "workspace/commands/handoff"
require_relative "workspace/commands/ask"
require_relative "workspace/commands/inbox"
require_relative "workspace/commands/wait_until_content"
require_relative "workspace/work_coordinator_client"
require_relative "workspace/pipeline_config"
require_relative "workspace/pipeline_state"
require_relative "workspace/sentinel_poller"
require_relative "workspace/agentd_parts"
require_relative "workspace/agentd_restart_desk"
require_relative "workspace/pipeline_desk"
require_relative "workspace/hook_fanout"
require_relative "workspace/workflow_nudge"
require_relative "workspace/agentd_router"
require_relative "workspace/agentd_socket_server"
require_relative "workspace/commands/agent"
require_relative "workspace/run_result"
require_relative "workspace/run_result_cleaner"
require_relative "workspace/run_result_store"
require_relative "workspace/commands/run_and_report"
require_relative "workspace/cli/invocation"
require_relative "workspace/cli/common"
require_relative "workspace/cli/names"
require_relative "workspace/cli/launcher"
require_relative "workspace/cli/relauncher"
require_relative "workspace/cli/workflow"
require_relative "workspace/cli/agent"
require_relative "workspace/cli/agent_run"
require_relative "workspace/cli/pipeline"
require_relative "workspace/cli/plan_spine"
require_relative "workspace/cli/work_queue"
require_relative "workspace/cli/template"
require_relative "workspace/cli/session_event_wiring"
require_relative "workspace/cli/session_event_entry"
require_relative "workspace/cli"

module Workspace
  # Builds the workflow engine and its phases over one shared {WorkflowRunChange}. `build_cli` and
  # the simulator's `engine_factory` call it, and so do the specs that drive a whole engine.
  #
  # @param store [Workspace::WorkflowRunStore]
  # @param resources [Workspace::RunResources] holds each step's `uses:` for the run
  # @param composer [Workspace::InstructionComposer] builds a step's instructions
  # @param panes [Workspace::WorkflowPanes] binds, finds and types into the run's pane
  # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
  # @param commands_config [Workspace::CommandsConfig] a workspace's `commands.test`/`commands.lint` (its own, else its project's)
  # @param lineage [Workspace::WorkspaceLineage] names a checkout's parent project
  # @param git [Workspace::Git] reads the checkout's branch
  # @param guard [Workspace::WorkflowGuard] records a run's base commit and checks a guarded step against it
  # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
  # @param env_stopper [#call, nil] stops the dev environment a run left running under a lock it
  #   gave up (`run_id:`, `worktree:`), so nobody queues behind an environment no step uses
  # @param event_log [Workspace::EventLog, nil] gets `workflow_changed` and the run's lock events
  # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
  # @param task_store [Workspace::TaskStore, nil] names the workspace's task in the run
  # @param attempt_record [Workspace::WorkflowAttemptRecord, nil] records what each attempt started from and ended with
  #   (default: one reading HEAD through `guard`)
  # @param require_check [Workspace::WorkflowRequire, nil] checks a step's `require:` proofs
  #   (default: one over `guard` and `gate_note`)
  # @param log_tail [Workspace::WorkflowLogTail, nil] reads the end of a failed check's log for `on_fail`'s `log_tail`
  #   (default: a new one)
  # @param alerts [Workspace::WorkflowAlerts, nil] tells a person of a gate, a failure, a stall or a finish through `alerts.notify`
  #   (default: none)
  # @param inbox_for [#call, nil] given a workspace name, its inbox store, for a guard's warning and each review round's item
  #   (`review:<run>:<step>`; default: no item)
  # @param ask_for [#call, nil] given a workspace name, its {AskStore}, for the ask a stated `needs_input` records (default: none)
  # @param workspace_known [#call, nil] given a project name, true when a workspace of that name exists (for `workflow check`'s `--name` hint); nil means none does
  # @param review_round [#call, nil] runs a review round a change registered, given the run id and the round, with the lock given up
  #   (default: none runs, so a reviewed step waits in `reviewing`); `build_cli` gives `review_runner:` instead, so this
  #   and +review_closer+ are for specs that stand in for the delivery
  # @param review_tally [#call, #open_round, nil] makes each round's directory as it starts and decides the round, given `run:`, `step:`
  #   and `round:` ({WorkflowReviewTally}; default: {WorkflowEvaluation::NoReviewTally}, and no directory is made)
  # @param review_closer [#call, nil] closes an ended round's review window, given the run id and the round's "step", "round" and "pane",
  #   with the lock given up (default: none, so the window stays open; specs only, beside `review_runner:`)
  # @param review_revision [#call, nil] computes a round's revision again when it ends, with the lock given up, given `run:`,
  #   `step:` and `stop_when:` ({WorkflowReviewRevision}; default: none, and a round is tallied at once)
  # @param review_runner [#call, nil] given the engine's `change:`, `store:` and `prompt:`, builds the round's delivery
  #   ({WorkflowReviewRound}), which is then the `review_round` and `review_closer` neither of which is given
  #   (default: none)
  # @param round_rerun [Workspace::WorkflowRoundRerun, nil] the round lifecycle progress and evaluation share (default: one over the
  #   engine's change, store, dispatch, attempt record, +review_revision+ and +round_holder+)
  # @param review_summary [Workspace::WorkflowReviewSummary, nil] writes each decided round's `summary.md` and posts its inbox item
  #   (default: one over +inbox_for+)
  # @param round_holder [#call, nil] answers the process that delivers a round a change starts ("pid", "started"), stored on
  #   the round as its `holder` (default: none stored)
  # @param holder_alive [#call, nil] given a round's `holder`, whether that process still runs, so a resume or a tick delivers a
  #   lapsed round again only once its holder is gone (default: none, every holder taken as alive)
  # @param interrupter [#call] presses keys in a pane (`workspace`, `pane`, `keys`) for `pause --interrupt`, the one the
  #   sweep presses through; raises {Workspace::Error} when it can't (default: one that always raises, so a pause
  #   asked to interrupt reports `interrupted: false` and keeps no mark)
  # @param downtime [Workspace::WorkflowDowntime, nil] the machine's recorded downtime, cut from the run, step and round
  #   clocks the engine reads (default: none, so they run on wall time)
  # @param exec_program [#problem] judges argument 1 of each `exec` proof when a run starts (default: {WorkflowExecProgram}, a lookup on this process's PATH)
  # @param transcript [#last_assistant_message] reads a transcript's last assistant message, for the status line a turn ends with
  #   (default: a new {TranscriptSummary})
  # @param clock [#call] returns the current Time
  # @param prompt_writer [#call] writes a step's instructions file, given the path, the text and an +encoding:+, as +File.write+ does
  # @param main_agent [Workspace::MainAgent, nil] reads a project's main agent kind, for the start preflight's
  #   `subagents` refusal (default: nil, which skips that check)
  # @return [Workspace::WorkflowEngine]
  def self.build_workflow_engine(store:, resources:, composer:, panes:, checker:, commands_config:, lineage:, git:, guard:, excludes:, gate_note:,
    env_stopper: nil, workspace_known: nil, event_log: nil, task_store: nil, attempt_record: nil, require_check: nil, log_tail: nil, alerts: nil, inbox_for: nil, ask_for: nil, review_round: nil, review_tally: nil, review_closer: nil, review_revision: nil,
    review_runner: nil, round_rerun: nil, review_summary: nil, round_holder: nil, holder_alive: nil, interrupter: ->(*) { raise Workspace::Error, "cannot interrupt: no key presser was given" }, clock: -> { Time.now },
    prompt_writer: File.method(:write), downtime: nil, exec_program: WorkflowExecProgram, transcript: TranscriptSummary.new, main_agent: nil)
    attempt_record ||= WorkflowAttemptRecord.new(guard: guard, clock: clock)
    require_check ||= WorkflowRequire.new(guard: guard, notes_dir_of: ->(workspace) { gate_note.notes_dir_of(workspace) },
      commands_config: commands_config, checker: checker)
    prompt = WorkflowPrompt.new(composer: composer, git: git, excludes: excludes, prompt_writer: prompt_writer)
    # The change types a step's line through Dispatch, which is built after it.
    dispatch = nil
    change = WorkflowRunChange.new(store: store, attempt_record: attempt_record, deliver: ->(run_id, delivery) { dispatch.deliver(run_id, delivery) },
      alerts: alerts, event_log: event_log)
    dispatch = WorkflowDispatch.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
      guard: guard, env_stopper: env_stopper, event_log: event_log, downtime: downtime, clock: clock)
    if review_runner
      runner = review_runner.call(change: change, store: store, prompt: prompt)
      review_round ||= runner.method(:call)
      review_closer ||= runner.method(:close)
    end
    log_tail ||= WorkflowLogTail.new
    rejection = WorkflowRejection.new(change: change, dispatch: dispatch, log_tail: log_tail)
    round_rerun ||= WorkflowRoundRerun.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record,
      review_revision: review_revision, holder: round_holder, clock: clock)
    review_summary ||= WorkflowReviewSummary.new(inbox_for: inbox_for, clock: clock)
    progress = WorkflowProgress.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes,
      log_tail: log_tail, review_tally: review_tally, guard: guard, round_rerun: round_rerun, review_summary: review_summary,
      rejection: rejection, clock: clock)
    evaluation = WorkflowEvaluation.new(change: change, store: store, progress: progress, panes: panes, checker: checker, require_check: require_check,
      guard: guard, commands_config: commands_config, inbox_for: inbox_for, ask_for: ask_for, review_round: review_round, review_tally: review_tally, review_closer: review_closer, review_revision: review_revision, round_rerun: round_rerun, transcript: transcript, clock: clock)
    starter = WorkflowStarter.new(change: change, store: store, prompt: prompt, dispatch: dispatch,
      lineage: lineage, commands_config: commands_config, guard: guard, gate_note: gate_note, task_store: task_store, workspace_known: workspace_known, exec_program: exec_program, main_agent: main_agent, clock: clock)
    recovery = WorkflowRecovery.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, holder_alive: holder_alive, panes: panes, downtime: downtime, clock: clock)
    decisions = WorkflowDecisions.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
      attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, holder_alive: holder_alive, interrupter: interrupter, recovery: recovery, downtime: downtime, clock: clock)
    WorkflowEngine.new(starter: starter, evaluation: evaluation, decisions: decisions, recovery: recovery)
  end

  # Builds the agent daemon's per-workspace builder. `build_cli` gives it to {Commands::Agent}, and the
  # daemon specs build theirs through it. The builder only constructs; {Commands::Agent#call} starts the parts.
  #
  # @param tmux [Workspace::Tmux] the tmux adapter the desks' panes read and type through
  # @param config [Workspace::Config] path configuration (the prompt queue, pipeline state and hand-off files)
  # @param work_coordinator_client [Workspace::WorkCoordinatorClient] the coordinator the pipeline desk registers and reports with
  # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
  # @param session_monitor_factory [#call] given the workspace name, builds its {Workspace::SessionMonitor}
  # @param event_log [Workspace::EventLog, nil] gets the desks' and the handoff watcher's events
  # @param context_reader [Workspace::ContextReader, nil] reads a pane's context use for the default {Workspace::AgentRestart}
  #   and the restart desk; nil refuses every `restart_agent` as `context_unavailable`
  # @param agent_restart_factory [#call, nil] builds the {Workspace::AgentRestart} that runs one `restart_agent`
  #   message; nil builds the real one
  # @param handoff_typer [Workspace::PromptTyper, Symbol, nil] what the default handoff watcher types through:
  #   +:prompt_typer+ (the default) a {Workspace::PromptTyper} over the workspace's panes and monitor, nil none
  # @param transcript_summary [Workspace::TranscriptSummary] says whether the main agent wrote anything after its Stop
  # @param idle_prompt_check [Workspace::IdlePromptCheck] reads a pane's input box
  # @param pane_bindings [Workspace::PaneBindings, nil] says which run a pane is bound to; a restart for a run
  #   stops typing once that changes
  # @param plan_paused_for [#call, nil] given the workspace name, whether its plan is paused, as the default
  #   handoff watcher's +plan_paused+; nil: never paused
  # @param hook_event_log_factory [#call, nil] given the workspace name, builds the {Workspace::HookEventLog}
  #   each forwarded hook event is written to; nil writes none
  # @param plan_progress_watcher_factory [#call, nil] given the workspace name, builds the
  #   {Workspace::PlanProgressWatcher} that records `plan_progress`; nil watches nothing
  # @param spine_watcher_factory [#call, nil] given the workspace name, builds the
  #   {Workspace::SpineWatcher} that records `spine_changed` for edits made by hand; nil watches nothing
  # @param spine_owner_report_factory [#call, nil] given the workspace name, builds the
  #   {Workspace::SpineOwnerReport} that records `spine_changed` with `change: "owner_finished"` when
  #   a stage owner's turn ends (Stop hook) or its stage is set completed; nil reports nothing
  # @param agent_recovery_desk_factory [#call, nil] given the workspace, its tmux session, the session
  #   monitor, the delivery lock, the event log, a pane-restarting check, the calls that claim and
  #   release a pane (the claim registers the calling thread) and +rebind_queue+ (pane id, agent pid),
  #   builds the {Workspace::AgentRecoveryDesk}, or answers nil when recovery is off or the workspace's
  #   agent isn't Claude Code; nil (the default) never builds one
  # @param agent_status_desk_factory [#call, nil] given the workspace, its tmux session, the session
  #   monitor, the hook event log, the delivery lock and a pane-restarting check, builds the
  #   {Workspace::AgentStatusDesk} that answers `status_request` and `status_post`; nil builds the real one
  # @param prompt_queue_desk_factory [#call, nil] given the workspace, its tmux session, the session
  #   monitor, the delivery lock, a pane-restarting check, the calls that claim and release a
  #   pane for a restart and a pane-recovering check, builds the {Workspace::PromptQueueDesk} that
  #   answers `prompt_send` and delivers queued prompts; nil builds the real one
  # @param handoff_watcher_factory [#call, nil] given the keywords workspace, session_name, session_monitor,
  #   delivery_lock, restarting and event_log, builds the {Workspace::HandoffWatcher} that follows up on a
  #   stalled handoff and takes `handoff_watch`; nil builds the real one
  # @param restart_runner_factory [#call, nil] given the session monitor, builds the {Workspace::RestartRunner};
  #   nil builds the real one
  # @param pipeline_state [Workspace::PipelineState, nil] the pipeline desk's in-flight work items; nil builds one over
  #   the workspace's persisted state file
  # @param sentinel_poller_factory [#call, nil] given +session_name:+, +pane:+, +token:+ and +deadline:+, builds the
  #   {Workspace::SentinelPoller} that watches a pipeline stage; nil builds the real one
  # @param workflow_nudger [Workspace::WorkflowNudger, nil] the shared nudger, wrapped per workspace in a {Workspace::WorkflowNudge}
  #   subscriber of the {Workspace::HookFanout}, that wakes a workflow run when a turn ends in its pane; nil wakes none
  # @param workflow_store [Workspace::WorkflowRunStore, nil] the runs the work queue desk reads; nil builds one over the config's run dirs
  # @param work_queue_desk_factory [#call, nil] given +workspace:+, builds the {Workspace::WorkQueueDesk} that starts the
  #   work queue's pass; nil builds the real one
  # @param permission_policy_config [Workspace::PermissionPolicyConfig, nil] lets each workspace's {Workspace::PermissionEscalationDesk}
  #   know whether a policy is configured; nil builds no such desk
  # @param token_generator [#call] returns a fresh completion token for one stage dispatch
  # @param epoch_generator [#call] returns a fresh epoch for the pipeline desk's registration and each re-registration
  # @param clock [#call] returns the current Time, for stage deadlines and when a turn began
  # @param retry_backoff [Numeric] seconds to wait between status report retries
  # @param logger [Workspace::Logger] debug logger
  # @param error_output [IO] where a restart worker's failure is written
  # @return [Proc] given +workspace:+, +session_name:+, +delivery_lock:+, +registry:+ (the
  #   {Workspace::RestartRegistry}) and +recovering:+ (pane id to whether a recovery holds it), the frozen {Workspace::AgentdParts}; +pipeline_desk:+ is one an earlier call built (nil builds one), and
  #   +pipeline_only: true+ builds the pipeline desk alone (every other member nil), so the daemon can
  #   recover and register its pipeline before the rest are built
  def self.build_agentd_parts(tmux:, config:, work_coordinator_client:, pipeline_config:, session_monitor_factory:, event_log: nil, context_reader: nil, agent_restart_factory: nil,
    handoff_typer: :prompt_typer, transcript_summary: TranscriptSummary.new, idle_prompt_check: IdlePromptCheck.new, pane_bindings: nil,
    plan_paused_for: nil, hook_event_log_factory: nil, plan_progress_watcher_factory: nil, spine_watcher_factory: nil,
    spine_owner_report_factory: nil, agent_recovery_desk_factory: nil, agent_status_desk_factory: nil, prompt_queue_desk_factory: nil,
    handoff_watcher_factory: nil, restart_runner_factory: nil, pipeline_state: nil, sentinel_poller_factory: nil, workflow_nudger: nil,
    workflow_store: nil, work_queue_desk_factory: nil, permission_policy_config: nil,
    token_generator: -> { SecureRandom.hex(4) }, epoch_generator: -> { "wa-#{Commands::Agent.ulid}" }, clock: -> { Time.now }, retry_backoff: 0.5,
    logger: Workspace::Logger.new, error_output: $stderr)
    sentinel_poller_factory ||= ->(session_name:, pane:, token:, deadline:) do
      SentinelPoller.new(tmux: tmux, session_name: session_name, pane: pane, token: token, deadline: deadline,
        clock: clock, logger: logger, error_output: error_output)
    end
    stage_marks = ->(timeout) { [token_generator.call, timeout && clock.call + timeout] }
    work_queue_desk_factory ||= lambda do |workspace:|
      store = WorkQueueStore.new(path: config.work_queue_path(workspace), history: WorkQueueHistory.new(path: config.work_queue_history_path(workspace)))
      WorkQueueDesk.new(workspace: workspace, store: store,
        run_store: workflow_store || WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir),
        executable: File.expand_path("../bin/workspace", __dir__), log_path: ->(name) { config.agent_log_path(name) }, logger: logger)
    end
    pipeline_desk_for = lambda do |workspace, session_name, delivery_lock|
      PipelineDesk.new(workspace: workspace, session_name: session_name, tmux: tmux, config: config, pipeline_config: pipeline_config,
        pipeline_state: pipeline_state || PipelineState.new(pipeline_config: pipeline_config, state_path: config.pipeline_state_path(workspace)),
        client: work_coordinator_client, delivery_lock: delivery_lock, sentinel_poller_factory: sentinel_poller_factory,
        stage_marks: stage_marks, epoch_generator: epoch_generator, retry_backoff: retry_backoff, event_log: event_log, logger: logger, error_output: error_output)
    end
    agent_restart_factory ||= ->(session_name:, delivery_lock:, pipeline_ref:, pane_state:, agent_pid:, pane_kind:,
      delivery_facts: ->(_pane_id) {}, **proof) do
      AgentRestart.new(panes: PaneFactory.new(tmux: tmux, session_name: session_name), context_reader: context_reader, session_name: session_name,
        delivery_lock: delivery_lock, pipeline_ref: pipeline_ref, pane_state: pane_state, agent_pid: agent_pid, pane_kind: pane_kind,
        delivery_facts: delivery_facts, logger: logger, **proof)
    end
    agent_status_desk_factory ||= lambda do |workspace:, session_name:, session_monitor:, hook_event_log:, delivery_lock:, restarting:|
      AgentStatusDesk.new(panes: PaneFactory.new(tmux: tmux, session_name: session_name), workspace: workspace, session_name: session_name, session_monitor: session_monitor,
        hook_event_log: hook_event_log, delivery_lock: delivery_lock, restarting: restarting, logger: logger)
    end
    prompt_queue_desk_factory ||= ->(workspace:, session_name:, session_monitor:, delivery_lock:, restarting:,
      claim_restart:, release_restart:, recovering: ->(_pane_id) { false }) do
      PromptQueueDesk.new(panes: PaneFactory.new(tmux: tmux, session_name: session_name), workspace: workspace, session_name: session_name, session_monitor: session_monitor,
        store: PromptQueueStore.new(path: config.prompt_queue_path(workspace)), delivery_lock: delivery_lock,
        restarting: restarting, claim_restart: claim_restart, release_restart: release_restart,
        recovering: recovering, event_log: event_log, logger: logger)
    end
    handoff_watcher_factory ||= lambda do |workspace:, session_name:, session_monitor:, delivery_lock:, restarting:, event_log:|
      typer = if handoff_typer == :prompt_typer
        PromptTyper.new(panes: PaneFactory.new(tmux: tmux, session_name: session_name), session_monitor: session_monitor, logger: logger)
      else
        handoff_typer
      end
      paused = plan_paused_for ? {plan_paused: plan_paused_for.call(workspace)} : {}
      HandoffWatcher.new(panes: PaneFactory.new(tmux: tmux, session_name: session_name), session_name: session_name, workspace: workspace, session_monitor: session_monitor,
        typer: typer, delivery_lock: delivery_lock, restarting: restarting, event_log: event_log, logger: logger, **paused)
    end

    lambda do |workspace:, session_name:, delivery_lock:, registry:, recovering:, pipeline_desk: nil, pipeline_only: false|
      pipeline_desk ||= pipeline_desk_for.call(workspace, session_name, delivery_lock)
      next AgentdParts.new(pipeline_desk: pipeline_desk).freeze if pipeline_only

      pipeline_ref = pipeline_desk.method(:pipeline_ref_on)
      hook_event_log = hook_event_log_factory&.call(workspace)
      monitor = session_monitor_factory.call(workspace)
      restart_runner = if restart_runner_factory
        restart_runner_factory.call(monitor)
      else
        RestartRunner.new(restart_factory: agent_restart_factory, registry: registry, panes: PaneFactory.new(tmux: tmux, session_name: session_name),
          session_name: session_name, delivery_lock: delivery_lock, pipeline_ref: pipeline_ref,
          monitor: monitor, idle_prompt_check: idle_prompt_check,
          transcript_summary: transcript_summary, pane_bindings: pane_bindings,
          error_output: error_output, logger: logger)
      end
      plan_progress_watcher = plan_progress_watcher_factory&.call(workspace)
      spine_owner_report = spine_owner_report_factory&.call(workspace)
      spine_watcher = spine_watcher_factory&.call(workspace)
      restart_desk = AgentdRestartDesk.new(workspace: workspace, session_name: session_name,
        pane_details: -> { tmux.pane_details(session_name, window: nil) }, monitor: monitor, context_reader: context_reader,
        registry: registry, runner: restart_runner, pipeline_ref: pipeline_ref, logger: logger)
      restarting = ->(pane_id) { registry.held?(pane_id) }
      status_desk = agent_status_desk_factory.call(workspace: workspace, session_name: session_name,
        session_monitor: monitor, hook_event_log: hook_event_log, delivery_lock: delivery_lock, restarting: restarting)
      # A --clear-first delivery holds the pane in the registry from its clear
      # until its text is typed, so restart_agent and status requests keep out.
      queue_desk = prompt_queue_desk_factory.call(workspace: workspace, session_name: session_name,
        session_monitor: monitor, delivery_lock: delivery_lock, restarting: restarting,
        claim_restart: ->(pane_id) { registry.claim_for_queue(pane_id) },
        release_restart: ->(pane_id, token) { registry.release(pane_id, token) },
        recovering: recovering)
      # The recovery desk claims a pane through RestartRegistry#claim_for_recovery on the attempt's own
      # thread, so RestartRegistry#stop_all can kill an attempt; the claim is refused while any claim holds
      # the pane or the daemon is shutting down, and a release matches by the token the claim returned.
      queue_path = config.prompt_queue_path(workspace) if agent_recovery_desk_factory
      recovery_desk = agent_recovery_desk_factory&.call(workspace: workspace, session_name: session_name,
        session_monitor: monitor, delivery_lock: delivery_lock, event_log: event_log,
        restarting: restarting,
        claim_restart: ->(pane_id) { registry.claim_for_recovery(pane_id) },
        release_restart: ->(pane_id, token) { registry.release(pane_id, token) },
        rebind_queue: ->(pane_id, agent_pid) { PromptQueueStore.new(path: queue_path).rebind_agent(pane_id, agent_pid: agent_pid) })
      # A recovery can hold a quiet pane whose agent is stopped, so a follow-up waits for it as for a restart.
      handoff_watcher = handoff_watcher_factory.call(workspace: workspace, session_name: session_name,
        session_monitor: monitor, delivery_lock: delivery_lock, event_log: event_log,
        restarting: ->(pane_id) { restarting.call(pane_id) || recovering.call(pane_id) })
      work_queue_desk = work_queue_desk_factory.call(workspace: workspace)
      escalation_desk = permission_policy_config && PermissionEscalationDesk.new(
        inbox_store: InboxStore.new(path: config.inbox_path("workspace", workspace), scope: "workspace:#{workspace}", error_output: error_output),
        policy_config: permission_policy_config, workspace: workspace, project: nil, monitor: monitor,
        pane_bindings: pane_bindings, tmux: tmux, clock: clock, logger: logger
      )
      hook_fanout = nil
      workflow_nudge = WorkflowNudge.new(workspace: workspace, nudger: workflow_nudger, hook_log: hook_event_log,
        turn_settled: -> { hook_fanout.turn_ended }, clock: clock)
      owner_finished = spine_owner_report && HookFanout::OwnerFinished.new(report: spine_owner_report)
      hook_fanout = HookFanout.new(monitor: monitor, hook_log: hook_event_log, logger: logger,
        subscribers: [handoff_watcher, workflow_nudge, owner_finished, queue_desk, recovery_desk, escalation_desk, work_queue_desk])
      AgentdParts.new(hook_event_log: hook_event_log, monitor: monitor, restart_runner: restart_runner, restart_desk: restart_desk,
        plan_progress_watcher: plan_progress_watcher, spine_owner_report: spine_owner_report, spine_watcher: spine_watcher,
        status_desk: status_desk, queue_desk: queue_desk, recovery_desk: recovery_desk, handoff_watcher: handoff_watcher,
        pipeline_desk: pipeline_desk, work_queue_desk: work_queue_desk, hook_fanout: hook_fanout).freeze
    end
  end

  # Builds the agent daemon over its parts builder: its socket server, the router of each workspace it serves
  # and the Claude pane lookup a coordinator command with no pipeline goes to. `build_cli` calls it, and the
  # daemon specs build theirs through it.
  #
  # @param config [Workspace::Config] path configuration
  # @param tmux [Workspace::Tmux] tmux session operations
  # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration, checked at startup
  # @param parts [#call] the per-workspace builder {.build_agentd_parts} returns
  # @param agent_labels [Workspace::AgentLabels, nil] lets the Claude pane search match the agent label
  # @param agent_commands [Workspace::AgentCommands, nil] the program names that count as an agent in the Claude
  #   pane search; nil knows only the providers' executables
  # @param restart_registry [Workspace::RestartRegistry] the panes being restarted
  # @param signal_trapper [#trap] receives the SIGTERM/SIGINT handler registration
  # @param socket_poll_interval [Numeric] seconds between the socket watcher's passes
  # @param workflow_tick_passes [Integer] the watcher ticks the hook fanout's subscribers (the workflow nudge among them) every this many passes
  # @param current_name [String, nil] the workspace served before {Commands::Agent#call} starts ({Commands::Agent#prepare})
  # @param event_log [Workspace::EventLog, nil] records the daemon's start and stop
  # @param name_migration [Workspace::NameMigration, nil] renames a mixed-case workspace before the socket is claimed
  # @param logger [Workspace::Logger] debug logger
  # @param output [IO] output stream for user-facing messages
  # @param error_output [IO] error output stream for errors
  # @return [Workspace::Commands::Agent]
  def self.build_agent_daemon(config:, tmux:, pipeline_config:, parts:, agent_labels: nil, agent_commands: nil,
    restart_registry: RestartRegistry.new, signal_trapper: Signal, socket_poll_interval: AgentdSocketServer::POLL_INTERVAL,
    workflow_tick_passes: AgentdSocketServer::TICK_PASSES, current_name: nil, event_log: nil,
    name_migration: nil, logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
    socket_server = AgentdSocketServer.new(poll_interval: socket_poll_interval, tick_passes: workflow_tick_passes,
      signal_trapper: signal_trapper, logger: logger, output: output, error_output: error_output)
    router_for = ->(workspace, handlers) { AgentdRouter.new(workspace: workspace, handlers: handlers, logger: logger) }
    claude_pane = lambda do |workspace, session_name|
      TmuxPane.new("Claude Code", tmux: tmux, agent_labels: agent_labels, detector: agent_commands&.detector(workspace)).target(session_name)
    end
    agent = Commands::Agent.new(config: config, tmux: tmux, pipeline_config: pipeline_config, parts: parts,
      socket_server: socket_server, router_for: router_for, claude_pane: claude_pane, restart_registry: restart_registry,
      event_log: event_log, name_migration: name_migration, logger: logger,
      output: output, error_output: error_output)
    agent.prepare(current_name) if current_name
    agent
  end

  # Assembles the full dependency graph and returns a ready-to-run CLI instance.
  #
  # @param output [IO] output stream for user-facing messages
  # @param error_output [IO] error output stream for warnings and errors
  # @param input [IO] input stream for interactive prompts
  # @param env [Hash] environment; `WORKSPACE_NO_INPUT` makes every prompt fail instead of waiting
  # @param logger [Workspace::Logger, nil] debug logger (created automatically if nil)
  # @param launchctl [#call, nil] runs `launchctl` for the sweep schedule: takes an argument array, answers `[output, exit_code]` (nil code: could not run); nil runs the real one
  # @param exit_handler [#exit, nil] receives the process exit; nil uses Kernel (specs pass a recorder)
  # @param sleeper [#call, nil] sleeps the given seconds (`relaunch`'s pause between stop and launch); nil builds one over `sleep`
  # @param editor_launcher [#call, nil] runs the editor of `config edit` and `template edit` given its argv array (no shell), answering true when it exited 0; nil runs `system`
  # @param tmux [Workspace::Tmux, nil] the tmux adapter every collaborator shares; nil builds the real one
  # @param task_store [Workspace::TaskStore, nil] the task store `start`, `finish`, `kill` and `rename` share; nil builds the one over the state directory
  # @param skill_source [Workspace::SkillSource, nil] where skill links and the sweep schedule's program come from; nil builds one over the installation directory
  # @param workflow_source_runner [#call, nil] runs the `gh` calls of `workflow install`: `(argv, chdir:, timeout:)` answering `[stdout, stderr, success]`; nil runs the real one
  # @param osascript [#call, nil] runs the AppleScript `ITerm` and `WindowManager` send: `(script)` answering an `OsascriptRunner::Result`; nil runs the real `osascript`
  # @param ui_osascript [#call, nil] runs the JXA script of `ui status`, the same way; nil runs the real `osascript -l JavaScript`
  # @param detacher [Workspace::DetachedSpawn, nil] starts the background run of a `relaunch` that includes the caller's own workspace; nil builds the real one
  # @return [Workspace::CLI] a fully-wired CLI instance
  def self.build_cli(output: $stdout, error_output: $stderr, input: $stdin, env: ENV, logger: nil, launchctl: nil, exit_handler: nil, editor_launcher: nil, tmux: nil, task_store: nil, skill_source: nil, workflow_source_runner: nil, osascript: nil, ui_osascript: nil, sleeper: nil, detacher: nil)
    input = PromptInput.new(input, no_input: PromptInput.env_truthy?(env))
    # Every collaborator writes through the gate, so a `--json` action can send their text to stderr.
    output = OutputGate.new(output)
    logger ||= Logger.new(output: error_output, enabled: ENV.key?("WORKSPACE_DEBUG"))
    exit_handler ||= Kernel
    config = Config.new
    skill_source ||= SkillSource.new(workspace_dir: config.workspace_dir)
    tmux ||= Tmux.new(config: config, logger: logger)
    task_store ||= TaskStore.new(dir: config.task_dir, error_output: error_output)
    project_settings = ProjectSettings.new(config: config)
    config_resolver = ConfigResolver.new(project_settings: project_settings)
    # One object for the daemon's tick and the sweep, so both beat the same heartbeat.
    workflow_config = WorkflowConfig.new(config_resolver: config_resolver)
    workflow_downtime = WorkflowDowntime.new(heartbeat_path: config.workflow_heartbeat_path, downtime_path: config.workflow_downtime_path,
      downtime_after: -> { workflow_config.downtime_after })
    events_config = EventsConfig.new(config_resolver: config_resolver, error_output: error_output)
    event_log = EventLog.new(config: config, project_settings: project_settings, error_output: error_output, logger: logger,
      compact_threshold: -> { events_config.compact_threshold })
    state = State.new(config: config, event_log: event_log, logger: logger)
    osascript ||= OsascriptRunner.new
    iterm = ITerm.new(config: config, output: output, logger: logger, osascript: osascript)
    window_manager = WindowManager.new(config: config, logger: logger, osascript: osascript)
    git = Git.new(output: output, input: input, logger: logger)
    agent_commands = AgentCommands.new(config_resolver: config_resolver)
    tmuxinator_config_writer = TmuxinatorConfigWriter.new(config: config)
    library = nil # built below over project_config, which resolves its tmuxinator templates through it
    # The `-> { library }` lambda is nil until Library.new below: ProjectConfig must not call it while it is constructed.
    project_config = ProjectConfig.new(config: config, git: git, output: output, agent_commands: agent_commands,
      writer: tmuxinator_config_writer, library: -> { library })
    window_positions = WindowPositions.new(dir: config.state_dir, logger: logger)
    window_layout = WindowLayout.new(window_manager: window_manager, config: config, width_percent: -> { project_settings.load_global.dig("launch", "window_width_percent") }, output: output, error_output: error_output, logger: logger)
    hook_runner = HookRunner.new(project_settings: project_settings, project_config: project_config, output: output, error_output: error_output, logger: logger)
    workspace_name = WorkspaceName.new(project_config: project_config, state: state)
    project_detector = ProjectDetector.new(state: state, project_config: project_config, workspace_name: workspace_name)
    bookkeeping_exclude = BookkeepingExclude.new(git: git, git_exclude: GitExclude.new(git: git))
    file_backup = FileBackup.new(output: output, excluder: bookkeeping_exclude)
    hook_installer = HookInstaller.new(backup: file_backup, output: output, input: input, excluder: bookkeeping_exclude)
    pipeline_config = PipelineConfig.new(config: config)
    launch_mode = LaunchMode.new(project_settings: project_settings)

    daemon_process_tree = ProcessTree.new(logger: logger)
    agent_daemon_stopper = AgentDaemonStopper.new(config: config, process_tree: daemon_process_tree)

    # Pre-build command objects so CLI delegates rather than constructs
    stop_command = Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, window_positions: window_positions,
      gateway_closer: GatewayWindowCloser.new(iterm: iterm, window_manager: window_manager, tmux: tmux, tty_processes: TtyProcesses.new),
      launch_mode: launch_mode, daemon_stopper: agent_daemon_stopper, output: output, error_output: error_output)
    agent_labels = AgentLabels.new(process_tree: ProcessTree.new(logger: logger))
    agent_readiness = AgentReadiness.new(tmux: tmux, process_tree: ProcessTree.new(logger: logger), logger: logger)
    name_migration = NameMigration.new(config: config, project_config: project_config, tmux: tmux, state: state, event_log: event_log,
      project_catalog_factory: -> { ProjectCatalog.new(project_config: project_config, git: git) }, writer: tmuxinator_config_writer)
    ensure_agent_command = Commands::EnsureAgent.new(config: config, pipeline_config: pipeline_config, error_output: error_output,
      name_migration: name_migration)
    pane_locator = PaneLocator.new(tmux: tmux)
    pane_bindings = PaneBindings.new(path: config.pane_bindings_path, logger: logger, error_output: error_output)
    workflow_evidence = WorkflowEvidence.new(dir: config.workflow_evidence_dir)
    workflow_store = WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, evidence: workflow_evidence, event_errors_path: config.workflow_event_errors_path)
    binding_command = Commands::Binding.new(bindings: pane_bindings, locator: pane_locator, tmux: tmux, output: output, runs: workflow_store)
    main_agent = MainAgent.new(project_config: project_config, agent_commands: agent_commands)
    lineage = WorkspaceLineage.new(rev_parse: git.method(:path_of))
    claude_trust_config = ClaudeTrustConfig.new(config_resolver: config_resolver, project_config: project_config, lineage: lineage, error_output: error_output)
    home_dir = env["HOME"].to_s.empty? ? Dir.home : env["HOME"]
    claude_trust = ClaudeTrust.new(env: env, home: home_dir, trust_config: claude_trust_config, main_agent: main_agent, error_output: error_output)
    launch_command = Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, pipeline_config: pipeline_config, agent_ensurer: ensure_agent_command, agent_readiness: agent_readiness, agent_commands: agent_commands, main_agent: main_agent, file_backup: file_backup, writer: tmuxinator_config_writer, event_log: event_log, claude_trust: claude_trust, window_positions: window_positions, restore_enabled: -> { project_settings.load_global.dig("launch", "restore_window_position").to_s != "false" }, binder: binding_command, output: output, error_output: error_output)
    library = Library.new(config: config, lineage: lineage, project_config: project_config,
      template_config: TmuxinatorTemplateConfig.new(config_resolver: config_resolver))
    template_validator = TemplateValidator.new(project_config: project_config)
    template_in_use = TemplateInUse.new(template_config: TmuxinatorTemplateConfig.new(config_resolver: config_resolver), project_config: project_config)
    library_installer = LibraryInstaller.new(git: git, dirs: LibraryInstallDirs.new(config_resolver: config_resolver))
    notes_command = Commands::Notes.new(notes_dir: NotesDir.new(git: git), project_config: project_config, config_resolver: config_resolver,
      git_exclude: GitExclude.new(git: git), output: output)
    notes_setup = NotesSetup.new(notes: notes_command, project_settings: project_settings)
    start_file_copies = StartFileCopies.new(config_resolver: config_resolver)
    # Read through closures: the review command SpineFacts needs, and the workflow store and panes
    # SpineInferred needs, are built further down.
    spine_facts = nil
    spine_inferred = nil
    spine_command = Commands::Spine.new(notes: notes_command, writer: SpineWriter.new, event_log: event_log, lock_dir: config.spine_lock_dir,
      spine_facts: -> { spine_facts }, spine_inferred: -> { spine_inferred }, output: output)
    spine_config = SpineConfig.new(config_resolver: config_resolver)
    spine_init_command = Commands::SpineInit.new(notes: notes_command, library: library, project_config: project_config, git: git, task_store: task_store, spine_config: spine_config, output: output)
    commands_config = CommandsConfig.new(config_resolver: config_resolver)
    instruction_composer = InstructionComposer.new(library: library, lineage: lineage,
      commands_config: commands_config, pane_bindings: pane_bindings, workflow_config: WorkflowConfig.new(config_resolver: config_resolver),
      notes_config: NotesConfig.new(config_resolver: config_resolver),
      dev_config: DevConfig.new(config_resolver: config_resolver), spine: spine_command,
      handoff_config: HandoffConfig.new(config_resolver: config_resolver, error_output: error_output),
      main_agent: main_agent)
    start_ref = StartRef.new(git: git, lineage: lineage)
    ticket_source = TicketSource.new
    skills_command = Commands::Skills.new(harnesses: SkillHarnesses.new(home: home_dir, env: env), source: skill_source,
      links: SkillLinks.new(state_dir: config.state_dir), state: SkillsState.new(dir: config.state_dir), input: input, output: output, error_output: error_output)
    ticket_command = Commands::Ticket.new(git: git, project_config: project_config, start_ref: start_ref, source: ticket_source, output: output, error_output: error_output)
    agent_snapshot_client = AgentSnapshotClient.new(config: config)
    send_command = Commands::Send.new(locator: pane_locator, tmux: tmux, client: agent_snapshot_client, output: output)
    focus_command = Commands::Focus.new(state: state, window_manager: window_manager, tmux: tmux, pane_locator: pane_locator, window_liveness: WindowLiveness.new(window_manager: window_manager), focus_config: FocusConfig.new(config_resolver: config_resolver), output: output, error_output: error_output)
    tile_command = Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    workflow_source_dirs = WorkflowSourceDirs.new(config_resolver: config_resolver, state_dir: config.state_dir)
    workflow_source_installer = WorkflowSourceInstaller.new(config: config, source_dirs: workflow_source_dirs, state_dir: config.state_dir,
      fetcher: WorkflowSourceFetcher.new(runner: workflow_source_runner || WorkflowSourceFetcher.method(:run)))
    init_command = Commands::Init.new(config: config, hook_installer: hook_installer, workflow_installer: workflow_source_installer,
      agent_commands: agent_commands, library: library, output: output, error_output: error_output, input: input)
    repair_command = Commands::Repair.new(state: state, iterm: iterm, window_manager: window_manager, output: output)
    cleanup_command = Commands::Cleanup.new(state: state, window_liveness: WindowLiveness.new(window_manager: window_manager), tmux: tmux, output: output, input: input)
    prune_command = Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command, daemon_stopper: agent_daemon_stopper, event_log: event_log, tmux: tmux, pull_requests: GhPullRequests.new(git: git), locks: name_migration, output: output, error_output: error_output, input: input)
    remove_command = Commands::Remove.new(project_config: project_config, project_settings: project_settings, state: state, tmux: tmux, git: git, file_backup: file_backup, locks: name_migration, output: output, input: input)
    claude_command = Commands::Claude.new(state: state, tmux: tmux, agent_labels: agent_labels, agent_commands: agent_commands, output: output, error_output: error_output)
    lookup_command = Commands::Lookup.new(project_config: project_config, output: output)
    template_status = TemplateStatus.new(library: library, project_config: project_config, writer: tmuxinator_config_writer)
    update_pane_command = Commands::UpdatePaneCommand.new(config: config, project_config: project_config, writer: tmuxinator_config_writer, template_status: template_status, output: output, input: input)
    run_command = Commands::Run.new(
      tmux: tmux,
      agent_labels: agent_labels,
      agent_commands: agent_commands,
      state: state,
      window_manager: window_manager,
      output: output,
      error_output: error_output
    )

    run_result_cleaner = RunResultCleaner.new(
      dir: config.run_results_dir,
      live_projects: -> {
        state.load
        Liveness.new(tmux: tmux).call(state.keys).reject { |_, alive| alive == false }.keys
      },
      logger: logger
    )
    run_result_store = RunResultStore.new(config: config, cleaner: run_result_cleaner)
    run_and_report_command = Commands::RunAndReport.new(run_result_store: run_result_store)
    capture_command = Commands::Capture.new(tmux: tmux, agent_labels: agent_labels, agent_commands: agent_commands, output: output, error_output: error_output)
    wait_until_content_command = Commands::WaitUntilContent.new(tmux: tmux, agent_labels: agent_labels, agent_commands: agent_commands, output: output, error_output: error_output)

    lock_namespace = LockNamespace.new(config: config, lineage: lineage)
    dev_config = DevConfig.new(config_resolver: config_resolver)
    lock_config = LockConfig.new(config_resolver: config_resolver, error_output: error_output)
    # Resolved once, from cwd's project, since a CLI run and the long-lived
    # `agent` daemon it may spawn both belong to a single project.
    cwd_project_name = begin
      lineage.resolve(cwd: Dir.pwd).name
    rescue Workspace::Error
      nil
    end
    ps_timeout = cwd_project_name ? lock_config.ps_timeout_for(cwd_project_name) : ProcessTree::DEFAULT_TIMEOUT
    events_rotate_size = nil
    reap_interval = cwd_project_name ? lock_config.reap_interval_for(cwd_project_name) : LockReaper::DEFAULT_INTERVAL
    process_tree = ProcessTree.new(logger: logger, timeout: ps_timeout)
    run_liveness = RunLiveness.new(dir: config.workflow_runs_dir)
    lock_holder = LockHolder.new(process_tree: process_tree, run_liveness: run_liveness, tmux: tmux)
    sessions_command = Commands::Sessions.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      project_config: project_config, snapshot_client: agent_snapshot_client, output: output, error_output: error_output)
    bound_run = BoundRun.new(pane_bindings: pane_bindings, tmux: tmux)
    session_ledger = SessionLedger.new(path: File.join(config.state_dir, "ledger.jsonl"), logger: logger)
    recovery_stop_marker = RecoveryStopMarker.new(state_dir: config.state_dir)
    delivery_log = DeliveryLog.new(path: File.join(config.state_dir, "session-event.log"))
    permission_policy_config = PermissionPolicyConfig.new(config_resolver: config_resolver, bound_run: bound_run, run_store: workflow_store, logger: logger)
    workspace_for_session = SessionWorkspace.new(tmux: tmux, project_config: project_config, config: config,
      on_ambiguous: ->(session, names) { delivery_log.record("ambiguous session=#{session} claimed by configs #{names.join(", ")}; using #{names.first}", key: "ambiguous/#{session}") })
    session_event_command = CLI::SessionEventWiring.build(config: config, tmux: tmux, input: input, output: output, error_output: error_output, logger: logger, env: env,
      event_log: event_log, permission_policy_config: permission_policy_config, instruction_composer: instruction_composer, executable: File.expand_path("../bin/workspace", __dir__),
      pane_bindings: pane_bindings, lock_namespace: lock_namespace, lock_holder: lock_holder, bound_run: bound_run, session_ledger: session_ledger,
      recovery_stop_marker: recovery_stop_marker, delivery_log: delivery_log, workspace_for_session: workspace_for_session)
    process_group_terminator = ProcessGroupTerminator.new
    lock_command = Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, lineage: lineage,
      terminator: process_group_terminator, dev_config: dev_config, lock_config: lock_config, event_log: event_log,
      bound_run: bound_run, output: output, error_output: error_output)
    dev_events = DevEvents.new(event_log: event_log, lineage: lineage)
    dev_runner = DevRunner.new(liveness: lock_holder, output: output, events: dev_events)
    dev_command = Commands::Dev.new(
      lock_namespace: lock_namespace,
      lock_holder: lock_holder,
      lineage: lineage,
      dev_config: dev_config,
      dev_runner: dev_runner,
      terminator: process_group_terminator,
      tmux: tmux,
      git: git,
      executable: File.expand_path("../bin/workspace", __dir__),
      event_log: event_log,
      bound_run: bound_run,
      dev_events: dev_events,
      hook_runner: hook_runner,
      snapshot_client: agent_snapshot_client,
      session_ledger: session_ledger,
      output: output,
      error_output: error_output
    )
    capabilities_command = Commands::Capabilities.new(config: config, output: output)
    ui_app_probe = UiAppProbe.new(osascript: ui_osascript || OsascriptRunner.new(command: ["osascript", "-l", "JavaScript"]))
    ui_command = Commands::Ui.new(output: output, notes: notes_command, app_probe: ui_app_probe)
    workspace_checkout = WorkspaceCheckout.new(git: git, project_config: project_config, project_detector: project_detector)
    library_command = Commands::Library.new(library: library, output: output, input: input, event_log: event_log,
      installer: library_installer, checkout: workspace_checkout, template_validator: template_validator, template_in_use: template_in_use)
    instructions_command = Commands::Instructions.new(composer: instruction_composer, bindings: binding_command, output: output)
    ask_store_for = ->(workspace) { AskStore.new(path: config.ask_state_path(workspace), error_output: error_output) }
    workflow_run_loader = WorkflowRunLoader.new(store: workflow_store)
    workflow_stats = WorkflowStats.new(store: workflow_store, loader: workflow_run_loader)
    workflow_compare = WorkflowCompare.new(loader: workflow_run_loader)
    daemon_command = Commands::Daemon.new(config: config, project_config: project_config, ensure_agent: ensure_agent_command, version_client: agent_snapshot_client, stopper: agent_daemon_stopper,
      watch_factory: ->(workspace:, run:) { DaemonWatch.new(workspace: workspace, run: run, store: workflow_store, stream: EventStream.new(lifecycle_path: nil, hook_dir: config.hook_events_dir, workspace: workspace)) },
      process_tree: daemon_process_tree, output: output)
    # Built before the engine: the review round waits for its window's agent through it, and a fan_out sibling's
    # author pane is split through it.
    pane_dispatch = PaneDispatch.new(snapshot_client: agent_snapshot_client, sender: send_command, binder: binding_command, library: library,
      runner: run_command, readiness: agent_readiness, main_agent: main_agent, tmux: tmux, project_config: project_config, agent_commands: agent_commands)
    agentd_config = AgentdConfig.new(config_resolver: config_resolver, project_config: project_config,
      lineage: lineage, error_output: error_output)
    workflow_panes = WorkflowPanes.new(config: config, bindings: pane_bindings, tmux: tmux, locator: pane_locator, binder: binding_command,
      snapshot_client: agent_snapshot_client, agent_ensurer: ensure_agent_command, idle_check: IdlePromptCheck.new, transcript: TranscriptSummary.new, error_output: error_output,
      spawner: pane_dispatch, poll_interval_for: agentd_config.method(:poll_interval_for))
    workflow_gate_note = WorkflowGateNote.new(notes: notes_command)
    workflow_guard = WorkflowGuard.new(git_path: Which.path("git") || "git")
    workflow_checker = WorkflowCheck.new
    alert_config = AlertConfig.new(config_resolver: config_resolver, project_config: project_config,
      lineage: lineage, error_output: error_output)
    # Taken under a run's lock, so the inbox's flock is inside it. Nothing takes them the other way round.
    workflow_inbox_for = ->(workspace) { InboxStore.new(path: config.inbox_path("workspace", workspace), scope: "workspace:#{workspace}", error_output: error_output) }
    workflow_review_tally = WorkflowReviewTally.new(proof: ReviewVerdictProof.new(hook_dir: config.hook_events_dir))
    workflow_review_revision = WorkflowReviewRevision.new(guard: workflow_guard, checker: workflow_checker, notes_dir: ->(ws) { notes_command.info(name: ws)["dir"] })
    # The process running the change delivers the round it starts, once the lock is given up.
    round_holder = WorkflowRoundHolder.new(lock_holder: lock_holder)
    review_shell = env["SHELL"].to_s
    review_shell = "/bin/sh" unless review_shell.start_with?("/") && File.executable?(review_shell)
    # One key presser for `pause --interrupt` and the sweep's time limits.
    workflow_interrupter = ->(workspace, pane, keys) { send_command.deliver(name: workspace, pane: pane, keys: keys) }
    workflow_session_names = ->(workspace) { [workspace, tmux.session_name_for(workspace)].uniq }
    # nil is also what a pane that is gone gives (a cancel or a kill), so the record never takes it as
    # proof of anything; its transcript test guards that case. Under the run's lock: 2s at most.
    workflow_server_for = ->(pane) do
      tmux.server_pid_for_pane(pane, timeout: 2)
    rescue
      nil
    end
    workflow_alerts = WorkflowAlerts.new(alert_config: alert_config, log_path: File.join(config.state_dir, "workflow-alerts.log"), error_output: error_output)
    workflow_engine = build_workflow_engine(
      store: workflow_store,
      resources: RunResources.new(lock_namespace: lock_namespace, lock_holder: lock_holder, lock_config: lock_config, terminator: process_group_terminator),
      composer: instruction_composer,
      panes: workflow_panes,
      checker: workflow_checker,
      commands_config: commands_config,
      workspace_known: ->(name) { project_config.existing_name(name) },
      lineage: lineage,
      git: git,
      guard: workflow_guard,
      attempt_record: WorkflowAttemptRecord.new(guard: workflow_guard, ledger: session_ledger, evidence: workflow_evidence,
        session_names: workflow_session_names, server_for: workflow_server_for, run_store: workflow_store),
      require_check: WorkflowRequire.new(guard: workflow_guard, notes_dir_of: workflow_gate_note.method(:notes_dir_of),
        commands_config: commands_config, checker: workflow_checker,
        inbox_for: workflow_inbox_for),
      inbox_for: workflow_inbox_for,
      ask_for: ask_store_for,
      review_tally: workflow_review_tally,
      review_revision: workflow_review_revision,
      review_runner: ->(change:, store:, prompt:) do
        WorkflowReviewRound.new(store: store, change: change, tmux: tmux, panes: workflow_panes, readiness: pane_dispatch, main_agent: main_agent,
          revision: workflow_review_revision, prompt: prompt, round_dirs: workflow_review_tally, holder: round_holder.method(:identity), shell: review_shell,
          error_output: error_output)
      end,
      round_holder: round_holder.method(:identity),
      holder_alive: round_holder.method(:alive?),
      excludes: GitExclude.new(git: git),
      gate_note: workflow_gate_note,
      env_stopper: ->(run_id:, worktree:) { dev_command.down_for_run(run_id, working_dir: worktree) },
      event_log: event_log,
      task_store: task_store,
      interrupter: workflow_interrupter,
      downtime: workflow_downtime,
      alerts: workflow_alerts,
      main_agent: main_agent
    )
    workflow_recovery_entry = ->(workspace, pane) do
      AgentRecoveryStore.new(path: config.agent_recovery_path(workspace)).get(pane)
    rescue Workspace::Error
      nil
    end
    workflow_live_usage = WorkflowLiveUsage.new(dir: File.join(config.workflow_runs_dir, "live"), ledger: session_ledger,
      session_names: workflow_session_names, server_for: workflow_server_for)
    workflow_status = WorkflowStatus.new(store: workflow_store, panes: workflow_panes, snapshot_client: agent_snapshot_client, ask_store_for: ask_store_for,
      gate_note: workflow_gate_note, recovery_entry: workflow_recovery_entry, downtime: workflow_downtime, live_usage: workflow_live_usage)
    workflow_workspace_facts = WorkflowWorkspaceFacts.new(liveness: Liveness.new(tmux: tmux), project_config: project_config, config: config,
      agents: ProjectAgents.new(client: agent_snapshot_client))
    workflow_review_orphans = WorkflowReviewOrphans.new(tmux: tmux, store: workflow_store, panes: workflow_panes)
    sweep_default_stall = -> { workflow_config.default_stall }
    workflow_review_sweep = WorkflowReviewSweep.new(engine: workflow_engine, panes: workflow_panes, interrupter: workflow_interrupter,
      orphans: workflow_review_orphans, holder_alive: round_holder.method(:alive?))
    workflow_sweep = WorkflowSweep.new(store: workflow_store, engine: workflow_engine, panes: workflow_panes,
      interrupter: workflow_interrupter, reviews: workflow_review_sweep, default_stall: sweep_default_stall,
      turn_failed_after: -> { workflow_config.turn_failed_after }, infra_retry_max: -> { workflow_config.infra_retry_max },
      permission_wait_limit: -> { workflow_config.permission_wait_limit }, recovery_entry: workflow_recovery_entry, downtime: workflow_downtime, live_usage: workflow_live_usage,
      log_path: config.sweep_log_path, last_path: config.workflow_sweep_last_path, alerts: workflow_alerts)
    sweep_schedule = SweepSchedule.new(agents_dir: File.join(home_dir, "Library", "LaunchAgents"),
      launchctl: launchctl || ->(args) do
        out, err, ok = TimedProcess.run(["launchctl", *args], chdir: Dir.pwd, timeout: 15)
        [out + err, ok ? 0 : 1]
      rescue SystemCallError, Timeout::Error => e
        [e.message, nil]
      end,
      source: skill_source, ruby: RbConfig.ruby, which: Which.method(:path), uid: Process.uid, log_path: config.sweep_log_path)
    workflow_catalog = WorkflowCatalog.new(config: config, sources: workflow_source_dirs)
    workflow_project = WorkflowProject.new(project_detector: project_detector, project_config: project_config, git: git, start_ref: start_ref, config: config, error_output: error_output)
    workflow_needs_me = WorkflowNeedsMe.new
    protected_branch = ProtectedBranch.new(git: git)
    branch_inputs = WorkflowBranchInputs.new(git: git, start_ref: start_ref, protected_branch: protected_branch, pull_request_status: PullRequestStatus.new)
    tmuxinator_report = TmuxinatorReport.new(config: config, tmux: tmux, agent_commands: agent_commands)
    agent_resume_command = AgentResumeCommand.new(tmuxinator_report: tmuxinator_report, agent_commands: agent_commands)
    workflow_recover = WorkflowRecover.new(store: workflow_store, engine: workflow_engine,
      restore: Commands::Restore.new(ledger: session_ledger, tmux: tmux, pane_bindings: pane_bindings, tmuxinator_report: tmuxinator_report,
        process_tree: process_tree, agent_ensurer: ensure_agent_command, agent_commands: agent_commands,
        resume_command: agent_resume_command, output: StringIO.new, error_output: error_output),
      readiness: agent_readiness, panes: workflow_panes, liveness: Liveness.new(tmux: tmux), project_config: project_config,
      config: workflow_config, session_name: ->(workspace) { tmux.session_name_for(workspace) })
    workflow_infra_retry = WorkflowInfraRetry.new(engine: workflow_engine, store: workflow_store, dispatch: pane_dispatch, lock_holder: lock_holder, agent_commands: agent_commands)
    workflow_reflect_command = Commands::WorkflowReflect.new(store: workflow_store, reflection: WorkflowReflection.new, panes: pane_dispatch, binder: binding_command,
      bindings: pane_bindings, main_agent: main_agent, evidence_dir: config.workflow_evidence_dir, output: output)
    watch_loop = WatchLoop.new(output: output, sleeper: Kernel.method(:sleep))
    workflow_command = Commands::Workflow.new(
      watch_loop: watch_loop,
      infra_retry: workflow_infra_retry,
      source_installer: workflow_source_installer,
      workflow_config: workflow_config,
      branch_inputs: branch_inputs,
      catalog: workflow_catalog,
      files: WorkflowFiles.new(config: config, catalog: workflow_catalog),
      run_files: WorkflowRunFiles.new,
      lint: WorkflowLint.new(library: library, commands_config: commands_config, lineage: lineage, project_config: project_config,
        workflow_config: WorkflowConfig.new(config_resolver: config_resolver), main_agent: main_agent),
      attempts: WorkflowAttempts.new,
      trace: WorkflowTrace.new,
      downtime: workflow_downtime,
      audit: WorkflowAudit.new(attempts: WorkflowAttempts.new, dir: config.workflow_evidence_dir),
      sweep: workflow_sweep,
      recover: workflow_recover,
      sweep_actions: WorkflowSweepActions.new(store: workflow_store, panes: workflow_panes, status: workflow_status),
      schedule: sweep_schedule,
      needs_me: workflow_needs_me,
      stats: workflow_stats,
      compare: workflow_compare,
      insights: WorkflowInsights.new(loader: workflow_run_loader, stats: workflow_stats, compare: workflow_compare),
      step_check: WorkflowStepCheck.new(engine: workflow_engine, checker: workflow_checker),
      simulator: WorkflowSimulator.new(engine_factory: ->(**parts) { build_workflow_engine(**parts) }),
      expect_fail: WorkflowExpectFail.new(lineage: lineage, commands_config: commands_config, checker: workflow_checker),
      engine: workflow_engine,
      status: workflow_status,
      workspace_facts: workflow_workspace_facts,
      store: workflow_store,
      panes: workflow_panes,
      process_tree: process_tree,
      lock_holder: lock_holder,
      output: output,
      input: input,
      error_output: error_output
    )
    workflow_nudger = WorkflowNudger.new(store: workflow_store, panes: workflow_panes, executable: File.expand_path("../bin/workspace", __dir__),
      log_path: ->(workspace) { config.agent_log_path(workspace) }, holder_alive: round_holder.method(:alive?), downtime: workflow_downtime, logger: logger, error_output: error_output)
    kill_command = Commands::Kill.new(git: git, pr_status: PullRequestStatus.new, project_config: project_config, project_settings: project_settings, stop_command: stop_command, window_positions: window_positions, notes: notes_command, project_detector: project_detector, task_store: task_store, event_log: event_log, workflow_runs: workflow_engine, dev: dev_command, tmux: tmux, locks: name_migration, output: output, input: input)
    pull_request_command = Commands::PullRequest.new(git: git, project_config: project_config, project_detector: project_detector, output: output)
    rebase_command = Commands::Rebase.new(git: git, checkout: workspace_checkout, output: output)
    push_command = Commands::Push.new(git: git, checkout: workspace_checkout, pr_status: PullRequestStatus.new, output: output)
    pr_feedback_command = Commands::PrFeedback.new(feedback: PullRequestFeedback.new, checkout: workspace_checkout, output: output)
    finish_command = Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, pull_request: pull_request_command, output: output, error_output: error_output, input: input)
    parent_command = Commands::Parent.new(lineage: lineage, project_config: project_config, output: output)
    project_catalog = ProjectCatalog.new(project_config: project_config, git: git)
    status_scope = StatusScope.new(project_detector: project_detector, catalog: project_catalog)
    hooks_command = Commands::Hooks.new(hook_installer: hook_installer, checkout: workspace_checkout, catalog: project_catalog)
    project_facts = ProjectFacts.new(tmux: tmux, state: state, config: config, lock_namespace: lock_namespace,
      lock_holder: lock_holder, dev: dev_command, agents: ProjectAgents.new(client: agent_snapshot_client),
      git: git, catalog: project_catalog, error_output: error_output)
    project_groups = ProjectGroups.new(config: config, git: git)
    projects_command = Commands::Projects.new(catalog: project_catalog, tmux: tmux, facts: project_facts, output: output, error_output: error_output, groups: project_groups)
    groups_command = Commands::Groups.new(groups: project_groups, projects: projects_command, output: output, error_output: error_output)
    hooks_config = HooksConfig.new(config_resolver: config_resolver, error_output: error_output)
    plan_config = PlanConfig.new(config_resolver: config_resolver, error_output: error_output)
    plan_state = PlanState.new
    plan_access = PlanAccess.new(notes: notes_command, tmux: tmux, event_log: event_log)
    plan_dispatch_command = Commands::PlanDispatch.new(access: plan_access, panes: pane_dispatch, library: library, output: output)
    spine_start_command = Commands::SpineStart.new(spine: spine_command, panes: pane_dispatch, library: library, composer: instruction_composer,
      notes: notes_command, main_agent: main_agent, output: output)
    plan_task_command = Commands::PlanTask.new(access: plan_access, output: output)
    plan_command = Commands::Plan.new(notes: notes_command, access: plan_access, dispatch: plan_dispatch_command, catalog: project_catalog, groups: project_groups,
      plan_state: plan_state, plan_config: plan_config, snapshot_client: agent_snapshot_client, ask_store_for: ask_store_for, task_store: task_store, binder: binding_command, output: output)
    start_command = Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, lineage: lineage, hook_installer: hook_installer, hooks_config: hooks_config, task_store: task_store, event_log: event_log, library: library, library_installer: library_installer, notes_setup: notes_setup, start_file_copies: start_file_copies, instruction_composer: instruction_composer, start_ref: start_ref, main_agent: main_agent, agent_commands: agent_commands, ticket_source: ticket_source, spine_init: spine_init_command, spine_config: spine_config, plan_command: plan_command, excluder: bookkeeping_exclude, output: output, input: input)
    workflow_defaults = WorkflowDefaults.new(config_resolver: config_resolver)
    workflow_start_command = Commands::WorkflowStart.new(
      catalog: workflow_catalog, workflow_defaults: workflow_defaults, engine: workflow_engine, start_ref: start_ref, ticket_source: ticket_source, git: git,
      project_config: project_config, workflow_project: workflow_project, start: start_command, workflow: workflow_command, readiness: agent_readiness, tmux: tmux, agent_commands: agent_commands,
      excludes: GitExclude.new(git: git), ssh_hosts: SshHostResolver.new, router: WorkflowRouter.new(catalog: workflow_catalog, workflow_defaults: workflow_defaults), output: output
    )
    workspace_at = lambda do |path|
      real = CheckoutMove.real_path(path)
      project_config.available_projects.find { |name| (root = project_config.project_root_for(name)) && CheckoutMove.real_path(File.expand_path(root)) == real }
    end
    go_task = Commands::GoTask.new(run_store: workflow_store, plan_task: plan_task_command, access: plan_access, output: output)
    namer_value = lambda do |key|
      lambda do |workspace|
        view = workspace ? config_resolver.view(workspace: workspace, upto: "project") : config_resolver.view(workspace: "global", upto: "global")
        winner = view.resolve(key).winner
        winner ? ConfigSchema.parse(key, winner.value) : ConfigSchema.default(key)
      rescue ArgumentError, ConfigParseError
        ConfigSchema.default(key)
      end
    end
    branch_name_picker = BranchNamePicker.new(
      commands: agent_commands, enabled: namer_value.call("go.branch_namer.enabled"),
      timeout: namer_value.call("go.branch_namer.timeout"), command: namer_value.call("go.branch_namer.command")
    )
    go_command = Commands::Go.new(
      workflow_start: workflow_start_command, workflow: workflow_command, workflow_defaults: workflow_defaults, catalog: workflow_catalog,
      start_ref: start_ref, git: git, project_detector: project_detector, project_config: project_config, go_task: go_task, ticket_source: ticket_source, protected_branch: protected_branch, branch_name_picker: branch_name_picker, output: output
    )
    held_locks = HeldLocks.new(lock_namespace: lock_namespace, lock_holder: lock_holder, bound_run: bound_run, env: env)
    promote_command = Commands::Promote.new(
      checkout_move: CheckoutMove.new(git: git, git_exclude: GitExclude.new(git: git), workspace_name: workspace_at),
      notes_carry: NotesCarry.new(spine_init: spine_init_command), start: start_command, notes: notes_command,
      project_config: project_config, panes: pane_dispatch, spine_init: spine_init_command, spine_config: spine_config,
      plan_command: plan_command, plan_dispatch: plan_dispatch_command, workspace_at: workspace_at, locks: held_locks, event_log: event_log, env: env,
      output: output, error_output: error_output
    )
    template_apply = TemplateApply.new(status: template_status, writer: tmuxinator_config_writer,
      backups: TmuxinatorBackupStore.new(config: config, writer: tmuxinator_config_writer), locks: name_migration,
      project_config: project_config, tmux: tmux, differ: TextDiff.new,
      retention: TmuxinatorBackupConfig.new(config_resolver: config_resolver, error_output: error_output))
    doctor = Doctor.new(config: config, state: state, command_probe: Doctor::CommandProbe.new, app_probe: Doctor::AppProbe.new, hook_installer: hook_installer, hooks_config: hooks_config, project_detector: project_detector, git: git, pipeline_config: pipeline_config, permission_policy_config: permission_policy_config, launch_mode: launch_mode, project_settings: project_settings, plan: plan_command, snapshot_client: agent_snapshot_client, project_catalog: project_catalog, agent_commands: agent_commands, project_config: project_config, main_agent: main_agent, file_backup: file_backup, writer: tmuxinator_config_writer, event_log: event_log, skills: skills_command, library: library, template_validator: template_validator, template_status: template_status, template_apply: template_apply, run_health: WorkflowRunHealth.new(store: workflow_store, liveness: run_liveness, lock_dir: config.lock_dir), review_orphans: workflow_review_orphans, tmux: tmux, daemon_stopper: agent_daemon_stopper, process_tree: daemon_process_tree, sweep_schedule: sweep_schedule, sweep_last_path: config.workflow_sweep_last_path, sweep_log_path: config.sweep_log_path, output: output, env: env)
    events_command = Commands::Events.new(
      stream_factory: -> { EventStream.new(lifecycle_path: config.event_log_file, hook_dir: config.hook_events_dir) }, output: output
    )
    review_command = Commands::Review.new(catalog: project_catalog, git: git, snapshot_client: agent_snapshot_client, task_store: task_store,
      ask_store_for: ask_store_for, session_ledger: session_ledger, transcript_summary: TranscriptSummary.new, pull_request_status: PullRequestStatus.new,
      event_log: event_log, output: output, error_output: error_output)
    spine_facts = SpineFacts.new(git: git, pull_request_status: PullRequestStatus.new(timeout: SpineFacts::GH_TIMEOUT), snapshot_client: agent_snapshot_client,
      review: review_command, ask_store_for: ask_store_for)
    spine_inferred = SpineInferred.new(workflow_store: workflow_store, workflow_panes: workflow_panes, git: git, plan_state: plan_state)
    snapshot_command = Commands::Snapshot.new(catalog: project_catalog, facts: project_facts, tmux: tmux, state: state, config: config,
      snapshot_client: agent_snapshot_client, sessions: sessions_command, git: git, pull_request_status: PullRequestStatus.new,
      ask_store_for: ask_store_for, plan: plan_command, plan_state: plan_state, plan_config: plan_config, task_store: task_store,
      spine: spine_command, spine_facts: spine_facts, output: output, error_output: error_output, groups: project_groups, spine_inferred: spine_inferred)
    goal_command = Commands::Goal.new(snapshot: snapshot_command, catalog: project_catalog, task_store: task_store, workflow_status: workflow_status,
      start_ref: start_ref, plan: plan_command, snapshot_client: agent_snapshot_client, delivery: DeliveryFacts.new(git: git), output: output)
    # Hook output goes to stderr so it never lands in the JSON on stdout.
    json_hook_runner = HookRunner.new(project_settings: project_settings, project_config: project_config, output: error_output, error_output: error_output, logger: logger)
    project_actions_command = Commands::ProjectActions.new(catalog: project_catalog, stop_command: stop_command, kill_command: kill_command,
      state: state, tmux: tmux, git: git, lock_namespace: lock_namespace, lock_holder: lock_holder,
      hook_runner: hook_runner, json_hook_runner: json_hook_runner, output: output, error_output: error_output, input: input)
    config_command = Commands::Config.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, event_log: event_log, project_config: project_config, agent_command_check: AgentCommandCheck.new, project_detector: project_detector, config_resolver: config_resolver, output: output, error_output: error_output)
    config_report = ConfigReport.new(project_settings: project_settings, project_config: project_config, notes_dir: NotesDir.new(git: git), library: library, catalog: workflow_catalog, template_validator: template_validator)
    restore_command = Commands::Restore.new(ledger: session_ledger, tmux: tmux, pane_bindings: pane_bindings, tmuxinator_report: tmuxinator_report,
      process_tree: process_tree, agent_ensurer: ensure_agent_command, agent_commands: agent_commands,
      resume_command: agent_resume_command, output: output, error_output: error_output)

    context_store = ContextStore.new(path: config.context_store_path, logger: logger)
    # One limiter for the reader and the monitors: it bounds how many scans and
    # scrapes run at once, machine-wide, over the slot files under the state
    # directory. A reader's scrape inside a monitor's scan runs under the slot
    # the scan holds, since the slot is re-entrant per thread and directory.
    scan_slots = ScanSlotLimiter.new(dir: File.join(config.state_dir, "scan-slots"), logger: logger)
    context_reader = ContextReader.new(context_store: context_store, project_settings: project_settings,
      tmux: tmux, logger: logger, lock_holder: lock_holder, scan_slots: scan_slots)
    statusline_command = Commands::Statusline.new(context_store: context_store, renderer: StatuslineRenderer.new(git: git, logger: logger),
      project_settings: project_settings, logger: logger, output: output, input: input, terminator: process_group_terminator,
      lock_holder: lock_holder)

    agent_recovery_config = AgentRecoveryConfig.new(config_resolver: config_resolver, project_config: project_config,
      lineage: lineage, error_output: error_output)
    ask_command = Commands::Ask.new(config: config, project_detector: project_detector, alert_config: alert_config,
      pane_sender: send_command, event_log: event_log, output: output, error_output: error_output)
    inbox_store_factory = ->(path:, scope:, error_output:) { InboxStore.new(path: path, scope: scope, error_output: error_output) }
    inbox_derived = InboxDerived.new(snapshot_client: agent_snapshot_client, tmux: tmux,
      ask_store_for: ->(workspace, sink) { AskStore.new(path: config.ask_state_path(workspace), error_output: sink) }, plan: plan_command,
      plan_state: plan_state, plan_config: plan_config, workflow_status: workflow_status, needs_me: workflow_needs_me, lock_namespace: lock_namespace,
      lock_store_for: ->(dir) { LockStore.new(dir: dir, liveness: lock_holder) }, lock_config: lock_config)
    inbox_acks = InboxAcks.new(path: config.inbox_acks_path)
    inbox_command = Commands::Inbox.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
      session_ledger: session_ledger, run_store: workflow_store, store_factory: inbox_store_factory, env: env, input: input, event_log: event_log, derived: inbox_derived, acks: inbox_acks,
      output: output, error_output: error_output, notes: notes_command)

    # Nil with recovery off or for a workspace whose agent isn't Claude Code, so the daemon builds no desk.
    agent_recovery_desk_factory = AgentRecoveryDeskFactory.new(tmux: tmux, config: config, recovery_config: agent_recovery_config,
      agent_commands: agent_commands, process_tree: process_tree, ledger: session_ledger, resume_command: agent_resume_command,
      readiness: agent_readiness, marker: recovery_stop_marker, logger: logger, error_output: error_output,
      transcript: TranscriptSummary.new, stopper: AgentStopper.new(process_tree: process_tree))

    work_coordinator_client = WorkCoordinatorClient.new(
      socket_path: config.work_coordinator_socket,
      status_socket_path: config.work_coordinator_status_socket,
      logger: logger
    )
    # Its own LockHolder: the reaper runs on the monitor thread, and a
    # LockHolder's snapshot scope is per-instance, not per-thread.
    lock_reaper = LockReaper.new(lock_namespace: lock_namespace, lock_holder: LockHolder.new(process_tree: process_tree, run_liveness: run_liveness, tmux: tmux),
      terminator: process_group_terminator, interval: reap_interval, logger: logger, error_output: error_output,
      on_reap: dev_events.method(:reaped))
    session_monitor_builder = SessionMonitorBuilder.new(tmux: tmux, logger: logger, error_output: error_output,
      agent_commands: agent_commands, alert_config: alert_config, agentd_config: agentd_config,
      lock_reaper: lock_reaper, ps_timeout: ps_timeout, event_log: event_log, context_reader: context_reader,
      label_reader: TranscriptLabel.new, task_store: task_store, scan_slots: scan_slots)
    notes_dir_of = ->(ws) { notes_command.info(name: ws)["dir"] }
    agentd_parts = build_agentd_parts(
      tmux: tmux,
      config: config,
      work_coordinator_client: work_coordinator_client,
      pipeline_config: pipeline_config,
      session_monitor_factory: session_monitor_builder,
      event_log: event_log,
      context_reader: context_reader,
      agent_recovery_desk_factory: agent_recovery_desk_factory,
      transcript_summary: TranscriptSummary.new,
      idle_prompt_check: IdlePromptCheck.new,
      pane_bindings: pane_bindings,
      plan_paused_for: ->(workspace) { PlanPaused.new(workspace: workspace, dir_resolver: notes_dir_of) },
      plan_progress_watcher_factory: ->(name) { PlanProgressWatcher.new(workspace: name, path_resolver: plan_command.method(:path_for), event_log: event_log, logger: logger) },
      spine_watcher_factory: ->(name) { SpineWatcher.new(workspace: name, dir_resolver: notes_dir_of, event_log: event_log, logger: logger) },
      spine_owner_report_factory: ->(name) { SpineOwnerReport.new(workspace: name, dir_resolver: notes_dir_of, event_log: event_log, logger: logger) },
      hook_event_log_factory: ->(name) { HookEventLog.new(dir: config.hook_events_dir, workspace: name, boot_id: Commands::Agent.ulid, rotate_threshold: (events_rotate_size ||= events_config.rotate_size), logger: logger) },
      workflow_nudger: workflow_nudger,
      workflow_store: workflow_store,
      permission_policy_config: permission_policy_config,
      logger: logger,
      error_output: error_output
    )
    agent_command = build_agent_daemon(
      config: config,
      tmux: tmux,
      agent_labels: agent_labels,
      agent_commands: agent_commands,
      pipeline_config: pipeline_config,
      parts: agentd_parts,
      event_log: event_log,
      name_migration: name_migration,
      restart_registry: RestartRegistry.new,
      logger: logger,
      output: output,
      error_output: error_output
    )

    restart_agent_command = Commands::RestartAgent.new(config: config, locator: pane_locator, output: output)
    prompt_queue_command = Commands::PromptQueue.new(config: config, locator: pane_locator, event_log: event_log, output: output, error_output: error_output)
    agent_status_command = Commands::AgentStatus.new(client: agent_snapshot_client, locator: pane_locator, tmux: tmux, output: output,
      workspace_for_session: workspace_for_session)
    agent_executables_command = Commands::AgentExecutables.new(executables: AgentExecutables.new(agent_commands: agent_commands, path: env["PATH"]),
      project_config: project_config, output: output)
    handoff_config = HandoffConfig.new(config_resolver: config_resolver, project_config: project_config,
      lineage: lineage, error_output: error_output)
    handoff_command = Commands::Handoff.new(config: config, tmux: tmux, locator: pane_locator, handoff_config: handoff_config,
      restart_agent_command: restart_agent_command, notes: notes_command, binder: binding_command, library: library,
      output: output, error_output: error_output)

    rename_journal = RenameJournal.new(config: config)
    rename_plan = RenamePlan.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes_command,
      notes_dir: NotesDir.new(git: git), run_store: workflow_store, dev_lock: ->(path) { dev_command.lock_held_by?(path) },
      journal: rename_journal.method(:read))
    rename_command = Commands::Rename.new(plan: rename_plan, journal: rename_journal, git: git, config: config, project_config: project_config,
      project_settings: project_settings, tmux: tmux, state: state, notes: notes_command, name_migration: name_migration, task_store: task_store,
      inbox_store_factory: inbox_store_factory, session_ledger: session_ledger, pane_bindings: pane_bindings, event_log: event_log,
      project_catalog_factory: -> { ProjectCatalog.new(project_config: project_config, git: git) }, error_output: error_output,
      writer: tmuxinator_config_writer)

    common = CLI::Common.new(input: input, editor_launcher: editor_launcher)
    working_dir = Dir.pwd
    names = CLI::Names.new(project_config: project_config, project_detector: project_detector, lineage: lineage, working_dir: working_dir, workspace_name: workspace_name)
    launch_hook_check = LaunchHookCheck.new(hook_installer: hook_installer, hooks_config: hooks_config)
    launcher = CLI::Launcher.new(project_config: project_config, launch_command: launch_command, launch_mode: launch_mode, state: state, project_settings: project_settings,
      hook_runner: hook_runner, common: common, working_dir: working_dir, library: library, instruction_composer: instruction_composer, name_migration: name_migration,
      hook_check: launch_hook_check)
    relauncher = CLI::Relauncher.new(stop_command: stop_command, hook_runner: hook_runner, launcher: launcher, state: state, sleeper: sleeper || ->(seconds) { sleep(seconds) }, tmux: tmux,
      detacher: detacher || DetachedSpawn.new, program: [RbConfig.ruby, File.join(SkillSource.stable_dir(config.workspace_dir), "bin", "workspace")], log_dir: config.relaunch_log_dir,
      processes: lock_holder)
    workflow_family = CLI::Workflow.new(workflow_command: workflow_command, workflow_reflect_command: workflow_reflect_command, workflow_start_command: workflow_start_command, workflow_project: workflow_project,
      status_scope: status_scope, config: config, project_config: project_config, project_detector: project_detector, git: git, launch_mode: launch_mode,
      common: common, names: names, input: input, working_dir: working_dir, launcher: launcher)
    agent_client = AgentMessageClient.new(config: config)
    agent_run_family = CLI::AgentRun.new(config: config, agent_client: agent_client, restart_agent_command: restart_agent_command,
      send_command: send_command, prompt_queue_command: prompt_queue_command, handoff_command: handoff_command,
      project_detector: project_detector, common: common, names: names, working_dir: working_dir)
    agent_family = CLI::Agent.new(agent_command: agent_command, ensure_agent_command: ensure_agent_command, daemon_command: daemon_command,
      sessions_command: sessions_command, review_command: review_command, agent_status_command: agent_status_command,
      agent_executables_command: agent_executables_command, agent_run: ->(args, invocation) { agent_run_family.prompt(args, invocation) },
      project_detector: project_detector, common: common, names: names, working_dir: working_dir)
    pipeline_family = CLI::Pipeline.new(config: config, agent_client: agent_client, common: common, names: names)
    template_selection = TemplateSelection.new(status_scope: status_scope, catalog: project_catalog, project_config: project_config)
    template_command = Commands::Template.new(library: library, project_config: project_config, writer: tmuxinator_config_writer,
      template_validator: template_validator, differ: TextDiff.new, config_command: config_command,
      selection: template_selection,
      status: template_status, template_in_use: template_in_use, tmuxinator_dir: config.tmuxinator_dir,
      backups: TmuxinatorBackupStore.new(config: config, writer: tmuxinator_config_writer),
      adopt: TemplateAdopt.new(library: library, project_config: project_config, writer: tmuxinator_config_writer, main_agent: main_agent, locks: name_migration),
      apply: template_apply,
      output: output, error_output: error_output)
    template_backups_command = Commands::TemplateBackups.new(backups: TmuxinatorBackupStore.new(config: config, writer: tmuxinator_config_writer),
      selection: template_selection, locks: name_migration, project_config: project_config, writer: tmuxinator_config_writer,
      retention: TmuxinatorBackupConfig.new(config_resolver: config_resolver, error_output: error_output), library: library, template_in_use: template_in_use, output: output)
    template_family = CLI::Template.new(template_command: template_command, backups_command: template_backups_command, relauncher: relauncher, common: common, names: names, working_dir: working_dir)
    plan_spine_family = CLI::PlanSpine.new(plan_command: plan_command, plan_dispatch_command: plan_dispatch_command, plan_task_command: plan_task_command,
      spine_command: spine_command, spine_init_command: spine_init_command, spine_start_command: spine_start_command, goal_command: goal_command,
      status_scope: status_scope, project_detector: project_detector, launcher: launcher, common: common, names: names, working_dir: working_dir)

    work_queue_history_for = ->(workspace) { WorkQueueHistory.new(path: config.work_queue_history_path(workspace)) }
    work_queue_store_for = lambda do |workspace|
      WorkQueueStore.new(path: config.work_queue_path(workspace), history: work_queue_history_for.call(workspace), workspace: workspace, event_log: event_log)
    end
    work_queue_starters = WorkQueueStarters.new(workflow: workflow_command, workflow_start: workflow_start_command, go: go_command,
      workflow_project: workflow_project, catalog: workflow_catalog)
    work_queue_advance = WorkQueueAdvance.new(store_factory: work_queue_store_for, run_store: workflow_store, starters: work_queue_starters.to_h,
      lock_holder: lock_holder, status: workflow_status)
    work_queue_command = Commands::WorkQueue.new(store_factory: work_queue_store_for, history_factory: work_queue_history_for, advance: work_queue_advance,
      decisions: workflow_engine, run_store: workflow_store, checkout: workspace_checkout, go: go_command, status_scope: status_scope,
      agent_ensurer: ensure_agent_command, agent_running: config.method(:agent_running?), watch_loop: watch_loop, working_dir: working_dir, output: output, error_output: error_output, input: input)

    work_queue_family = CLI::WorkQueue.new(work_queue_command: work_queue_command, common: common)

    CLI.new(
      common: common,
      names: names,
      launcher: launcher,
      relauncher: relauncher,
      families: {workflow: workflow_family, agent: agent_family, agent_run: agent_run_family, pipeline: pipeline_family, plan_spine: plan_spine_family, template: template_family, work_queue: work_queue_family},
      working_dir: working_dir,
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
      workspace_name: workspace_name,
      launch_command: launch_command,
      kill_command: kill_command,
      rename_command: rename_command,
      finish_command: finish_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      repair_command: repair_command,
      cleanup_command: cleanup_command,
      prune_command: prune_command,
      remove_command: remove_command,
      claude_command: claude_command,
      lookup_command: lookup_command,
      update_pane_command: update_pane_command,
      run_command: run_command,
      run_result_store: run_result_store,
      run_and_report_command: run_and_report_command,
      capture_command: capture_command,
      wait_until_content_command: wait_until_content_command,
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      notes_command: notes_command,
      notes_setup: notes_setup,
      claude_trust: claude_trust,
      ticket_command: ticket_command,
      skills_command: skills_command,
      pull_request_command: pull_request_command,
      rebase_command: rebase_command,
      push_command: push_command,
      pr_feedback_command: pr_feedback_command,
      promote_command: promote_command,
      projects_command: projects_command,
      capabilities_command: capabilities_command,
      ui_command: ui_command,
      binding_command: binding_command,
      library_command: library_command,
      library: library,
      instructions_command: instructions_command,
      instruction_composer: instruction_composer,
      workflow_start_command: workflow_start_command,
      go_command: go_command,
      restore_command: restore_command,
      snapshot_command: snapshot_command,
      events_command: events_command,
      project_actions_command: project_actions_command,
      groups_command: groups_command,
      session_event_command: session_event_command,
      hooks_command: hooks_command,
      config_command: config_command,
      config_report: config_report,
      tmuxinator_report: tmuxinator_report,
      statusline_command: statusline_command,
      ask_command: ask_command,
      inbox_command: inbox_command,
      launch_mode: launch_mode,
      liveness: Liveness.new(tmux: tmux),
      window_liveness: WindowLiveness.new(window_manager: window_manager),
      name_migration: name_migration,
      exit_handler: exit_handler,
      logger: logger,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
