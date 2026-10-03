require "json"
require "open3"

module Workspace
  module Commands
    # Reads and controls a workspace's agent daemon from outside it: whether
    # it is answering and which process it is, the tail of its log, and a
    # restart that stops it and starts a fresh one detached.
    #
    # The daemon writes its own `daemon_started` and `daemon_stopped` events,
    # so a restart here writes none: the old daemon records its stop when it
    # exits on SIGTERM and the new one records its start.
    class Daemon
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # Lines `log` returns when the caller names no count.
      DEFAULT_LINES = 40

      # Most lines `log` returns, however many are asked for.
      MAX_LINES = 10_000

      # How much of the end of the log is read; a line cut by the boundary is dropped.
      TAIL_BYTES = 1_048_576

      # How long a restart waits for the old daemon's socket to stop answering.
      DEFAULT_STOP_TIMEOUT = 5

      # What a restart did. `outcome` is "restarted" (a daemon was stopped and
      # a new one answers), "started" (none was running, one answers now) or
      # "failed", with `reason` and `message` saying why.
      Result = Struct.new(:outcome, :old_pid, :pid, :reason, :message) do
        # @return [Boolean] whether a daemon is answering after the restart
        def ok?
          outcome != "failed"
        end
      end

      # @param config [Workspace::Config] socket and log paths, liveness probe
      # @param project_config [Workspace::ProjectConfig] knows which workspaces exist
      # @param ensure_agent [Workspace::Commands::EnsureAgent] starts the new daemon, detached, under its lock
      # @param process_tree [Workspace::ProcessTree] confirms a pid is an `agentd` process before it is signalled
      # @param pid_finder [#call] `(socket_path)` returns the pids with the socket open
      # @param signaller [#call] `(signal, pid)`; raises Errno::ESRCH when the process is gone
      # @param sleeper [#call] sleeps for the given seconds
      # @param clock [#call] monotonic seconds
      # @param stop_timeout [Numeric] seconds to wait for the old daemon to let go of its socket
      # @param output [IO]
      def initialize(config:, project_config:, ensure_agent:, process_tree: ProcessTree.new, pid_finder: method(:lsof_pids), signaller: Process.method(:kill),
        sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        stop_timeout: DEFAULT_STOP_TIMEOUT, output: $stdout)
        @config = config
        @project_config = project_config
        @ensure_agent = ensure_agent
        @process_tree = process_tree
        @pid_finder = pid_finder
        @signaller = signaller
        @sleeper = sleeper
        @clock = clock
        @stop_timeout = stop_timeout
        @output = output
      end

      # Prints whether the workspace's daemon answers on its socket.
      #
      # @param name [String] workspace name
      # @param json [Boolean] print one JSON document
      # @return [Hash] `{exit_code: 0}`; not running is an answer, not a failure
      # @raise [Workspace::Error] code `unknown_workspace` when the workspace has no config
      def status(name:, json: false)
        require_workspace!(name)
        running = @config.agent_running?(name)
        pid = running ? find_pid(name) : nil
        socket = @config.agent_socket_path(name)
        log = @config.agent_log_path(name)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name,
                                      "running" => running, "pid" => pid, "socket" => socket, "log" => log})
        elsif running
          @output.puts "agentd for #{name} is running#{" (pid #{pid})" if pid}"
          @output.puts "socket: #{socket}"
          @output.puts "log:    #{log}"
        else
          @output.puts "agentd for #{name} is not running"
          @output.puts "Start it with: workspace agentd --ensure --name #{name}"
        end
        {exit_code: 0}
      end

      # Prints the end of the daemon's log. Only a daemon started detached
      # (`agentd --ensure`, `daemon restart`, `launch`) writes the file; one
      # run in a terminal writes to that terminal.
      #
      # @param name [String] workspace name
      # @param lines [Integer, nil] how many trailing lines; {DEFAULT_LINES} when nil
      # @param json [Boolean] print one JSON document with `path` and `lines`
      # @return [Hash] `{exit_code: 0}`
      # @raise [Workspace::Error] code `unknown_workspace` when the workspace has no config
      # @raise [Workspace::UsageError] when +lines+ isn't a positive integer within range
      def log(name:, lines: nil, json: false)
        require_workspace!(name)
        count = lines || DEFAULT_LINES
        unless count.is_a?(Integer) && count.between?(1, MAX_LINES)
          raise UsageError, "--lines must be a whole number from 1 to #{MAX_LINES}"
        end

        path = @config.agent_log_path(name)
        tail = read_tail(path, count)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name,
                                      "path" => path, "exists" => !tail.nil?, "lines" => tail || []})
        elsif tail.nil?
          @output.puts "No log at #{path}: no daemon for #{name} has been started in the background yet."
        else
          tail.each { |line| @output.puts line }
        end
        {exit_code: 0}
      end

      # Stops the workspace's daemon, then starts a new one detached. The
      # daemon is the process holding the socket, found with lsof, so a hung
      # one that no longer answers is stopped too; a daemon run in a terminal
      # is replaced by a detached one. With none running it just starts one.
      # Nothing is signalled unless exactly one process, other than this one,
      # has the socket open and is an `agentd` process.
      #
      # @param name [String] workspace name
      # @param wc_socket [String, nil] work-coordinator socket for the new daemon
      # @return [Result]
      # @raise [Workspace::Error] code `unknown_workspace` when the workspace has no config
      def restart(name:, wc_socket: nil)
        require_workspace!(name)
        # The owner of the socket is looked for even when nothing answers on
        # it: a hung daemon is the usual reason to restart, and starting a
        # second one beside it would help nobody.
        pids = socket_pids(name)
        running = @config.agent_running?(name)
        if pids.size > 1 || (pids.empty? && running)
          return failed("not_stopped", nil, "can't tell which process is the daemon for #{name} " \
            "(#{pids.empty? ? "lsof found none" : "#{pids.size} processes have its socket open"}); " \
            "stop it by hand and run: workspace agentd --ensure --name #{name}")
        end

        old_pid = pids.first
        if old_pid
          refused = confirm_agentd(name, old_pid)
          return refused if refused

          stopped = stop(name, old_pid)
          return stopped if stopped
        end

        start(name, wc_socket, old_pid)
      end

      private

      def require_workspace!(name)
        return if @project_config.exists?(name)

        raise Workspace::Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name})
      end

      # Refuses unless the process holding the socket is an `agentd`, so a
      # reused pid or an unrelated process that opened the socket is never signalled.
      def confirm_agentd(name, pid)
        entry = @process_tree.snapshot.find(pid)
        words = entry ? entry[:args].to_s.split : []
        return nil if words.drop(1).include?("agentd")

        described = entry ? "is running #{entry[:args].to_s[0, 80].inspect}" : "is not in the process table"
        failed("not_agentd", pid, "pid #{pid} holds the socket for #{name} but #{described}, not `workspace agentd`; " \
          "not signalling it. Stop it by hand and run: workspace agentd --ensure --name #{name}")
      rescue Workspace::Error => e
        failed("not_stopped", pid, "couldn't confirm pid #{pid} is the daemon for #{name}: #{e.message}")
      end

      def stop(name, pid)
        begin
          @signaller.call("TERM", pid)
        rescue Errno::ESRCH
          # already gone
        rescue SystemCallError => e
          return failed("not_stopped", pid, "couldn't stop the daemon for #{name} (pid #{pid}): #{e.message}")
        end
        deadline = @clock.call + @stop_timeout
        while @config.agent_running?(name) || alive?(pid)
          if @clock.call >= deadline
            return failed("not_stopped", pid, "the daemon for #{name} (pid #{pid}) was still running #{@stop_timeout}s after SIGTERM. " \
              "It may still exit: check `workspace daemon status #{name}`, then run `workspace daemon restart #{name}` again")
          end

          @sleeper.call(0.1)
        end
        nil
      end

      def alive?(pid)
        @signaller.call(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue SystemCallError
        true
      end

      def start(name, wc_socket, old_pid)
        result = @ensure_agent.call(name: name, wc_socket: wc_socket)
        case result.status
        when :started, :running
          Result.new(old_pid ? "restarted" : "started", old_pid, find_pid(name))
        when :invalid_config
          failed("invalid_config", old_pid, "#{name}'s pipeline config is invalid, so no daemon was started (see the warning above)")
        else
          failed("start_failed", old_pid, "couldn't start the daemon for #{name}: #{result.detail}")
        end
      end

      def failed(reason, old_pid, message)
        Result.new("failed", old_pid, nil, reason, message)
      end

      def find_pid(name)
        pids = socket_pids(name)
        (pids.size == 1) ? pids.first : nil
      end

      def socket_pids(name)
        Array(@pid_finder.call(@config.agent_socket_path(name))).map(&:to_i).select(&:positive?).uniq - [Process.pid]
      end

      # @return [Array<String>, nil] the last +count+ lines, nil when there is no log
      def read_tail(path, count)
        File.open(path, "rb") do |file|
          start = [file.size - TAIL_BYTES, 0].max
          cut_mid_line = start.positive? && file.seek(start - 1) && file.read(1) != "\n"
          file.seek(start)
          rows = file.read.to_s.force_encoding(Encoding::UTF_8).scrub("?").split("\n", -1)
          rows.pop if rows.last == ""
          rows.shift if cut_mid_line
          rows.last(count)
        end
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Workspace::Error, "Can't read #{path}: #{e.message}"
      end

      def lsof_pids(socket_path)
        out, _status = Open3.capture2("lsof", "-t", socket_path, err: File::NULL)
        out.split.map(&:to_i)
      rescue SystemCallError
        []
      end
    end
  end
end
