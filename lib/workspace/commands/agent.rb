require "socket"
require "json"
require "securerandom"

module Workspace
  module Commands
    # Runs the long-lived workspace agent: probes for an existing agent,
    # registers with the work-coordinator, binds its own Unix socket, and
    # serves commands until terminated.
    class Agent
      # @param config [Workspace::Config] path configuration
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param work_coordinator_client [Workspace::WorkCoordinatorClient] coordinator client
      # @param epoch_generator [#call] returns a new epoch string
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      def initialize(config:, tmux:, work_coordinator_client:,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @work_coordinator_client = work_coordinator_client
        @epoch_generator = epoch_generator
        @signal_trapper = signal_trapper
        @logger = logger
        @output = output
        @error_output = error_output
      end

      # @return [String] a lexicographically sortable 26-character ULID
      def self.ulid
        encoding = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        value = (Time.now.to_f * 1000).to_i << 80 | SecureRandom.random_number(1 << 80)
        (0...26).reverse_each.map { |i| encoding[(value >> (i * 5)) & 31] }.join
      end

      # Starts the agent for a workspace and serves until terminated.
      #
      # @param name [String] workspace name
      # @param wc_socket [String, nil] override path to the coordinator socket
      # @return [Boolean] false when the agent refused to start, true after a clean shutdown
      def call(name:, wc_socket: nil)
        socket_path = @config.agent_socket_path(name)

        return false unless claim_socket(name, socket_path)

        epoch = @epoch_generator.call
        return false unless register(name, socket_path, epoch, wc_socket)

        server = UNIXServer.new(socket_path)
        install_signal_handlers(server)

        @output.puts "workspace agent '#{name}' ready"
        serve(server)

        true
      ensure
        shutdown(name, socket_path, server) if server
      end

      # Accepts connections until the server is closed.
      #
      # @param server [UNIXServer] the bound server
      # @return [void]
      def serve(server)
        loop do
          client = server.accept
          client.close
        rescue IOError, Errno::EBADF
          break
        end
      end

      private

      # Returns true when the socket path is free to bind (cleaning up a stale
      # socket if needed), false when another agent is already answering.
      def claim_socket(name, socket_path)
        UNIXSocket.open(socket_path) { |s| s.close }
        @error_output.puts "workspace agent '#{name}' is already running"
        false
      rescue Errno::ECONNREFUSED
        @logger.debug { "removing stale socket #{socket_path}" }
        File.unlink(socket_path)
        true
      rescue Errno::ENOENT
        true
      end

      def register(name, socket_path, epoch, wc_socket)
        @client = wc_socket ? rebind_client(wc_socket) : @work_coordinator_client
        reply = @client.register(name: name, socket: socket_path, pipeline: true, epoch: epoch)
        return true if reply["ok"]

        @error_output.puts "Could not register with work-coordinator: #{reply["error"]}"
        false
      rescue Workspace::Error => e
        @error_output.puts "Could not reach work-coordinator: #{e.message}"
        false
      end

      def rebind_client(wc_socket)
        WorkCoordinatorClient.new(
          socket_path: wc_socket,
          status_socket_path: @work_coordinator_client.status_socket_path,
          logger: @logger
        )
      end

      def install_signal_handlers(server)
        %w[TERM INT].each do |signal|
          @signal_trapper.trap(signal) { server.close }
        end
      end

      def shutdown(name, socket_path, server)
        server.close unless server.closed?
        File.unlink(socket_path) if File.socket?(socket_path)
        @client.deregister(name: name)
      rescue Workspace::Error => e
        @logger.debug { "deregister failed: #{e.message}" }
      end
    end
  end
end
