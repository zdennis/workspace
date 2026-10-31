require "socket"
require "json"
require "time"
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
    # the daemon's first pane of kind "claude" (else its first "codex" pane) is used. `--pane` takes a tmux
    # pane id ("%19", what `$TMUX_PANE` holds in the pane itself), "window.pane",
    # or a pane index in window 0. The id is the one to prefer: it names one
    # pane for its whole life. Either way the pane is looked up in the
    # workspace's own tmux session before anything is typed, the daemon's
    # default pane included: a daemon can be older than this command and list
    # another session's panes. Neither ever guesses a context percentage
    # either -- see {#check}'s exit code 2.
    #
    # With no explicit doc, a workspace that has a plan (`IMPLEMENTATION_PLAN.md`
    # in its notes directory) uses the plan as the handoff doc, so there is one
    # task list; `new` then also binds the pane to the `implementation-plan`
    # play, so the fresh conversation is pointed back at it.
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
      #   are, which is where the plan and the default doc `HANDOFF.md` live
      # @param binder [Workspace::Commands::Binding] binds the pane to the plan play when the plan is the doc
      # @param library [Workspace::Library] finds the built-in `implementation-plan` play
      # @param output [IO] stream for the result (and `--json` output)
      # @param error_output [IO] stream for the "undetermined" reason (non-JSON)
      def initialize(config:, tmux:, locator:, handoff_config:, restart_agent_command:, notes:, binder:, library:, output: $stdout, error_output: $stderr)
        @binder = binder
        @library = library
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
      #   index; nil picks the daemon's first "claude" pane, else its first "codex" pane
      # @param threshold [Integer, nil] context-usage percent that triggers a
      #   handoff; nil uses `handoff.threshold` (default 11)
      # @param context_pct [Integer, nil] skips detection and uses this value
      # @param handoff_doc [String, nil] path the agent updates and resumes from; with neither this nor
      #   +handoff_prompt+, the workspace's plan when it has one, else +HANDOFF.md+ in its notes directory
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
        raise Workspace::UsageError, unsupported_pane_message(name, pane_info) unless pane_kind_ok?(pane_info)

        if context_pct && !context_pct.between?(0, 100)
          raise Workspace::UsageError, "--context-pct must be between 0 and 100"
        end
        pct = context_pct || pane_info["context_pct"]
        reason = context_pct ? nil : pane_info["context_error"]
        if pct.nil?
          return undetermined(json, reason || ContextReasons::NO_READING,
            fix: ContextReasons.fix_hint(pane_info["kind"]), doc: doc)
        end

        if pct < threshold
          return ok(json, pct: pct, threshold: threshold, pane: pane_info, doc: doc)
        end

        prepare_default_doc(name) if doc && handoff_doc.nil?
        plan_is_doc = handoff_doc.nil? && plan_doc?(doc)
        new_cmd = new_command(name: name, pane: pane_info, handoff_doc: handoff_doc || doc,
          handoff_prompt: handoff_prompt, plan_is_doc: plan_is_doc)
        body = check_body(pct: pct, threshold: threshold, new_cmd: new_cmd,
          handoff_doc: handoff_doc || doc, handoff_prompt: handoff_prompt, defaults: defaults,
          plan_is_doc: plan_is_doc)
        sent_at = Time.now
        delivery = begin
          @tmux.deliver(detail[:session], detail[:id], body)
        rescue Workspace::Error, SystemCallError => e
          Workspace::Tmux::Delivery.new(status: :failed, message: e.message)
        end
        # In the path-picking mode the prompt shows the command with PATH left for the agent to fill in.
        followup_cmd = (handoff_prompt || handoff_doc || doc) ? new_cmd : "#{new_cmd} --handoff-doc PATH"
        followup = start_followups(name, detail[:id], defaults, followup_cmd, body, sent_at) if delivery.landed?
        over_threshold(json, pct: pct, threshold: threshold, pane: pane_info, delivery: delivery, doc: doc, followup: followup)
      end

      # @param name [String] workspace name
      # @param pane [String, nil] pane id ("%19"), "window.pane" or pane
      #   index; nil picks the daemon's first "claude" pane, else its first "codex" pane, same as {#check}
      # @param handoff_doc [String, nil] path the agent should resume from; with neither this nor
      #   +handoff_prompt+, the workspace's plan when it has one (and the pane is bound to the
      #   `implementation-plan` play), else +HANDOFF.md+ in its notes directory
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

        unless handoff_prompt || handoff_doc
          handoff_doc = resolve_default_doc(name)
          bind_plan_play(name, pane) if plan_doc?(handoff_doc)
        end
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

      DEFAULT_FOLLOWUP_PROMPT = ConfigSchema.default("handoff.followup_prompt")

      # The daemon refuses a follow-up or save-state text longer than this; a cut text could carry a broken command.
      FOLLOWUP_TEXT_LIMIT = 4000

      # Seconds `check` waits for the daemon's reply to `handoff_watch`.
      FOLLOWUP_REPLY_WAIT = 2

      PAUSED_PLAN_NOTE = "If the plan's status: is paused, write the doc and end your turn without running that command."

      # The ref of the built-in play `new` binds the pane to when the plan is the doc.
      PLAN_PLAY = "implementation-plan"

      # @return [String] the plan's absolute path when the workspace has a plan file, else the
      #   default doc's
      # @raise [Workspace::Error] when the notes directory can't be resolved
      def resolve_default_doc(name, create: false)
        dir = @notes.info(name: name, create: create)["dir"]
        plan = PlanFile.path_in(dir)
        File.file?(plan) ? plan : File.join(dir, DEFAULT_DOC_NAME)
      end

      def plan_doc?(path)
        !path.nil? && File.basename(path) == PlanFile::FILE_NAME
      end

      # Points the pane's fresh conversation back at the plan play after the restart. A pane bound
      # to a run or review keeps that binding; a play binding keeps its packs. A failure is a
      # warning: the restart still resumes from the plan.
      def bind_plan_play(name, pane)
        id = locate(name, pane)[:id]
        existing = @binder.live(pane: id)
        return if existing && existing["kind"] != "play"
        entry, _body = @library.pack(PLAN_PLAY, cwd: nil)
        @binder.bind(workspace: name, pane: id, **@library.play_binding(entry, packs: Array(existing && existing["packs"])))
      rescue Workspace::Error, SystemCallError => e
        @error_output.puts "Warning: could not bind pane #{pane} to the plan play (#{e.message}); the restart goes ahead."
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
      def new_command(name:, pane:, handoff_doc:, handoff_prompt:, plan_is_doc:)
        base = "workspace handoff new #{[name].shelljoin} --pane '#{pane["pane_id"]}'"
        if handoff_prompt
          "#{base} #{["--handoff-prompt", handoff_prompt].shelljoin}"
        elsif handoff_doc
          # With the plan as the doc, `new` is left to find it, so it also binds the pane to the plan play.
          plan_is_doc ? base : "#{base} #{["--handoff-doc", handoff_doc].shelljoin}"
        else
          base
        end
      end

      def check_body(pct:, threshold:, new_cmd:, handoff_doc:, handoff_prompt:, defaults:, plan_is_doc: false)
        usage = "Context usage is at #{pct}%, #{(pct > threshold) ? "over" : "at"} the #{threshold}% threshold."

        if handoff_prompt
          safe_format(DEFAULT_CHECK_PROMPT_PROMPT, DEFAULT_CHECK_PROMPT_PROMPT, usage: usage, new_cmd: new_cmd)
        elsif handoff_doc
          template = defaults[:check_prompt] || DEFAULT_CHECK_PROMPT_DOC
          body = safe_format(template, DEFAULT_CHECK_PROMPT_DOC, usage: usage, doc: handoff_doc, new_cmd: new_cmd)
          plan_is_doc ? "#{body} #{PAUSED_PLAN_NOTE}" : body
        else
          safe_format(DEFAULT_CHECK_PROMPT_PICK, DEFAULT_CHECK_PROMPT_PICK, usage: usage, new_cmd: new_cmd)
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

      # Asks the agent daemon to watch the pane after the save-state prompt landed. The prompt is
      # already in the pane, so nothing here changes `check`'s exit code.
      #
      # @return [Hash{String=>Object}] "watching" and "reason" (nil when watching)
      def start_followups(name, pane_id, defaults, new_cmd, sent_text, sent_at)
        max = defaults[:followup_max].to_i
        return {"watching" => false, "reason" => "disabled"} if max <= 0
        return {"watching" => false, "reason" => "bound_pane"} if %w[run review].include?(@binder.live(pane: pane_id)&.fetch("kind", nil))

        text = safe_format(defaults[:followup_prompt] || DEFAULT_FOLLOWUP_PROMPT, DEFAULT_FOLLOWUP_PROMPT, new_cmd: new_cmd)
        if text.length > FOLLOWUP_TEXT_LIMIT || sent_text.length > FOLLOWUP_TEXT_LIMIT
          return {"watching" => false, "reason" => "text_too_long"}
        end

        reply = request_watch("type" => "handoff_watch", "workspace" => name, "pane_id" => pane_id,
          "sent_at" => sent_at.iso8601(3), "interval" => defaults[:followup_interval], "max" => max,
          "text" => text, "sent_text" => sent_text)
        parsed = reply[:parsed]
        return {"watching" => false, "reason" => reply[:reason]} unless parsed
        if parsed["ok"] == true && parsed["watching"] == true
          {"watching" => true, "reason" => nil}
        elsif parsed["ok"] == true
          {"watching" => false, "reason" => parsed["reason"].to_s.empty? ? "unknown" : parsed["reason"].to_s}
        else
          {"watching" => false, "reason" => (parsed["error"] || parsed["code"] || "refused").to_s}
        end
      rescue Workspace::Error, SystemCallError => e
        @error_output.puts "Warning: could not start handoff follow-ups (#{e.message}); the save-state prompt was sent."
        {"watching" => false, "reason" => "error"}
      end

      # One request to the daemon with a short wait for the reply, since `check` runs inside the agent's turn.
      # An old daemon (`unknown_type`), no reply or a bad reply is a skip reason; a connection failure warns.
      #
      # @return [Hash] :parsed (the reply Hash) or :reason
      def request_watch(message)
        path = @config.agent_socket_path(message["workspace"])
        UNIXSocket.open(path) do |socket|
          socket.puts(JSON.generate(message))
          line = read_line_within(socket, FOLLOWUP_REPLY_WAIT)
          unless line
            @error_output.puts "Warning: the agent daemon did not answer the handoff follow-up request in #{FOLLOWUP_REPLY_WAIT}s; the save-state prompt was sent."
            return {reason: "no_reply"}
          end
          parsed = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          return {reason: "bad_reply"} unless parsed.is_a?(Hash)
          return {reason: "unsupported_daemon"} if parsed["error"] == "unknown_type" || parsed["code"] == "unknown_type"
          {parsed: parsed}
        end
      rescue SystemCallError, IOError => e
        @error_output.puts "Warning: could not reach the agent daemon to start handoff follow-ups (#{e.class}); the save-state prompt was sent."
        {reason: "no_daemon"}
      end

      # Reads up to the first newline, giving up when the whole read has taken +limit+ seconds, so a
      # daemon that writes half a line can not hold `check` up.
      #
      # @return [String, nil] the line, or nil on timeout or when the daemon closes without a word
      def read_line_within(socket, limit)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
        buffer = +""
        until buffer.include?("\n")
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil unless remaining.positive? && socket.wait_readable(remaining)
          chunk = socket.read_nonblock(4096, exception: false)
          next if chunk == :wait_readable
          break if chunk.nil?
          buffer << chunk
        end
        buffer.empty? ? nil : buffer[/\A[^\n]*/]
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

      # @return [String] the pane id of the first Claude Code pane the daemon lists, else of the first Codex pane
      def default_pane(name, snapshot)
        panes = (snapshot["panes"] || []).select { |p| p["pane_id"] }
        listed = panes.find { |p| p["kind"] == "claude" } || panes.find { |p| p["kind"] == "codex" }
        raise Workspace::UsageError, "No Claude Code or Codex pane found in workspace '#{name}'; pass --pane." unless listed
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
      # into: the providers marked restartable (Claude Code and Codex), and a
      # pane not identified yet. Mirrors
      # RESTARTABLE_KINDS in lib/workspace/commands/agent.rb -- keep both in
      # sync if this changes. Unlike `new` (which hands the pane to the
      # daemon's own restart_agent, already gated this way), `check` delivers
      # directly via Tmux#deliver, so it must gate the pane kind itself.
      RESTARTABLE_KINDS = AgentProvider.restartable_kinds.freeze
      private_constant :RESTARTABLE_KINDS

      def pane_kind_ok?(pane_info)
        RESTARTABLE_KINDS.include?(pane_info["kind"])
      end

      def unsupported_pane_message(name, pane_info)
        "Pane #{pane_info["index"]} in workspace '#{name}' is running #{pane_info["kind"]}, not Claude Code or Codex; " \
          "handoff only restarts Claude Code and Codex, whose /clear it types."
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
      def over_threshold(json, pct:, threshold:, pane:, delivery:, doc: nil, followup: nil)
        status = delivery.landed? ? "handoff_sent" : "handoff_send_failed"
        if json
          document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "status" => status,
                      "context_pct" => pct, "threshold" => threshold, "pane" => pane["index"], "pane_id" => pane["pane_id"],
                      "delivery" => delivery.status.to_s, "landed" => delivery.landed?,
                      "next" => "handoff", "doc" => doc}
          document["followup"] = followup if followup
          @output.puts JSON.generate(document)
        elsif delivery.landed?
          @output.puts "Context usage: #{pct}% (threshold #{threshold}%) -- at/over threshold; sent save-state prompt to pane #{pane["index"]} (#{delivery.status})."
          @output.puts "The agent daemon will follow up in pane #{pane["index"]} if no handoff happens." if followup && followup["watching"]
        else
          @output.puts "Context usage: #{pct}% (threshold #{threshold}%) -- at/over threshold; failed to deliver the save-state prompt to pane #{pane["index"]} (#{delivery.status})."
          @error_output.puts "Warning: the save-state prompt did not reach the pane (#{delivery.status})."
        end
        {exit_code: 1}
      end
    end
  end
end
