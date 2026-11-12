# frozen_string_literal: true

require "fileutils"

module Workspace
  # The agent daemon's pipeline and its work-coordinator traffic: a command typed into the first stage
  # (or the Claude pane), each stage watched for its sentinel and handed on, steers (+inject+), and every
  # status report stamped, retried, buffered while the coordinator is away and replayed when it is back.
  #
  # Poller threads and the accept loop both change the pollers, steers, pipeline state and report buffer,
  # so those change under one state lock, held briefly and never across a delivery to a pane. Deliveries
  # take turns under the daemon's delivery lock, taken before the state lock and never inside it.
  class PipelineDesk
    # How many times one status report is sent before it is buffered for replay.
    REPORT_ATTEMPTS = 3
    # How many unacknowledged reports are held before the oldest are dropped.
    MAX_PENDING_REPORTS = 500
    # Longest stage summary written to the event log.
    MAX_LOGGED_SUMMARY = 500

    # @param workspace [String] the workspace the daemon serves
    # @param session_name [String] the workspace's tmux session
    # @param tmux [Workspace::Tmux] types into, interrupts and reads the session's window-0 panes
    # @param config [Workspace::Config] path configuration (where stage hand-off files go)
    # @param pipeline_config [Workspace::PipelineConfig] the workspace's pipeline stages
    # @param pipeline_state [Workspace::PipelineState] in-flight work item tracking
    # @param client [Workspace::WorkCoordinatorClient] the coordinator registrations and reports go to
    # @param delivery_lock [Mutex] the daemon's lock that deliveries to panes take turns under
    # @param sentinel_poller_factory [#call] given +session_name:+, +pane:+, +token:+ and +deadline:+, builds the
    #   {Workspace::SentinelPoller} that watches a stage
    # @param stage_marks [#call] given a stage's timeout in seconds (nil for none), answers a fresh sentinel token and
    #   the stage's deadline (nil with no timeout) for a stage started now
    # @param retry_backoff [Numeric] seconds to wait between status report retries (times the attempt number)
    # @param event_log [Workspace::EventLog, nil] records dispatches, stage completions and failures; nil records nothing
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] where failures and warnings are written
    def initialize(workspace:, session_name:, tmux:, config:, pipeline_config:, pipeline_state:, client:, delivery_lock:,
      sentinel_poller_factory:, stage_marks:, retry_backoff: 0.5, event_log: nil, logger: Workspace::Logger.new, error_output: $stderr)
      @workspace = workspace
      @session_name = session_name
      @tmux = tmux
      @config = config
      @pipeline_config = pipeline_config
      @pipeline_state = pipeline_state
      @work_coordinator_client = client
      @client = nil
      @delivery_lock = delivery_lock
      @sentinel_poller_factory = sentinel_poller_factory
      @stage_marks = stage_marks
      @retry_backoff = retry_backoff
      @event_log = event_log
      @logger = logger
      @error_output = error_output
      @re_register = -> { false }
      @pollers = {}
      @sequences = Hash.new(0)
      @queued_steers = {}
      @pending_reports = []
      @buffering_announced = false
      @coordinator_unavailable = false
      @wc_epoch = nil
      @state_lock = Mutex.new
    end

    # @return [#call] re-registers the workspace when the coordinator restarted, answering true when it took
    #   the registration (the buffered reports are then replayed)
    attr_writer :re_register

    # Picks up work the previous agent process left behind: a stage whose pane is alive gets its watch
    # re-armed (its persisted token, or any sentinel for an entry without one; a passed deadline fails it
    # on the first pass unless that pass finds its sentinel); one whose pane died is dropped, which tells
    # the coordinator, through the registration, to reconcile it.
    # @return [void]
    def recover_in_flight
      @pipeline_state.in_flight_refs.each do |ref|
        entry = @pipeline_state.current(ref)
        next unless entry
        pane = entry[:pane_index]
        # Checked against the session served, not the name in the file, so the check and the watch agree.
        if pane_alive?(pane)
          @state_lock.synchronize do
            watch_for_completion(ref, pane, entry[:sentinel_token], @pipeline_state.deadline(ref))
          end
          @logger.debug { "re-attached sentinel watch for #{ref} at pane #{pane}" }
        else
          @error_output.puts "workspace agent: #{ref} lost its pane (#{pane}) while the agent was down"
          log_activity("stage_failed", "work_item_ref" => ref, "pane" => pane, "message" => "lost its pane while the agent was down")
          # A watch re-armed earlier in this loop may be writing the file from its poller thread.
          @state_lock.synchronize { @pipeline_state.complete(work_item_ref: ref) }
        end
      end
    end

    # Registers the workspace with the coordinator at startup, through a client rebound to +wc_socket+
    # when one is given.
    # @param socket [String] the daemon's own socket path
    # @param epoch [String] this daemon's epoch
    # @param wc_socket [String, nil] a coordinator socket to use instead of the configured one
    # @return [Boolean] true when the coordinator accepted the registration
    def register(socket:, epoch:, wc_socket: nil)
      @client = wc_socket ? rebind_client(wc_socket) : @work_coordinator_client
      reply = send_registration(socket: socket, epoch: epoch)
      @wc_epoch = reply["epoch"]
      return true if reply["ok"]
      @error_output.puts "Could not register with work-coordinator: #{reply["error"]}"
      false
    rescue Workspace::Error => e
      @error_output.puts "Could not reach work-coordinator: #{e.message}"
      false
    end

    # Sends the workspace's registration (socket, pipeline flag, epoch, in-flight items) to the coordinator
    # reports go to. A pipeline workspace is not told to report task_complete itself: its pollers do.
    # @param socket [String] the daemon's own socket path
    # @param epoch [String] the epoch to register under
    # @return [Hash] the coordinator's reply
    # @raise [Workspace::Error] when the coordinator cannot be reached
    def send_registration(socket:, epoch:)
      status_client.register(name: @workspace, socket: socket, pipeline: @pipeline_config.pipeline?(@workspace),
        epoch: epoch, in_flight: @pipeline_state.in_flight)
    end

    # Tells the coordinator the daemon is going away.
    # @return [void]
    # @raise [Workspace::Error] when the coordinator cannot be reached
    def deregister
      @client.deregister(name: @workspace)
    end

    # Stops every stage watch, as the daemon shuts down.
    # @return [void]
    def stop_watches
      @pollers.each_value(&:stop)
      @pollers.clear
    end

    # Holds status reports from now on (a +coordinator_restart+ message), until the coordinator is back.
    # @return [void]
    def coordinator_restarting
      @state_lock.synchronize { @coordinator_unavailable = true }
    end

    # The work item whose current pipeline stage runs on pane +index+ of window 0, or nil.
    # @param index [Integer] the pane index
    # @return [String, nil]
    def pipeline_ref_on(index)
      @state_lock.synchronize do
        @pipeline_state.in_flight_refs.find { |ref| @pipeline_state.current(ref)&.dig(:pane_index) == index }
      end
    end

    # Delivers a command body to the first pipeline stage (told how to signal it is done), or the Claude
    # pane with no pipeline. Text that never reached the pane is reported and answered "not_delivered", and
    # its item dropped; text that may not have been submitted still starts the stage, with a warning,
    # since sending it again would type it twice.
    # @param message [Hash] the parsed +command+ message
    # @param claude_pane [#call] answers the tmux target of the workspace's Claude pane
    # @return [Hash] the reply for the sender
    def command(message, claude_pane:)
      ref = message["work_item_ref"]
      stages = @pipeline_config.stages_for(@workspace)
      text = "#{message["body"]}#{reporting_text(message)}"
      entry, started_message, watch_pane, token, deadline, timeout, delivery = @delivery_lock.synchronize do
        if stages
          stage = stages.first
          token, deadline = @stage_marks.call(stage[:timeout])
          # A re-dispatch replaces the item's stage: the old watch's sentinel would advance the new one.
          @state_lock.synchronize { @pollers.delete(ref)&.stop }
          delivery = @tmux.deliver(@session_name, pane_target(stage[:pane_index]),
            "#{text}\n\n#{SentinelPoller.instruction(token)}")
          @state_lock.synchronize do
            unless delivery.landed?
              # The old watch is gone, so an item left here would have nothing running or watching.
              @queued_steers.delete(ref)
              @pipeline_state.complete(work_item_ref: ref) if @pipeline_state.current(ref)
              next [untracked_entry(ref), nil, nil, nil, nil, nil, delivery]
            end
            started = @pipeline_state.start(work_item_ref: ref, workspace_name: @workspace,
              dispatch_id: message["dispatch_id"], sentinel_token: token, deadline: deadline)
            @logger.debug { "pipeline started for #{ref} at pane #{stage[:pane_index]} (#{stage[:role]})" }
            [started, "Pipeline started at stage #{stage[:role]} (pane #{stage[:pane_index]})", stage[:pane_index], token, deadline, stage[:timeout], delivery]
          end
        else
          target = claude_pane.call
          @logger.debug { "delivering #{ref} to #{@session_name}:#{target}" }
          delivery = @tmux.deliver(@session_name, target, text)
          @logger.debug { "command for #{ref} to #{@session_name}:#{target}: #{delivery.status}" }
          [untracked_entry(ref), "Command delivered to #{@session_name}:#{target}", nil, nil, nil, nil, delivery]
        end
      end
      unless delivery.landed?
        failure = "command for #{ref} was not delivered to #{@workspace}: #{delivery.message}"
        @error_output.puts "workspace agent: #{failure}"
        log_activity("dispatch_failed", "work_item_ref" => ref, "dispatch_id" => message["dispatch_id"], "message" => delivery.message)
        report(entry, "type" => "error", "message" => failure)
        return AgentProtocol.error("not_delivered", delivery.message)
      end
      log_activity("dispatched", "work_item_ref" => ref, "dispatch_id" => message["dispatch_id"],
        "stage" => stages&.first&.dig(:role), "pane" => watch_pane, "delivery" => delivery.status.to_s)
      # Reported before the poller is armed, so "started" precedes anything the poller reports.
      report(entry, "type" => "status_update", "message" => started_message)
      unless delivery.ok?
        @error_output.puts "workspace agent: #{ref}: #{delivery.message}"
        report(entry, "type" => "status_update", "message" => "Warning: #{delivery.message}")
      end
      arm_watch(ref, watch_pane, token, deadline, timeout) if watch_pane
      AgentProtocol.ok
    end

    # Accepts a mid-pipeline steer: an urgent one interrupts the running stage, an ordinary one waits
    # for the next stage.
    # @param message [Hash] the parsed +inject+ message
    # @return [Hash] the reply for the sender
    def inject(message)
      ref = message["work_item_ref"]
      # Held across the decision and the keystrokes, or a hand-off mid-inject could get C-c sent to a
      # pane the work item has left.
      @delivery_lock.synchronize do
        urgent = nil
        decided = @state_lock.synchronize do
          entry = @pipeline_state.current(ref)
          if entry.nil?
            @logger.debug { "steer for #{ref} dropped: no active pipeline" }
            AgentProtocol.error("no_active_pipeline")
          elsif stale_token?(message, entry)
            # Aimed at a stage that has finished; typing now would reach the one that replaced it.
            @logger.debug { "steer for #{ref} dropped: stage token no longer current" }
            AgentProtocol.error("stale_token")
          elsif message["interrupt"]
            urgent = entry
            nil
          elsif (next_stage = next_stage_for(entry))
            (@queued_steers[ref] ||= []) << message["body"]
            AgentProtocol.ok(queued_for_pane: next_stage[:pane_index])
          else
            # No later pane to hold it for, so say so rather than queue it into a vanishing state.
            AgentProtocol.error("no_next_stage")
          end
        end
        decided || urgent_steer_reply(ref, urgent, message["body"])
      end
    end

    # Reports progress while a stage runs, without touching its pane.
    # @param work_item_ref [String]
    # @param message [String] the progress text
    # @return [void]
    def report_progress(work_item_ref, message)
      entry = @pipeline_state.current(work_item_ref)
      return unless entry
      report(entry, "type" => "status_update", "message" => message)
    end

    # Takes a work item out of the pipeline after its current stage failed; no later stage starts.
    # @param work_item_ref [String]
    # @param message [String] why the work item failed
    # @param watched_by [Object, nil] fails it only while this poller still watches it, so a replaced
    #   watch cannot fail the stage that replaced it
    # @param event [String] the event log type: "stage_failed", or "stage_timed_out" past a deadline
    # @return [void]
    def fail_pipeline(work_item_ref, message, watched_by: nil, event: "stage_failed")
      entry = @state_lock.synchronize do
        next nil if watched_by && !@pollers[work_item_ref].equal?(watched_by)
        @pollers.delete(work_item_ref)&.stop
        @queued_steers.delete(work_item_ref)
        found = @pipeline_state.current(work_item_ref)
        @pipeline_state.complete(work_item_ref: work_item_ref) if found
        found
      end
      return unless entry
      @error_output.puts "workspace agent: #{work_item_ref} failed at pane #{entry[:pane_index]}: #{message}"
      log_activity(event, "work_item_ref" => work_item_ref, "pane" => entry[:pane_index], "message" => message)
      report(entry, "type" => "error", "message" => message)
    end

    private

    def pane_alive?(pane_index)
      @tmux.panes(@session_name).include?(pane_index)
    rescue => e
      @logger.debug { "pane check failed for #{@session_name}: #{e.message}" }
      false
    end

    def urgent_steer_reply(ref, entry, body)
      delivery = deliver_urgent_steer(entry, body)
      return AgentProtocol.ok(queued_for_pane: entry[:pane_index]) if delivery.ok?
      # "not_submitted": the text is, or may be, in the pane, so resending could type it twice.
      @error_output.puts "workspace agent: steer for #{ref} to pane #{entry[:pane_index]}: #{delivery.message}"
      AgentProtocol.error((delivery.landed? ? "not_submitted" : "not_delivered"), delivery.message)
    end

    # An inject may name its stage by token; one without is aimed at whatever stage is running.
    def stale_token?(message, entry)
      expected = message["expected_token"]
      !expected.nil? && expected != entry[:sentinel_token]
    end

    # Interrupts the stage's pane, then types the steer, which carries no reporting instructions (the
    # agent has them from its command).
    def deliver_urgent_steer(entry, body)
      @tmux.send_key(@session_name, pane_target(entry[:pane_index]), "C-c")
      @tmux.deliver(@session_name, pane_target(entry[:pane_index]), body)
    end

    # The stage after the one this entry is sitting on, or nil when it is last.
    def next_stage_for(entry)
      stages = @pipeline_config.stages_for(entry[:workspace_name]) || []
      index = stages.index { |stage| stage[:pane_index] == entry[:pane_index] }
      index && stages[index + 1]
    end

    # Frames the coordinator's ready-rendered reporting block (its text and whether to send it are the
    # coordinator's). Only stage 1 sees it; later stages are seen through this desk's own reports.
    def reporting_text(message)
      instructions = message["reporting_instructions"]
      stripped = instructions.strip if instructions.is_a?(String)
      (stripped.nil? || stripped.empty?) ? "" : "\n\nStatus reporting:\n#{stripped}"
    end

    # Pane N of window 0, the one window a workspace uses.
    def pane_target(index)
      "0.#{index}"
    end

    # Never raises: {Workspace::EventLog#record} swallows write errors.
    def log_activity(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end

    # A one-shot entry to stamp a report on for work the pipeline does not track.
    def untracked_entry(work_item_ref)
      {work_item_ref: work_item_ref, workspace_name: @workspace}
    end

    # Arms the watch for a stage started outside the lock, unless the item has since moved on.
    def arm_watch(work_item_ref, pane, token, deadline, timeout)
      @state_lock.synchronize do
        next unless @pipeline_state.current(work_item_ref)&.fetch(:sentinel_token, nil) == token
        watch_for_completion(work_item_ref, pane, token, deadline, timeout)
      end
    end

    # Watches a stage's pane for the sentinel carrying +token+, replacing the item's poller. A stage still
    # running at +deadline+ fails, naming +timeout+ (its budget; nil when unknown, as after a restart).
    def watch_for_completion(work_item_ref, pane, token, deadline, timeout = nil)
      @pollers.delete(work_item_ref)&.stop
      poller = @sentinel_poller_factory.call(session_name: @session_name, pane: pane,
        token: token, deadline: deadline)
      @pollers[work_item_ref] = poller
      on_error = ->(message) { fail_pipeline(work_item_ref, message, watched_by: poller) }
      on_timeout = lambda do
        fail_pipeline(work_item_ref, timeout_message(token, deadline, timeout), watched_by: poller, event: "stage_timed_out")
      end
      poller.start(on_error: on_error, on_timeout: on_timeout) do |summary|
        advance_pipeline(work_item_ref, summary, poller)
      end
    end

    def timeout_message(token, deadline, timeout)
      budget = timeout ? " after #{format_duration(timeout)}" : ""
      "timed out#{budget} (deadline #{deadline.utc.iso8601}): no #{SentinelPoller.marker(token)} line"
    end

    # Seconds as the largest whole unit a pipeline config would use: 1800 -> "30m".
    def format_duration(seconds)
      seconds = seconds.round if seconds == seconds.round
      return "#{seconds / 3600}h" if seconds.is_a?(Integer) && seconds.positive? && (seconds % 3600).zero?
      return "#{seconds / 60}m" if seconds.is_a?(Integer) && seconds.positive? && (seconds % 60).zero?
      "#{seconds}s"
    end

    # Hands the finished stage's output to the next stage, or reports the item complete. Only the poller
    # watching the item may move it. The next watch is armed after the reports, so the coordinator hears
    # the hand-off first; a hand-off that raises fails the item, since nothing else would look again.
    def advance_pipeline(work_item_ref, summary, poller)
      entry, next_stage, from_pane, next_watch, steer_failures =
        @delivery_lock.synchronize { advance_state(work_item_ref, poller) }
      return unless entry
      log_activity("stage_completed", "work_item_ref" => work_item_ref, "pane" => from_pane,
        "next_stage" => next_stage&.dig(:role), "next_pane" => next_stage&.dig(:pane_index), "summary" => summary.to_s[0, MAX_LOGGED_SUMMARY])
      # Outside the locks: a slow coordinator must not stall command dispatch.
      begin
        if next_stage
          report(entry, "type" => "phase_change", "phase" => next_stage[:role])
          report(entry, "type" => "pipeline_advanced", "from_pane" => from_pane, "to_pane" => next_stage[:pane_index])
          steer_failures.each { |payload| report(entry, payload) }
        else
          report(entry, "type" => "task_complete", "summary" => summary)
        end
      ensure
        # The next stage is running, so it is watched even if reporting its start went wrong.
        arm_watch(work_item_ref, *next_watch) if next_watch
      end
    rescue => e
      @error_output.puts "workspace agent: could not advance #{work_item_ref}: #{e.message}"
      fail_pipeline(work_item_ref, e.message, watched_by: poller)
    end

    # Moves the item onto its next stage (or off the pipeline), under the delivery lock; answers the entry,
    # next stage, pane left, arm_watch arguments (nil after the last) and failed steers' reports, or nil
    # when +poller+ no longer watches it. The state lock is held to decide and to commit, the panes typed
    # between; the old poller stays registered until the next watch replaces it.
    def advance_state(work_item_ref, poller)
      entry, next_stage, steers = @state_lock.synchronize do
        next unless @pollers[work_item_ref].equal?(poller)
        found = @pipeline_state.current(work_item_ref)
        next unless found
        stage = next_stage_for(found)
        [found, stage, stage ? @queued_steers.delete(work_item_ref) || [] : []]
      end
      return nil unless entry
      session = @session_name
      from_pane = entry[:pane_index]
      captured = @tmux.capture_pane(session, from_pane, all: true) || ""
      handoff_path = write_handoff(entry[:workspace_name], work_item_ref, captured)
      steer_failures = []
      if next_stage
        token, deadline = @stage_marks.call(next_stage[:timeout])
        delivery = @tmux.deliver(session, pane_target(next_stage[:pane_index]),
          handoff_instructions(next_stage[:role], handoff_path, token))
        # Raised before the state moves, so the caller fails the item: the next stage got no instructions.
        unless delivery.landed?
          raise Workspace::Error,
            "could not hand off to the #{next_stage[:role]} stage (pane #{next_stage[:pane_index]}): #{delivery.message}"
        end
        @error_output.puts "workspace agent: #{work_item_ref}: #{delivery.message}" unless delivery.ok?
        steer_failures = deliver_queued_steers(session, work_item_ref, next_stage[:pane_index], steers)
        next_watch = [next_stage[:pane_index], token, deadline, next_stage[:timeout]]
      end
      committed = @state_lock.synchronize do
        # Failed or aborted while its panes were typed into: moving it now would bring it back.
        next false unless @pollers[work_item_ref].equal?(poller) && @pipeline_state.current(work_item_ref)
        if next_stage
          @pipeline_state.advance(work_item_ref: work_item_ref, to_stage: next_stage,
            sentinel_token: next_watch[1], deadline: next_watch[2])
        else
          @queued_steers.delete(work_item_ref)
          @pipeline_state.complete(work_item_ref: work_item_ref)
          @pollers.delete(work_item_ref)&.stop
        end
        true
      end
      return nil unless committed
      [entry, next_stage, from_pane, next_watch, steer_failures]
    end

    # Types the steers queued during the previous stage; each not confirmed comes back as a report (an
    # error when it never arrived, a warning when it may have), since its sender was told it was accepted.
    def deliver_queued_steers(session, work_item_ref, pane, steers)
      steers.filter_map do |steer|
        delivery = @tmux.deliver(session, pane_target(pane), steer)
        next if delivery.ok?
        @error_output.puts "workspace agent: queued steer for #{work_item_ref} to pane #{pane}: #{delivery.message}"
        if delivery.landed?
          {"type" => "status_update", "message" => "Warning: queued steer for pane #{pane}: #{delivery.message}"}
        else
          {"type" => "error", "message" => "queued steer for pane #{pane} was not delivered: #{delivery.message}"}
        end
      end
    end

    # Where the previous stage's output is and how to signal done; the token is fresh per stage, so a
    # stage that prints its context (holding the old sentinel) does not end itself.
    def handoff_instructions(role, handoff_path, token)
      "You are the #{role} stage. Context from the previous stage: #{handoff_path}\n" \
        "#{SentinelPoller.instruction(token)}"
    end

    # Writes a stage's output for the next stage; the ref comes off a socket, so it is made path-safe.
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

    # Stamps a payload with the item's next message id and sequence, then sends it; an unreachable
    # coordinator buffers it rather than take the pipeline down.
    def report(entry, payload)
      # Stamped once: a retry is the same report, with the same id and sequence.
      full_payload = stamp(entry).merge(payload)
      ref = entry[:work_item_ref]
      if @state_lock.synchronize { @coordinator_unavailable }
        buffer_report(ref, full_payload, Workspace::Error.new("coordinator unavailable"))
        return
      end
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

    # Holds a report the coordinator would not take, for replay once it is back; capped, dropping the oldest.
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

    # Acts on the coordinator's answer, the authority on whether an item is still worth reporting on.
    def handle_status_reply(work_item_ref, reply)
      case reply["action"]
      when "give_up"
        @error_output.puts "workspace agent: work-coordinator has no record of #{work_item_ref}; stopping its pipeline"
        log_activity("pipeline_dropped", "work_item_ref" => work_item_ref, "message" => "work-coordinator has no record of it")
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

    # A new epoch is a coordinator we did not register with, which knows nothing of our work.
    def check_epoch(epoch)
      return if epoch.nil? || epoch == @wc_epoch
      handle_wc_restart(epoch) if @wc_epoch
      @wc_epoch = epoch
    end

    def handle_wc_restart(epoch)
      @logger.debug { "work-coordinator restarted (epoch #{@wc_epoch.inspect} -> #{epoch.inspect}); re-registering" }
      @wc_epoch = epoch
      # The drain waits on a good registration, or it would burn the buffer.
      if @re_register.call
        @state_lock.synchronize { @coordinator_unavailable = false }
        drain_pending_reports
      end
    end

    # Replays what the coordinator missed, in order, stopping at the first refusal with the rest put back.
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

    # The envelope of one report; the counters survive an item leaving and re-entering the pipeline.
    def stamp(entry)
      ref = entry[:work_item_ref]
      @state_lock.synchronize do
        sequence = (@sequences[ref] += 1)
        {"message_id" => "m-#{sequence}", "sequence" => sequence, "workspace" => entry[:workspace_name], "work_item_ref" => ref}
      end
    end

    def status_client
      @client || @work_coordinator_client
    end

    def rebind_client(wc_socket)
      WorkCoordinatorClient.new(socket_path: wc_socket, status_socket_path: @work_coordinator_client.status_socket_path, logger: @logger)
    end
  end
end
