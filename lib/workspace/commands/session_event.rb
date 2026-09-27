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
        "PreToolUse" => "subagent_start"
      }.freeze

      # @param config [Workspace::Config] socket path lookups
      # @param tmux [Workspace::Tmux] resolves the pane's session name
      # @param input [IO] stream the hook payload arrives on
      # @param env [Hash] process environment, for TMUX_PANE
      # @param error_output [IO] stream a deny message is written to
      # @param logger [Workspace::Logger] debug logger
      # @param lock_idle_tracker [Workspace::LockIdleTracker, nil] marks the
      #   agent's locks idle/active; nil skips lock tracking
      # @param lock_enforcer [Workspace::LockEnforcer, nil] denies an edit while
      #   another agent holds the edit lock, and releases locks on session end;
      #   nil skips enforcement
      def initialize(config:, tmux:, input: $stdin, env: ENV, error_output: $stderr, logger: Workspace::Logger.new,
        lock_idle_tracker: nil, lock_enforcer: nil)
        @config = config
        @tmux = tmux
        @input = input
        @env = env
        @error_output = error_output
        @logger = logger
        @lock_idle_tracker = lock_idle_tracker
        @lock_enforcer = lock_enforcer
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
        return nil if raw.nil? || raw.strip.empty?
        JSON.parse(raw)
      rescue JSON::ParserError => e
        @logger.debug { "session-event: unparseable payload (#{e.message})" }
        nil
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
          "agent" => agent_for(payload)
        }.compact
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
