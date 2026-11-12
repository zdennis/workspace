require "socket"
require "json"

module Workspace
  # Sends one message to a workspace's agent daemon over its Unix socket and reads the
  # one-line reply, with no time limit. `agent-run command`, `agent-run inject`,
  # `agent run PROMPT` and `pipeline start|advance` send through it.
  class AgentMessageClient
    # @param config [Workspace::Config] names each workspace's agent socket
    def initialize(config:)
      @config = config
    end

    # @param project [String] the workspace whose agent daemon gets the message
    # @param message [Hash] the message, written as one JSON line
    # @return [Object] the parsed reply
    # @raise [Workspace::Error] `no_daemon` when nothing listens on the socket,
    #   `connection_failed` when the daemon hangs up without a reply, `unreadable_reply`
    #   when the reply is not JSON
    def call(project, message)
      socket = begin
        UNIXSocket.open(@config.agent_socket_path(project))
      rescue SystemCallError, IOError
        raise Error.new("No agent is running for #{project}. Start one with: workspace agentd --name #{project}", code: "no_daemon")
      end
      reply = begin
        socket.puts(message.to_json)
        socket.gets
      rescue SystemCallError, IOError
        raise Error.new("The agent for #{project} closed the connection without replying", code: "connection_failed")
      ensure
        socket.close
      end
      raise Error.new("The agent for #{project} closed the connection without replying", code: "connection_failed") if reply.nil?
      JSON.parse(reply)
    rescue JSON::ParserError
      raise Error.new("Unreadable reply from the agent for #{project}", code: "unreadable_reply")
    end
  end
end
