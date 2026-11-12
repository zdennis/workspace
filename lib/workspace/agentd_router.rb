require "json"

module Workspace
  # The agent daemon's table from an {AgentProtocol} message type to the handler that answers it. A message
  # addressed to another workspace is refused with +wrong_workspace+, and a type with no handler with
  # +unknown_type+; the coordinator's restart notice names no workspace, so it goes to its handler unchecked.
  class AgentdRouter
    # The types handled whatever workspace the message names.
    UNADDRESSED = [AgentProtocol::COORDINATOR_RESTART].freeze

    # @param workspace [String, nil] the workspace served; nil refuses every addressed message
    # @param handlers [Hash{String => #call}] by message type, each called with the message and the client;
    #   it answers on the client itself (through {#reply}) and returns +:handed_off+ when a worker thread now owns it
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, handlers:, logger: Workspace::Logger.new)
      @workspace = workspace
      @handlers = handlers
      @logger = logger
    end

    # Routes one parsed message to its handler, or answers it with +wrong_workspace+ or +unknown_type+.
    #
    # @param message [Hash] the parsed message, with its +"type"+ and +"workspace"+
    # @param client [#puts, nil] the connection to answer on
    # @return [Symbol, nil] +:handed_off+ when a worker thread now owns +client+
    def handle(message, client = nil)
      @logger.debug { "received: #{JSON.pretty_generate(message)}" }
      type = AgentProtocol.type_of(message)
      handler = @handlers[type]
      return handler.call(message, client) if handler && UNADDRESSED.include?(type)

      workspace = message["workspace"]
      if !WorkspaceName.same?(workspace, @workspace)
        @logger.debug { "dropped message for workspace '#{workspace}' (I am '#{@workspace}')" }
        return reply(client, AgentProtocol.error(AgentProtocol::WRONG_WORKSPACE))
      end
      return handler.call(message, client) if handler

      @logger.debug { "unknown message type: #{message["type"]}" }
      reply(client, AgentProtocol.error(AgentProtocol::UNKNOWN_TYPE))
    end

    # Answers on the connection the message arrived on, as one JSON line. A fire-and-forget
    # sender that has already hung up is not an error worth reporting.
    #
    # @param client [#puts, nil] the connection; nil writes nothing
    # @param payload [Object] the reply, written as JSON
    # @return [nil]
    def reply(client, payload)
      client&.puts(payload.to_json)
      nil
    rescue SystemCallError, IOError => e
      @logger.debug { "no one was listening for the reply: #{e.message}" }
      nil
    end
  end
end
