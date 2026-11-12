# Builds a Commands::Agent over parts made by Workspace.build_agentd_parts, so the daemon specs build
# their parts as build_cli does. A keyword build_agentd_parts takes (a part's factory, which replaces
# that part with an example's fake, or a sub-part: agent_restart_factory, context_reader, handoff_typer)
# goes to it unchanged; the rest go to Commands::Agent, and the ones both take to both.
module AgentdPartsHelper
  PARTS_KEYWORDS = %i[tmux config session_monitor_factory event_log context_reader agent_restart_factory handoff_typer
    transcript_summary idle_prompt_check pane_bindings plan_paused_for hook_event_log_factory plan_progress_watcher_factory
    spine_watcher_factory spine_owner_report_factory agent_recovery_desk_factory agent_status_desk_factory
    prompt_queue_desk_factory handoff_watcher_factory restart_runner_factory logger error_output].freeze
  SHARED_KEYWORDS = %i[tmux config event_log context_reader logger error_output].freeze

  def build_agentd(**given)
    agent_given = given.reject { |key, _| PARTS_KEYWORDS.include?(key) && !SHARED_KEYWORDS.include?(key) }
    Workspace::Commands::Agent.new(parts: Workspace.build_agentd_parts(**given.slice(*PARTS_KEYWORDS)), **agent_given)
  end
end

RSpec.configure { |config| config.include AgentdPartsHelper }
