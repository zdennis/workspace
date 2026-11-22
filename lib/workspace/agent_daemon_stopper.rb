module Workspace
  # Stops one workspace's agent daemon (`workspace agentd --name NAME`) from
  # its name alone, so it works after the workspace's config is gone. The
  # daemon is the process holding the workspace's socket, found with `lsof`
  # (a hung daemon that no longer answers is found too). Nothing is signalled
  # unless exactly one process, other than this one, holds the socket, is an
  # `agentd` process and does not name a different workspace.
  class AgentDaemonStopper
    # How long a stop waits for the daemon to let go of its socket.
    DEFAULT_STOP_TIMEOUT = 5

    # How long `lsof` gets to name the processes that have the socket open.
    LSOF_TIMEOUT = 2

    LSOF_COMMAND = %w[lsof -t].freeze
    private_constant :LSOF_COMMAND

    # What {#call} did. `status` is :stopped, :not_running (nothing holds the
    # socket and nothing answers), :refused (nothing was signalled, or the
    # signal failed) or :timed_out (signalled, still there after the wait).
    # `pid` is the process looked at, nil when there was none.
    Result = Struct.new(:status, :pid, :message) do
      # @return [Boolean] whether a daemon was stopped or none was running
      def ok?
        status == :stopped || status == :not_running
      end

      # The line a teardown prints to its output for workspace +name+, nil
      # unless a daemon was stopped.
      #
      # @return [String, nil]
      def notice(name)
        "Stopped agent daemon for #{name} (pid #{pid})" if status == :stopped
      end

      # The line a teardown prints to its error output for workspace +name+,
      # nil unless the stop was refused or timed out.
      #
      # @return [String, nil]
      def warning(name)
        "Warning: #{message}. Check it with: workspace daemon status #{name}" if status == :refused || status == :timed_out
      end
    end

    # What a socket holder's command line says. `refusal` is nil when it is
    # the workspace's `agentd`; else :not_agentd (`detail` says what it is
    # running), :other_workspace (`detail` is the name it serves) or
    # :unconfirmed (the process table couldn't be read; `detail` says why).
    Holder = Struct.new(:words, :refusal, :detail)

    # agentd flags that take the next word as their value, so that word is
    # not the positional workspace name.
    VALUE_FLAGS = %w[--name --wc-socket].freeze

    # @return [Numeric] seconds a stop waits for the daemon to exit
    attr_reader :stop_timeout

    # @return [Numeric] seconds the default pid finder waits for `lsof`
    attr_reader :lsof_timeout

    # @param config [Workspace::Config] socket path and liveness probe
    # @param process_tree [Workspace::ProcessTree] confirms a pid is an `agentd` process before it is signalled
    # @param pid_finder [#call, nil] `(socket_path)` returns the pids with the socket open, or nil when it
    #   couldn't find out in time; defaults to `lsof`
    # @param signaller [#call] `(signal, pid)`; raises Errno::ESRCH when the process is gone
    # @param sleeper [#call] sleeps for the given seconds
    # @param clock [#call] monotonic seconds
    # @param stop_timeout [Numeric] seconds to wait for the daemon to let go of its socket
    # @param lsof_command [Array<String>] the `lsof` argv the default +pid_finder+ runs, before the socket path
    # @param lsof_timeout [Numeric] seconds the default +pid_finder+ waits for `lsof` before killing it
    def initialize(config:, process_tree: ProcessTree.new, pid_finder: nil, signaller: Process.method(:kill),
      sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      stop_timeout: DEFAULT_STOP_TIMEOUT, lsof_command: LSOF_COMMAND, lsof_timeout: LSOF_TIMEOUT)
      @config = config
      @process_tree = process_tree
      @signaller = signaller
      @sleeper = sleeper
      @clock = clock
      @stop_timeout = stop_timeout
      @lsof_command = lsof_command
      @lsof_timeout = lsof_timeout
      @pid_finder = pid_finder || method(:lsof_pids)
    end

    # Stops the workspace's daemon with SIGTERM and waits for it to go.
    #
    # @param name [String] workspace name
    # @return [Result]
    def call(name:)
      pids = socket_pids(name)
      unless pids
        return refused(nil, "lsof did not answer within #{@lsof_timeout}s, so the process holding the socket for #{name} can't be identified; nothing was stopped")
      end

      running = @config.agent_running?(name)
      return Result.new(:not_running, nil, "no agentd for #{name} is running").freeze if pids.empty? && !running
      if pids.size > 1 || pids.empty?
        return refused(nil, "can't tell which process is the daemon for #{name} " \
          "(#{pids.empty? ? "lsof found none" : "#{pids.size} processes have its socket open"}); nothing was stopped")
      end

      pid = pids.first
      holder = holder(name, pid)
      return refused(pid, refusal_message(name, pid, holder)) if holder.refusal

      terminate(name, pid)
    end

    # @return [Integer, nil] the pid of the one process holding the workspace's socket; nil when none, several, or lsof didn't answer
    def find_pid(name)
      pids = socket_pids(name)
      (pids&.size == 1) ? pids.first : nil
    end

    # @return [Array<Integer>, nil] the pids holding the workspace's socket, this process excluded; nil when the finder couldn't answer in time
    def socket_pids(name)
      found = @pid_finder.call(socket_path_on_disk(@config.agent_socket_path(name)))
      found && (Array(found).map(&:to_i).select(&:positive?).uniq - [Process.pid])
    end

    # Reads the process +pid+ from the process table and checks it is the
    # `agentd` of workspace +name+, so a reused pid or an unrelated process
    # that opened the socket is never signalled.
    #
    # @return [Holder]
    def holder(name, pid)
      entry = @process_tree.snapshot.find(pid)
      words = entry ? entry[:args].to_s.split : []
      unless words.drop(1).include?("agentd")
        described = entry ? "is running #{entry[:args].to_s[0, 80].inspect}" : "is not in the process table"
        return Holder.new(words, :not_agentd, described).freeze
      end

      served = served_name(words)
      return Holder.new(words, :other_workspace, served).freeze if served && !WorkspaceName.same?(served, name)

      Holder.new(words, nil, nil).freeze
    rescue Workspace::Error => e
      Holder.new([], :unconfirmed, e.message).freeze
    end

    # Sends SIGTERM to +pid+ and waits up to the stop timeout for it and its
    # socket to go. Never signals this process.
    #
    # @return [Result] :stopped, :refused (the signal failed) or :timed_out
    def terminate(name, pid)
      return refused(pid, "refusing to signal this process (pid #{pid})") if pid == Process.pid

      begin
        @signaller.call("TERM", pid)
      rescue Errno::ESRCH
        # already gone
      rescue SystemCallError => e
        return refused(pid, "couldn't stop the daemon for #{name} (pid #{pid}): #{e.message}")
      end
      deadline = @clock.call + @stop_timeout
      while @config.agent_running?(name) || alive?(pid)
        if @clock.call >= deadline
          return Result.new(:timed_out, pid, "the daemon for #{name} (pid #{pid}) was still running #{@stop_timeout}s after SIGTERM").freeze
        end

        @sleeper.call(0.1)
      end
      Result.new(:stopped, pid, "stopped the daemon for #{name} (pid #{pid})").freeze
    end

    private

    def refused(pid, message)
      Result.new(:refused, pid, message).freeze
    end

    def refusal_message(name, pid, holder)
      case holder.refusal
      when :not_agentd then "pid #{pid} holds the socket for #{name} but #{holder.detail}, not `workspace agentd`; not signalling it"
      when :other_workspace then "pid #{pid} holds the socket for #{name} but is the agentd for #{holder.detail}; not signalling it"
      else "couldn't confirm pid #{pid} is the daemon for #{name}: #{holder.detail}"
      end
    end

    # The workspace an `agentd` command line names: `--name NAME`, `--name=NAME`
    # (any abbreviation OptionParser takes), else a trailing positional word.
    # nil when it names none or can't be told.
    def served_name(words)
      start = words.index("agentd")
      args = words[(start + 1)..]
      index = args.rindex { |word| word.start_with?("--") && word.split("=", 2).first.length >= 3 && "--name".start_with?(word.split("=", 2).first) }
      if index
        return args[index].include?("=") ? args[index].split("=", 2).last : args[index + 1]
      end

      last = args.last
      return nil if last.nil? || last.start_with?("-")

      VALUE_FLAGS.include?(args[-2]) ? nil : last
    end

    def alive?(pid)
      @signaller.call(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue SystemCallError
      true
    end

    # The socket as the file system spells it (this is only for `lsof`, which matches paths exactly).
    # A daemon started as `notes` for the config `Notes` made `notes.sock`.
    def socket_path_on_disk(path)
      entries = Dir.children(File.dirname(path))
      return path if entries.include?(File.basename(path))

      found = entries.find { |entry| WorkspaceName.same?(entry, File.basename(path)) }
      found ? File.join(File.dirname(path), found) : path
    rescue SystemCallError
      path
    end

    # Waits at most @lsof_timeout for `lsof`, so one that hangs (a dead
    # network mount is the usual cause) can't stall a stop. On timeout the
    # child is killed and reaped.
    #
    # @return [Array<Integer>, nil] the pids; empty when lsof is missing or
    #   found none; nil when it didn't answer in time
    def lsof_pids(socket_path)
      reader, writer = IO.pipe
      pid = Process.spawn(*@lsof_command, socket_path, in: File::NULL, out: writer, err: File::NULL)
      waiter = Process.detach(pid)
      writer.close
      output = Thread.new { reader.read }.tap { |thread| thread.report_on_exception = false }
      return nil unless waiter.join(@lsof_timeout)

      output.value.split.map(&:to_i)
    rescue SystemCallError
      []
    ensure
      if waiter&.alive?
        begin
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join
      end
      output&.kill&.join
      [reader, writer].each { |io| io.close if io && !io.closed? }
    end
  end
end
