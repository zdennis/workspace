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
      # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
      # @param pipeline_state [Workspace::PipelineState] in-flight work item tracking
      # @param epoch_generator [#call] returns a new epoch string
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      def initialize(config:, tmux:, work_coordinator_client:, pipeline_config:, pipeline_state:,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @work_coordinator_client = work_coordinator_client
        @pipeline_config = pipeline_config
        @pipeline_state = pipeline_state
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
        @current_name = name
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

      # Accepts and dispatches one JSON message per connection until the server closes.
      #
      # @param server [UNIXServer] the bound server
      # @return [void]
      def serve(server)
        loop do
          client = server.accept
          line = client.gets
          client.close
          next unless line

          begin
            dispatch(JSON.parse(line))
          rescue JSON::ParserError => e
            @logger.debug { "malformed message dropped: #{e.message}" }
          end
        rescue IOError, Errno::EBADF
          break
        end
      end

      private

      # Routes a parsed message, ignoring anything addressed to another workspace.
      def dispatch(message)
        workspace = message["workspace"]
        if workspace != @current_name
          @logger.debug { "dropped message for workspace '#{workspace}' (I am '#{@current_name}')" }
          return
        end

        case message["type"]
        when "command" then handle_command(message)
        else @logger.debug { "unknown message type: #{message["type"]}" }
        end
      end

      # Delivers a command body to the first pipeline stage, or to pane 0 when the
      # workspace has no pipeline configured.
      def handle_command(message)
        ref = message["work_item_ref"]
        stages = @pipeline_config.stages_for(@current_name)

        if stages
          stage = stages.first
          @tmux.send_keys(@current_name, stage[:pane_index], message["body"])
          @pipeline_state.start(
            work_item_ref: ref,
            workspace_name: @current_name,
            dispatch_id: message["dispatch_id"]
          )
          @logger.debug { "pipeline started for #{ref} at pane #{stage[:pane_index]} (#{stage[:role]})" }
        else
          @tmux.send_keys(@current_name, 0, message["body"])
          @logger.debug { "command delivered to default pane for #{ref}" }
        end
      end

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
