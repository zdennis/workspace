require "open3"
require "rbconfig"
require "socket"
require "time"
require "json"

module Workspace
  module Commands
    # Starts, stops, and inspects a repository's single dev environment,
    # guarded by the repo-wide `devenv` lock.
    #
    # `up` opens a `devenv` tmux window running `workspace dev __run` (the
    # {DevRunner} wrapper, which holds the lock for exactly as long as the
    # dev command runs), waits for the wrapper to hold the lock, then waits
    # for the configured `ready` probe. Every public method returns
    # `{exit_code:}` so `CLI#cmd_dev` picks the process exit code.
    class Dev
      LOCK_NAME = DevRunner::LOCK_NAME
      WINDOW_NAME = "devenv"
      # `workspace dev status --json`'s schema version (see docs/README.dev.md).
      JSON_SCHEMA_VERSION = 1
      POLL_SECONDS = 0.2
      RELEASE_MARGIN = 2
      PASSTHROUGH_ENV = %w[XDG_STATE_HOME WORKSPACE_DEBUG].freeze
      # Set in a takeover wrapper's window: its `dev __run` queues ahead of everyone.
      TAKEOVER_ENV = "WORKSPACE_DEV_TAKEOVER"
      NO_COMMAND = %(No dev command configured. Set one with: workspace config set dev.up "<command>")

      # @param lock_namespace [Workspace::LockNamespace] resolves the repo's lock store directory
      # @param lock_holder [Workspace::LockHolder] checks holder liveness (pid + start time)
      # @param lineage [Workspace::WorkspaceLineage] resolves the parent project for dev config
      # @param dev_config [Workspace::DevConfig] reads `dev.up`, `dev.ready`, `dev.stop_timeout`,
      #   `dev.startup_timeout`, `dev.ready_timeout`
      # @param dev_runner [Workspace::DevRunner] the wrapper behind `dev __run`
      # @param terminator [Workspace::ProcessGroupTerminator] stops a holder's process group
      # @param tmux [Workspace::Tmux] opens the devenv window
      # @param executable [String] path to `bin/workspace`, run in the devenv window
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for refusals and failures
      # @param env [Hash] environment lookup (TMUX_PANE, passthrough variables)
      # @param sleeper [#call] sleeps between polls
      # @param clock [#now] monotonic seconds, for timeouts
      # @param poll [Numeric] seconds between polls
      # @param kill [#call] probes or signals a wrapper pid, called as `kill.call(signal, pid)` like `Process.kill`
      # @param pid_provider [#call] returns this invocation's own pid, recorded on a holder it is stopping
      # @param event_log [Workspace::EventLog, nil] records waits for the devenv lock and
      #   takeovers; nil records nothing
      def initialize(lock_namespace:, lock_holder:, lineage:, dev_config:, dev_runner:, terminator:, tmux:, executable:,
        output: $stdout, error_output: $stderr, env: ENV, sleeper: ->(seconds) { sleep(seconds) }, clock: Lock::MonotonicClock,
        poll: POLL_SECONDS,
        kill: ->(signal, pid) { Process.kill(signal, pid) }, pid_provider: -> { Process.pid }, event_log: nil)
        @lock_namespace = lock_namespace
        @event_log = event_log
        @lock_holder = lock_holder
        @lineage = lineage
        @dev_config = dev_config
        @dev_runner = dev_runner
        @terminator = terminator
        @tmux = tmux
        @executable = executable
        @output = output
        @error_output = error_output
        @env = env
        @sleeper = sleeper
        @clock = clock
        @poll = poll
        @kill = kill
        @pid_provider = pid_provider
        @holder_stopper = ProcessHolderStopper.for(terminator: terminator, lock_holder: lock_holder, error_output: error_output,
          clock: clock, sleeper: sleeper)
      end

      # @param wait [Boolean] queue FIFO behind another worktree's env instead of refusing
      # @param takeover [Boolean] stop another worktree's env first
      # @param ready [Boolean] run the `dev.ready` probe before returning
      # @param max_wait [Numeric, nil] give up (exit 75) after this many seconds; implies +wait+,
      #   and with +takeover+ bounds the whole takeover
      # @param working_dir [String] directory inside the worktree to start
      # @return [Hash] {exit_code:} — 0, 1 (refused/failed), 4 (cleared while
      #   queued), 6 (ready check failed), or 75 (still queued after max_wait)
      # @raise [Workspace::Error] if no dev command is configured or no tmux session is found
      def up(wait: false, takeover: false, ready: true, max_wait: nil, working_dir: Dir.pwd)
        raise Workspace::UsageError, "--max-wait must be greater than 0." if max_wait && max_wait.to_f <= 0
        wait ||= !max_wait.nil?
        ctx = context(working_dir)
        raise Workspace::Error, NO_COMMAND unless command?(ctx)

        entry = entry(ctx[:store])
        holder = entry["holder"]
        if holder && !holder["stale"] && holder["worktree"] == ctx[:worktree]
          @output.puts "Dev environment is already running for #{describe(holder)}."
          return {exit_code: 0}
        end

        return take_over(ctx, holder, ready: ready, max_wait: max_wait) if takeover && holder && !holder["stale"]

        refused = clear_the_way(ctx, entry, wait: wait, takeover: takeover)
        return refused if refused

        session = session_for(ctx)
        wrapper = open_wrapper(ctx, session, wait: wait)
        limit = wait ? max_wait : ctx[:settings][:startup_timeout]
        limit_name = wait ? "--max-wait" : "startup timeout"
        code = await_wrapper(ctx, wrapper, limit: limit, limit_name: limit_name)
        finish_up(ctx, session, wrapper, code, ready: ready)
      end

      # Stops this repository's dev environment, whichever worktree holds it.
      #
      # @param force [Boolean] also kill the process group left behind by a dead wrapper
      # @param working_dir [String] any directory inside the repository
      # @return [Hash] {exit_code:}
      def down(force: false, working_dir: Dir.pwd)
        ctx = context(working_dir)
        holder = entry(ctx[:store])["holder"]
        unless holder
          @output.puts "No dev environment is running."
          return {exit_code: 0}
        end

        if holder["stale"]
          result = stop_orphan(ctx, holder, force: force)
          close_window(holder) if result[:exit_code].zero?
          return result
        end

        result = stop(ctx, holder)
        return {exit_code: 1} if result == :kept || result == :in_progress
        close_window(holder)
        if result == :gone
          @output.puts "Dev environment for #{describe(holder)} was not running; removed its stale lock."
        else
          @output.puts "Stopped dev environment for #{describe(holder)}#{" (SIGKILL after #{format_seconds(ctx[:settings][:stop_timeout])})" if result == :killed}."
        end
        {exit_code: 0}
      end

      # @param working_dir [String] any directory inside the repository
      # @param json [Boolean] emit the documented `--json` schema (see docs/README.dev.md)
      #   on stdout instead of the human-readable listing; a store error becomes
      #   a `{"error":}` JSON object on stdout (exit 1) rather than a raised error
      # @return [Hash] {exit_code:}
      def status(working_dir: Dir.pwd, json: false)
        return status_json(working_dir) if json

        ctx = context(working_dir)
        entry = entry(ctx[:store])
        holder = entry["holder"]

        if holder.nil?
          @output.puts "No dev environment is running."
        elsif holder["stale"]
          @output.puts "Dev environment: STALE for #{describe(holder)} (wrapper pid #{holder["pid"]} is gone#{orphan_note(holder)})"
        else
          @output.puts "Dev environment: running for #{describe(holder)}"
          @output.puts "  pid #{holder["pid"]}, pgid #{holder["pgid"]}, pane #{holder["pane"] || "?"}, up #{uptime(holder)}"
          @output.puts "  ready: #{readiness(ctx)}"
        end

        (entry["queue"] || []).each_with_index do |waiter, i|
          stale = waiter["stale"] ? " STALE" : ""
          @output.puts "  #{i + 1}. queued: #{describe(waiter)} (pid #{waiter["waiter_pid"]})#{stale}"
        end
        {exit_code: 0}
      end

      # The hidden `dev __run` entry point: runs {DevRunner} in the current
      # pane with this worktree's configured command. A wrapper opened by
      # `up --force` (TAKEOVER_ENV set) queues ahead of everyone waiting.
      #
      # @param wait [Boolean] queue for the lock instead of failing when it is held
      # @param working_dir [String] directory inside the worktree
      # @return [Hash] {exit_code:} — the dev command's own exit status
      def run(wait: false, working_dir: Dir.pwd)
        ctx = context(working_dir)
        raise Workspace::Error, NO_COMMAND unless command?(ctx)
        code = @dev_runner.call(store: ctx[:store], command: ctx[:settings][:up], worktree: ctx[:worktree],
          branch: ctx[:branch], wait: wait, priority: @env[TAKEOVER_ENV] == "1")
        {exit_code: code}
      end

      private

      # Stops another worktree's env and hands its lock straight to this one,
      # ahead of anyone already queued: the new wrapper joins the queue at its
      # head in one flocked step, so the stopped holder's release promotes it.
      # A +max_wait+ deadline covers the whole takeover. Once it passes, the
      # queued wrapper is stopped (so it leaves the queue) and up exits 75,
      # as with `--wait --max-wait`; a holder not yet stopped is left running.
      def take_over(ctx, holder, ready:, max_wait:)
        deadline = max_wait && @clock.now + max_wait
        session = session_for(ctx)
        wrapper = open_wrapper(ctx, session, wait: true, takeover: true)
        code = await_queued(ctx, wrapper, max_wait: max_wait, deadline: deadline)
        return {exit_code: code} unless code.zero?
        if deadline && @clock.now >= deadline && entry(ctx[:store]).dig("holder", "pid") != wrapper
          return {exit_code: give_up(wrapper, true, max_wait, limit_name: "--max-wait")}
        end

        @output.puts "Taking over: stopping dev environment for #{describe(holder)}..."
        log_activity(ctx, "lock_takeover", wrapper, "from" => holder.slice("pid", "pgid", "worktree", "branch"))
        case stop(ctx, holder)
        when :kept
          @error_output.puts "This worktree's dev environment stays queued first for the #{LOCK_NAME} lock in its #{WINDOW_NAME} window. " \
            "Run `workspace dev status` to watch it. Have its owner run `kill -TERM -#{holder["pgid"]}`; " \
            "the lock frees on its own once the group is empty."
          return {exit_code: 1}
        when :in_progress
          @error_output.puts "This worktree's dev environment stays queued first for the #{LOCK_NAME} lock in its #{WINDOW_NAME} window " \
            "and takes it once that group is stopped. Run `workspace dev status` to watch it."
          return {exit_code: 1}
        end
        close_window(holder)
        code = if deadline
          await_wrapper(ctx, wrapper, limit: max_wait, limit_name: "--max-wait", deadline: deadline)
        else
          await_wrapper(ctx, wrapper, limit: ctx[:settings][:startup_timeout], limit_name: "startup timeout")
        end
        finish_up(ctx, session, wrapper, code, ready: ready)
      end

      def open_wrapper(ctx, session, wait:, takeover: false)
        env = passthrough_env
        env[TAKEOVER_ENV] = "1" if takeover
        wrapper = @tmux.new_window(session, name: WINDOW_NAME, cwd: ctx[:worktree], command: run_argv(wait), env: env,
          remain_on_exit: true)
        raise Workspace::Error, "Could not open a #{WINDOW_NAME} window in tmux session #{session}." unless wrapper
        wrapper
      end

      # The devenv window outlives its wrapper (remain-on-exit) so a crash
      # stays readable; a window whose env was stopped on purpose is closed.
      # tmux may take a moment to mark the pane dead after the wrapper exits.
      def close_window(holder)
        return unless holder["pane"]
        deadline = @clock.now + RELEASE_MARGIN
        until @tmux.close_dead_pane(holder["pane"], pid: holder["pid"]) != false || @clock.now >= deadline
          @sleeper.call(@poll)
        end
      end

      def finish_up(ctx, session, wrapper, code, ready:)
        code = await_ready(ctx, wrapper) if code.zero? && ready && ctx[:settings][:ready]
        return {exit_code: code} unless code.zero?

        @output.puts "Dev environment running for #{label(ctx[:worktree])} (#{ctx[:branch]}) in #{session}:#{WINDOW_NAME}."
        {exit_code: 0}
      end

      def context(working_dir)
        lineage = @lineage.resolve(cwd: working_dir)
        worktree = git(working_dir, "rev-parse", "--show-toplevel") || File.expand_path(working_dir)
        {
          worktree: worktree,
          branch: git(worktree, "rev-parse", "--abbrev-ref", "HEAD"),
          config_name: lineage.worktree || lineage.name,
          project: lineage.name,
          workspace: lineage.worktree,
          settings: @dev_config.for_project(lineage.name),
          store: LockStore.new(dir: @lock_namespace.resolve(cwd: working_dir)[:dir], liveness: @lock_holder, terminator: @terminator)
        }
      end

      # A blank `dev.up` is as good as unset: there is nothing to run.
      def command?(ctx)
        !ctx[:settings][:up].to_s.strip.empty?
      end

      def git(dir, *args)
        stdout, _, status = Open3.capture3("git", "-C", dir, *args)
        status.success? ? stdout.strip : nil
      rescue Errno::ENOENT
        nil
      end

      def entry(store)
        store.status(LOCK_NAME)[LOCK_NAME] || {}
      end

      # @return [Hash] {exit_code:} — 0 on success, 1 if the store itself
      #   could not be read (e.g. a corrupt `locks.json`)
      def status_json(working_dir)
        ctx = context(working_dir)
        entry = entry(ctx[:store])
        holder = entry["holder"]
        payload = {
          "schema_version" => JSON_SCHEMA_VERSION,
          "running" => !holder.nil? && !holder["stale"],
          "holder" => holder,
          "ready" => (holder && !holder["stale"] && ctx[:settings][:ready]) ? ready?(ctx[:settings][:ready], ctx[:worktree]) : nil,
          "queue" => entry["queue"] || []
        }
        @output.puts JSON.generate(payload)
        {exit_code: 0}
      rescue Workspace::Error => e
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      # @return [Hash, nil] an exit result if up must not proceed
      def clear_the_way(ctx, entry, wait:, takeover:)
        holder = entry["holder"]
        if holder && holder["stale"]
          return orphan_refusal(holder) if orphan_running?(holder) && !takeover
          stop_orphan(ctx, holder, force: true) if takeover
          return nil
        end

        return nil if wait
        if holder
          @error_output.puts "Dev environment is running for #{describe(holder)}. Use --wait to queue or --force (formerly --takeover) to switch."
          return {exit_code: 1}
        end
        unless (entry["queue"] || []).empty?
          @error_output.puts "Others are queued for the #{LOCK_NAME} lock. Use --wait to queue."
          return {exit_code: 1}
        end
        nil
      end

      def orphan_refusal(holder)
        @error_output.puts "A previous dev environment's process group #{holder["pgid"]} is still running " \
          "(its wrapper pid #{holder["pid"]} is gone). Stop it with: workspace dev down --force"
        {exit_code: 1}
      end

      def orphan_running?(holder)
        @terminator.orphan_running?(holder, pid_alive: method(:process_alive?))
      end

      def pgid_reused?(holder)
        @terminator.pgid_reused?(holder, pid_alive: method(:process_alive?))
      end

      def stop_orphan(ctx, holder, force:)
        running = orphan_running?(holder)
        return orphan_refusal(holder) if running && !force

        # The group can exit and its id be reused at any point up to SIGKILL,
        # stop_timeout later: the reuse check is repeated just before every signal.
        if running && @terminator.terminate(holder["pgid"], stop_timeout: ctx[:settings][:stop_timeout],
          guard: -> { !pgid_reused?(holder) }) != :not_running
          @output.puts "Killed orphaned dev process group #{holder["pgid"]} (wrapper pid #{holder["pid"]} was gone)."
        elsif holder["pgid"] && pgid_reused?(holder)
          @output.puts "Dev environment for #{describe(holder)} was not running (its pid #{holder["pid"]} now belongs " \
            "to an unrelated process, left alone); removed its stale lock."
        else
          @output.puts "Dev environment for #{describe(holder)} was not running; removed its stale lock."
        end
        # A dead holder is reaped by any mutating op; releasing its pid does exactly that.
        ctx[:store].release(LOCK_NAME, holder["pid"])
        {exit_code: 0}
      end

      # SIGTERM to the wrapper, which forwards it once to its group; SIGKILL to
      # the group after stop_timeout. Then waits briefly for the lock to free.
      # A group that can't be stopped keeps its lock, exactly as `lock clear`
      # would (see {ProcessHolderStopper}). The holder is marked `clearing`
      # by this process while it is stopped, the same marker `lock clear`
      # uses, so a concurrent clear, `dev down` or takeover never signals it
      # a second time; one already marked by another live process is left to it.
      #
      # @return [Symbol] :terminated, :killed, :gone, :kept, or :in_progress
      #   (another process is stopping it) — the last two reported on stderr
      def stop(ctx, holder)
        store = ctx[:store]
        clearer = @holder_stopper.clearer(@pid_provider.call)
        if (other = store.mark_clearing(LOCK_NAME, holder, clearer))
          @error_output.puts "#{LOCK_NAME} lock is already being cleared by pid #{other["pid"]}, which is stopping process group " \
            "#{holder["pgid"] || holder["pid"]} (pid #{holder["pid"]}); nothing to do here. " \
            "Check the result with: workspace dev status"
          return :in_progress
        end
        begin
          result = @holder_stopper.stop(store, LOCK_NAME, holder, stop_timeout: ctx[:settings][:stop_timeout],
            retry_command: "workspace dev down", kill_grace: kill_grace_for(ctx), clearer: clearer)
          return result if result == :kept
          deadline = @clock.now + RELEASE_MARGIN
          while @lock_holder.alive?(pid: holder["pid"], started: holder["started"]) && @clock.now < deadline
            @sleeper.call(@poll)
          end
          store.release(LOCK_NAME, holder["pid"]) unless @lock_holder.alive?(pid: holder["pid"], started: holder["started"])
          result
        ensure
          store.unmark_clearing(LOCK_NAME, holder, clearer)
        end
      end

      def kill_grace_for(ctx)
        ctx[:settings][:kill_grace]
      end

      def session_for(ctx)
        pane = @env["TMUX_PANE"]
        session = @tmux.session_name_for_pane(pane) if pane && !pane.empty?
        return session if session
        fallback = @tmux.session_name_for(ctx[:config_name])
        return fallback if @tmux.sessions.include?(fallback)
        unless @tmux.server_running?
          raise Workspace::Error, "tmux server not running; start the workspace with `workspace launch`, " \
            "then run `workspace dev up` again."
        end
        raise Workspace::Error, "No tmux session found for #{ctx[:config_name]}; run `workspace dev up` inside the workspace's tmux session."
      end

      def run_argv(wait)
        [RbConfig.ruby, @executable, "dev", "__run", *(wait ? ["--wait"] : [])]
      end

      def passthrough_env
        PASSTHROUGH_ENV.filter_map { |key| [key, @env[key]] if @env[key] }.to_h
      end

      # Polls until the wrapper in the new window holds the lock. The wrapper
      # does its own queueing; this only watches the store.
      #
      # @param limit [Numeric, nil] seconds to wait, reported on giving up; nil waits indefinitely
      # @param limit_name [String] the name of the limit being applied ("--max-wait" or
      #   "startup timeout"), reported on giving up
      # @param deadline [Numeric, nil] clock time to give up at
      def await_wrapper(ctx, pid, limit:, limit_name:, deadline: limit && @clock.now + limit)
        store = ctx[:store]
        seen_queued = false
        started = @clock.now
        waited = -> { {"waited_seconds" => (@clock.now - started).round(1)} }

        loop do
          entry = entry(store)
          holder = entry["holder"]
          if holder && holder["pid"] == pid && !holder["stale"]
            log_activity(ctx, "lock_acquired", pid, waited.call) if seen_queued
            return 0
          end

          queued = (entry["queue"] || []).any? { |w| w["waiter_pid"] == pid }
          if queued && !seen_queued
            @output.puts "Trying to obtain workspace #{LOCK_NAME} lock (held by #{holder ? describe(holder) : "no one"})..."
            log_activity(ctx, "lock_wait_started", pid, "holder" => holder&.slice("pid", "worktree", "branch"))
            seen_queued = true
          end
          if seen_queued && !queued
            @error_output.puts "#{LOCK_NAME} lock was cleared while waiting."
            log_activity(ctx, "lock_wait_cleared", pid, waited.call)
            return 4
          end
          unless process_alive?(pid)
            @error_output.puts "The dev wrapper (pid #{pid}) exited before it acquired the #{LOCK_NAME} lock."
            return 1
          end
          if deadline && @clock.now >= deadline
            log_activity(ctx, "lock_wait_gave_up", pid, waited.call) if queued
            return give_up(pid, queued, limit, limit_name: limit_name)
          end

          @sleeper.call(@poll)
        end
      end

      # Records a devenv lock event for the wrapper +pid+ under the project's
      # name. Also carries the originating worktree's own workspace name in
      # "workspace" (data), when running from a worktree, so `event-log show
      # --project <worktree name>` still finds its devenv lock events.
      # EventLog#record never raises.
      def log_activity(ctx, type, pid, data)
        entry_data = {"lock" => LOCK_NAME, "pid" => pid}.merge(data)
        entry_data["workspace"] = ctx[:workspace] if ctx[:workspace]
        @event_log&.record(type: type, project: ctx[:project], data: entry_data)
      end

      # Polls until the takeover wrapper is in the queue (or already holds
      # the lock, if the holder went away meanwhile), giving up at the
      # startup timeout or the takeover's --max-wait deadline, whichever is first.
      def await_queued(ctx, pid, max_wait:, deadline:)
        store = ctx[:store]
        limit = ctx[:settings][:startup_timeout]
        limit_name = "startup timeout"
        startup_deadline = @clock.now + limit
        if deadline.nil? || startup_deadline <= deadline
          deadline = startup_deadline
        else
          limit = max_wait
          limit_name = "--max-wait"
        end
        loop do
          entry = entry(store)
          return 0 if entry.dig("holder", "pid") == pid
          return 0 if (entry["queue"] || []).any? { |w| w["waiter_pid"] == pid }
          unless process_alive?(pid)
            @error_output.puts "The dev wrapper (pid #{pid}) exited before it queued for the #{LOCK_NAME} lock."
            return 1
          end
          return give_up(pid, false, limit, limit_name: limit_name) if @clock.now >= deadline
          @sleeper.call(@poll)
        end
      end

      def give_up(pid, queued, limit, limit_name:)
        signal_wrapper(pid)
        if queued
          @error_output.puts "Still queued for #{LOCK_NAME} lock after #{limit_name}; re-run to keep waiting."
          return 75
        end
        @error_output.puts "The dev wrapper (pid #{pid}) did not acquire the #{LOCK_NAME} lock within #{format_seconds(limit)}; stopped it."
        1
      end

      def signal_wrapper(pid)
        @kill.call("TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_alive?(pid)
        @kill.call(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def await_ready(ctx, pid)
        spec = ctx[:settings][:ready]
        ready_timeout = ctx[:settings][:ready_timeout]
        deadline = @clock.now + ready_timeout
        loop do
          return 0 if ready?(spec, ctx[:worktree])
          holder = entry(ctx[:store])["holder"]
          unless holder && holder["pid"] == pid && !holder["stale"]
            @error_output.puts "The dev command exited before its ready check (#{spec}) passed; see the #{WINDOW_NAME} window."
            return 6
          end
          if @clock.now >= deadline
            outcome = (stop(ctx, holder) == :kept) ? "its process group could not be stopped (see above)" :
              "stopped the dev environment and released the #{LOCK_NAME} lock"
            @error_output.puts "Ready check (#{spec}) did not pass within #{format_seconds(ready_timeout)}; #{outcome}."
            return 6
          end
          @sleeper.call(@poll)
        end
      end

      # `port:N` passes once localhost:N accepts a TCP connection; anything
      # else is a shell command run in the worktree that passes on exit 0.
      def ready?(spec, worktree)
        if (port = spec.to_s[/\Aport:(\d+)\z/, 1])
          TCPSocket.new("localhost", port.to_i, connect_timeout: 1).close
          true
        else
          system(spec.to_s, chdir: worktree, in: File::NULL, out: File::NULL, err: File::NULL) == true
        end
      rescue SystemCallError, SocketError, IO::TimeoutError
        false
      end

      def readiness(ctx)
        spec = ctx[:settings][:ready]
        return "not configured" unless spec
        "#{ready?(spec, ctx[:worktree]) ? "yes" : "no"} (#{spec})"
      end

      def orphan_note(holder)
        orphan_running?(holder) ? "; its process group #{holder["pgid"]} is still running — stop it with `workspace dev down --force`" : ""
      rescue Workspace::Error => e
        "; #{e.message}"
      end

      def describe(record)
        branch = record["branch"]
        "#{label(record["worktree"])}#{" (#{branch})" if branch}"
      end

      def label(worktree)
        worktree ? File.basename(worktree) : "?"
      end

      def uptime(holder)
        seconds = (Time.now - Time.iso8601(holder["acquired_at"])).to_i
        format_seconds([seconds, 0].max)
      rescue ArgumentError, TypeError
        "?"
      end

      def format_seconds(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600
        "#{seconds / 3600}h #{seconds % 3600 / 60}m"
      end
    end
  end
end
