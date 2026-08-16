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
      # How many times one status report is sent before it is buffered for replay.
      REPORT_ATTEMPTS = 3

      # How many unacknowledged reports are held before the oldest are dropped.
      MAX_PENDING_REPORTS = 500

      # @param config [Workspace::Config] path configuration
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param work_coordinator_client [Workspace::WorkCoordinatorClient] coordinator client
      # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
      # @param pipeline_state [Workspace::PipelineState, nil] in-flight work item
      #   tracking; built from the project's persisted state file when omitted
      # @param epoch_generator [#call] returns a new epoch string
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param sentinel_poller_factory [#call] builds a poller for a session/pane pair
      # @param retry_backoff [Float] seconds to wait between status report retries
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      def initialize(config:, tmux:, work_coordinator_client:, pipeline_config:, pipeline_state: nil,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        sentinel_poller_factory: nil,
        retry_backoff: 0.5,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @work_coordinator_client = work_coordinator_client
        @pipeline_config = pipeline_config
        @pipeline_state = pipeline_state
        @epoch_generator = epoch_generator
        @signal_trapper = signal_trapper
        @sentinel_poller_factory = sentinel_poller_factory || method(:build_sentinel_poller)
        @retry_backoff = retry_backoff
        @pollers = {}
        @sequences = Hash.new(0)
        @queued_steers = {}
        @pending_reports = []
        @buffering_announced = false
        @wc_epoch = nil
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

        @pipeline_state ||= PipelineState.new(
          pipeline_config: @pipeline_config,
          state_path: @config.pipeline_state_path(name)
        )
        recover_in_flight

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
          begin
            line = client.gets
            dispatch(JSON.parse(line), client) if line
          rescue JSON::ParserError => e
            @logger.debug { "malformed message dropped: #{e.message}" }
            reply_to(client, "ok" => false, "error" => "malformed_message")
          rescue => e
            # One bad pane or a wedged tmux must cost us this connection, not
            # the agent and every pipeline running under it.
            @error_output.puts "workspace agent: dropped a message: #{e.message}"
            reply_to(client, "ok" => false, "error" => "internal_error")
          ensure
            client.close
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
          @queued_steers.delete(work_item_ref)
          found = @pipeline_state.current(work_item_ref)
          @pipeline_state.complete(work_item_ref: work_item_ref) if found
          found
        end
        return unless entry

        @error_output.puts "workspace agent: #{work_item_ref} failed at pane #{entry[:pane_index]}: #{message}"
        report(entry, "type" => "error", "message" => message)
      end

      private

      # Picks up work the previous agent process left behind. A stage whose pane
      # is still alive gets its watch re-armed so it can still finish; a stage
      # whose pane died is dropped, and leaving it out of the registration is
      # what tells the coordinator to reconcile it.
      def recover_in_flight
        @pipeline_state.in_flight_refs.each do |ref|
          entry = @pipeline_state.current(ref)
          pane = entry[:pane_index]

          # Checked against the session we are actually serving, not the name in
          # the file, so the liveness check and the re-armed watch cannot differ.
          if pane_alive?(@current_name, pane)
            @state_lock.synchronize { watch_for_completion(ref, pane) }
            @logger.debug { "re-attached sentinel watch for #{ref} at pane #{pane}" }
          else
            @error_output.puts "workspace agent: #{ref} lost its pane (#{pane}) while the agent was down"
            @pipeline_state.complete(work_item_ref: ref)
          end
        end
      end

      def pane_alive?(session_name, pane_index)
        @tmux.panes(session_name).include?(pane_index)
      rescue => e
        @logger.debug { "pane check failed for #{session_name}: #{e.message}" }
        false
      end

      # Routes a parsed message, ignoring anything addressed to another workspace.
      def dispatch(message, client = nil)
        workspace = message["workspace"]
        if workspace != @current_name
          @logger.debug { "dropped message for workspace '#{workspace}' (I am '#{@current_name}')" }
          return reply_to(client, "ok" => false, "error" => "wrong_workspace")
        end

        # Every inbound connection ends in one JSON line, so a caller can always
        # read a reply and tell an answer apart from a dead agent.
        case message["type"]
        when "command"
          handle_command(message)
          reply_to(client, "ok" => true)
        when "inject" then handle_inject(message, client)
        else
          @logger.debug { "unknown message type: #{message["type"]}" }
          reply_to(client, "ok" => false, "error" => "unknown_type")
        end
      end

      # Accepts a mid-pipeline steer from the coordinator and answers on the same
      # connection. An urgent steer interrupts the running stage; an ordinary one
      # waits for the next stage so the running stage is left alone.
      def handle_inject(message, client)
        ref = message["work_item_ref"]

        # Held across the decision and the keystrokes: a poller thread advancing
        # this work item mid-inject would otherwise send C-c to a pane the work
        # item has already left.
        reply = @state_lock.synchronize do
          entry = @pipeline_state.current(ref)
          if entry.nil?
            @logger.debug { "steer for #{ref} dropped: no active pipeline" }
            {"ok" => false, "error" => "no_active_pipeline"}
          elsif message["interrupt"]
            deliver_urgent_steer(entry, message["body"])
            {"ok" => true, "queued_for_pane" => entry[:pane_index]}
          elsif (next_stage = next_stage_for(entry))
            (@queued_steers[ref] ||= []) << message["body"]
            {"ok" => true, "queued_for_pane" => next_stage[:pane_index]}
          else
            # Nothing comes after the last stage, so there is no later pane to
            # hold this for. Say so rather than queue it into a vanishing state.
            {"ok" => false, "error" => "no_next_stage"}
          end
        end

        reply_to(client, reply)
      end

      # Interrupts whatever the stage's pane is doing, then types the steer into it.
      def deliver_urgent_steer(entry, body)
        @tmux.send_key(entry[:workspace_name], entry[:pane_index], "C-c")
        @tmux.send_keys(entry[:workspace_name], entry[:pane_index], body)
      end

      # The stage after the one this entry is sitting on, or nil when it is last.
      def next_stage_for(entry)
        stages = @pipeline_config.stages_for(entry[:workspace_name]) || []
        index = stages.index { |stage| stage[:pane_index] == entry[:pane_index] }
        index && stages[index + 1]
      end

      # Answers on the connection the message arrived on. A fire-and-forget
      # sender that has already hung up is not an error worth reporting.
      def reply_to(client, payload)
        client&.puts(payload.to_json)
        nil
      rescue SystemCallError, IOError => e
        @logger.debug { "no one was listening for the reply: #{e.message}" }
        nil
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
          deliver_queued_steers(entry[:workspace_name], work_item_ref, next_stage[:pane_index])
          @pipeline_state.advance(work_item_ref: work_item_ref, to_stage: next_stage)
          watch_for_completion(work_item_ref, next_stage[:pane_index])
        else
          @queued_steers.delete(work_item_ref)
          @pipeline_state.complete(work_item_ref: work_item_ref)
          @pollers.delete(work_item_ref)&.stop
        end

        [entry, next_stage, from_pane]
      end

      # Hands the next stage any steers that arrived while the previous stage was
      # still running. Called with the state lock already held.
      def deliver_queued_steers(name, work_item_ref, pane)
        steers = @queued_steers.delete(work_item_ref) || []
        steers.each { |steer| @tmux.send_keys(name, pane, steer) }
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
        # Stamped once, up front: a retry is the same report, so it carries the
        # same message id and sequence number the coordinator already saw.
        full_payload = stamp(entry).merge(payload)
        ref = entry[:work_item_ref]

        REPORT_ATTEMPTS.times do |attempt|
          begin
            return handle_status_reply(ref, status_client.report_status(full_payload))
          rescue Workspace::Error => e
            last_error = e
          end
          if attempt == REPORT_ATTEMPTS - 1
            buffer_report(ref, full_payload, last_error)
          else
            sleep(@retry_backoff * (attempt + 1))
          end
        end
        nil
      end

      # Holds a report the coordinator would not take, so it can be replayed once
      # the coordinator is back. The pipeline keeps running either way. The buffer
      # is capped so an agent left running against a dead coordinator for hours
      # does not grow without bound; the oldest reports are the ones dropped.
      def buffer_report(work_item_ref, payload, error)
        dropped = @state_lock.synchronize do
          @pending_reports << payload
          @pending_reports.shift if @pending_reports.size > MAX_PENDING_REPORTS
        end
        unless @buffering_announced
          @buffering_announced = true
          @error_output.puts "workspace agent: work-coordinator unreachable; holding status updates until it returns"
        end
        @logger.debug { "buffered report for #{work_item_ref} after #{REPORT_ATTEMPTS} attempts: #{error.message}" }
        @logger.debug { "dropped oldest buffered report for #{dropped["work_item_ref"]}" } if dropped
      end

      # Acts on the coordinator's answer to a status report. The coordinator is
      # the authority on whether a work item is still worth reporting on.
      def handle_status_reply(work_item_ref, reply)
        case reply["action"]
        when "give_up"
          @error_output.puts "workspace agent: work-coordinator has no record of #{work_item_ref}; stopping its pipeline"
          @state_lock.synchronize do
            @pollers.delete(work_item_ref)&.stop
            @queued_steers.delete(work_item_ref)
            @pipeline_state.complete(work_item_ref: work_item_ref)
          end
        when "abort_pipeline"
          fail_pipeline(work_item_ref, "work-coordinator aborted the pipeline (#{reply["error"]})")
        when "reregister"
          handle_wc_restart(reply["epoch"])
        when nil
          check_epoch(reply["epoch"])
        else
          @logger.debug { "unknown action #{reply["action"].inspect} from work-coordinator" }
          check_epoch(reply["epoch"])
        end
        reply
      end

      # A new epoch means the coordinator we are talking to is not the one we
      # registered with, so it knows nothing about our in-flight work.
      def check_epoch(epoch)
        return if epoch.nil? || epoch == @wc_epoch
        handle_wc_restart(epoch) if @wc_epoch
        @wc_epoch = epoch
      end

      def handle_wc_restart(epoch)
        @logger.debug { "work-coordinator restarted (epoch #{@wc_epoch.inspect} -> #{epoch.inspect}); re-registering" }
        @wc_epoch = epoch
        # Replaying into a coordinator that would not have us back would just
        # burn the buffer, so the drain waits on a good registration.
        drain_pending_reports if re_register
      end

      # @return [Boolean] true when the coordinator accepted the registration
      def re_register
        reply = status_client.register(
          name: @current_name,
          socket: @config.agent_socket_path(@current_name),
          pipeline: true,
          epoch: @epoch_generator.call,
          in_flight: @pipeline_state.in_flight
        )
        return true if reply["ok"]

        @error_output.puts "workspace agent: work-coordinator refused re-registration: #{reply["error"]}"
        false
      rescue Workspace::Error => e
        @error_output.puts "workspace agent: could not re-register with work-coordinator: #{e.message}"
        false
      end

      # Replays everything the coordinator missed, in the order it was reported.
      # Stops at the first refusal and puts the rest back at the front, because a
      # report arriving after a later one is worse than one arriving late.
      def drain_pending_reports
        pending = @state_lock.synchronize { @pending_reports.slice!(0..-1) || [] }
        @buffering_announced = false if pending.any?

        until pending.empty?
          payload = pending.first
          begin
            status_client.report_status(payload)
          rescue Workspace::Error => e
            @logger.debug { "replay stopped at #{payload["work_item_ref"]}: #{e.message}" }
            @state_lock.synchronize { @pending_reports.unshift(*pending) }
            return
          end
          pending.shift
        end
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
        reply = @client.register(name: name, socket: socket_path, pipeline: true, epoch: epoch,
          in_flight: @pipeline_state.in_flight)
        @wc_epoch = reply["epoch"]
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
