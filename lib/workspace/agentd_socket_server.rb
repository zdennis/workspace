require "socket"
require "json"
require "shellwords"

module Workspace
  # The agent daemon's Unix socket: claims the path (a stale socket removed, a running daemon refused or,
  # forced, stopped), listens, accepts one JSON line per connection for an {AgentdRouter}, and watches
  # that the socket file is still there, binding it again when it is gone.
  class AgentdSocketServer
    # How often the socket watcher checks that the agent's socket file is still there.
    POLL_INTERVAL = 5

    # How many socket watcher passes go by between calls of its +on_tick+.
    TICK_PASSES = 3

    # @param bind [#call] given a socket path, returns a listening UNIXServer on it
    # @param poll_interval [Numeric] seconds between the socket watcher's passes
    # @param tick_passes [Integer] the watcher calls its +on_tick+ every this many passes
    # @param signal_trapper [#trap] receives the SIGTERM/SIGINT handler registration
    # @param logger [Workspace::Logger] debug logger
    # @param output [IO] where stopping a running daemon is announced
    # @param error_output [IO] where a dropped message and a failed rebind are reported
    def initialize(bind: ->(path) { UNIXServer.new(path) }, poll_interval: POLL_INTERVAL, tick_passes: TICK_PASSES,
      signal_trapper: Signal, logger: Workspace::Logger.new, output: $stdout, error_output: $stderr)
      @bind = bind
      @poll_interval = poll_interval
      @tick_passes = tick_passes
      @signal_trapper = signal_trapper
      @logger = logger
      @output = output
      @error_output = error_output
      @server = nil
      @shutting_down = false
      @shutdown_signal = Queue.new
    end

    # Returns true when the socket path is free to bind (cleaning up a stale
    # socket if needed), false when another agent is already answering.
    # When +force+ is true and an agent is running, kills it and waits for
    # the socket to be released before returning.
    #
    # @param name [String] the workspace, as the messages name it
    # @param socket_path [String]
    # @param force [Boolean] stop a daemon that answers on the path
    # @return [Boolean]
    def claim(name, socket_path, force: false)
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

    # Starts listening on +socket_path+.
    #
    # @param socket_path [String]
    # @return [void]
    def listen(socket_path)
      @server = @bind.call(socket_path)
    end

    # @return [Boolean] whether {#listen} has bound a server
    def listening?
      !@server.nil?
    end

    # Accepts and routes one JSON message per connection until the server
    # closes. Reads +@server+ on every pass so a socket the watcher rebound
    # takes over without the loop restarting.
    #
    # @param router [Workspace::AgentdRouter] routes each message and writes its replies
    # @return [void]
    def serve(router)
      loop do
        break if @shutting_down
        client = @server.accept
        # A restart_agent caller that waits for the outcome gets its reply
        # from the worker thread, which then owns (and closes) the socket.
        handed_off = false
        begin
          line = client.gets
          handed_off = router.handle(JSON.parse(line), client) == :handed_off if line
        rescue JSON::ParserError => e
          @logger.debug { "malformed message dropped: #{e.message}" }
          router.reply(client, AgentProtocol.error(AgentProtocol::MALFORMED_MESSAGE))
        rescue => e
          # One bad pane or a wedged tmux must cost us this connection, not
          # the agent and every pipeline running under it.
          @error_output.puts "workspace agent: dropped a message: #{e.message}"
          router.reply(client, AgentProtocol.error(AgentProtocol::INTERNAL_ERROR))
        ensure
          client.close unless handed_off
        end
      rescue IOError, Errno::EBADF
        # Either we are on our way out, or the watcher swapped the server out
        # from under the accept — in which case we go round on the new one.
        break if @shutting_down
      end
    end

    # Watches for the agent's socket file going missing — macOS sweeps old
    # /tmp entries, and another agent start for this workspace unlinks it.
    # The listening fd survives that, so the agent looks healthy while no
    # caller can reach it; rebinding and re-registering is what actually
    # restores it.
    #
    # @param socket_path [String]
    # @param needs_registration [Boolean] the first pass already calls +re_register+
    # @param on_tick [#call] called every +tick_passes+ passes
    # @param re_register [#call] registers the socket again, returning whether it succeeded; called after a
    #   rebind and on every pass until it does
    # @return [Thread] the watcher, which ends once {#shut_down!} and {#wake} are called
    def watch(socket_path, needs_registration:, on_tick:, re_register:)
      Thread.new do
        passes = 0
        loop do
          # Woken by shutdown rather than slept through, so a terminating
          # agent does not wait out a whole poll interval to exit.
          @shutdown_signal.pop(timeout: @poll_interval)
          break if @shutting_down

          passes += 1
          on_tick.call if (passes % @tick_passes).zero?

          unless File.socket?(socket_path)
            @logger.debug { "agent socket at #{socket_path} has disappeared; rebinding" }
            begin
              old_server = @server
              @server = @bind.call(socket_path)
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
          needs_registration = !re_register.call if needs_registration
        end
      end
    end

    # Marks the server as going down, so the accept loop and the watcher stop at their next look; takes no
    # lock, so a signal handler may call it.
    #
    # @return [void]
    def shut_down!
      @shutting_down = true
    end

    # Wakes the watcher from its wait between passes.
    #
    # @return [void]
    def wake
      @shutdown_signal << :stop
    end

    # Traps TERM and INT: each calls +on_signal+, then closes the listening server.
    #
    # @param on_signal [#call] called first in the handler; it must take no lock, as it runs in trap context
    # @return [void]
    def install_signal_handlers(on_signal:)
      %w[TERM INT].each do |signal|
        @signal_trapper.trap(signal) do
          on_signal.call
          # IO#close cannot run in trap context (Ruby raises ThreadError), so the
          # unblocking close runs on its own thread: the accept loop then reads
          # IOError and the server's shut_down!, and the ensure block tears the rest down.
          # A TERM before the server exists closes nothing.
          Thread.new { close }
        end
      end
    end

    # Closes the listening server, which ends a blocked accept; nothing before {#listen}.
    #
    # @return [void]
    def close
      @server&.close
    end

    # Closes the listening server if it is still open and removes the socket file.
    #
    # @param socket_path [String]
    # @return [void]
    def close_and_remove(socket_path)
      @server.close unless @server.closed?
      File.unlink(socket_path) if File.socket?(socket_path)
    end

    private

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
  end
end
