module Workspace
  # The stable `code` values in `--json` error envelopes. A code never changes
  # meaning; renaming or repurposing one is a `schema_version` bump. Documented
  # in docs/README.json.md; a spec checks that every code a raise site names
  # is listed here and in that file.
  module ErrorCodes
    REGISTRY = {
      "error" => "Any failure without a more specific code.",
      "usage" => "A bad option, a missing or extra argument, or an unknown subcommand.",
      "unknown_workspace" => "The named workspace isn't known.",
      "not_in_workspace" => "No workspace could be detected from the working directory.",
      "no_daemon" => "No agent daemon is running for the workspace.",
      "connection_failed" => "The agent daemon's socket refused or dropped the connection.",
      "unreadable_reply" => "The agent daemon's reply couldn't be read.",
      "unsaved_work" => "The worktree has uncommitted changes or unpushed commits.",
      "unsaved_unknown" => "git couldn't tell whether the worktree has unsaved work.",
      "not_submitted" => "Text reached the pane but wasn't confirmed submitted; check before resending.",
      "config_parse" => "A config file exists but can't be parsed as a YAML mapping.",
      # Codes the agent daemon puts in its replies; `agent-run` passes them through.
      "malformed_message" => "The daemon couldn't parse the request.",
      "internal_error" => "The daemon failed while handling the request.",
      "wrong_workspace" => "The request named a different workspace than the daemon's.",
      "unknown_type" => "The daemon doesn't know the request type.",
      "no_active_pipeline" => "No pipeline work item is in flight.",
      "stale_token" => "The pipeline token no longer matches the in-flight item.",
      "no_next_stage" => "The pipeline has no stage after the current one.",
      "not_delivered" => "The text never reached the pane; safe to resend.",
      "missing_prompt" => "restart needs a non-empty prompt.",
      "missing_pane" => "restart needs a pane.",
      "bad_pane" => "The pane reference isn't a pane id, window.pane, or index.",
      "bad_timeout" => "The timeout isn't a number of seconds in range.",
      "wrong_session" => "The pane belongs to another tmux session.",
      "no_such_pane" => "No pane matches the reference.",
      "pane_gone" => "The pane closed before or during the restart.",
      "pane_busy" => "The pane didn't go quiet in time; nothing was typed.",
      "pane_in_pipeline" => "A pipeline stage is running on the pane; pass force to restart it.",
      "not_an_agent" => "The pane is running a shell, not a coding agent.",
      "unsupported_agent" => "The pane's agent can't be restarted.",
      "context_unavailable" => "The agent can't report context usage, so /clear can't be confirmed.",
      "context_unknown" => "The agent's context usage couldn't be read.",
      "clear_not_confirmed" => "/clear was typed but a new conversation didn't appear.",
      "restart_in_progress" => "A restart is already running on the pane.",
      "agent_stopped" => "The agent stopped during the restart."
    }.freeze

    # @param code [String]
    # @return [Boolean] whether the registry lists the code
    def self.known?(code)
      REGISTRY.key?(code)
    end
  end
end
