require "socket"
require "json"

module Workspace
  # Asks one workspace's agent daemon for its session snapshot over the
  # daemon's Unix socket, with a bound on how long it waits for the reply.
  #
  # Shared by `workspace sessions` and `workspace projects show`, so a hung
  # daemon costs a caller at most the timeout instead of blocking forever.
  class AgentSnapshotClient
    # Seconds to wait for a reply when the caller gives no timeout.
    DEFAULT_TIMEOUT = 5.0

    # Nothing answered: the socket is missing or refused the connection, or
    # the daemon didn't reply in time. Callers that can carry on without the
    # snapshot rescue this; {#reason} says which of the two it was.
    class Unavailable < Workspace::Error
      # @return [Symbol] `:no_daemon` or `:timeout`
      attr_reader :reason

      def initialize(message, reason:)
        super(message)
        @reason = reason
      end
    end

    # @param config [Workspace::Config] socket path lookups
    # @param timeout [Numeric] default seconds to wait for a reply
    # @param connector [#call] opens a socket for a path; injected so tests need no real daemon
    # @param clock [#call] monotonic seconds, injected for tests
    def initialize(config:, timeout: DEFAULT_TIMEOUT, connector: ->(path) { UNIXSocket.new(path) },
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @config = config
      @timeout = timeout
      @connector = connector
      @clock = clock
    end

    # @param name [String] workspace name
    # @param timeout [Numeric, nil] seconds to wait for the reply; nil uses the default
    # @return [Hash] the daemon's parsed snapshot
    # @raise [Unavailable] if no daemon is listening or it doesn't answer in time
    # @raise [Workspace::Error] if the daemon closes the connection or sends a malformed reply
    def fetch(name, timeout: nil)
      limit = timeout || @timeout
      deadline = @clock.call + limit
      socket = @connector.call(@config.agent_socket_path(name))
      begin
        socket.puts(JSON.generate("type" => "sessions", "workspace" => name))
        reply = read_line(socket, deadline, name, limit)
      ensure
        socket.close unless socket.closed?
      end
      snapshot = begin
        JSON.parse(reply)
      rescue JSON::ParserError
        nil
      end
      raise Workspace::Error, "Malformed reply from session monitor for '#{name}'." unless snapshot.is_a?(Hash)
      snapshot
    rescue SystemCallError, IOError
      raise Unavailable.new("No agent daemon for '#{name}'.\nStart one with:  workspace agentd #{name}", reason: :no_daemon)
    end

    private

    def read_line(socket, deadline, name, limit)
      buffer = +""
      until buffer.include?("\n")
        remaining = deadline - @clock.call
        raise timeout_error(name, limit) unless remaining.positive? && socket.wait_readable(remaining)
        chunk = socket.read_nonblock(65_536, exception: false)
        next if chunk == :wait_readable
        break if chunk.nil?
        buffer << chunk
      end
      raise Workspace::Error, "Agent for '#{name}' closed the connection." if buffer.empty?
      buffer.lines.first
    end

    def timeout_error(name, limit)
      Unavailable.new("Agent daemon for '#{name}' did not answer within #{limit}s.", reason: :timeout)
    end
  end
end
