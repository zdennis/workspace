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
    # the daemon's first pane of kind "claude" is used. `--pane` takes a tmux
    # pane id ("%19", what `$TMUX_PANE` holds in the pane itself), "window.pane",
    # or a pane index in window 0. The id is the one to prefer: it names one
    # pane for its whole life. Either way the pane is looked up in the
    # workspace's own tmux session before anything is typed, the daemon's
    # default pane included: a daemon can be older than this command and list
    # another session's panes. Neither ever guesses a context percentage
    # either -- see {#check}'s exit code 2.
    class Handoff
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # @param config [Workspace::Config] socket path lookups
      # @param tmux [Workspace::Tmux] delivers the save-state prompt directly
      #   (no /clear involved, so this doesn't need the daemon's restart
      #   machinery)
      # @param locator [Workspace::PaneLocator] finds the pane in the
      #   workspace's own tmux session
      # @param handoff_config [Workspace::HandoffConfig] threshold and prompt
      #   template defaults
      # @param restart_agent_command [Workspace::Commands::RestartAgent] the
      #   H2 `/clear` + resume flow, reused verbatim by `new`
      # @param notes [Workspace::Commands::Notes] says where a workspace's notes
      #   are, which is where the default doc `HANDOFF.md` lives
      # @param output [IO] stream for the result (and `--json` output)
      # @param error_output [IO] stream for the "undetermined" reason (non-JSON)
      def initialize(config:, tmux:, locator:, handoff_config:, restart_agent_command:, notes:, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @locator = locator
        @handoff_config = handoff_config
        @restart_agent_command = restart_agent_command
        @notes = notes
        @output = output
        @error_output = error_output
      end

      # @param name [String] workspace name
      # @param pane [String, nil] pane id ("%19"), "window.pane" or pane
      #   index; nil picks the daemon's first "claude" pane
      # @param threshold [Integer, nil] context-usage percent that triggers a
      #   handoff; nil uses `handoff.threshold` (default 11)
      # @param context_pct [Integer, nil] skips detection and uses this value
      # @param handoff_doc [String, nil] path the agent updates and resumes from; with neither this nor
      #   +handoff_prompt+, +HANDOFF.md+ in the workspace's notes directory
      # @param handoff_prompt [String, nil] prompt sent verbatim instead of a doc
      # @param json [Boolean] emit the result as JSON instead of text
      # @return [Hash] {exit_code:} -- 0 under the threshold, 1 at/over it
      #   (the save-state prompt was sent), 2 when usage can't be determined
      #   (nothing was sent). This 2 is a deliberate departure from this
      #   project's usual `--json` error contract (exit 1): "undetermined" is
      #   a third outcome, not an error, so callers can tell it apart from
      #   "over threshold" with a plain exit-code check.
      # @raise [Workspace::Error] see {Workspace::PaneLocator#locate}, when
      #   the pane isn't one of the workspace's own; nothing is typed
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

        doc = if handoff_prompt then nil
        elsif handoff_doc then File.expand_path(handoff_doc)
        else default_doc(name)
        end
        snapshot, error = fetch_sessions(name)
        return undetermined(json, error, doc: doc) if error

        detail = locate(name, pane || default_pane(name, snapshot))
        pane_info = (snapshot["panes"] || []).find { |p| p["pane_id"] == detail[:id] }
        return undetermined(json, unlisted_reason(name, detail), fix: unlisted_fix(name), doc: doc) unless pane_info
        raise Workspace::UsageError, not_claude_message(name, pane_info) unless pane_kind_ok?(pane_info)

        if context_pct && !context_pct.between?(0, 100)
          raise Workspace::UsageError, "--context-pct must be between 0 and 100"
        end
        pct = context_pct || pane_info["context_pct"]
        reason = context_pct ? nil : pane_info["context_error"]
        return undetermined(json, reason || ContextReasons::NO_READING, doc: doc) if pct.nil?

        if pct < threshold
          return ok(json, pct: pct, threshold: threshold, pane: pane_info, doc: doc)
        end

        prepare_default_doc(name) if doc && handoff_doc.nil?
        body = check_body(name: name, pane: pane_info, pct: pct, threshold: threshold,
          handoff_doc: handoff_doc || doc, handoff_prompt: handoff_prompt, defaults: defaults)
        delivery = begin
          @tmux.deliver(detail[:session], detail[:id], body)
        rescue Workspace::Error, SystemCallError => e
          Workspace::Tmux::Delivery.new(status: :failed, message: e.message)
        end
        over_threshold(json, pct: pct, threshold: threshold, pane: pane_info, delivery: delivery, doc: doc)
      end

      # @param name [String] workspace name
      # @param pane [String, nil] pane id ("%19"), "window.pane" or pane
      #   index; nil picks the daemon's first "claude" pane, same as {#check}
      # @param handoff_doc [String, nil] path the agent should resume from; with neither this nor
      #   +handoff_prompt+, +HANDOFF.md+ in the workspace's notes directory
      # @param handoff_prompt [String, nil] prompt sent verbatim instead
      # @param wait [Boolean] wait for the restart to finish instead of
      #   returning once it has started
      # @param json [Boolean] emit the result as JSON instead of text
      # @return [Hash] {exit_code:} -- see {Workspace::Commands::RestartAgent#call}
      # @raise [Workspace::Error] when a default doc is needed and the notes directory can't be resolved
      def new(name:, pane: nil, handoff_doc: nil, handoff_prompt: nil, wait: false, json: false)
        if pane.nil?
          snapshot, error = fetch_sessions(name)
          raise Workspace::Error, error if error
          pane = default_pane(name, snapshot)
        end

        handoff_doc ||= resolve_default_doc(name) unless handoff_prompt
        defaults = @handoff_config.for_workspace(name)
        template = defaults[:resume_prompt] || DEFAULT_RESUME_PROMPT
        prompt = handoff_prompt || safe_format(template, DEFAULT_RESUME_PROMPT, doc: handoff_doc)
        @restart_agent_command.call(name: name, pane: pane, prompt: prompt, wait: wait, json: json)
      end

      private

      # The doc `check` and `new` use when given neither --handoff-doc nor --handoff-prompt.
      DEFAULT_DOC_NAME = "HANDOFF.md"

      DEFAULT_RESUME_PROMPT = ConfigSchema.default("handoff.resume_prompt")
      DEFAULT_CHECK_PROMPT_DOC = ConfigSchema.default("handoff.check_prompt")

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

      # @return [String] the default doc's absolute path
      # @raise [Workspace::Error] when the notes directory can't be resolved
      def resolve_default_doc(name, create: false)
        File.join(@notes.info(name: name, create: create)["dir"], DEFAULT_DOC_NAME)
      end

      # @return [String, nil] the default doc's path, or nil when the notes directory can't be
      #   resolved (`check` then lets the agent pick a path, as it did before the default existed)
      def default_doc(name)
        resolve_default_doc(name)
      rescue Workspace::Error, SystemCallError
        nil
      end

      # Makes the notes directory so the agent can write the doc. Without it the prompt still goes out.
      def prepare_default_doc(name)
        resolve_default_doc(name, create: true)
      rescue Workspace::Error, SystemCallError => e
        @error_output.puts "Warning: could not make the notes directory (#{e.message}); the handoff prompt is sent anyway."
      end

      # The command it tells the agent to run names the pane by its id, which
      # stays with the pane however its window is split or renumbered. The id
      # is quoted because `%` is special in some shells.
      def check_body(name:, pane:, pct:, threshold:, handoff_doc:, handoff_prompt:, defaults:)
        usage = "Context usage is at #{pct}%, #{(pct > threshold) ? "over" : "at"} the #{threshold}% threshold."
        new_cmd_base = "workspace handoff new #{[name].shelljoin} --pane '#{pane["pane_id"]}'"

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

      # @return [String] the pane id of the first Claude Code pane the daemon lists
      def default_pane(name, snapshot)
        listed = (snapshot["panes"] || []).find { |p| p["kind"] == "claude" && p["pane_id"] }
        raise Workspace::UsageError, "No Claude Code pane found in workspace '#{name}'; pass --pane." unless listed
        listed["pane_id"]
      end

      # Finds the pane in the workspace's own tmux session. A bare index is a
      # pane of window 0, as `agent-run restart` reads it.
      #
      # @return [Hash] see {Workspace::PaneLocator#locate}
      def locate(name, spec)
        spec = spec.to_s.strip
        @locator.locate(name, spec.match?(/\A\d+\z/) ? "0.#{spec}" : spec)
      end

      # The pane is in the workspace's session, yet the daemon doesn't list
      # it: the daemon is watching something else, so its readings can't be
      # used for this pane.
      def unlisted_reason(name, detail)
        "the agent daemon for '#{name}' doesn't list pane #{detail[:id]} of tmux session '#{detail[:session]}'"
      end

      def unlisted_fix(name)
        "Restart the agent daemon: workspace agentd restart #{[name].shelljoin}"
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

      def undetermined(json, reason, fix: ContextReasons::FIX_HINT, doc: nil)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "status" => "undetermined",
                                        "reason" => reason, "fix" => fix, "next" => "unknown", "doc" => doc})
        else
          @error_output.puts "workspace: could not determine context usage"
          @error_output.puts "  reason: #{reason}"
          @error_output.puts "  #{fix.gsub("\n", "\n  ")}"
        end
        {exit_code: 2}
      end

      def ok(json, pct:, threshold:, pane:, doc: nil)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "status" => "ok", "context_pct" => pct,
                                        "threshold" => threshold, "pane" => pane["index"], "pane_id" => pane["pane_id"],
                                        "next" => "continue", "doc" => doc})
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
      def over_threshold(json, pct:, threshold:, pane:, delivery:, doc: nil)
        status = delivery.landed? ? "handoff_sent" : "handoff_send_failed"
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "status" => status,
                                        "context_pct" => pct, "threshold" => threshold, "pane" => pane["index"], "pane_id" => pane["pane_id"],
                                        "delivery" => delivery.status.to_s, "landed" => delivery.landed?,
                                        "next" => "handoff", "doc" => doc})
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
