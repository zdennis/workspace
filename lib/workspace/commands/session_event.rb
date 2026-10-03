require "socket"
require "json"

module Workspace
  module Commands
    # Receives one hook event from a coding agent and forwards it to that
    # workspace's agent daemon.
    #
    # This runs as a hook, inside the agent's own turn, so it holds two rules
    # above all else: never block, and never fail. A hook that errors or hangs
    # degrades the thing it is meant to observe, and session monitoring is not
    # worth interrupting someone's work for. Every failure path here exits 0.
    class SessionEvent
      # Maps each agent's own event names onto workspace's vocabulary. A new
      # agent adds a table here and an entry in {Workspace::AgentProvider}.
      CLAUDE_EVENTS = {
        "SessionStart" => "session_start",
        "SessionEnd" => "session_end",
        "UserPromptSubmit" => "user_prompt",
        "Stop" => "stop",
        "SubagentStop" => "subagent_stop",
        "PreToolUse" => "subagent_start",
        "Notification" => "notification",
        "PostToolUse" => "tool_use"
      }.freeze

      # The hooks recorded in the session ledger, as the names it stores.
      LEDGER_EVENTS = {"SessionStart" => "session_start", "SessionEnd" => "session_end"}.freeze

      # Longest notification message forwarded to the daemon. The message is
      # shown in `sessions --json` and handed to the notify command; a long
      # one is cut rather than dropped.
      MAX_MESSAGE_LENGTH = SessionMonitor::MAX_MESSAGE_LENGTH

      # Longest user prompt forwarded to the daemon. A prompt can be a pasted
      # file; a label only needs its opening, so the rest is cut.
      MAX_PROMPT_LENGTH = 1000

      # Longest stop reason forwarded to the daemon.
      MAX_STOP_REASON_LENGTH = 64

      # @param config [Workspace::Config] socket path lookups
      # @param tmux [Workspace::Tmux] resolves the pane's session name
      # @param input [IO] stream the hook payload arrives on
      # @param env [Hash] process environment, for TMUX_PANE
      # @param output [IO] stream a bound pane's SessionStart context is written to
      # @param error_output [IO] stream a deny message is written to
      # @param logger [Workspace::Logger] debug logger
      # @param lock_idle_tracker [Workspace::LockIdleTracker, nil] marks the
      #   agent's locks idle/active; nil skips lock tracking
      # @param lock_enforcer [Workspace::LockEnforcer, nil] denies an edit while
      #   another agent holds the edit lock, and releases locks on session end;
      #   nil skips enforcement
      # @param session_ledger [Workspace::SessionLedger, nil] records each
      #   SessionStart and SessionEnd; nil skips the ledger
      # @param pane_bindings [Workspace::PaneBindings, nil] looked up on SessionStart to
      #   remind a bound pane of its subject; nil skips bindings
      def initialize(config:, tmux:, input: $stdin, env: ENV, output: $stdout, error_output: $stderr, logger: Workspace::Logger.new,
        lock_idle_tracker: nil, lock_enforcer: nil, session_ledger: nil, pane_bindings: nil)
        @config = config
        @tmux = tmux
        @input = input
        @env = env
        @output = output
        @error_output = error_output
        @logger = logger
        @lock_idle_tracker = lock_idle_tracker
        @lock_enforcer = lock_enforcer
        @session_ledger = session_ledger
        @pane_bindings = pane_bindings
      end

      # Reads a hook payload, updates the agent's lock idle state, enforces
      # the edit lock, and forwards the event to the agent daemon.
      #
      # @param workspace [String, nil] overrides the workspace the event is sent
      #   to; normally derived from the pane the hook is running in
      # @return [Hash] {exit_code:} — 2 when an edit is denied, 0 otherwise
      def call(workspace: nil)
        payload = parse(@input.read)
        return ok unless payload.is_a?(Hash)

        hook = payload["hook_event_name"]
        cwd = payload["cwd"]

        @lock_idle_tracker&.update(hook, cwd: cwd)

        if hook == "PreToolUse"
          deny = @lock_enforcer&.check(tool_name: payload["tool_name"], cwd: cwd)
          if deny
            @error_output.puts deny
            return {exit_code: 2}
          end
        elsif hook == "SessionEnd" || (hook == "SessionStart" && payload["source"] == "clear")
          @lock_enforcer&.release_all(cwd: cwd)
        end

        pane_id = @env["TMUX_PANE"]
        return ok { "session-event: not inside tmux, dropped" } unless pane_id

        name = workspace || @tmux.session_name_for_pane(pane_id)
        return ok { "session-event: no session for #{pane_id}, dropped" } unless name

        record_in_ledger(payload, pane_id, name)
        announce_binding(payload, pane_id)

        event = translate(payload, pane_id, name)
        return ok { "session-event: ignoring #{hook}" } unless event

        deliver(name, event)
        ok
      end

      private

      def ok
        @logger.debug { yield } if block_given?
        {exit_code: 0}
      end

      def parse(raw)
        return nil if raw.nil?

        # Invalid bytes would make strip and JSON.generate raise inside the
        # agent's turn; replacing them keeps the event deliverable. Hook stdin is UTF-8
        # whatever the locale tags it, so retag first.
        raw = raw.dup.force_encoding(Encoding::UTF_8).scrub
        return nil if raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        @logger.debug { "session-event: unparseable payload (#{e.message})" }
        nil
      end

      # Written before delivery so a missing daemon doesn't lose the record. The
      # slot lookup shells out to tmux, so it runs only for the two events that
      # are recorded.
      def record_in_ledger(payload, pane_id, workspace)
        hook = payload["hook_event_name"]
        return unless @session_ledger && LEDGER_EVENTS.key?(hook)

        @session_ledger.record(
          "event" => LEDGER_EVENTS[hook],
          "workspace" => workspace,
          "pane_slot" => @tmux.pane_slot(pane_id),
          "pane_id" => pane_id,
          "session_id" => text_field(payload, "session_id"),
          "transcript_path" => text_field(payload, "transcript_path"),
          "cwd" => text_field(payload, "cwd"),
          "source" => text_field(payload, "source"),
          "reason" => text_field(payload, "reason")
        )
      rescue => e
        @logger.debug { "session-event: ledger write failed (#{e.class}: #{e.message})" }
      end

      # A SessionStart for a bound pane prints Claude Code's `additionalContext`, so the
      # agent knows its subject again after startup, clear, resume and compact. Only a
      # binding made for this pane's own tmux session and slot counts, so a pane id
      # reused after a tmux restart doesn't inherit another pane's subject.
      def announce_binding(payload, pane_id)
        return unless @pane_bindings && payload["hook_event_name"] == "SessionStart"

        entry = @pane_bindings.binding_for(pane_id)
        return unless entry && entry["session"] == @tmux.session_name_for_pane(pane_id)
        return if entry["pane_slot"] && entry["pane_slot"] != @tmux.pane_slot(pane_id)

        @output.puts JSON.generate("hookSpecificOutput" => {
          "hookEventName" => "SessionStart",
          "additionalContext" => @pane_bindings.context_for(entry)
        })
      rescue => e
        @logger.debug { "session-event: binding context failed (#{e.class}: #{e.message})" }
      end

      def translate(payload, pane_id, workspace)
        hook = payload["hook_event_name"]
        name = CLAUDE_EVENTS[hook]
        return nil unless name

        # PreToolUse fires for every tool; only the Task tool starts a sub-agent.
        return nil if hook == "PreToolUse" && payload["tool_name"] != "Task"

        {
          "type" => "session_event",
          "workspace" => workspace,
          "event" => name,
          "pane_id" => pane_id,
          "session_id" => payload["session_id"],
          "cwd" => payload["cwd"],
          "transcript_path" => text_field(payload, "transcript_path"),
          # Set only when the hook fired inside a sub-agent, so the daemon can
          # tell its events from the main agent's.
          "agent_id" => payload["agent_id"],
          "agent" => agent_for(payload),
          "message" => message_for(payload),
          "prompt" => prompt_for(payload),
          "stop_reason" => stop_reason_for(payload)
        }.compact
      end

      def message_for(payload)
        message = payload["message"]
        return nil unless payload["hook_event_name"] == "Notification" && message.is_a?(String)

        message[0, MAX_MESSAGE_LENGTH]
      end

      def stop_reason_for(payload)
        return nil unless payload["hook_event_name"] == "Stop"

        text_field(payload, "stop_reason")&.then { |reason| reason[0, MAX_STOP_REASON_LENGTH] }
      end

      def text_field(payload, key)
        value = payload[key]
        value.is_a?(String) ? value : nil
      end

      def prompt_for(payload)
        prompt = payload["prompt"]
        return nil unless payload["hook_event_name"] == "UserPromptSubmit" && prompt.is_a?(String)

        prompt[0, MAX_PROMPT_LENGTH]
      end

      def agent_for(payload)
        input = payload["tool_input"]
        return nil unless input.is_a?(Hash)

        name = input["subagent_type"] || input["description"]
        name ? {"name" => name} : nil
      end

      # A missing or dead socket is the normal case when no daemon is running,
      # so it is logged and swallowed rather than reported.
      def deliver(workspace, event)
        path = @config.agent_socket_path(workspace)
        UNIXSocket.open(path) do |socket|
          socket.puts(JSON.generate(event))
          # The daemon answers every connection. Reading the reply before
          # closing keeps it from writing into a socket we already dropped,
          # which it would report as a dropped message on its stderr.
          socket.gets
        end
        @logger.debug { "session-event: sent #{event["event"]} for #{event["pane_id"]}" }
      rescue SystemCallError, IOError => e
        @logger.debug { "session-event: no daemon listening on #{path} (#{e.message})" }
      end
    end
  end
end
