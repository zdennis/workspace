# frozen_string_literal: true

require "json"

module Workspace
  # Runs one +restart_agent+ on its worker thread and reports how it ended: on
  # the caller's connection when it waited, and on the daemon's stderr when it
  # failed, since a caller that didn't wait has nowhere else to hear about it.
  #
  # A worker killed by {RestartRegistry#stop_all} says so on stderr and to a
  # waiting caller, including whether /clear was already typed, since that
  # leaves the pane cleared with no prompt.
  class RestartRunner
    # @param restart_factory [#call] builds the {Workspace::AgentRestart} (keyword arguments)
    # @param registry [Workspace::RestartRegistry] releases the pane's claim when the run ends
    # @param tmux [#capture_screen_styled]
    # @param session_name [String] the tmux session the pane is in
    # @param delivery_lock [Mutex]
    # @param pipeline_ref [#call] pane index to the work item running on it, or nil
    # @param session_monitor [Workspace::SessionMonitor, nil]
    # @param idle_prompt_check [Workspace::IdlePromptCheck]
    # @param transcript_summary [Workspace::TranscriptSummary]
    # @param pane_bindings [Workspace::PaneBindings, nil]
    # @param error_output [IO]
    # @param logger [#debug]
    def initialize(restart_factory:, registry:, tmux:, session_name:, delivery_lock:, pipeline_ref:, session_monitor:,
      idle_prompt_check:, transcript_summary:, pane_bindings:, error_output:, logger: Workspace::Logger.new)
      @restart_factory = restart_factory
      @registry = registry
      @tmux = tmux
      @session_name = session_name
      @delivery_lock = delivery_lock
      @pipeline_ref = pipeline_ref
      @session_monitor = session_monitor
      @idle_prompt_check = idle_prompt_check
      @transcript_summary = transcript_summary
      @pane_bindings = pane_bindings
      @error_output = error_output
      @logger = logger
    end

    # @param started [Hash] the "started" reply (+"pane"+, +"pane_id"+)
    # @param prompt [String] typed after the clear
    # @param force [Boolean]
    # @param timeout [Numeric] how long the clear may take to confirm
    # @param client [#puts, #close, nil] the connection of a caller that waits
    # @param run_id [String, nil] a workflow run the pane must stay bound to
    # @return [void]
    def run(started, prompt, force, timeout, client, run_id: nil)
      pane_id = started["pane_id"]
      restart = nil
      finished = false
      result = begin
        restart = @restart_factory.call(
          session_name: @session_name,
          delivery_lock: @delivery_lock,
          pipeline_ref: @pipeline_ref,
          pane_state: ->(id) { @session_monitor&.restart_state(id) },
          agent_pid: ->(id) { @session_monitor&.agent_pid(id) },
          pane_kind: ->(id) { @session_monitor&.pane_kind(id) },
          delivery_facts: ->(id) { @session_monitor&.delivery_facts(id) },
          turn_over: method(:main_turn_missing),
          screen_ready: ->(id) { @idle_prompt_check.refusal(@session_monitor&.typing_facts(id), @tmux.capture_screen_styled(id)) },
          subagents_running: ->(id) { @session_monitor&.background_subagents(id) },
          run_bound: method(:pane_bound_to_run?)
        )
        restart.call(pane_id: pane_id, prompt: prompt, force: force, confirm_timeout: timeout, run_id: run_id, waiting: !client.nil?)
      rescue => e
        {"ok" => false, "error" => "internal_error", "message" => e.message}
      end
      finished = true
      result = {"pane" => started["pane"]}.merge(result)
      @error_output.puts "workspace agent: restart_agent for pane #{started["pane"]}: #{result["message"]}" unless result["ok"]
      # Released before the caller hears the outcome, so a follow-up sent
      # the moment it does isn't refused as already running.
      @registry.release(pane_id)
      reply_to(client, result)
    ensure
      report_stopped(started, restart, client) unless finished
      begin
        client&.close
      rescue IOError, SystemCallError
        nil
      end
      @registry.release(pane_id)
    end

    private

    # What keeps a pane's main turn from being proven over, by name: the monitor's
    # evidence, then what the transcript holds after the Stop. nil once proven.
    def main_turn_missing(pane_id)
      evidence = @session_monitor&.main_turn_evidence(pane_id)
      return "no_monitor" unless evidence
      return evidence[:missing] if evidence[:missing]

      found = @transcript_summary.main_activity_after?(evidence[:transcript_path], evidence[:since])
      found && "transcript_activity:#{found}"
    end

    def pane_bound_to_run?(pane_id, run_id)
      entry = @pane_bindings&.binding_for(pane_id)
      !entry.nil? && entry["kind"] == "run" && entry["id"] == run_id
    end

    def report_stopped(started, restart, client)
      typed = (restart.respond_to?(:cleared?) && restart.cleared?) ?
        "/clear was typed but the prompt may not have been" : "nothing was typed"
      message = "stopped by shutdown; #{typed}"
      @error_output.puts "workspace agent: restart_agent for pane #{started["pane"]}: #{message}"
      reply_to(client, {"ok" => false, "error" => "agent_stopped", "message" => message,
                        "pane" => started["pane"], "pane_id" => started["pane_id"]})
    end

    def reply_to(client, payload)
      client&.puts(payload.to_json)
      nil
    rescue SystemCallError, IOError => e
      @logger.debug { "no one was listening for the reply: #{e.message}" }
      nil
    end
  end
end
