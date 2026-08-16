require "socket"
require "json"

module Workspace
  # Talks to the work-coordinator over its Unix sockets using JSONL messages.
  #
  # Each request opens a connection, writes one JSON line, reads one JSON line
  # reply, and closes. The coordinator is assumed to be a separate process.
  class WorkCoordinatorClient
    # @param socket_path [String] path to the coordinator's main socket
    # @param status_socket_path [String] path to the coordinator's status socket
    # @param logger [Workspace::Logger] debug logger
    def initialize(socket_path:, status_socket_path:, logger: Workspace::Logger.new)
      @socket_path = socket_path
      @status_socket_path = status_socket_path
      @logger = logger
    end

    # @return [String] path to the coordinator's main socket
    attr_reader :socket_path

    # @return [String] path to the coordinator's status socket
    attr_reader :status_socket_path

    # Registers a workspace agent with the coordinator.
    #
    # @param name [String] workspace name
    # @param socket [String] path to the agent's own socket
    # @param pipeline [Boolean] whether the agent participates in the pipeline
    # @param epoch [String] the agent's epoch identifier
    # @param in_flight [Array<Hash>] work items the agent believes are in flight
    # @return [Hash] the parsed reply
    # @raise [Workspace::Error] if the coordinator cannot be reached
    def register(name:, socket:, pipeline:, epoch:, in_flight: [])
      send_message(@socket_path, {
        "type" => "register",
        "name" => name,
        "socket" => socket,
        "pipeline" => pipeline,
        "epoch" => epoch,
        "in_flight" => in_flight
      })
    end

    # Deregisters a workspace agent from the coordinator.
    #
    # @param name [String] workspace name
    # @return [Hash] the parsed reply
    # @raise [Workspace::Error] if the coordinator cannot be reached
    def deregister(name:)
      send_message(@socket_path, {"type" => "deregister", "name" => name})
    end

    # Sends a status report to the coordinator's status socket.
    #
    # @param payload [Hash] the status payload
    # @return [Hash] the parsed reply
    # @raise [Workspace::Error] if the coordinator cannot be reached
    def report_status(payload)
      send_message(@status_socket_path, payload)
    end

    private

    def send_message(path, payload)
      @logger.debug { "wc-client -> #{path}: #{payload.to_json}" }
      reply = UNIXSocket.open(path) do |socket|
        socket.puts(payload.to_json)
        socket.gets
      end
      raise Workspace::Error, "work-coordinator closed the connection without replying" if reply.nil?
      JSON.parse(reply)
    rescue Errno::ENOENT, Errno::ECONNREFUSED => e
      raise Workspace::Error, "Could not reach work-coordinator at #{path}: #{e.message}"
    rescue JSON::ParserError => e
      raise Workspace::Error, "Invalid reply from work-coordinator at #{path}: #{e.message}"
    end
  end
end
