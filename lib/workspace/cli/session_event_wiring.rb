module Workspace
  class CLI
    # The one construction of {Commands::SessionEvent} and the collaborators it is given: the lock
    # tracker and enforcer, the workflow `deny:` tripwire, the review and reflection write guards,
    # the session ledger, the delivery log, the hang guard's counter, the session-to-workspace map and the dev-lock release.
    # `build_cli` calls it with the objects it shares with other commands; a caller that shares
    # nothing leaves those keywords out and each is built here. It names only classes that have a
    # file of their own, never anything `lib/workspace.rb` alone defines.
    # A new collaborator's file must also be added to {SessionEventEntry::CLOSURE} (or to one of
    # its deferred lists), which loads it for the fast path, or the fast path cannot build the command.
    class SessionEventWiring
      # @param config [Workspace::Config]
      # @param tmux [Workspace::Tmux]
      # @param input [IO] where the hook payload is read from
      # @param output [IO]
      # @param error_output [IO]
      # @param logger [Workspace::Logger]
      # @param env [Hash] the environment the write guards read
      # @param event_log [#append] records a guard's deny ({EventLog}, or a {Deferred} of one)
      # @param permission_policy_config [Workspace::PermissionPolicyConfig, nil] passed through to the command
      # @param instruction_composer [Workspace::InstructionComposer, nil] passed through to the command
      # @param executable [String] the `bin/workspace` {DevSessionRelease} runs
      # @param lineage [Workspace::WorkspaceLineage, nil] for the lock namespace; needed only when lock_namespace is not given
      # @param pane_bindings [Workspace::PaneBindings, nil] nil builds one over `config.pane_bindings_path`
      # @param lock_namespace [Workspace::LockNamespace, nil] nil builds one over config and lineage
      # @param process_tree [Workspace::ProcessTree, nil] for the lock holder; needed only when lock_holder is not given
      # @param run_liveness [Workspace::RunLiveness, nil] for the lock holder; nil builds one over the run dir
      # @param lock_holder [Workspace::LockHolder, nil] nil builds one over process_tree, run_liveness and tmux
      # @param bound_run [Workspace::BoundRun, nil] nil builds one over pane_bindings and tmux
      # @param run_store [Workspace::WorkflowRunStore, nil] the store {WorkflowDeny} reads; nil builds one with no evidence dir
      # @param session_ledger [Workspace::SessionLedger, nil] nil builds one at `state_dir/ledger.jsonl`
      # @param recovery_stop_marker [Workspace::RecoveryStopMarker, nil] nil builds one over `state_dir`
      # @param delivery_log [Workspace::DeliveryLog, nil] nil builds one at `state_dir/session-event.log`; give it with workspace_for_session
      # @param hang_guard_counter [Workspace::HangGuardCounter, nil] nil builds one at `state_dir/hang-guard.json`
      # @param config_names [#available_projects, nil] the configs {SessionWorkspace} looks through; needed only when workspace_for_session is not given
      # @param workspace_for_session [Workspace::SessionWorkspace, nil] nil builds one whose ambiguity lines go to delivery_log
      # @return [Workspace::Commands::SessionEvent]
      # @raise [ArgumentError] when lineage, process_tree or config_names is missing and the object built from it is not given
      def self.build(config:, tmux:, input:, output:, error_output:, logger:, env:, event_log:, permission_policy_config:, instruction_composer:, executable:,
        lineage: nil, pane_bindings: nil, lock_namespace: nil, process_tree: nil, run_liveness: nil, lock_holder: nil, bound_run: nil, run_store: nil,
        session_ledger: nil, recovery_stop_marker: nil, delivery_log: nil, config_names: nil, workspace_for_session: nil, hang_guard_counter: nil)
        raise ArgumentError, "SessionEventWiring.build needs lineage: when lock_namespace: is not given" unless lock_namespace || lineage
        raise ArgumentError, "SessionEventWiring.build needs process_tree: when lock_holder: is not given" unless lock_holder || process_tree
        raise ArgumentError, "SessionEventWiring.build needs config_names: when workspace_for_session: is not given" unless workspace_for_session || config_names

        pane_bindings ||= PaneBindings.new(path: config.pane_bindings_path, logger: logger, error_output: error_output)
        lock_namespace ||= LockNamespace.new(config: config, lineage: lineage)
        lock_holder ||= LockHolder.new(process_tree: process_tree, run_liveness: run_liveness || RunLiveness.new(dir: config.workflow_runs_dir), tmux: tmux)
        bound_run ||= BoundRun.new(pane_bindings: pane_bindings, tmux: tmux)
        run_store ||= WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, event_errors_path: config.workflow_event_errors_path)
        session_ledger ||= SessionLedger.new(path: File.join(config.state_dir, "ledger.jsonl"), logger: logger)
        recovery_stop_marker ||= RecoveryStopMarker.new(state_dir: config.state_dir)
        delivery_log ||= DeliveryLog.new(path: File.join(config.state_dir, "session-event.log"))
        hang_guard_counter ||= HangGuardCounter.new(path: File.join(config.state_dir, "hang-guard.json"))
        command_pieces = BashCommandPieces.new
        workspace_for_session ||= SessionWorkspace.new(tmux: tmux, project_config: config_names, config: config,
          on_ambiguous: ->(session, names) { delivery_log.record("ambiguous session=#{session} claimed by configs #{names.join(", ")}; using #{names.first}", key: "ambiguous/#{session}") })

        Commands::SessionEvent.new(config: config, tmux: tmux, input: input, output: output, error_output: error_output, logger: logger,
          workspace_for_session: workspace_for_session, delivery_log: delivery_log, permission_policy_config: permission_policy_config, hang_guard_counter: hang_guard_counter, command_pieces: command_pieces,
          session_ambiguous: workspace_for_session.method(:ambiguous?),
          lock_idle_tracker: LockIdleTracker.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger),
          lock_enforcer: LockEnforcer.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger),
          workflow_deny: WorkflowDeny.new(bound_run: bound_run, command_pieces: command_pieces, logger: logger, event_log: event_log, run_store: run_store),
          review_write_guard: ReviewWriteGuard.new(pane_bindings: pane_bindings, tmux: tmux, env: env, event_log: event_log, logger: logger),
          reflection_write_guard: ReflectionWriteGuard.new(pane_bindings: pane_bindings, tmux: tmux, config: config, env: env, event_log: event_log, logger: logger),
          session_ledger: session_ledger, pane_bindings: pane_bindings, instruction_composer: instruction_composer,
          dev_session_release: DevSessionRelease.new(config: config, executable: executable, recovery_marker: recovery_stop_marker, logger: logger))
      end
    end
  end
end
