require "socket"
require "json"

module Workspace
  module Commands
    # Asks a workspace's agent daemon to restart the coding agent in one
    # named pane: type `/clear`, confirm its context usage dropped, then
    # type a prompt. The daemon does the typing, from outside the pane, so an
    # agent can restart itself: it sends this and ends its turn.
    #
    # The pane is always named by the caller. Nothing picks "the Claude
    # pane" on its behalf, since a workspace can run several.
    class RestartAgent
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # @param config [Workspace::Config] socket path lookups
      # @param output [IO] stream for the result (and `--json` errors)
      def initialize(config:, output: $stdout)
        @config = config
        @output = output
      end

      # @param name [String] workspace name
      # @param pane [String] pane id ("%12"), "window.pane", "session:window.pane", or a pane index
      # @param prompt [String] text typed once the conversation is cleared
      # @param force [Boolean] restart a pane with a pipeline stage running on it
      # @param wait [Boolean] wait for the outcome instead of returning once started
      # @param timeout [Numeric, nil] longest wait for usage to drop, in seconds
      # @param json [Boolean] print the daemon's reply as JSON
      # @return [Hash] {exit_code:} — 0 when the restart started (or, with
      #   +wait+, finished), 1 when it was refused or failed. With +json+,
      #   errors go to stdout as `{"schema_version":1,"error":...}`.
      # @raise [Workspace::Error] when it was refused or failed and +json+ is false
      def call(name:, pane:, prompt:, force: false, wait: false, timeout: nil, json: false)
        message = {"type" => "restart_agent", "workspace" => name, "pane" => pane, "prompt" => prompt,
                   "force" => force, "wait" => wait}
        message["timeout"] = timeout if timeout
        reply = send_message(name, message)
        return failure(reply, json) unless reply["ok"]

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION}.merge(reply.except("ok")))
        else
          render(reply)
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      private

      # The daemon's error code travels as "code", so "error" keeps the
      # documented shape: the message a person reads.
      def failure(reply, json)
        message = reply["message"] || reply["error"]
        raise Workspace::Error, [message, reply["fix"]].compact.join("\n") unless json

        extra = reply.except("ok", "error", "message")
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => message, "code" => reply["error"]}.merge(extra))
        {exit_code: 1}
      end

      def render(reply)
        where = "pane #{reply["pane"]} (#{reply["pane_id"]})"
        if reply["status"] == "restarted"
          @output.puts "Restarted #{where}: context #{reply["context_before"]}% -> #{reply["context_after"]}%; prompt #{reply["delivery"]}."
        else
          @output.puts "Restart started on #{where} at #{reply["context_pct"]}% context."
          @output.puts "The agent daemon waits for the pane to go quiet, types /clear, and types the prompt once usage drops."
          @output.puts "A failure is reported on the daemon's stderr; pass --wait to see it here."
        end
        @output.puts "Warning: #{reply["warning"]}" if reply["warning"]
      end

      def send_message(name, message)
        UNIXSocket.open(@config.agent_socket_path(name)) do |socket|
          socket.puts(JSON.generate(message))
          reply = socket.gets
          raise Workspace::Error, "The agent for #{name} closed the connection without replying" unless reply
          JSON.parse(reply)
        end
      rescue SystemCallError, IOError
        raise Workspace::Error, "No agent daemon for '#{name}'. Start one with: workspace agent --name #{name}"
      rescue JSON::ParserError
        raise Workspace::Error, "Unreadable reply from the agent for #{name}"
      end
    end
  end
end
