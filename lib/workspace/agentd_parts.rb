module Workspace
  # The parts the agent daemon builds for the one workspace it serves, as the
  # builder from {Workspace.build_agentd_parts} returns them: built, none of
  # them started. {Commands::Agent#call} starts them in its own order.
  #
  # @!attribute [r] hook_event_log
  #   @return [Workspace::HookEventLog, nil] where each forwarded hook event is written; nil writes none
  # @!attribute [r] monitor
  #   @return [Workspace::SessionMonitor] the workspace's session monitor
  # @!attribute [r] restart_runner
  #   @return [Workspace::RestartRunner] runs one `restart_agent` on its worker thread
  # @!attribute [r] restart_desk
  #   @return [Workspace::AgentdRestartDesk] checks a `restart_agent` message, claims its pane and starts the worker
  # @!attribute [r] plan_progress_watcher
  #   @return [Workspace::PlanProgressWatcher, nil] records `plan_progress`; nil watches nothing
  # @!attribute [r] spine_owner_report
  #   @return [Workspace::SpineOwnerReport, nil] records a stage owner's finished turn; nil reports nothing
  # @!attribute [r] spine_watcher
  #   @return [Workspace::SpineWatcher, nil] records `spine_changed` for edits made by hand; nil watches nothing
  # @!attribute [r] status_desk
  #   @return [Workspace::AgentStatusDesk] answers `status_request` and `status_post`
  # @!attribute [r] queue_desk
  #   @return [Workspace::PromptQueueDesk] answers `prompt_send` and delivers queued prompts
  # @!attribute [r] recovery_desk
  #   @return [Workspace::AgentRecoveryDesk, nil] recovers a failed turn; nil with recovery off
  # @!attribute [r] handoff_watcher
  #   @return [Workspace::HandoffWatcher] follows up on a stalled handoff
  AgentdParts = Struct.new(:hook_event_log, :monitor, :restart_runner, :restart_desk, :plan_progress_watcher, :spine_owner_report,
    :spine_watcher, :status_desk, :queue_desk, :recovery_desk, :handoff_watcher, keyword_init: true)
end
