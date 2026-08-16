require "socket"
require "json"
require "fileutils"
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
      # @param sentinel_poller_factory [#call] builds a poller for a session/pane pair
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      def initialize(config:, tmux:, work_coordinator_client:, pipeline_config:, pipeline_state:,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        sentinel_poller_factory: nil,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @work_coordinator_client = work_coordinator_client
        @pipeline_config = pipeline_config
        @pipeline_state = pipeline_state
        @epoch_generator = epoch_generator
        @signal_trapper = signal_trapper
        @sentinel_poller_factory = sentinel_poller_factory || method(:build_sentinel_poller)
        @pollers = {}
        @sequences = Hash.new(0)
        # Poller threads advance the pipeline while the accept loop may be
        # dispatching another command; both mutate @pollers and pipeline state.
        @state_lock = Mutex.new
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

      # Reports something noteworthy that happened while a stage is running.
      # Never touches the pane, so a running stage keeps going.
      #
      # @param work_item_ref [String]
      # @param message [String] the progress text
      # @return [void]
      def report_progress(work_item_ref, message)
        entry = @pipeline_state.current(work_item_ref)
        return unless entry
        report(entry, "type" => "status_update", "message" => message)
      end

      # Takes a work item out of the pipeline after its current stage failed.
      # No further stage is started for it.
      #
      # @param work_item_ref [String]
      # @param message [String] why the work item failed
      # @return [void]
      def fail_pipeline(work_item_ref, message)
        entry = @state_lock.synchronize do
          @pollers.delete(work_item_ref)&.stop
          found = @pipeline_state.current(work_item_ref)
          @pipeline_state.complete(work_item_ref: work_item_ref) if found
          found
        end
        return unless entry

        @error_output.puts "workspace agent: #{work_item_ref} failed at pane #{entry[:pane_index]}: #{message}"
        report(entry, "type" => "error", "message" => message)
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

        entry, started_message, watch_pane = @state_lock.synchronize do
          if stages
            stage = stages.first
            @tmux.send_keys(@current_name, stage[:pane_index], message["body"])
            started = @pipeline_state.start(
              work_item_ref: ref,
              workspace_name: @current_name,
              dispatch_id: message["dispatch_id"]
            )
            @logger.debug { "pipeline started for #{ref} at pane #{stage[:pane_index]} (#{stage[:role]})" }
            [started, "Pipeline started at stage #{stage[:role]} (pane #{stage[:pane_index]})", stage[:pane_index]]
          else
            @tmux.send_keys(@current_name, 0, message["body"])
            @logger.debug { "command delivered to default pane for #{ref}" }
            [untracked_entry(ref), "Command delivered to default pane"]
          end
        end

        # Reported before the poller is armed so the "started" message always
        # precedes anything the poller thread goes on to report.
        report(entry, "type" => "status_update", "message" => started_message)
        @state_lock.synchronize { watch_for_completion(ref, watch_pane) } if watch_pane
      end

      # A one-shot reporting entry for work the agent does not track in the
      # pipeline. It exists only long enough to stamp a single status message.
      def untracked_entry(work_item_ref)
        {work_item_ref: work_item_ref, workspace_name: @current_name}
      end

      # Watches a stage's pane for the completion sentinel, replacing any poller
      # already watching this work item.
      def watch_for_completion(work_item_ref, pane)
        @pollers.delete(work_item_ref)&.stop
        poller = @sentinel_poller_factory.call(session_name: @current_name, pane: pane)
        @pollers[work_item_ref] = poller
        on_error = ->(message) { fail_pipeline(work_item_ref, message) }
        poller.start(on_error: on_error) { |summary| advance_pipeline(work_item_ref, summary) }
      end

      # Hands the finished stage's output to the next stage, or reports the work
      # item complete when the finished stage was the last one.
      def advance_pipeline(work_item_ref, summary)
        entry, next_stage, from_pane = @state_lock.synchronize do
          advance_state(work_item_ref)
        end
        return unless entry

        # Reporting talks to the coordinator over a socket, so it stays outside
        # the lock — a slow coordinator must not stall command dispatch.
        if next_stage
          report_phase_change(entry, next_stage[:role])
          report_pipeline_advanced(entry, from_pane, next_stage[:pane_index])
        else
          report_task_complete(entry, summary)
        end
      rescue => e
        @error_output.puts "workspace agent: could not advance #{work_item_ref}: #{e.message}"
      end

      # Moves the work item onto its next stage (or off the pipeline) and returns
      # the entry, the stage moved to, and the pane moved from.
      def advance_state(work_item_ref)
        entry = @pipeline_state.current(work_item_ref)
        return nil unless entry

        stages = @pipeline_config.stages_for(entry[:workspace_name]) || []
        current_index = stages.index { |stage| stage[:pane_index] == entry[:pane_index] }
        next_stage = current_index && stages[current_index + 1]
        from_pane = entry[:pane_index]

        captured = @tmux.capture_pane(entry[:workspace_name], from_pane, all: true) || ""
        handoff_path = write_handoff(entry[:workspace_name], work_item_ref, captured)

        if next_stage
          @tmux.send_keys(entry[:workspace_name], next_stage[:pane_index],
            handoff_instructions(next_stage[:role], handoff_path))
          @pipeline_state.advance(work_item_ref: work_item_ref, to_stage: next_stage)
          watch_for_completion(work_item_ref, next_stage[:pane_index])
        else
          @pipeline_state.complete(work_item_ref: work_item_ref)
          @pollers.delete(work_item_ref)&.stop
        end

        [entry, next_stage, from_pane]
      end

      # The stage-to-stage contract: where the previous stage's output lives and
      # how this stage signals that it is finished.
      def handoff_instructions(role, handoff_path)
        "You are the #{role} stage. Context from the previous stage: #{handoff_path}\n" \
          "When you are done, print a single line: #{SentinelPoller::SENTINEL} <one-line summary>"
      end

      # Writes a stage's captured output where the next stage can read it.
      # The work item reference comes off a socket, so it is reduced to path-safe
      # characters before it is allowed anywhere near a filename.
      def write_handoff(name, work_item_ref, content)
        dir = @config.handoff_dir
        FileUtils.mkdir_p(dir, mode: 0o700)
        path = File.join(dir, "#{path_safe(name)}-#{path_safe(work_item_ref)}-handoff.txt")
        File.write(path, content, perm: 0o600)
        path
      end

      def path_safe(value)
        value.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
      end

      def report_phase_change(entry, phase)
        report(entry, "type" => "phase_change", "phase" => phase)
      end

      def report_pipeline_advanced(entry, from_pane, to_pane)
        report(entry, "type" => "pipeline_advanced", "from_pane" => from_pane, "to_pane" => to_pane)
      end

      def report_task_complete(entry, summary)
        report(entry, "type" => "task_complete", "summary" => summary)
      end

      # Stamps a status payload with the work item's next message id and sequence
      # number, then sends it. A coordinator we cannot reach must not take the
      # pipeline down with it.
      def report(entry, payload)
        status_client.report_status(stamp(entry).merge(payload))
      rescue Workspace::Error => e
        @logger.debug { "status report failed: #{e.message}" }
      end

      # Builds the envelope for one status message. Counters live on the agent
      # keyed by work item so they survive a work item leaving and re-entering
      # the pipeline, and they are taken under the lock because the accept loop
      # and a poller thread can both report on the same work item.
      def stamp(entry)
        ref = entry[:work_item_ref]
        @state_lock.synchronize do
          sequence = (@sequences[ref] += 1)
          {
            "message_id" => "m-#{sequence}",
            "sequence" => sequence,
            "workspace" => entry[:workspace_name],
            "work_item_ref" => ref
          }
        end
      end

      def status_client
        @client || @work_coordinator_client
      end

      def build_sentinel_poller(session_name:, pane:)
        SentinelPoller.new(tmux: @tmux, session_name: session_name, pane: pane,
          logger: @logger, error_output: @error_output)
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
        @pollers.each_value(&:stop)
        @pollers.clear
        server.close unless server.closed?
        File.unlink(socket_path) if File.socket?(socket_path)
        @client.deregister(name: name)
      rescue Workspace::Error => e
        @logger.debug { "deregister failed: #{e.message}" }
      end
    end
  end
end
