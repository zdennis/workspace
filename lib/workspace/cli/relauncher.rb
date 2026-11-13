module Workspace
  class CLI
    # Stops active workspaces and brings them back the way they were launched: the `relaunch` verb's
    # work, kept apart from its option parsing so another verb can reuse it. {#call} stops every
    # workspace, pauses, launches the windowed batch, then the headless one, and answers one entry
    # per workspace.
    class Relauncher
      # Set to "1" in the environment of the run {#detach} starts: that run relaunches in the foreground.
      # `relaunch` deletes it from the process environment as soon as it reads it, so the tmux
      # server and panes the run launches never inherit it.
      DETACHED_ENV = "WORKSPACE_RELAUNCH_DETACHED"

      # How many background relaunch logs {#detach} keeps, the newest by name.
      LOGS_KEPT = 20

      # @param stop_command [Workspace::Commands::Stop] stops the workspaces' sessions
      # @param hook_runner [Workspace::HookRunner] runs each stopped project's `post_stop` hook
      # @param launcher [CLI::Launcher] launches each batch and builds the rows
      # @param state [Workspace::State] says which workspaces were launched headless
      # @param sleeper [#call] sleeps the given seconds, injected for fast tests
      # @param tmux [Workspace::Tmux] says whether a workspace's session is up ({#running?}, and after the stop under +only_stopped+)
      # @param detacher [Workspace::DetachedSpawn, nil] starts the background run of {#detach}; nil refuses one (`relaunch_detach_failed`)
      # @param program [Array<String>] the command that runs `workspace` (Ruby and `bin/workspace`), for {#detach}
      # @param log_dir [String, nil] where {#detach} writes each background run's log and the `<name>.pid` record of each workspace it relaunches (`Config#relaunch_log_dir`)
      # @param processes [#start_time, #alive?, nil] tells a live background run from a dead one by pid and start time ({LockHolder}); nil treats every record as dead
      # @param clock [#call] the time a log is named by
      # @param pid [Integer] this process's pid, the other part of a log's name
      # @param wrapper_pid [#call] answers the pid of the wrapper that started this process (`Process.ppid`), whose record the background run leaves alone and removes
      def initialize(stop_command:, hook_runner:, launcher:, state:, sleeper:, tmux:, detacher: nil, program: [], log_dir: nil, processes: nil, clock: -> { Time.now }, pid: Process.pid, wrapper_pid: -> { Process.ppid })
        @detacher = detacher
        @program = program
        @log_dir = log_dir
        @processes = processes
        @wrapper_pid = wrapper_pid
        @clock = clock
        @pid = pid
        @stop_command = stop_command
        @tmux = tmux
        @hook_runner = hook_runner
        @launcher = launcher
        @state = state
        @sleeper = sleeper
      end

      # Stops the workspaces, waits, and launches them again. Headless ones stay headless. Both
      # batches are attempted even if the windowed batch fails, so a windowed failure never
      # silently drops the headless relaunch; the exit code reflects either failure.
      #
      # With +only_stopped+ (a verb that rewrote the workspaces' configs, where launching a session
      # left running would only re-attach it), each session is checked after the stop, since the stop
      # command answers its names whether or not tmux killed the session: a workspace whose session
      # is still up is not launched and answers a `failed` row, reason `relaunch_stop_failed`.
      #
      # @param invocation [Invocation] its output takes the progress line and the launches' text
      # @param names [Array<String>] the active workspaces to relaunch
      # @param only_stopped [Boolean] launch only the workspaces whose session is gone after the stop
      # @return [Hash] `{exit_code:, results:, warnings:}`: `results` one `relaunched` row per workspace, `warnings` what the stop command collected
      def call(invocation, names, only_stopped: false)
        headless, windowed = names.partition { |name| @state.dig(name, "headless") }
        invocation.output.puts "Will relaunch: #{names.join(", ")}"

        stopped = @stop_command.call(names.dup)
        stopped.each { |name| @hook_runner.run(name, "post_stop") }
        not_stopped = only_stopped ? names.select { |name| running?(name) } : []
        headless -= not_stopped
        windowed -= not_stopped

        @sleeper.call(2)

        launches = []
        launches << @launcher.launch(invocation, windowed.dup) if windowed.any?
        launches << @launcher.launch(invocation, headless.dup, headless: true) if headless.any?
        failed = launches.any? { |l| l[:exit_code] && !l[:exit_code].zero? }
        rows = launches.flat_map { |l| @launcher.rows(l[:projects], l[:result], ok_outcome: "relaunched") }
        rows += not_stopped.map do |name|
          {"workspace" => name, "outcome" => "failed", "reason" => "relaunch_stop_failed", "message" => "its tmux session did not stop, so it was not launched again"}
        end
        {exit_code: (failed || not_stopped.any?) ? 1 : 0, results: rows, warnings: @stop_command.warnings}
      end

      # Hands the relaunch of +names+ to a run of `workspace relaunch -- NAMES...` that leaves this
      # terminal's session ({DetachedSpawn}), for a caller inside a session the relaunch stops, whose
      # hangup would end it before anything was launched again. The run has {DETACHED_ENV} set, so it
      # never detaches again, and writes everything to its log. Under a lock in the log directory it
      # refuses a workspace another background run still relaunches, starts the run, writes each
      # workspace's `<name>.pid` record (the wrapper's pid, start time and log) and keeps the newest
      # {LOGS_KEPT} logs. Nothing is stopped here.
      #
      # @param names [Array<String>] the active workspaces, as the state file spells them
      # @return [Hash] `{pid:, log:}`, the wrapper's pid and the log's path
      # @raise [Workspace::Error] `relaunch_detach_failed` when the run could not be started (no runner, a
      #   program file that is missing or not executable, a spawn that failed); `relaunch_in_progress`
      #   from {#refuse_in_progress!}
      def detach(names)
        log = nil
        raise Error.new("No background runner is set up, so nothing was stopped.", code: "relaunch_detach_failed", details: {"log" => nil}) unless @detacher && @log_dir
        missing = @program.reject { |file| File.file?(file) && File.executable?(file) }
        if @program.empty? || missing.any?
          raise Error.new("The program the background relaunch runs (#{missing.join(", ")}) is missing or not executable, so nothing was stopped. Run `workspace relaunch #{names.join(" ")}` from a terminal outside the workspace.",
            code: "relaunch_detach_failed", details: {"log" => nil, "program" => missing})
        end
        log = File.join(@log_dir, "#{@clock.call.utc.strftime("%Y%m%dT%H%M%SZ")}-#{@pid}.log")
        FileLock.new(File.join(@log_dir, "relaunch.lock")).hold do
          refuse_in_progress!(names)
          pid = @detacher.call([*@program, "relaunch", "--", *names], log_path: log, env: {DETACHED_ENV => "1"})
          record = JSON.generate({"pid" => pid, "started" => start_time(pid), "log" => log})
          write_records(names, record)
          prune_logs
          {pid: pid, log: log}
        end
      rescue SystemCallError => e
        raise Error.new("Could not start the background relaunch (#{e.message}), so nothing was stopped. Run `workspace relaunch #{names.join(" ")}` from a terminal outside the workspace.",
          code: "relaunch_detach_failed", details: {"log" => log})
      end

      # Refuses +names+ when a background relaunch of one of them is still running: its `<name>.pid`
      # record names a live process (pid and start time) other than the wrapper that started this
      # one. A record of a dead process is ignored; a process table that can't be read counts as live.
      #
      # @param names [Array<String>]
      # @param except_own [Boolean] leave alone the record of this process's own wrapper (the background run's check)
      # @return [void]
      # @raise [Workspace::Error] `relaunch_in_progress` with `names`, `pid` and `log`
      def refuse_in_progress!(names, except_own: false)
        return unless @log_dir
        own = except_own ? @wrapper_pid.call : nil
        busy = names.filter_map do |name|
          record = read_record(name)
          next unless record && record["pid"] != own && live?(record)
          [name, record]
        end
        return if busy.empty?
        record = busy.first.last
        raise Error.new("A background relaunch of #{busy.map(&:first).join(", ")} is still running (pid #{record["pid"]}); its log is #{record["log"]}. Wait for it to finish, then try again.",
          code: "relaunch_in_progress", details: {"names" => busy.map(&:first), "pid" => record["pid"], "log" => record["log"]})
      end

      # Removes the `<name>.pid` records that name this process's own wrapper, once the background run is done.
      #
      # @param names [Array<String>]
      # @return [void]
      def release(names)
        return unless @log_dir
        own = @wrapper_pid.call
        names.each do |name|
          File.delete(record_path(name)) if read_record(name)&.dig("pid") == own
        rescue SystemCallError
          nil
        end
      end

      # A test of whether a workspace is the one this command runs in: +here+ (the workspace of the
      # working directory), or one whose tmux session holds `$TMUX_PANE` (asked of that workspace's
      # own tmux server), or, where `$TMUX_PANE` is unset or tmux can't place it for that workspace,
      # whose session is that of the tmux client `$TMUX` names (read once). Either match counts, so a
      # stale `$TMUX_PANE` can only count too many. A workspace tmux can't place counts only by +here+.
      #
      # @param env [Hash{String=>String}] the run's environment (`TMUX_PANE`, `TMUX`)
      # @param here [String, nil] the workspace of the working directory
      # @param tally [Hash, nil] `{asked:, answered:}`, counting the tmux lookups and the ones tmux answered
      # @return [Proc] given a workspace name, true when it is the caller's own
      def own_workspace(env, here, tally = nil)
        pane = env["TMUX_PANE"]
        pane = nil if pane&.empty?
        client = env["TMUX"]
        client = nil if client&.empty?
        client_session = nil
        client_read = false
        lambda do |name|
          next true if WorkspaceName.same?(name, here)
          next false unless pane || client
          answer = pane && pane_in_session?(pane, name)
          if answer.nil? && client
            client_session = client_session(client) unless client_read
            client_read = true
            answer = client_session && session_of?(client_session, name)
          end
          if tally
            tally[:asked] += 1
            tally[:answered] += 1 unless answer.nil?
          end
          answer == true
        end
      end

      # The state file's key for +name+ (matched with {WorkspaceName.same?}), the test `relaunch`
      # refuses an inactive workspace by.
      #
      # @param name [String]
      # @return [String, nil] the key as the state file spells it, nil when the workspace isn't active
      def active_name(name)
        @state.load
        @state.keys.find { |key| WorkspaceName.same?(key, name) }
      end

      # Whether +pane_id+ is a pane of the workspace's tmux session, asked of the tmux server the
      # workspace runs on (its custom socket, if its config names one). Both session names are
      # compared as tmux stores them (the pane's from tmux, the workspace's through {Tmux#session_name_for}).
      #
      # @param pane_id [String] a pane id such as `$TMUX_PANE`
      # @param name [String] the workspace
      # @return [Boolean, nil] nil when tmux can't say which session the pane is in on that server
      def pane_in_session?(pane_id, name)
        session = @tmux.session_name_for_pane(pane_id, project: name)
        return nil if session.nil?
        Tmux.stored_session_name(session) == @tmux.session_name_for(name)
      rescue Error, SystemCallError
        nil
      end

      # The session of the tmux client this command runs in, for a command with `$TMUX` set but no `$TMUX_PANE`.
      #
      # @param tmux_env [String] the value of `$TMUX`
      # @return [String, nil] nil when tmux can't say
      def client_session(tmux_env)
        @tmux.client_session_name(tmux_env)
      rescue Error, SystemCallError
        nil
      end

      # Whether +session+ is the workspace's tmux session, both names compared as tmux stores them.
      #
      # @param session [String] a session name tmux gave
      # @param name [String] the workspace
      # @return [Boolean, nil] nil when the workspace's session name can't be read
      def session_of?(session, name)
        Tmux.stored_session_name(session) == @tmux.session_name_for(name)
      rescue Error, SystemCallError
        nil
      end

      # Whether the workspace's tmux session is up, asked under the name tmux stores it by. A session
      # whose name can't be worked out counts as up, so a relaunch never launches over it.
      #
      # @param name [String]
      # @return [Boolean]
      def running?(name)
        @tmux.session_exists?(@tmux.session_name_for(name), project: name)
      rescue Error, SystemCallError
        true
      end

      private

      def record_path(name)
        File.join(@log_dir, "#{name.downcase}.pid")
      end

      def read_record(name)
        record = JSON.parse(File.read(record_path(name)))
        (record.is_a?(Hash) && record["pid"].is_a?(Integer)) ? record : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end

      # The run has already started, so a record that can't be written only costs the second-relaunch check.
      def write_records(names, record)
        names.each { |name| AtomicFile.write(record_path(name), record, perm: 0o600) }
      rescue SystemCallError
        nil
      end

      def live?(record)
        return false unless @processes
        return pid_exists?(record["pid"]) if record["started"].nil?
        @processes.alive?(pid: record["pid"], started: record["started"])
      rescue Error
        true
      end

      # A record with no start time can only be checked by whether its pid exists.
      def pid_exists?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue SystemCallError
        true
      end

      def start_time(pid)
        @processes&.start_time(pid)
      rescue Error
        nil
      end

      def prune_logs
        logs = Dir.glob(File.join(@log_dir, "*.log")).sort
        logs[0...-LOGS_KEPT].to_a.each { |file| File.delete(file) }
      rescue SystemCallError
        nil
      end
    end
  end
end
