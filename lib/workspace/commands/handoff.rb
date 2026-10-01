require "socket"
require "json"
require "shellwords"

module Workspace
  module Commands
    # `workspace handoff check|new` — replaces `~/bin/agent-context check|new`.
    #
    # `check` reads a pane's context-window usage (via the agent daemon's
    # `sessions` snapshot, which already carries `context_pct`/`context_error`
    # from {Workspace::ContextReader}) and, once it's at or over the
    # threshold, types a save-state prompt into that exact pane so the agent
    # can write down where it is before running `workspace handoff new` on
    # itself. `new` sends the H2 `restart_agent` flow (`/clear`, confirm,
    # resume prompt) at an explicit pane and returns once it's started.
    #
    # Neither command ever guesses a pane: `--pane` names one explicitly, or
    # the daemon's first pane of kind "claude" is used. Neither ever guesses
    # a context percentage either -- see {#check}'s exit code 2.
    class Handoff
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # @param config [Workspace::Config] socket path lookups
      # @param tmux [Workspace::Tmux] delivers the save-state prompt directly
      #   (no /clear involved, so this doesn't need the daemon's restart
      #   machinery)
      # @param handoff_config [Workspace::HandoffConfig] threshold and prompt
      #   template defaults
      # @param restart_agent_command [Workspace::Commands::RestartAgent] the
      #   H2 `/clear` + resume flow, reused verbatim by `new`
      # @param output [IO] stream for the result (and `--json` output)
      # @param error_output [IO] stream for the "undetermined" reason (non-JSON)
      def initialize(config:, tmux:, handoff_config:, restart_agent_command:, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @handoff_config = handoff_config
        @restart_agent_command = restart_agent_command
        @output = output
        @error_output = error_output
      end

      # @param name [String] workspace name
      # @param pane [String, nil] pane index; nil picks the daemon's first
      #   "claude" pane
      # @param threshold [Integer, nil] context-usage percent that triggers a
      #   handoff; nil uses `handoff.threshold` (default 11)
      # @param context_pct [Integer, nil] skips detection and uses this value
      # @param handoff_doc [String, nil] path the agent updates and resumes from
      # @param handoff_prompt [String, nil] prompt sent verbatim instead of a doc
      # @param json [Boolean] emit the result as JSON instead of text
      # @return [Hash] {exit_code:} -- 0 under the threshold, 1 at/over it
      #   (the save-state prompt was sent), 2 when usage can't be determined
      #   (nothing was sent). This 2 is a deliberate departure from this
      #   project's usual `--json` error contract (exit 1): "undetermined" is
      #   a third outcome, not an error, so callers can tell it apart from
      #   "over threshold" with a plain exit-code check.
      def check(name:, pane: nil, threshold: nil, context_pct: nil, handoff_doc: nil, handoff_prompt: nil, json: false)
        defaults = @handoff_config.for_workspace(name)
        if threshold
          begin
            threshold = Workspace::HandoffConfig.parse_threshold(threshold)
          rescue ArgumentError => e
            raise Workspace::UsageError, "--threshold #{e.message}"
          end
        else
          threshold = defaults[:threshold]
        end

        snapshot, error = fetch_sessions(name)
        return undetermined(json, error) if error

        pane_info = find_pane(snapshot, pane)
        raise Workspace::UsageError, no_pane_message(name, pane, snapshot) unless pane_info
        raise Workspace::UsageError, not_claude_message(name, pane_info) unless pane_kind_ok?(pane_info)

        if context_pct && !context_pct.between?(0, 100)
          raise Workspace::UsageError, "--context-pct must be between 0 and 100"
        end
        pct = context_pct || pane_info["context_pct"]
        reason = context_pct ? nil : pane_info["context_error"]
        return undetermined(json, reason || ContextReasons::NO_READING) if pct.nil?

        if pct < threshold
          return ok(json, pct: pct, threshold: threshold, pane: pane_info)
        end

        body = check_body(name: name, pane_index: pane_info["index"], pct: pct, threshold: threshold,
          handoff_doc: handoff_doc, handoff_prompt: handoff_prompt, defaults: defaults)
        delivery = begin
          @tmux.deliver(@tmux.session_name_for(name), "0.#{pane_info["index"]}", body)
        rescue Workspace::Error, SystemCallError => e
          Workspace::Tmux::Delivery.new(status: :failed, message: e.message)
        end
        over_threshold(json, pct: pct, threshold: threshold, pane: pane_info, delivery: delivery)
      end

      # @param name [String] workspace name
      # @param pane [String, nil] pane index; nil picks the daemon's first
      #   "claude" pane, same as {#check}
      # @param handoff_doc [String, nil] path the agent should resume from
      # @param handoff_prompt [String, nil] prompt sent verbatim instead
      # @param wait [Boolean] wait for the restart to finish instead of
      #   returning once it has started
      # @param json [Boolean] emit the result as JSON instead of text
      # @return [Hash] {exit_code:} -- see {Workspace::Commands::RestartAgent#call}
      def new(name:, pane: nil, handoff_doc: nil, handoff_prompt: nil, wait: false, json: false)
        if pane.nil?
          snapshot, error = fetch_sessions(name)
          raise Workspace::Error, error if error
          pane_info = find_pane(snapshot, nil)
          raise Workspace::UsageError, no_pane_message(name, nil, snapshot) unless pane_info
          pane = pane_info["index"].to_s
        end

        defaults = @handoff_config.for_workspace(name)
        template = defaults[:resume_prompt] || DEFAULT_RESUME_PROMPT
        prompt = handoff_prompt || safe_format(template, DEFAULT_RESUME_PROMPT, doc: handoff_doc)
        @restart_agent_command.call(name: name, pane: pane, prompt: prompt, wait: wait, json: json)
      end

      private

      DEFAULT_RESUME_PROMPT = <<~PROMPT.strip
        Read %{doc} and follow its "Start here" instructions. Act strictly
        as an orchestrator: delegate the actual work to sub-agents rather than doing it
        yourself.
      PROMPT

      DEFAULT_CHECK_PROMPT_DOC = <<~PROMPT.strip
        %{usage} Update %{doc} now with
        everything needed to continue this work: current state, next steps, and the
        process/workflow for picking it back up in a fresh session (a "Start here" section
        with a single paste-able prompt). Commit it if appropriate. Then run this exact
        command yourself: %{new_cmd}
      PROMPT

      DEFAULT_CHECK_PROMPT_PROMPT = <<~PROMPT.strip
        %{usage} Save any in-progress state you'll need
        to continue this work, and commit it if appropriate. Then run this exact command
        yourself: %{new_cmd}
      PROMPT

      DEFAULT_CHECK_PROMPT_PICK = <<~PROMPT.strip
        %{usage} Write a handoff doc, at a path you
        choose, with everything needed to continue this work: current state, next steps,
        and the process/workflow for picking it back up in a fresh session (a "Start here"
        section with a single paste-able prompt). Commit it if appropriate. Then run this
        command yourself, with PATH replaced by the doc's absolute path:
        %{new_cmd} --handoff-doc PATH
      PROMPT

      def check_body(name:, pane_index:, pct:, threshold:, handoff_doc:, handoff_prompt:, defaults:)
        usage = "Context usage is at #{pct}%, #{(pct > threshold) ? "over" : "at"} the #{threshold}% threshold."
        new_cmd_base = "workspace handoff new #{[name].shelljoin} --pane #{pane_index}"

        if handoff_prompt
          new_cmd = "#{new_cmd_base} #{["--handoff-prompt", handoff_prompt].shelljoin}"
          safe_format(DEFAULT_CHECK_PROMPT_PROMPT, DEFAULT_CHECK_PROMPT_PROMPT, usage: usage, new_cmd: new_cmd)
        elsif handoff_doc
          new_cmd = "#{new_cmd_base} #{["--handoff-doc", handoff_doc].shelljoin}"
          template = defaults[:check_prompt] || DEFAULT_CHECK_PROMPT_DOC
          safe_format(template, DEFAULT_CHECK_PROMPT_DOC, usage: usage, doc: handoff_doc, new_cmd: new_cmd)
        else
          safe_format(DEFAULT_CHECK_PROMPT_PICK, DEFAULT_CHECK_PROMPT_PICK, usage: usage, new_cmd: new_cmd_base)
        end
      end

      # A hand-edited `handoff.check_prompt`/`handoff.resume_prompt` with a
      # stray `%` (not one of the documented placeholders) would otherwise
      # raise from `format` and crash `check` with a Ruby backtrace instead
      # of its documented `--json` error contract. Falls back to the
      # built-in template rather than guessing at the intended text.
      def safe_format(template, fallback, **placeholders)
        format(template, **placeholders)
      rescue KeyError, ArgumentError, TypeError => e
        @error_output.puts "Warning: invalid prompt template (#{e.message}); using the built-in default."
        format(fallback, **placeholders)
      end

      def fetch_sessions(name)
        path = @config.agent_socket_path(name)
        snapshot = UNIXSocket.open(path) do |socket|
          socket.puts(JSON.generate("type" => "sessions", "workspace" => name))
          reply = socket.gets
          return [nil, "no reply from the agent daemon for '#{name}'"] unless reply
          begin
            parsed = JSON.parse(reply)
          rescue JSON::ParserError
            return [nil, "malformed reply from the agent daemon for '#{name}'"]
          end
          return [nil, "malformed reply from the agent daemon for '#{name}'"] unless parsed.is_a?(Hash)
          parsed
        end
        [snapshot, nil]
      rescue SystemCallError, IOError
        [nil, "no agent daemon for '#{name}' (start one with: workspace agentd --name #{name})"]
      end

      def find_pane(snapshot, pane)
        panes = snapshot["panes"] || []
        return panes.find { |p| p["kind"] == "claude" } if pane.nil?
        return panes.find { |p| p["pane_id"] == pane.to_s } if pane.to_s.match?(Workspace::TmuxPane::PANE_ID)
        panes.find { |p| p["index"].to_s == pane.to_s }
      end

      def no_pane_message(name, pane, snapshot)
        return "No Claude Code pane found in workspace '#{name}'; pass --pane." if pane.nil?
        "No pane #{pane} in workspace '#{name}'. Panes: #{(snapshot["panes"] || []).map { |p| p["index"] }.join(", ")}"
      end

      # Session monitor pane kinds `check` will type the save-state prompt
      # into: the Claude provider, and a pane not identified yet. Mirrors
      # RESTARTABLE_KINDS in lib/workspace/commands/agent.rb -- keep both in
      # sync if this changes. Unlike `new` (which hands the pane to the
      # daemon's own restart_agent, already gated this way), `check` delivers
      # directly via Tmux#deliver, so it must gate the pane kind itself.
      RESTARTABLE_KINDS = ["claude", "unknown"].freeze
      private_constant :RESTARTABLE_KINDS

      def pane_kind_ok?(pane_info)
        RESTARTABLE_KINDS.include?(pane_info["kind"])
      end

      def not_claude_message(name, pane_info)
        "Pane #{pane_info["index"]} in workspace '#{name}' is running #{pane_info["kind"]}, not Claude Code; " \
          "handoff only restarts Claude Code, whose /clear it types."
      end

      def undetermined(json, reason)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "status" => "undetermined",
                                        "reason" => reason, "fix" => ContextReasons::FIX_HINT})
        else
          @error_output.puts "workspace: could not determine context usage"
          @error_output.puts "  reason: #{reason}"
          @error_output.puts "  #{ContextReasons::FIX_HINT.gsub("\n", "\n  ")}"
        end
        {exit_code: 2}
      end

      def ok(json, pct:, threshold:, pane:)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "status" => "ok", "context_pct" => pct,
                                        "threshold" => threshold, "pane" => pane["index"]})
        else
          @output.puts "Context usage: #{pct}% (threshold #{threshold}%) -- under threshold, nothing to do."
        end
        {exit_code: 0}
      end

      # +delivery.landed?+ is false only when tmux itself failed (e.g. a
      # dead pane) -- see {Workspace::Tmux::Delivery} -- not merely
      # "unconfirmed". A caller scripting on `--json` can check "landed"
      # without parsing the status string; the status still travels for
      # anyone who wants the detail.
      def over_threshold(json, pct:, threshold:, pane:, delivery:)
        status = delivery.landed? ? "handoff_sent" : "handoff_send_failed"
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "status" => status,
                                        "context_pct" => pct, "threshold" => threshold, "pane" => pane["index"],
                                        "delivery" => delivery.status.to_s, "landed" => delivery.landed?})
        elsif delivery.landed?
          @output.puts "Context usage: #{pct}% (threshold #{threshold}%) -- at/over threshold; sent save-state prompt to pane #{pane["index"]} (#{delivery.status})."
        else
          @output.puts "Context usage: #{pct}% (threshold #{threshold}%) -- at/over threshold; failed to deliver the save-state prompt to pane #{pane["index"]} (#{delivery.status})."
          @error_output.puts "Warning: the save-state prompt did not reach the pane (#{delivery.status})."
        end
        {exit_code: 1}
      end
    end
  end
end
