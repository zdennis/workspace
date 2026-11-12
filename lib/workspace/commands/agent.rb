require "socket"
require "json"
require "securerandom"
require "shellwords"

module Workspace
  module Commands
    # Runs the long-lived workspace agent: probes for an existing agent,
    # registers with the work-coordinator, binds its own Unix socket, and
    # serves commands until terminated.
    class Agent
      # How often the socket watcher checks that the agent's socket file is still there.
      SOCKET_POLL_INTERVAL = 5

      # How many socket watcher passes go by between looks at the workspace's
      # workflow runs (one waiting for a lock is woken to ask for it again).
      WORKFLOW_TICK_PASSES = 3

      # Longest confirm wait a restart_agent message may ask for, in seconds ({AgentdRestartDesk::MAX_TIMEOUT}).
      MAX_RESTART_TIMEOUT = AgentdRestartDesk::MAX_TIMEOUT

      # @param config [Workspace::Config] path configuration
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param agent_labels [Workspace::AgentLabels, nil] lets a --pane title search match the agent label
      # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration, checked at startup
      # @param epoch_generator [#call] returns a new epoch string
      # @param signal_trapper [#trap] receives SIGTERM/SIGINT handler registration
      # @param parts [#call] given +workspace:+, +session_name:+, +delivery_lock:+, +registry:+, +recovering:+ and
      #   +pipeline_desk:+ (or +pipeline_only: true+), builds the {Workspace::AgentdParts} of the workspace served,
      #   none of them started ({Workspace.build_agentd_parts} returns it)
      # @param clock [#call] returns the current Time, for when a turn began
      # @param event_log [Workspace::EventLog, nil] records the daemon's start and stop; nil records nothing
      # @param workflow_nudger [Workspace::WorkflowNudger, nil] wakes a workflow run when a turn ends in
      #   its pane, and on a timer; nil leaves workflow runs alone
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
        clock: -> { Time.now },
        event_log: nil,
        workflow_nudger: nil,
        restart_registry: RestartRegistry.new,
        current_name: nil,
        name_migration: nil,
        socket_poll_interval: SOCKET_POLL_INTERVAL,
        workflow_tick_passes: WORKFLOW_TICK_PASSES,
        logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
        @socket_poll_interval = socket_poll_interval
        @workflow_tick_passes = workflow_tick_passes
        @name_migration = name_migration
        @config = config
        @tmux = tmux
        @agent_labels = agent_labels
        @agent_commands = agent_commands
        @pipeline_config = pipeline_config
        @epoch_generator = epoch_generator
        @signal_trapper = signal_trapper
        @clock = clock
        @parts = parts
        @session_monitor = nil
        @workflow_nudger = workflow_nudger
        @agent_recovery_desk = nil
        # Restart workers by pane id, so one pane is restarted once at a time.
        @restarts = restart_registry
        @restart_desk = nil
        @pipeline_desk = nil
        # When the main agent's current turn began, by pane id, for the workflow nudger.
        @turn_starts = {}
        @event_log = event_log
        @re_register_warned = false
        @shutting_down = false
        @shutdown_signal = Queue.new
        @server = nil
        # Deliveries to panes take turns under this lock, taken before any
        # desk's own state lock and never inside it. A delivery can take
        # seconds to check, so it keeps a work item from moving between
        # deciding where text goes and typing it.
        @delivery_lock = Mutex.new
        @logger = logger
        @output = output
        @error_output = error_output
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

        return false unless claim_socket(name, socket_path, force: force)

        build_pipeline_desk unless @pipeline_desk
        @pipeline_desk.recover_in_flight

        epoch = @epoch_generator.call
        registered = @pipeline_desk.register(socket: socket_path, epoch: epoch, wc_socket: wc_socket)
        @error_output.puts "workspace agent: work-coordinator unavailable; will keep retrying in the background" unless registered

        @server = UNIXServer.new(socket_path)
        install_signal_handlers

        # Built here, before any worker thread can ask for it.
        parts = build_parts(pipeline_desk: @pipeline_desk)
        @hook_event_log = parts.hook_event_log
        @session_monitor = parts.monitor
        @restart_desk = parts.restart_desk
        @session_monitor.start
        @plan_progress_watcher = parts.plan_progress_watcher
        @plan_progress_watcher&.start
        @spine_owner_report = parts.spine_owner_report
        @spine_watcher = parts.spine_watcher
        @spine_watcher.owner_report = @spine_owner_report if @spine_watcher.respond_to?(:owner_report=)
        @spine_watcher&.start
        @agent_status_desk = parts.status_desk
        @prompt_queue_desk = parts.queue_desk
        @agent_recovery_desk = parts.recovery_desk
        # The scan is the queue's regular trigger, besides the send and the Stop hook.
        @session_monitor.on_scan = -> { scan_desks } if @session_monitor.respond_to?(:on_scan=)
        @handoff_watcher = parts.handoff_watcher

        @output.puts "workspace agent '#{name}' ready"
        log_activity("daemon_started", "workspace" => name, "daemon" => "agent", "pid" => Process.pid)
        @daemon_started = true
        watcher = start_socket_watcher(socket_path, needs_registration: !registered)
        serve

        true
      ensure
        begin_shutdown
        @shutdown_signal << :stop
        @session_monitor&.stop
        @plan_progress_watcher&.stop
        @spine_watcher&.stop
        @handoff_watcher&.stop
        @restarts.stop_all
        watcher&.join(1)
        watcher&.kill
        shutdown(socket_path) if @server
        log_activity("daemon_stopped", "workspace" => name, "daemon" => "agent", "pid" => Process.pid) if @daemon_started
        @daemon_started = false
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
          # A restart_agent caller that waits for the outcome gets its reply
          # from the worker thread, which then owns (and closes) the socket.
          handed_off = false
          begin
            line = client.gets
            handed_off = dispatch(JSON.parse(line), client) == :handed_off if line
          rescue JSON::ParserError => e
            @logger.debug { "malformed message dropped: #{e.message}" }
            reply_to(client, AgentProtocol.error(AgentProtocol::MALFORMED_MESSAGE))
          rescue => e
            # One bad pane or a wedged tmux must cost us this connection, not
            # the agent and every pipeline running under it.
            @error_output.puts "workspace agent: dropped a message: #{e.message}"
            reply_to(client, AgentProtocol.error(AgentProtocol::INTERNAL_ERROR))
          ensure
            client.close unless handed_off
          end
        rescue IOError, Errno::EBADF
          # Either we are on our way out, or the watcher swapped the server out
          # from under the accept — in which case we go round on the new one.
          break if @shutting_down
        end
      end

      # Routes one parsed socket message as the accept loop does, answering on
      # +client+ with one JSON line. A message for another workspace is dropped
      # with a +wrong_workspace+ reply.
      #
      # @param message [Hash] the parsed message, with its +"type"+ and +"workspace"+
      # @param client [#puts, #close, nil] the connection to answer on
      # @return [Symbol, nil] +:handed_off+ when a worker thread now owns +client+
      def handle(message, client = nil)
        dispatch(message, client)
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
          registry: @restarts, recovering: ->(pane_id) { @agent_recovery_desk&.holding?(pane_id) || false }, **extra)
      end

      # Builds the served workspace's pipeline desk, which asks this daemon to re-register when the
      # coordinator restarts.
      def build_pipeline_desk
        @pipeline_desk = build_parts(pipeline_only: true).pipeline_desk
        @pipeline_desk.re_register = method(:re_register)
      end

      # Routes a parsed message, ignoring anything addressed to another workspace.
      def dispatch(message, client = nil)
        @logger.debug { "received: #{JSON.pretty_generate(message)}" }

        if AgentProtocol.type_of(message) == AgentProtocol::COORDINATOR_RESTART
          @logger.debug { "coordinator_restart received, entering unavailable window" }
          @pipeline_desk&.coordinator_restarting
          return
        end

        workspace = message["workspace"]
        if !WorkspaceName.same?(workspace, @current_name)
          @logger.debug { "dropped message for workspace '#{workspace}' (I am '#{@current_name}')" }
          return reply_to(client, AgentProtocol.error(AgentProtocol::WRONG_WORKSPACE))
        end

        # Every inbound connection ends in one JSON line, so a caller can always
        # read a reply and tell an answer apart from a dead agent.
        case AgentProtocol.type_of(message)
        when AgentProtocol::COMMAND
          reply_to(client, @pipeline_desk.command(message, claude_pane: -> { claude_pane_target }))
        when AgentProtocol::INJECT then reply_to(client, @pipeline_desk.inject(message))
        when AgentProtocol::RESTART_AGENT
          # Before #call has built the parts there is no desk, and no context reader to confirm a /clear with.
          @restart_desk ? @restart_desk.handle(message, client) : reply_to(client, AgentdRestartDesk.refusal_before_start(message))
        when AgentProtocol::SESSION_EVENT
          # Before the monitor records it: a /clear moves the pane's session_id there, and a poll
          # in the gap would end the watch session_changed, not carried_out.
          notify_handoff_watcher(message)
          @session_monitor&.record(message)
          @hook_event_log&.record(message)
          nudge_workflow(message) if @workflow_nudger && message["agent_id"].nil?
          report_owner_finished(message) if @spine_owner_report && message["agent_id"].nil?
          @prompt_queue_desk&.session_event(message)
          @agent_recovery_desk&.session_event(message)
          reply_to(client, AgentProtocol.ok)
        when AgentProtocol::HANDOFF_WATCH then reply_to(client, handle_handoff_watch(message))
        when AgentProtocol::STATUS_REQUEST then handle_status_request(message, client)
        when AgentProtocol::PROMPT_SEND then handle_prompt_send(message, client)
        when AgentProtocol::PROMPT_INTERRUPT_SEND then handle_prompt_send(message, client, :interrupt_send)
        when AgentProtocol::STATUS_POST then reply_to(client, @agent_status_desk.post(message))
        when AgentProtocol::SESSIONS
          reply_to(client, @session_monitor&.snapshot || {"workspace" => @current_name, "panes" => []})
        when AgentProtocol::VERSION_REQUEST
          reply_to(client, AgentProtocol.ok(version: Workspace::VERSION))
        else
          @logger.debug { "unknown message type: #{message["type"]}" }
          reply_to(client, AgentProtocol.error(AgentProtocol::UNKNOWN_TYPE))
        end
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
          reply_to(client, reply)
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
          reply_to(client, reply)
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
      end

      # Stops new recovery claims and marks the daemon as going down; takes no lock,
      # so the signal handler may call it.
      def begin_shutdown
        @shutting_down = true
        @restarts.shut_down!
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

      # Shows a hook event to the handoff watcher. A failure there is logged and costs the monitor nothing.
      def notify_handoff_watcher(message)
        @handoff_watcher&.session_event(message)
      rescue => e
        @logger.debug { "handoff watcher: #{e.class}: #{e.message}" }
      end

      # The session monitor's after-scan call: both desks run, and one that
      # raises does not stop the other.
      def scan_desks
        [@prompt_queue_desk, @agent_recovery_desk].compact.each do |desk|
          desk.scan
        rescue => e
          @logger.debug { "agent: #{desk.class.name.split("::").last} scan failed (#{e.class}: #{e.message})" }
        end
      end

      # The main agent's turn ended: a workflow run bound to the pane decides
      # its step now. The run is told when that turn began (the prompt that
      # started it), so a turn already under way when the step's line was
      # typed does not decide the step; a turn whose start this daemon did
      # not see is sent without one.
      def nudge_workflow(message)
        pane_id = message["pane_id"]
        case message["event"]
        when "user_prompt" then @turn_starts[pane_id] = @clock.call
        # A new conversation: a prompt this daemon then fails to see leaves no start, so its turn's end counts.
        when "session_start", "session_end" then @turn_starts.delete(pane_id)
        when "stop" then @workflow_nudger.turn_ended(@current_name, pane_id, turn_started: @turn_starts[pane_id], background: message["background_tasks"])
        end
      end

      # The main agent's turn ended (the Stop hook): a stage the pane owns is reported as finished.
      def report_owner_finished(message)
        return unless message["event"] == "stop"
        pane_id = message["pane_id"]
        Thread.new { @spine_owner_report.turn_ended(pane_id) }
      end

      # Watches for the agent's socket file going missing — macOS sweeps old
      # /tmp entries, and another agent start for this workspace unlinks it.
      # The listening fd survives that, so the agent looks healthy while no
      # caller can reach it; rebinding and re-registering is what actually
      # restores it.
      def start_socket_watcher(socket_path, needs_registration: false)
        Thread.new do
          passes = 0
          loop do
            # Woken by shutdown rather than slept through, so a terminating
            # agent does not wait out a whole poll interval to exit.
            @shutdown_signal.pop(timeout: @socket_poll_interval)
            break if @shutting_down

            passes += 1
            @workflow_nudger&.tick(@current_name) if (passes % @workflow_tick_passes).zero?

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

      # Retries are quiet after the first warning, and a registration that
      # lands after one says so once, so a coordinator left down does not
      # spam the pane.
      #
      # @return [Boolean] true when the coordinator accepted the registration
      def re_register
        reply = @pipeline_desk.send_registration(socket: @config.agent_socket_path(@current_name), epoch: @epoch_generator.call)
        return registered_after_outage if reply["ok"]

        warn_once("workspace agent: work-coordinator refused re-registration: #{reply["error"]}; will keep retrying")
        false
      rescue Workspace::Error => e
        warn_once("workspace agent: could not re-register with work-coordinator: #{e.message}; will keep retrying")
        false
      end

      def warn_once(message)
        return if @re_register_warned

        @re_register_warned = true
        Warn.puts(@error_output, message)
      end

      def registered_after_outage
        @error_output.puts "workspace agent: re-registered with work-coordinator" if @re_register_warned
        @re_register_warned = false
        true
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

      def install_signal_handlers
        %w[TERM INT].each do |signal|
          @signal_trapper.trap(signal) do
            begin_shutdown
            # IO#close cannot run in trap context (Ruby raises ThreadError), so the
            # unblocking close runs on its own thread: the accept loop then reads
            # IOError and @shutting_down, and the ensure block tears the rest down.
            # A TERM before the server exists closes nothing.
            Thread.new { @server&.close }
          end
        end
      end

      def shutdown(socket_path)
        @pipeline_desk.stop_watches
        @server.close unless @server.closed?
        File.unlink(socket_path) if File.socket?(socket_path)
        @pipeline_desk.deregister
      rescue Workspace::Error => e
        @logger.debug { "deregister failed: #{e.message}" }
      end
    end
  end
end
