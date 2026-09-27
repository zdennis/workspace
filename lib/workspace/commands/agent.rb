require "socket"
require "json"
require "fileutils"
require "securerandom"
require "shellwords"

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

      # How often the socket watcher checks that the agent's socket file is still there.
      SOCKET_POLL_INTERVAL = 5

      # Longest stage summary written to the event log.
      MAX_LOGGED_SUMMARY = 500

      # @param config [Workspace::Config] path configuration
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param work_coordinator_client [Workspace::WorkCoordinatorClient] coordinator client
      # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
      # @param pipeline_state [Workspace::PipelineState, nil] in-flight work item
      #   tracking; built from the project's persisted state file when omitted
      # @param epoch_generator [#call] returns a new epoch string
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param sentinel_poller_factory [#call] builds a poller for a session/pane/token
      # @param token_generator [#call] returns a fresh completion token for one stage dispatch
      # @param clock [#call] returns the current Time, for stage deadlines
      # @param session_monitor_factory [#call] builds the session monitor for a workspace name
      # @param lock_reaper [Workspace::LockReaper, nil] reaps stale lock holds from the session monitor's scan thread
      # @param alert_config [Workspace::AlertConfig, nil] reads the workspace's
      #   notify command and idle alert threshold; nil sends no alerts
      # @param notifier_factory [#call] builds a {Workspace::Notifier} for a command
      # @param ps_timeout [Numeric] seconds to wait for `ps` before killing it, for
      #   the session monitor's {Workspace::ProcessTree}
      # @param retry_backoff [Float] seconds to wait between status report retries
      # @param event_log [Workspace::EventLog, nil] records dispatches, stage
      #   completions and failures, and (through the session monitor) each agent
      #   pane's state changes; nil records nothing
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      def initialize(config:, tmux:, work_coordinator_client:, pipeline_config:, pipeline_state: nil,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        sentinel_poller_factory: nil,
        token_generator: -> { SecureRandom.hex(4) },
        clock: -> { Time.now },
        session_monitor_factory: nil,
        lock_reaper: nil,
        alert_config: nil,
        notifier_factory: nil,
        ps_timeout: Workspace::ProcessTree::DEFAULT_TIMEOUT,
        retry_backoff: 0.5,
        event_log: nil,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @config = config
        @tmux = tmux
        @work_coordinator_client = work_coordinator_client
        @pipeline_config = pipeline_config
        @pipeline_state = pipeline_state
        @epoch_generator = epoch_generator
        @signal_trapper = signal_trapper
        @sentinel_poller_factory = sentinel_poller_factory || method(:build_sentinel_poller)
        @token_generator = token_generator
        @clock = clock
        @session_monitor_factory = session_monitor_factory || method(:build_session_monitor)
        @session_monitor = nil
        @lock_reaper = lock_reaper
        @alert_config = alert_config
        @notifier_factory = notifier_factory || ->(command) { Notifier.new(command: command, error_output: @error_output) }
        @ps_timeout = ps_timeout
        @retry_backoff = retry_backoff
        @event_log = event_log
        @pollers = {}
        @sequences = Hash.new(0)
        @queued_steers = {}
        @pending_reports = []
        @buffering_announced = false
        @coordinator_unavailable = false
        @shutting_down = false
        @shutdown_signal = Queue.new
        @server = nil
        @wc_epoch = nil
        # Poller threads advance the pipeline while the accept loop may be
        # dispatching another command; both mutate @pollers and pipeline state.
        # Held only briefly, never across a delivery to a pane.
        @state_lock = Mutex.new
        # Deliveries to panes take turns under this lock, taken before
        # @state_lock and never inside it. A delivery can take seconds to
        # check, so it keeps a work item from moving between deciding where
        # text goes and typing it, without stalling failures, reports and
        # other state changes that need only @state_lock.
        @delivery_lock = Mutex.new
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
      # @param force [Boolean] kill any running agent before starting
      # @return [Boolean] false when the agent refused to start, true after a clean shutdown
      def call(name:, wc_socket: nil, force: false)
        @current_name = name
        @tmux_session = @tmux.session_name_for(name)
        socket_path = @config.agent_socket_path(name)

        # Read once up front so a bad stage timeout stops the agent here, with
        # the config error, rather than later as a dropped dispatch.
        @pipeline_config.stages_for(name)
        @pipeline_config.literal_sentinel_warnings(name).each { |warning| @error_output.puts "Warning: #{warning}" }

        return false unless claim_socket(name, socket_path, force: force)

        @pipeline_state ||= PipelineState.new(
          pipeline_config: @pipeline_config,
          state_path: @config.pipeline_state_path(name)
        )
        recover_in_flight

        epoch = @epoch_generator.call
        registered = register(name, socket_path, epoch, wc_socket)
        @error_output.puts "workspace agent: work-coordinator unavailable; will keep retrying in the background" unless registered

        @server = UNIXServer.new(socket_path)
        install_signal_handlers

        @session_monitor = @session_monitor_factory.call(name)
        @session_monitor.start

        @output.puts "workspace agent '#{name}' ready"
        watcher = start_socket_watcher(socket_path, needs_registration: !registered)
        serve

        true
      ensure
        @shutting_down = true
        @shutdown_signal << :stop
        @session_monitor&.stop
        watcher&.join(1)
        watcher&.kill
        shutdown(name, socket_path) if @server
      end

      # Accepts and dispatches one JSON message per connection until the server
      # closes. Reads +@server+ on every pass so a socket the watcher rebound
      # takes over without the loop restarting.
      #
      # @return [void]
      def serve
        loop do
          break if @shutting_down
          client = @server.accept
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
          # Either we are on our way out, or the watcher swapped the server out
          # from under the accept — in which case we go round on the new one.
          break if @shutting_down
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
      # @param watched_by [Object, nil] when given, the work item is only failed
      #   while this poller is still the one watching it, so a watch that has
      #   been replaced cannot fail the stage that replaced it
      # @param event [String] the event log type: "stage_failed", or
      #   "stage_timed_out" for a stage that ran past its deadline
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

      # Picks up work the previous agent process left behind. A stage whose pane
      # is still alive gets its watch re-armed so it can still finish; a stage
      # whose pane died is dropped, and leaving it out of the registration is
      # what tells the coordinator to reconcile it.
      #
      # The re-armed watch looks for the stage's persisted token anywhere in the
      # pane, so a stage that finished while the agent was down is seen at once.
      # An entry written before tokens existed has none; its watch falls back to
      # accepting any sentinel printed from now on, which is what the stage was
      # told to print. A deadline that passed while the agent was down fails the
      # stage on the first pass, unless that pass finds its sentinel.
      def recover_in_flight
        @pipeline_state.in_flight_refs.each do |ref|
          entry = @pipeline_state.current(ref)
          next unless entry
          pane = entry[:pane_index]

          # Checked against the session we are actually serving, not the name in
          # the file, so the liveness check and the re-armed watch cannot differ.
          if pane_alive?(@tmux_session, pane)
            @state_lock.synchronize do
              watch_for_completion(ref, pane, entry[:sentinel_token], @pipeline_state.deadline(ref))
            end
            @logger.debug { "re-attached sentinel watch for #{ref} at pane #{pane}" }
          else
            @error_output.puts "workspace agent: #{ref} lost its pane (#{pane}) while the agent was down"
            log_activity("stage_failed", "work_item_ref" => ref, "pane" => pane, "message" => "lost its pane while the agent was down")
            # A watch re-armed earlier in this loop may be advancing its own
            # item on its poller thread, and both end in a write of the file.
            @state_lock.synchronize { @pipeline_state.complete(work_item_ref: ref) }
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
        @logger.debug { "received: #{JSON.pretty_generate(message)}" }

        if message["type"] == "coordinator_restart"
          @logger.debug { "coordinator_restart received, entering unavailable window" }
          @state_lock.synchronize { @coordinator_unavailable = true }
          return
        end

        workspace = message["workspace"]
        if workspace != @current_name
          @logger.debug { "dropped message for workspace '#{workspace}' (I am '#{@current_name}')" }
          return reply_to(client, "ok" => false, "error" => "wrong_workspace")
        end

        # Every inbound connection ends in one JSON line, so a caller can always
        # read a reply and tell an answer apart from a dead agent.
        case message["type"]
        when "command"
          reply_to(client, handle_command(message))
        when "inject" then handle_inject(message, client)
        when "session_event"
          @session_monitor&.record(message)
          reply_to(client, "ok" => true)
        when "sessions"
          reply_to(client, @session_monitor&.snapshot || {"workspace" => @current_name, "panes" => []})
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

        # The delivery lock is held across the decision and the keystrokes: a
        # hand-off moving this work item mid-inject would otherwise send C-c
        # to a pane the work item has already left.
        reply = @delivery_lock.synchronize do
          urgent = nil
          decided = @state_lock.synchronize do
            entry = @pipeline_state.current(ref)
            if entry.nil?
              @logger.debug { "steer for #{ref} dropped: no active pipeline" }
              {"ok" => false, "error" => "no_active_pipeline"}
            elsif stale_token?(message, entry)
              # The sender aimed at a stage that has since finished; typing into
              # the pane now would reach the stage that replaced it.
              @logger.debug { "steer for #{ref} dropped: stage token no longer current" }
              {"ok" => false, "error" => "stale_token"}
            elsif message["interrupt"]
              urgent = entry
              nil
            elsif (next_stage = next_stage_for(entry))
              (@queued_steers[ref] ||= []) << message["body"]
              {"ok" => true, "queued_for_pane" => next_stage[:pane_index]}
            else
              # Nothing comes after the last stage, so there is no later pane to
              # hold this for. Say so rather than queue it into a vanishing state.
              {"ok" => false, "error" => "no_next_stage"}
            end
          end
          decided || urgent_steer_reply(ref, urgent, message["body"])
        end

        reply_to(client, reply)
      end

      def urgent_steer_reply(ref, entry, body)
        delivery = deliver_urgent_steer(entry, body)
        return {"ok" => true, "queued_for_pane" => entry[:pane_index]} if delivery.ok?

        # "not_submitted" means the text is, or may be, in the pane: resending
        # could type it twice.
        @error_output.puts "workspace agent: steer for #{ref} to pane #{entry[:pane_index]}: #{delivery.message}"
        {"ok" => false, "error" => (delivery.landed? ? "not_submitted" : "not_delivered"),
         "message" => delivery.message}
      end

      # An inject may name the stage it was meant for by that stage's token.
      # One without a token is aimed at whatever stage is running.
      def stale_token?(message, entry)
        expected = message["expected_token"]
        !expected.nil? && expected != entry[:sentinel_token]
      end

      # Steers deliberately carry no reporting instructions: an inject lands in a
      # Claude that is already mid-task and already has them from its command.
      #
      # Interrupts whatever the stage's pane is doing, then types the steer into it.
      #
      # @return [Workspace::Tmux::Delivery]
      def deliver_urgent_steer(entry, body)
        @tmux.send_key(@tmux_session, pane_target(entry[:pane_index]), "C-c")
        @tmux.deliver(@tmux_session, pane_target(entry[:pane_index]), body)
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

      # Delivers a command body to the first pipeline stage, or the detected Claude
      # pane when the workspace has no pipeline configured. A pipeline's first
      # stage is told how to signal it is done, the same as every later stage.
      #
      # Text that never reached the pane is reported as an error and answered
      # with "not_delivered"; a pipeline item is dropped rather than left with
      # no stage running and nothing watching it. Text that reached the pane
      # but may not have been submitted still starts the stage, with a warning,
      # since sending it again would type it twice.
      #
      # @return [Hash] the reply for the sender
      def handle_command(message)
        ref = message["work_item_ref"]
        stages = @pipeline_config.stages_for(@current_name)
        text = "#{message["body"]}#{reporting_text(message)}"

        entry, started_message, watch_pane, token, deadline, timeout, delivery = @delivery_lock.synchronize do
          if stages
            stage = stages.first
            token = @token_generator.call
            deadline = stage_deadline(stage)
            # A re-dispatch replaces the item's stage, so the old stage's watch
            # must go now: left current, its sentinel would advance the new one.
            @state_lock.synchronize { @pollers.delete(ref)&.stop }
            delivery = @tmux.deliver(@tmux_session, pane_target(stage[:pane_index]),
              "#{text}\n\n#{SentinelPoller.instruction(token)}")
            @state_lock.synchronize do
              unless delivery.landed?
                # The old stage's watch is already gone, so an item left in the
                # pipeline here would have nothing running and nothing watching.
                @queued_steers.delete(ref)
                @pipeline_state.complete(work_item_ref: ref) if @pipeline_state.current(ref)
                next [untracked_entry(ref), nil, nil, nil, nil, nil, delivery]
              end
              started = @pipeline_state.start(
                work_item_ref: ref,
                workspace_name: @current_name,
                dispatch_id: message["dispatch_id"],
                sentinel_token: token,
                deadline: deadline
              )
              @logger.debug { "pipeline started for #{ref} at pane #{stage[:pane_index]} (#{stage[:role]})" }
              [started, "Pipeline started at stage #{stage[:role]} (pane #{stage[:pane_index]})", stage[:pane_index], token, deadline, stage[:timeout], delivery]
            end
          else
            target = claude_pane_target
            @logger.debug { "delivering #{ref} to #{@tmux_session}:#{target}" }
            delivery = @tmux.deliver(@tmux_session, target, text)
            @logger.debug { "command for #{ref} to #{@tmux_session}:#{target}: #{delivery.status}" }
            [untracked_entry(ref), "Command delivered to #{@tmux_session}:#{target}", nil, nil, nil, nil, delivery]
          end
        end

        unless delivery.landed?
          failure = "command for #{ref} was not delivered to #{@current_name}: #{delivery.message}"
          @error_output.puts "workspace agent: #{failure}"
          log_activity("dispatch_failed", "work_item_ref" => ref, "dispatch_id" => message["dispatch_id"], "message" => delivery.message)
          report(entry, "type" => "error", "message" => failure)
          return {"ok" => false, "error" => "not_delivered", "message" => delivery.message}
        end

        log_activity("dispatched", "work_item_ref" => ref, "dispatch_id" => message["dispatch_id"],
          "stage" => stages&.first&.dig(:role), "pane" => watch_pane, "delivery" => delivery.status.to_s)
        # Reported before the poller is armed so the "started" message always
        # precedes anything the poller thread goes on to report.
        report(entry, "type" => "status_update", "message" => started_message)
        unless delivery.ok?
          @error_output.puts "workspace agent: #{ref}: #{delivery.message}"
          report(entry, "type" => "status_update", "message" => "Warning: #{delivery.message}")
        end
        arm_watch(ref, watch_pane, token, deadline, timeout) if watch_pane
        {"ok" => true}
      end

      # The coordinator ships a ready-rendered block telling Claude how to report
      # progress back. We only frame it — the text, its substitutions, and whether
      # it is sent at all are all the coordinator's decisions.
      #
      # Only stage 1 sees this. Later stages get handoff_instructions instead, and
      # their visibility comes from the agent's own phase_change and
      # pipeline_advanced reports rather than from anything Claude runs by hand.
      def reporting_text(message)
        instructions = message["reporting_instructions"]
        return "" unless instructions.is_a?(String)

        stripped = instructions.strip
        return "" if stripped.empty?

        "\n\nStatus reporting:\n#{stripped}"
      end

      # Converts a bare pane index to a qualified tmux target within window 0.
      # All workspaces use a single window, so pane N is always "0.N".
      def pane_target(index)
        "0.#{index}"
      end

      # Returns the tmux pane target for the Claude Code pane in the current workspace.
      # Detects by pane title so that layout changes don't break routing.
      # Falls back to pane 1 if detection fails.
      def claude_pane_target
        TmuxPane.new("Claude Code", tmux: @tmux).target(@tmux_session)
      rescue Workspace::Error => e
        @logger.debug { "agent: Claude pane not found (#{e.message}); falling back to pane 1" }
        pane_target(1)
      end

      # Never raises: {Workspace::EventLog#record} swallows write errors.
      def log_activity(type, data)
        @event_log&.record(type: type, project: @current_name, data: data)
      end

      # A one-shot reporting entry for work the agent does not track in the
      # pipeline. It exists only long enough to stamp a single status message.
      def untracked_entry(work_item_ref)
        {work_item_ref: work_item_ref, workspace_name: @current_name}
      end

      # When a stage started now must be done by, or nil when its config sets
      # no timeout.
      def stage_deadline(stage)
        stage[:timeout] && @clock.call + stage[:timeout]
      end

      # Arms the watch for a stage started outside the lock, unless the work
      # item has since moved on to another stage or dispatch — arming then
      # would replace the watch that now belongs to it.
      def arm_watch(work_item_ref, pane, token, deadline, timeout)
        @state_lock.synchronize do
          next unless @pipeline_state.current(work_item_ref)&.fetch(:sentinel_token, nil) == token
          watch_for_completion(work_item_ref, pane, token, deadline, timeout)
        end
      end

      # Watches a stage's pane for the completion sentinel carrying +token+,
      # replacing any poller already watching this work item. A stage still
      # running at +deadline+ is failed the same way a dead poller is.
      # +timeout+ is the stage's configured budget in seconds, named in the
      # failure so it can be read without the project's config; nil when
      # unknown, as for a stage recovered after a restart.
      def watch_for_completion(work_item_ref, pane, token, deadline, timeout = nil)
        @pollers.delete(work_item_ref)&.stop
        poller = @sentinel_poller_factory.call(session_name: @tmux_session, pane: pane,
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

      # Hands the finished stage's output to the next stage, or reports the work
      # item complete when the finished stage was the last one.
      #
      # A poller that has since been replaced (the work item was re-dispatched,
      # or moved on) can still be finishing its last pass; only the poller
      # currently watching the work item may move it.
      #
      # The next stage's watch is armed only after the finished stage's reports
      # go out, so the coordinator always hears the hand-off before anything
      # the next stage does. A hand-off that raises fails the work item: the
      # poller that saw the sentinel is done, and nothing else would look again.
      def advance_pipeline(work_item_ref, summary, poller)
        entry, next_stage, from_pane, next_watch, steer_failures =
          @delivery_lock.synchronize { advance_state(work_item_ref, poller) }
        return unless entry

        log_activity("stage_completed", "work_item_ref" => work_item_ref, "pane" => from_pane,
          "next_stage" => next_stage&.dig(:role), "next_pane" => next_stage&.dig(:pane_index), "summary" => summary.to_s[0, MAX_LOGGED_SUMMARY])
        # Reporting talks to the coordinator over a socket, so it stays outside
        # the locks — a slow coordinator must not stall command dispatch.
        begin
          if next_stage
            report_phase_change(entry, next_stage[:role])
            report_pipeline_advanced(entry, from_pane, next_stage[:pane_index])
            steer_failures.each { |payload| report(entry, payload) }
          else
            report_task_complete(entry, summary)
          end
        ensure
          # The next stage is already running in its pane, so it is watched
          # even if reporting its start went wrong.
          arm_watch(work_item_ref, *next_watch) if next_watch
        end
      rescue => e
        @error_output.puts "workspace agent: could not advance #{work_item_ref}: #{e.message}"
        fail_pipeline(work_item_ref, e.message, watched_by: poller)
      end

      # Moves the work item onto its next stage (or off the pipeline) and returns
      # the entry, the stage moved to, the pane moved from, the arguments for
      # arm_watch once the move has been reported (nil after the last stage),
      # and the reports for queued steers that did not land cleanly. Returns
      # nil when +poller+ no longer watches the item. Called with the delivery
      # lock held.
      #
      # The state lock is held only to decide and to commit; the panes are
      # typed into between the two. The finished stage's poller stays
      # registered until the next watch replaces it, so a failure before then
      # is still its to report.
      def advance_state(work_item_ref, poller)
        entry, next_stage, steers = @state_lock.synchronize do
          next unless @pollers[work_item_ref].equal?(poller)
          found = @pipeline_state.current(work_item_ref)
          next unless found
          stage = next_stage_for(found)
          [found, stage, stage ? @queued_steers.delete(work_item_ref) || [] : []]
        end
        return nil unless entry

        session = @tmux_session
        from_pane = entry[:pane_index]
        captured = @tmux.capture_pane(session, from_pane, all: true) || ""
        handoff_path = write_handoff(entry[:workspace_name], work_item_ref, captured)

        steer_failures = []
        if next_stage
          token = @token_generator.call
          deadline = stage_deadline(next_stage)
          # The old stage's poller is still keyed in @pollers here; it is left
          # alone until the caller's arm_watch replaces it for the new stage,
          # and its own thread exits on its own once its token no longer matches.
          delivery = @tmux.deliver(session, pane_target(next_stage[:pane_index]),
            handoff_instructions(next_stage[:role], handoff_path, token))
          # Raised before the state moves, so the finished stage's poller is
          # still the one watching and the caller fails the item: the next
          # stage never got its instructions and would never finish.
          unless delivery.landed?
            raise Workspace::Error,
              "could not hand off to the #{next_stage[:role]} stage (pane #{next_stage[:pane_index]}): #{delivery.message}"
          end
          @error_output.puts "workspace agent: #{work_item_ref}: #{delivery.message}" unless delivery.ok?
          steer_failures = deliver_queued_steers(session, work_item_ref, next_stage[:pane_index], steers)
          next_watch = [next_stage[:pane_index], token, deadline, next_stage[:timeout]]
        end

        committed = @state_lock.synchronize do
          # The item failed, or was aborted, while its panes were being typed
          # into; moving it now would bring it back.
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

      # Hands the next stage any steers that arrived while the previous stage was
      # still running. The sender was already told each steer was accepted, so
      # one that doesn't land cleanly is returned as a report for the
      # coordinator: an error when it never arrived, a warning when it may have.
      #
      # @return [Array<Hash>] report payloads, one per steer not confirmed
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

      # The stage-to-stage contract: where the previous stage's output lives and
      # how this stage signals that it is finished. The token is fresh per stage:
      # the handoff file holds the previous stage's sentinel, and a stage that
      # prints its context must not end itself by doing so.
      def handoff_instructions(role, handoff_path, token)
        "You are the #{role} stage. Context from the previous stage: #{handoff_path}\n" \
          "#{SentinelPoller.instruction(token)}"
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
        if re_register
          @state_lock.synchronize { @coordinator_unavailable = false }
          drain_pending_reports
        end
      end

      # Watches for the agent's socket file going missing — macOS sweeps old
      # /tmp entries, and another agent start for this workspace unlinks it.
      # The listening fd survives that, so the agent looks healthy while no
      # caller can reach it; rebinding and re-registering is what actually
      # restores it.
      def build_session_monitor(name)
        # Alert settings are read once, here, so a change takes effect the
        # next time the daemon starts.
        alerts = @alert_config&.for_workspace(name) || {}
        notifier = alerts[:notify] && @notifier_factory.call(alerts[:notify])
        SessionMonitor.new(
          tmux: @tmux,
          process_tree: ProcessTree.new(logger: @logger, timeout: @ps_timeout),
          session_name: @tmux.session_name_for(name),
          logger: @logger,
          error_output: @error_output,
          lock_reaper: @lock_reaper,
          notifier: notifier,
          idle_alert_after: alerts[:idle_after],
          event_log: @event_log,
          project: name
        )
      end

      def start_socket_watcher(socket_path, needs_registration: false)
        Thread.new do
          loop do
            # Woken by shutdown rather than slept through, so a terminating
            # agent does not wait out a whole poll interval to exit.
            @shutdown_signal.pop(timeout: SOCKET_POLL_INTERVAL)
            break if @shutting_down

            unless File.socket?(socket_path)
              @logger.debug { "agent socket at #{socket_path} has disappeared; rebinding" }
              begin
                old_server = @server
                @server = UNIXServer.new(socket_path)
                begin
                  old_server.close
                rescue IOError, SystemCallError
                  nil
                end
                needs_registration = true
              rescue => e
                @error_output.puts "workspace agent: could not rebind its socket: #{e.message}"
              end
            end

            # Retry re_register each cycle until it succeeds — if it failed
            # after a rebind (e.g. coordinator was also down), the coordinator
            # has no record of our socket and will never dispatch work to us.
            needs_registration = !re_register if needs_registration
          end
        end
      end

      # @return [Boolean] true when the coordinator accepted the registration
      def re_register
        reply = status_client.register(
          name: @current_name,
          socket: @config.agent_socket_path(@current_name),
          pipeline: @pipeline_config.pipeline?(@current_name),
          epoch: @epoch_generator.call,
          in_flight: @pipeline_state.in_flight
        )
        return true if reply["ok"]

        Warn.puts(@error_output, "workspace agent: work-coordinator refused re-registration: #{reply["error"]}")
        false
      rescue Workspace::Error => e
        Warn.puts(@error_output, "workspace agent: could not re-register with work-coordinator: #{e.message}")
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

      def build_sentinel_poller(session_name:, pane:, token:, deadline:)
        SentinelPoller.new(tmux: @tmux, session_name: session_name, pane: pane, token: token,
          deadline: deadline, clock: @clock, logger: @logger, error_output: @error_output)
      end

      # Returns true when the socket path is free to bind (cleaning up a stale
      # socket if needed), false when another agent is already answering.
      # When +force+ is true and an agent is running, kills it and waits for
      # the socket to be released before returning.
      def claim_socket(name, socket_path, force: false)
        UNIXSocket.open(socket_path) { |s| s.close }
        # A live agent is answering. Force-kill it if requested.
        return kill_existing_agent(name, socket_path) if force

        @error_output.puts "workspace agent '#{name}' is already running"
        false
      rescue Errno::ECONNREFUSED
        @logger.debug { "removing stale socket #{socket_path}" }
        File.unlink(socket_path)
        true
      rescue Errno::ENOENT
        true
      end

      # Finds the PID listening on +socket_path+, sends SIGTERM, and waits up
      # to 5 seconds for it to exit. Returns true when the socket is gone,
      # false when the process did not exit in time.
      def kill_existing_agent(name, socket_path)
        pid = lsof_pid(socket_path)
        if pid
          @output.puts "Stopping existing workspace agent '#{name}' (PID #{pid})..."
          Process.kill("TERM", pid)
        else
          @logger.debug { "force: no PID found for #{socket_path}; removing socket directly" }
        end

        deadline = Time.now + 5
        loop do
          break unless File.socket?(socket_path)
          if Time.now > deadline
            @error_output.puts "workspace agent '#{name}': timed out waiting for previous agent to exit"
            return false
          end
          sleep 0.1
        end
        true
      rescue Errno::ESRCH
        # Process was already gone; socket may still be there — remove it.
        File.unlink(socket_path) if File.socket?(socket_path)
        true
      end

      # Returns the PID of the process listening on the given Unix socket path,
      # or nil when none is found (requires lsof).
      def lsof_pid(socket_path)
        output = `lsof -t #{socket_path.shellescape} 2>/dev/null`.strip
        pid = output.to_i
        (pid > 0) ? pid : nil
      end

      def register(name, socket_path, epoch, wc_socket)
        @client = wc_socket ? rebind_client(wc_socket) : @work_coordinator_client
        # The coordinator conditions the reporting instructions it sends on this flag:
        # a pipeline workspace must not be told to report task_complete itself, because
        # the sentinel poller already does.
        reply = @client.register(name: name, socket: socket_path,
          pipeline: @pipeline_config.pipeline?(@current_name), epoch: epoch,
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

      def install_signal_handlers
        %w[TERM INT].each do |signal|
          @signal_trapper.trap(signal) do
            @shutting_down = true
            @server.close
          end
        end
      end

      def shutdown(name, socket_path)
        @pollers.each_value(&:stop)
        @pollers.clear
        @server.close unless @server.closed?
        File.unlink(socket_path) if File.socket?(socket_path)
        @client.deregister(name: name)
      rescue Workspace::Error => e
        @logger.debug { "deregister failed: #{e.message}" }
      end
    end
  end
end
