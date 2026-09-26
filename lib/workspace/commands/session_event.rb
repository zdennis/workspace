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
      # @param logger [Workspace::Logger] debug logger
      def initialize(config:, tmux:, input: $stdin, env: ENV, logger: Workspace::Logger.new)
        @config = config
        @tmux = tmux
        @input = input
        @env = env
        @logger = logger
      end

      # Reads a hook payload and forwards it. Always succeeds.
      #
      # @param workspace [String, nil] overrides the workspace the event is sent
      #   to; normally derived from the pane the hook is running in
      # @return [void]
      def call(workspace: nil)
        pane_id = @env["TMUX_PANE"]
        return @logger.debug { "session-event: not inside tmux, dropped" } unless pane_id

        payload = parse(@input.read)
        return unless payload

        name = workspace || @tmux.session_name_for_pane(pane_id)
        return @logger.debug { "session-event: no session for #{pane_id}, dropped" } unless name

        event = translate(payload, pane_id, name)
        return @logger.debug { "session-event: ignoring #{payload["hook_event_name"]}" } unless event

        deliver(name, event)
      end

      private

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
