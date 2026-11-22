require "json"
require "time"

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
      DEFAULT_STOP_TIMEOUT = AgentDaemonStopper::DEFAULT_STOP_TIMEOUT

      # How long `lsof` gets to name the processes that have the socket open.
      LSOF_TIMEOUT = AgentDaemonStopper::LSOF_TIMEOUT

      # How long `list` waits for each answering daemon to say its version.
      VERSION_TIMEOUT = 2

      # What a skipped run is waiting for, for the codes the daemon logs.
      SKIP_REASONS = {"paused" => "paused", "retry_backoff" => "waiting out its retry backoff", "not_due" => "nothing to do yet"}.freeze

      # Seconds between reads while `watch` follows.
      WATCH_POLL_INTERVAL = 0.25

      # What a restart did. `outcome` is "restarted" (a daemon was stopped and
      # a new one answers), "started" (none was running, one answers now) or
      # "failed", with `reason` and `message` saying why. `wc_socket` is the
      # work-coordinator socket the new daemon was started with: the caller's,
      # else the old daemon's, else nil for the default one. On a failure it
      # is the socket to name when running the restart again, and nil when
      # there is none to name.
      Result = Struct.new(:outcome, :old_pid, :pid, :reason, :message, :wc_socket) do
        # @return [Boolean] whether a daemon is answering after the restart
        def ok?
          outcome != "failed"
        end
      end

      # One running agent daemon, as `list` reports it. `pid` and `started_at`
      # are nil when they can't be read; `answering` is false for a daemon that
      # holds its socket but no longer replies (a hung one). `version` is the
      # workspace version the daemon runs: nil when it is hung, doesn't answer
      # in time, or predates the `version` request.
      Entry = Struct.new(:workspace, :pid, :socket, :log, :started_at, :wc_socket, :answering, :version)

      # @param config [Workspace::Config] socket and log paths, liveness probe
      # @param project_config [Workspace::ProjectConfig] knows which workspaces exist
      # @param ensure_agent [Workspace::Commands::EnsureAgent] starts the new daemon, detached, under its lock
      # @param process_tree [Workspace::ProcessTree] confirms a pid is an `agentd` process before it is signalled
      # @param version_client [Workspace::AgentSnapshotClient] asks an answering daemon which version it runs
      # @param stopper [Workspace::AgentDaemonStopper, nil] stops and finds the daemon; nil builds one from the
      #   +process_tree+, +pid_finder+, +signaller+, +clock+, +stop_timeout+, +lsof_command+ and +lsof_timeout+ given here
      # @param pid_finder [#call] `(socket_path)` returns the pids with the socket open,
      #   or nil when it couldn't find out in time
      # @param signaller [#call] `(signal, pid)`; raises Errno::ESRCH when the process is gone
      # @param sleeper [#call] sleeps for the given seconds
      # @param clock [#call] monotonic seconds
      # @param stop_timeout [Numeric] seconds to wait for the old daemon to let go of its socket
      # @param lsof_command [Array<String>] the `lsof` argv the default +pid_finder+ runs, before the socket path
      # @param lsof_timeout [Numeric] seconds the default +pid_finder+ waits for `lsof` before killing it
      # @param watch_factory [#call, nil] `(workspace:, run:)` builds the {Workspace::DaemonWatch} that `watch` follows; nil refuses `watch`
      # @param wall_clock [#now] time source, for the watch's first and last lines
      # @param output [IO]
      def initialize(config:, project_config:, ensure_agent:, version_client:, watch_factory: nil, wall_clock: Time, process_tree: ProcessTree.new, stopper: nil, pid_finder: nil, signaller: Process.method(:kill),
        sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        stop_timeout: DEFAULT_STOP_TIMEOUT, lsof_command: nil, lsof_timeout: LSOF_TIMEOUT, output: $stdout)
        @config = config
        @project_config = project_config
        @ensure_agent = ensure_agent
        @process_tree = process_tree
        @version_client = version_client
        @watch_factory = watch_factory
        @wall_clock = wall_clock
        @sleeper = sleeper
        @stop_timeout = stop_timeout
        @stopper = stopper || AgentDaemonStopper.new(config: config, process_tree: process_tree, pid_finder: pid_finder, signaller: signaller,
          sleeper: sleeper, clock: clock, stop_timeout: stop_timeout, lsof_timeout: lsof_timeout, **{lsof_command: lsof_command}.compact)
        @output = output
      end

      # Finds every running agent daemon and prints it: the workspace it
      # serves, its pid, start time, version, work-coordinator socket and paths. The
      # workspaces come from the tmuxinator configs, and each one's daemon
      # from its socket: a daemon counts when it answers on the socket, or
      # holds it but is hung and is an `agentd` process. A socket file with no
      # process behind it is stale and is ignored.
      #
      # @param json [Boolean] print one JSON document
      # @return [Hash] `{exit_code: 0}`; none running is an answer, not a failure
      def list(json: false)
        entries = running_daemons
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "daemons" => entries.map { |e| entry_hash(e) }, "warnings" => []})
        elsif entries.empty?
          @output.puts "No agentd processes are running."
        else
          rows = entries.map do |e|
            [e.workspace, e.pid.to_s, e.started_at.to_s, e.version || "-", e.answering ? "yes" : "no (hung)", e.socket]
          end
          table = [%w[WORKSPACE PID STARTED VERSION ANSWERING SOCKET]] + rows
          widths = table.transpose.map { |column| column.map(&:length).max }
          table.each { |row| @output.puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
        end
        {exit_code: 0}
      end

      # Restarts every running agent daemon, one after another, with {#restart}.
      # One failing does not stop the rest; an error a restart raises becomes that
      # workspace's failed row, with the error's code as the reason (`restart_failed`
      # when it carries none).
      #
      # @return [Array<Array(String, Result)>] workspace name and what its restart did
      def restart_all
        report_progress("Looking for running agentd processes...")
        running_daemons(on_check: ->(name) { report_progress("Checking agentd candidate for #{name}...") },
          on_found: ->(name) { report_progress("Found agentd for #{name}.") }).map do |entry|
          report_progress("Restarting agentd for #{entry.workspace}...")
          [entry.workspace, restart(name: entry.workspace)]
        rescue Workspace::Error => e
          [entry.workspace, failed((e.code.to_s == "error") ? "restart_failed" : e.code, entry.pid, e.message)]
        end
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

      # Follows what the workspace's daemon decides about its workflow runs and
      # what its runs record, as one stream of lines, until stopped (Ctrl-C) or,
      # with +run+, until that run has finished and its events are all printed.
      # It starts from now; +since+ resumes after a line. It only reads files, so
      # it needs no running daemon. Each line carries a cursor (see
      # {Workspace::DaemonWatch}); the first is a `follow_started` line and, with
      # +run+, the last a `follow_ended` line.
      #
      # @param name [String] workspace name
      # @param run [String, nil] follow only this run
      # @param since [String, nil] a cursor a line of this watch (same workspace and +run+) printed
      # @param json [Boolean] one JSON document per line instead of a sentence
      # @param max_polls [Integer, nil] stop after this many reads (for tests)
      # @return [Hash] `{exit_code: 0}`
      # @raise [Workspace::Error] code `unknown_workspace`, or `unknown_run` when +run+ names no run
      # @raise [Workspace::EventStream::InvalidCursor] when +since+ can't be read
      def watch(name:, run: nil, since: nil, json: false, max_polls: nil)
        raise Workspace::Error, "daemon watch is not available: no watch was wired" unless @watch_factory
        require_workspace!(name)
        watch = @watch_factory.call(workspace: name, run: run)
        gaps = watch.open(cursor: since, at: :end)
        emit_watch([watch_line("follow_started", name, run, watch.cursor_string), *gaps], json)
        polls = 0
        loop do
          polls += 1
          emit_watch(watch.read(discover: nil), json)
          if watch.done?
            emit_watch([watch_line("follow_ended", name, run, watch.cursor_string).merge("state" => watch.state)], json)
            break
          end
          break if max_polls && polls >= max_polls
          @sleeper.call(WATCH_POLL_INTERVAL) unless watch.more?
        end
        {exit_code: 0}
      rescue Errno::EPIPE, Interrupt
        {exit_code: 0}
      rescue SystemCallError, IOError => e
        raise Workspace::Error, "could not read the event files (#{e.message})"
      end

      # Stops the workspace's daemon, then starts a new one detached. The
      # daemon is the process holding the socket, found with lsof, so a hung
      # one that no longer answers is stopped too; a daemon run in a terminal
      # is replaced by a detached one. With none running it just starts one.
      # Nothing is signalled unless exactly one process, other than this one,
      # has the socket open and is an `agentd` process.
      #
      # The new daemon keeps the old one's work-coordinator socket: without
      # +wc_socket+ it gets the `--wc-socket` on the old daemon's command
      # line. When that path can't be read back, nothing is stopped.
      #
      # @param name [String] workspace name
      # @param wc_socket [String, nil] work-coordinator socket for the new daemon;
      #   nil keeps the old daemon's
      # @return [Result]
      # @raise [Workspace::Error] code `unknown_workspace` when the workspace has no config
      def restart(name:, wc_socket: nil)
        require_workspace!(name)
        # The owner of the socket is looked for even when nothing answers on
        # it: a hung daemon is the usual reason to restart, and starting a
        # second one beside it would help nobody.
        pids = socket_pids(name)
        unless pids
          return failed("not_stopped", nil, "lsof did not answer within #{@stopper.lsof_timeout}s, so the process holding the socket " \
            "for #{name} can't be identified; nothing was stopped. Run it again: workspace daemon restart #{name}")
        end

        running = @config.agent_running?(name)
        if pids.size > 1 || (pids.empty? && running)
          return failed("not_stopped", nil, "can't tell which process is the daemon for #{name} " \
            "(#{pids.empty? ? "lsof found none" : "#{pids.size} processes have its socket open"}); " \
            "stop it by hand and run: workspace agentd --ensure --name #{name}")
        end

        old_pid = pids.first
        if old_pid
          holder = @stopper.holder(name, old_pid)
          return holder_refusal(name, old_pid, holder) if holder.refusal

          wc_socket ||= old_wc_socket(holder.words, name)
          if wc_socket == :unknown
            return failed("wc_socket_unknown", old_pid, "the daemon for #{name} (pid #{old_pid}) was started with a --wc-socket " \
              "whose path can't be read back from its command line (a relative path, or one with a space); nothing was stopped. " \
              "Name the socket for the new daemon: workspace daemon restart #{name} --wc-socket PATH")
          end

          stopped = stop_failure(name, old_pid, wc_socket, @stopper.terminate(name, old_pid))
          return stopped if stopped
        end

        start(name, wc_socket, old_pid)
      end

      private

      # @return [Array<Entry>] the running daemons, by workspace name
      def running_daemons(on_check: nil, on_found: nil)
        candidates = @project_config.available_projects.filter_map do |name|
          socket = @config.agent_socket_path(name)
          [name, socket] if File.exist?(socket)
        rescue Workspace::Error
          nil
        end
        return [] if candidates.empty?

        snapshot = begin
          @process_tree.snapshot
        rescue Workspace::Error
          nil
        end
        candidates.filter_map { |name, socket| daemon_entry(name, socket, snapshot, on_check: on_check, on_found: on_found) }
      end

      def daemon_entry(name, socket, snapshot, on_check: nil, on_found: nil)
        on_check&.call(name)
        answering = @config.agent_running?(name)
        pids = socket_pids(name)
        pid = (pids&.size == 1) ? pids.first : nil
        process = pid && snapshot&.find(pid)
        agentd = process && process[:args].to_s.split.drop(1).include?("agentd")
        return nil unless answering || agentd || pids&.size.to_i > 1

        wc_socket = agentd ? old_wc_socket(process[:args].to_s.split, name) : nil
        on_found&.call(name)
        Entry.new(name, pid, socket, @config.agent_log_path(name), started_at(process), wc_socket.is_a?(String) ? wc_socket : nil, answering,
          answering ? daemon_version(name) : nil)
      end

      def report_progress(message)
        @output.puts message
        @output.flush
      end

      def daemon_version(name)
        @version_client.version(name, timeout: VERSION_TIMEOUT)
      rescue Workspace::Error
        nil
      end

      def started_at(process)
        process && Time.strptime("#{process[:lstart].to_s.squeeze(" ")} +0000", "%a %b %d %H:%M:%S %Y %z").utc.iso8601
      rescue ArgumentError
        nil
      end

      def entry_hash(entry)
        {"workspace" => entry.workspace, "pid" => entry.pid, "started_at" => entry.started_at, "version" => entry.version, "answering" => entry.answering,
         "socket" => entry.socket, "log" => entry.log, "wc_socket" => entry.wc_socket}
      end

      def watch_line(type, workspace, run, cursor)
        {"source" => "watch", "at" => @wall_clock.now.utc.iso8601(3), "type" => type, "workspace" => workspace, "run_id" => run, "event" => {}, "cursor" => cursor}
      end

      def emit_watch(lines, json)
        return if lines.empty?
        lines.each { |line| @output.puts(json ? JSON.generate(line) : "#{Duration.clock_time(line["at"])} #{watch_sentence(line)}") }
        @output.flush
      end

      # One plain sentence for a line; every piece that may hold pane or file text is escaped.
      def watch_sentence(line)
        event = line["event"]
        run = TerminalText.escape(line["run_id"])
        case line["type"]
        when "follow_started" then "watching #{TerminalText.escape(line["workspace"])}#{" for run #{run}" if line["run_id"]} from now; Ctrl-C stops#{history_hint(line)}"
        when "follow_ended" then "run #{run} #{TerminalText.escape(line["state"] || "finished")}; no more events#{history_hint(line)}"
        when "gap" then "lines before the cursor are gone (#{TerminalText.escape(event["reason"])}) from the #{TerminalText.escape(event["source"])} log"
        when "workflow_advance_started" then advance_started_text(event, run)
        when "workflow_run_skipped" then "run #{run} skipped: #{SKIP_REASONS.fetch(event["reason"]) { TerminalText.escape(event["reason"]) }}"
        when "workflow_sweep_started" then "sweep started for #{run_names(event["run_ids"])}"
        when "workflow_process_exited" then process_exited_text(event, run)
        else run_event_text(line)
        end
      end

      def history_hint(line)
        " (earlier events: workspace workflow events #{TerminalText.escape(line["run_id"])})" if line["run_id"]
      end

      def advance_started_text(event, run)
        pane = event["pane_id"] && " in pane #{TerminalText.escape(event["pane_id"])}"
        why = (event["cause"] == "turn_ended") ? " after its turn ended" : " by the tick#{" (#{TerminalText.escape(event["reason"])})" if event["reason"]}"
        "advance started for run #{run}#{pane}#{why}"
      end

      def process_exited_text(event, run)
        what = (event["kind"] == "sweep") ? "sweep for #{run_names(event["run_ids"])}" : "advance for run #{run}"
        how = event["signal"] ? "was ended by signal #{TerminalText.escape(event["signal"])}" : "exited with code #{TerminalText.escape(event["exit_code"])}"
        seconds = event["seconds"]
        "#{what} #{how}#{" after #{seconds.to_f.round(1).to_s.delete_suffix(".0")}s" if seconds.is_a?(Numeric)}"
      end

      def run_names(ids)
        names = Array(ids).map { |id| TerminalText.escape(id) }
        names.empty? ? "no runs" : "run#{"s" if names.size > 1} #{names.join(", ")}"
      end

      # `run ID  N  type  key=value ...`, like `workflow events`.
      def run_event_text(line)
        event = line["event"]
        rest = event.except("n", "ts", "at", "type").map do |key, value|
          "#{TerminalText.escape(key)}=#{value.is_a?(String) ? TerminalText.escape(value) : TerminalText.escape(JSON.generate(value))}"
        end
        ["run #{TerminalText.escape(line["run_id"])}", ("line #{event["n"]}" if event["n"]), TerminalText.escape(line["type"]), *rest].compact.join("  ")
      end

      def require_workspace!(name)
        return if @project_config.exists?(name)

        raise Workspace::Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name})
      end

      # The `--wc-socket` a daemon was started with, from its command line as
      # `ps` prints it: words joined by spaces, so a path with a space in it
      # can't always be told from a path followed by a workspace name or
      # another flag. The last one given is read, as the daemon's own parser
      # does, in any spelling that parser takes (`--wc`, `--wc-socket=PATH`).
      #
      # @return [String, Symbol, nil] the path, nil when the daemon named
      #   none, :unknown when it named one that can't be read back
      def old_wc_socket(words, name)
        index = words.rindex { |word| flag?(word, "--wc-socket") }
        return nil unless index

        value = words[(index + 1)..].take_while { |word| !word.start_with?("-") }
        value.unshift(words[index].split("=", 2).last) if words[index].include?("=")
        value.pop if value.size > 1 && WorkspaceName.same?(value.last, name) && words.none? { |word| flag?(word, "--name") }
        (value.size == 1 && value.first.start_with?("/")) ? value.first : :unknown
      end

      # Whether +word+ is +flag+ as OptionParser would take it: the flag or an
      # abbreviation of it down to its first letter, with or without `=VALUE`.
      def flag?(word, flag)
        given = word.split("=", 2).first
        given.length >= 3 && flag.start_with?(given)
      end

      # What to add to a failure after the old daemon was signalled: once it
      # has exited, its command line is gone and a second restart can't read
      # the socket back.
      def retry_hint(name, wc_socket)
        return "" unless wc_socket

        ". The old daemon's work-coordinator socket can't be read again once it has stopped, so name it: " \
          "workspace daemon restart #{name} --wc-socket #{wc_socket}"
      end

      def start(name, wc_socket, old_pid)
        result = @ensure_agent.call(name: name, wc_socket: wc_socket)
        case result.status
        when :started
          Result.new(old_pid ? "restarted" : "started", old_pid, find_pid(name), nil, nil, wc_socket)
        when :running
          # Another caller started one between the stop and the start, with
          # whatever socket it chose; this restart's was not used.
          Result.new(old_pid ? "restarted" : "started", old_pid, find_pid(name))
        when :invalid_config
          failed("invalid_config", old_pid, "#{name}'s pipeline config is invalid, so no daemon was started (see the warning above)" \
            "#{retry_hint(name, old_pid && wc_socket)}", wc_socket)
        else
          failed("start_failed", old_pid, "couldn't start the daemon for #{name}: #{result.detail}#{retry_hint(name, old_pid && wc_socket)}", wc_socket)
        end
      end

      def holder_refusal(name, pid, holder)
        case holder.refusal
        when :not_agentd
          failed("not_agentd", pid, "pid #{pid} holds the socket for #{name} but #{holder.detail}, not `workspace agentd`; " \
            "not signalling it. Stop it by hand and run: workspace agentd --ensure --name #{name}")
        when :other_workspace
          failed("not_stopped", pid, "pid #{pid} holds the socket for #{name} but is the agentd for #{holder.detail}; " \
            "not signalling it. Stop it by hand and run: workspace agentd --ensure --name #{name}")
        else
          failed("not_stopped", pid, "couldn't confirm pid #{pid} is the daemon for #{name}: #{holder.detail}")
        end
      end

      # @return [Result, nil] the failure a stopper result means for a restart, nil when the old daemon is gone
      def stop_failure(name, pid, wc_socket, result)
        case result.status
        when :refused
          failed("not_stopped", pid, result.message, wc_socket)
        when :timed_out
          failed("not_stopped", pid, "the daemon for #{name} (pid #{pid}) was still running #{@stopper.stop_timeout}s after SIGTERM. " \
            "It may still exit: check `workspace daemon status #{name}`, then run `workspace daemon restart #{name}` again" \
            "#{retry_hint(name, wc_socket)}", wc_socket)
        end
      end

      def find_pid(name)
        @stopper.find_pid(name)
      end

      def socket_pids(name)
        @stopper.socket_pids(name)
      end

      def failed(reason, old_pid, message, wc_socket = nil)
        Result.new("failed", old_pid, nil, reason, message, wc_socket)
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
    end
  end
end
