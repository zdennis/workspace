require "socket"
require "json"
require "securerandom"

module Workspace
  module Commands
    # Runs the long-lived workspace agent: probes for an existing agent,
    # registers with the work-coordinator, binds its own Unix socket, and
    # serves commands until terminated.
    class Agent
      # How often the socket watcher checks that the agent's socket file is still there
      # ({AgentdSocketServer::POLL_INTERVAL}).
      SOCKET_POLL_INTERVAL = AgentdSocketServer::POLL_INTERVAL

      # How many socket watcher passes go by between looks at the workspace's
      # workflow runs (one waiting for a lock is woken to ask for it again; {AgentdSocketServer::TICK_PASSES}).
      WORKFLOW_TICK_PASSES = AgentdSocketServer::TICK_PASSES

      # Longest confirm wait a restart_agent message may ask for, in seconds ({AgentdRestartDesk::MAX_TIMEOUT}).
      MAX_RESTART_TIMEOUT = AgentdRestartDesk::MAX_TIMEOUT

      # @param config [Workspace::Config] path configuration
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param agent_labels [Workspace::AgentLabels, nil] lets a --pane title search match the agent label
      # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration, checked at startup
      # @param epoch_generator [#call] returns a new epoch string, for the registration and (through the parts) each
      #   re-registration
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param parts [#call] given +workspace:+, +session_name:+, +delivery_lock:+, +registry:+, +epoch_generator:+,
      #   +recovering:+ and +pipeline_desk:+ (or +pipeline_only: true+), builds the {Workspace::AgentdParts} of the workspace served,
      #   none of them started ({Workspace.build_agentd_parts} returns it)
      # @param event_log [Workspace::EventLog, nil] records the daemon's start and stop; nil records nothing
      # @param workflow_nudger [Workspace::WorkflowNudger, nil] wakes the workspace's workflow runs on a timer
      #   (the parts' hook fan-out wakes one when a turn ends in its pane); nil leaves workflow runs alone
      # @param name_migration [Workspace::NameMigration, nil] renames a mixed-case workspace
      #   to lowercase before the socket is claimed; nil renames nothing
      # @param logger [Workspace::Logger] debug logger
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for errors
      # @param agent_commands [Workspace::AgentCommands, nil] the program names that count as an agent, read
      #   once when the session monitor starts; nil knows only the providers' executables
      # @param restart_registry [Workspace::RestartRegistry] the panes being restarted; one is
      #   built by default
      # @param current_name [String, nil] the workspace served before {#call} starts, so {#handle}
      #   works without it (its pipeline desk is built at once); +call+ sets it from its +name+
      # @param socket_poll_interval [Numeric] seconds between the socket watcher's passes
      # @param workflow_tick_passes [Integer] the watcher ticks the workflow nudger every this many passes
      def initialize(config:, tmux:, pipeline_config:, parts:, agent_labels: nil, agent_commands: nil,
        epoch_generator: -> { "wa-#{Agent.ulid}" },
        signal_trapper: Signal,
        event_log: nil,
        workflow_nudger: nil,
        restart_registry: RestartRegistry.new,
        current_name: nil,
        name_migration: nil,
        socket_poll_interval: SOCKET_POLL_INTERVAL,
        workflow_tick_passes: WORKFLOW_TICK_PASSES,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @name_migration = name_migration
        @config = config
        @tmux = tmux
        @agent_labels = agent_labels
        @agent_commands = agent_commands
        @pipeline_config = pipeline_config
        @epoch_generator = epoch_generator
        @parts = parts
        @session_monitor = nil
        @workflow_nudger = workflow_nudger
        @agent_recovery_desk = nil
        @hook_fanout = nil
        # Restart workers by pane id, so one pane is restarted once at a time.
        @restarts = restart_registry
        @restart_desk = nil
        @pipeline_desk = nil
        @event_log = event_log
        @socket_server = AgentdSocketServer.new(poll_interval: socket_poll_interval, tick_passes: workflow_tick_passes,
          signal_trapper: signal_trapper, logger: logger, output: output, error_output: error_output)
        # Deliveries to panes take turns under this lock, taken before any
        # desk's own state lock and never inside it. A delivery can take
        # seconds to check, so it keeps a work item from moving between
        # deciding where text goes and typing it.
        @delivery_lock = Mutex.new
        @logger = logger
        @output = output
        @error_output = error_output
        @router = route_for(nil)
        return unless current_name

        serve_workspace(current_name)
        build_pipeline_desk
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
        name = migrate_name(name)
        serve_workspace(name)
        socket_path = @config.agent_socket_path(name)

        # Read once up front so a bad stage timeout stops the agent here, with
        # the config error, rather than later as a dropped dispatch.
        @pipeline_config.stages_for(name)
        @pipeline_config.literal_sentinel_warnings(name).each { |warning| @error_output.puts "Warning: #{warning}" }

        return false unless @socket_server.claim(name, socket_path, force: force)

        build_pipeline_desk unless @pipeline_desk
        @pipeline_desk.recover_in_flight

        epoch = @epoch_generator.call
        registered = @pipeline_desk.register(socket: socket_path, epoch: epoch, wc_socket: wc_socket)
        @error_output.puts "workspace agent: work-coordinator unavailable; will keep retrying in the background" unless registered

        @socket_server.listen(socket_path)
        @socket_server.install_signal_handlers(on_signal: -> { begin_shutdown })

        # Built here, before any worker thread can ask for it.
        parts = build_parts(pipeline_desk: @pipeline_desk)
        @session_monitor = parts.monitor
        @restart_desk = parts.restart_desk
        @session_monitor.start
        @plan_progress_watcher = parts.plan_progress_watcher
        @plan_progress_watcher&.start
        @spine_watcher = parts.spine_watcher
        @spine_watcher.owner_report = parts.spine_owner_report if @spine_watcher.respond_to?(:owner_report=)
        @spine_watcher&.start
        @agent_status_desk = parts.status_desk
        @prompt_queue_desk = parts.queue_desk
        @agent_recovery_desk = parts.recovery_desk
        @hook_fanout = parts.hook_fanout
        # The scan is the queue's regular trigger, besides the send and the Stop hook.
        @session_monitor.on_scan = -> { @hook_fanout.scan_desks } if @session_monitor.respond_to?(:on_scan=)
        @handoff_watcher = parts.handoff_watcher

        @output.puts "workspace agent '#{name}' ready"
        log_activity("daemon_started", "workspace" => name, "daemon" => "agent", "pid" => Process.pid)
        @daemon_started = true
        watcher = @socket_server.watch(socket_path, needs_registration: !registered,
          on_tick: -> { @workflow_nudger&.tick(@current_name) }, re_register: -> { @pipeline_desk.re_register })
        @socket_server.serve(@router)

        true
      ensure
        begin_shutdown
        @socket_server.wake
        @session_monitor&.stop
        @plan_progress_watcher&.stop
        @spine_watcher&.stop
        @handoff_watcher&.stop
        @restarts.stop_all
        watcher&.join(1)
        watcher&.kill
        shutdown(socket_path) if @socket_server.listening?
        log_activity("daemon_stopped", "workspace" => name, "daemon" => "agent", "pid" => Process.pid) if @daemon_started
        @daemon_started = false
      end

      # Routes one parsed socket message as the accept loop does, answering on
      # +client+ with one JSON line. A message for another workspace is dropped
      # with a +wrong_workspace+ reply.
      #
      # @param message [Hash] the parsed message, with its +"type"+ and +"workspace"+
      # @param client [#puts, #close, nil] the connection to answer on
      # @return [Symbol, nil] +:handed_off+ when a worker thread now owns +client+
      def handle(message, client = nil)
        @router.handle(message, client)
      end

      # Reports something noteworthy that happened while a stage is running
      # ({Workspace::PipelineDesk#report_progress}); nothing before the pipeline desk is built.
      #
      # @param work_item_ref [String]
      # @param message [String] the progress text
      # @return [void]
      def report_progress(work_item_ref, message)
        @pipeline_desk&.report_progress(work_item_ref, message)
      end

      # Takes a work item out of the pipeline after its current stage failed
      # ({Workspace::PipelineDesk#fail_pipeline}); nothing before the pipeline desk is built.
      #
      # @param work_item_ref [String]
      # @param message [String] why the work item failed
      # @param watched_by [Object, nil] fails it only while this poller still watches it
      # @param event [String] the event log type: "stage_failed" or "stage_timed_out"
      # @return [void]
      def fail_pipeline(work_item_ref, message, watched_by: nil, event: "stage_failed")
        @pipeline_desk&.fail_pipeline(work_item_ref, message, watched_by: watched_by, event: event)
      end

      private

      # The parts builder's call for the workspace served; +extra+ is +pipeline_desk:+ or +pipeline_only:+.
      def build_parts(**extra)
        @parts.call(workspace: @current_name, session_name: @tmux_session, delivery_lock: @delivery_lock,
          registry: @restarts, epoch_generator: @epoch_generator, recovering: ->(pane_id) { @agent_recovery_desk&.holding?(pane_id) || false }, **extra)
      end

      # Builds the served workspace's pipeline desk.
      def build_pipeline_desk
        @pipeline_desk = build_parts(pipeline_only: true).pipeline_desk
      end

      # The router of +name+'s messages, over this daemon's handlers.
      def route_for(name)
        AgentdRouter.new(workspace: name, handlers: handlers, logger: @logger)
      end

      # Each message type's handler: it answers on the client through the router, or hands the client off.
      def handlers
        {
          AgentProtocol::COORDINATOR_RESTART => ->(_message, _client) do
            @logger.debug { "coordinator_restart received, entering unavailable window" }
            @pipeline_desk&.coordinator_restarting
            nil
          end,
          # Every inbound connection ends in one JSON line, so a caller can always
          # read a reply and tell an answer apart from a dead agent.
          AgentProtocol::COMMAND => ->(message, client) do
            @router.reply(client, @pipeline_desk.command(message, claude_pane: -> { claude_pane_target }))
          end,
          AgentProtocol::INJECT => ->(message, client) { @router.reply(client, @pipeline_desk.inject(message)) },
          AgentProtocol::RESTART_AGENT => ->(message, client) do
            # Before #call has built the parts there is no desk, and no context reader to confirm a /clear with.
            @restart_desk ? @restart_desk.handle(message, client) : @router.reply(client, AgentdRestartDesk.refusal_before_start(message))
          end,
          AgentProtocol::SESSION_EVENT => ->(message, client) do
            # Before #call has built the parts there is no fan-out, and nothing to show the event to.
            @hook_fanout&.session_event(message)
            @router.reply(client, AgentProtocol.ok)
          end,
          AgentProtocol::HANDOFF_WATCH => ->(message, client) { @router.reply(client, handle_handoff_watch(message)) },
          AgentProtocol::STATUS_REQUEST => ->(message, client) { handle_status_request(message, client) },
          AgentProtocol::PROMPT_SEND => ->(message, client) { handle_prompt_send(message, client) },
          AgentProtocol::PROMPT_INTERRUPT_SEND => ->(message, client) { handle_prompt_send(message, client, :interrupt_send) },
          AgentProtocol::STATUS_POST => ->(message, client) { @router.reply(client, @agent_status_desk.post(message)) },
          AgentProtocol::SESSIONS => ->(_message, client) do
            @router.reply(client, @session_monitor&.snapshot || {"workspace" => @current_name, "panes" => []})
          end,
          AgentProtocol::VERSION_REQUEST => ->(_message, client) { @router.reply(client, AgentProtocol.ok(version: Workspace::VERSION)) }
        }
      end

      # Answers a status request from a worker thread, which owns +client+:
      # checking and typing take seconds, and the accept loop keeps serving
      # hook events meanwhile.
      #
      # @return [Symbol] :handed_off
      def handle_status_request(message, client)
        Thread.new do
          reply = begin
            @agent_status_desk.request(message)
          rescue => e
            AgentProtocol.error(AgentProtocol::INTERNAL_ERROR, e.message)
          end
          @router.reply(client, reply)
        ensure
          begin
            client&.close
          rescue IOError, SystemCallError
            nil
          end
        end
        :handed_off
      end

      # Longest follow-up or save-state text a handoff_watch may carry. A longer one
      # is refused rather than cut, since a cut command could be broken.
      MAX_WATCH_TEXT = 4_000
      private_constant :MAX_WATCH_TEXT

      # Opens a handoff follow-up watch for `handoff check`. Arming only reads facts,
      # so it is answered on the accept thread.
      #
      # @return [Hash] `ok`, `watching` and `reason`, or an error reply
      def handle_handoff_watch(message)
        pane_id = message["pane_id"]
        sent_at = parse_watch_time(message["sent_at"])
        interval = message["interval"]
        max = message["max"]
        text = message["text"]
        sent_text = message["sent_text"]
        valid = pane_id.is_a?(String) && pane_id.match?(Workspace::TmuxPane::PANE_ID) && sent_at &&
          interval.is_a?(Numeric) && interval.to_f.finite? && interval > 0 &&
          max.is_a?(Integer) && max > 0 &&
          [text, sent_text].all? { |t| t.is_a?(String) && !t.strip.empty? && t.length <= MAX_WATCH_TEXT }
        unless valid
          return AgentProtocol.error("usage",
            "handoff_watch needs a pane_id, an ISO 8601 sent_at, a positive interval and max, " \
            "and a text and sent_text of 1 to #{MAX_WATCH_TEXT} characters")
        end

        detail = @tmux.pane_details(@tmux_session, window: nil).find { |d| d[:id] == pane_id }
        ref = (detail && detail[:window] == 0) ? @pipeline_desk&.pipeline_ref_on(detail[:index]) : nil
        if ref
          return AgentProtocol.error("pipeline_stage", nil, work_item_ref: ref,
            message: "#{ref} has a pipeline stage running on pane #{pane_id}; it gets no handoff follow-ups")
        end

        # Started on the first arm, not at boot: its thread wakes every tick, and a stop waits for the tick.
        # Safe without a lock: this runs on the accept thread, so no two arms race to start it.
        @handoff_watcher.start
        result = @handoff_watcher.arm(pane_id: pane_id, sent_at: sent_at, interval: interval, max: max, text: text, sent_text: sent_text)
        AgentProtocol.ok(watching: result[:watching], reason: result[:reason])
      rescue => e
        AgentProtocol.error(AgentProtocol::INTERNAL_ERROR, e.message)
      end

      # @return [Time, nil] the time +value+ spells as ISO 8601, nil when it is not a string or not a time
      def parse_watch_time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end

      # Answers `agent-run send --when-idle` from a worker thread, which owns
      # +client+: a ready pane gets its text typed before the reply.
      #
      # @return [Symbol] :handed_off
      def handle_prompt_send(message, client, handler = :send_prompt)
        Thread.new do
          reply = begin
            @prompt_queue_desk.public_send(handler, message)
          rescue => e
            code = e.is_a?(Workspace::Error) ? e.code : "internal_error"
            AgentProtocol.error(code, e.message)
          end
          @router.reply(client, reply)
        ensure
          begin
            client&.close
          rescue IOError, SystemCallError
            nil
          end
        end
        :handed_off
      end

      # The one place the workspace this daemon serves, and its tmux session, are set. A pipeline desk
      # built for another workspace is dropped.
      def serve_workspace(name)
        @pipeline_desk = nil unless name == @current_name
        @current_name = name
        @tmux_session = @tmux.session_name_for(name)
        @router = route_for(name)
      end

      # Stops new recovery claims and marks the daemon as going down; takes no lock,
      # so the signal handler may call it.
      def begin_shutdown
        @socket_server.shut_down!
        @restarts.shut_down!
      end

      # Returns the tmux pane target for the Claude Code pane in the current workspace.
      # Detects by pane title so that layout changes don't break routing.
      # Falls back to pane 1 if detection fails.
      def claude_pane_target
        TmuxPane.new("Claude Code", tmux: @tmux, agent_labels: @agent_labels, detector: @agent_commands&.detector(@current_name)).target(@tmux_session)
      rescue Workspace::Error => e
        @logger.debug { "agent: Claude pane not found (#{e.message}); falling back to pane 1" }
        "0.1"
      end

      # Never raises: {Workspace::EventLog#record} swallows write errors.
      def log_activity(type, data)
        @event_log&.record(type: type, project: @current_name, data: data)
      end

      # Renames a mixed-case workspace to lowercase when no daemon answers for it,
      # under the startup lock. A lock held elsewhere is an `agentd --ensure`
      # that renamed it before starting this daemon, so it is left alone. With
      # a migration wired, the daemon runs under the lowercase name whatever the outcome.
      def migrate_name(name)
        return name unless @name_migration

        result = @name_migration.call_locked(name, wait: false)
        return WorkspaceName.normalize(name) unless result

        @error_output.puts "workspace agent: renamed workspace '#{result.from}' to '#{result.name}'" if result.from
        result.warnings.each { |warning| @error_output.puts "Warning: #{warning}" }
        result.name
      end

      def shutdown(socket_path)
        @pipeline_desk.stop_watches
        @socket_server.close_and_remove(socket_path)
        @pipeline_desk.deregister
      rescue Workspace::Error => e
        @logger.debug { "deregister failed: #{e.message}" }
      end
    end
  end
end
