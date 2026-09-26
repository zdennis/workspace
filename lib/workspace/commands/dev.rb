require "open3"
require "rbconfig"
require "socket"
require "time"

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
      POLL_SECONDS = 0.2
      STARTUP_TIMEOUT = 30
      READY_TIMEOUT = 120
      RELEASE_MARGIN = 2
      PASSTHROUGH_ENV = %w[XDG_STATE_HOME WORKSPACE_DEBUG].freeze
      NO_COMMAND = %(No dev command configured. Set one with: workspace config set dev.up "<command>")

      # @param lock_namespace [Workspace::LockNamespace] resolves the repo's lock store directory
      # @param lock_holder [Workspace::LockHolder] checks holder liveness (pid + start time)
      # @param lineage [Workspace::WorkspaceLineage] resolves the parent project for dev config
      # @param dev_config [Workspace::DevConfig] reads `dev.up`, `dev.ready`, `dev.stop_timeout`
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
      # @param startup_timeout [Numeric] seconds to wait for the wrapper to take a free lock
      # @param ready_timeout [Numeric] seconds to wait for the ready probe to pass
      def initialize(lock_namespace:, lock_holder:, lineage:, dev_config:, dev_runner:, terminator:, tmux:, executable:,
        output: $stdout, error_output: $stderr, env: ENV, sleeper: ->(seconds) { sleep(seconds) }, clock: Lock::MonotonicClock,
        poll: POLL_SECONDS, startup_timeout: STARTUP_TIMEOUT, ready_timeout: READY_TIMEOUT)
        @lock_namespace = lock_namespace
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
        @startup_timeout = startup_timeout
        @ready_timeout = ready_timeout
      end

      # @param wait [Boolean] queue FIFO behind another worktree's env instead of refusing
      # @param takeover [Boolean] stop another worktree's env first
      # @param ready [Boolean] run the `dev.ready` probe before returning
      # @param max_wait [Numeric, nil] with +wait+, give up (exit 75) after this many seconds
      # @param working_dir [String] directory inside the worktree to start
      # @return [Hash] {exit_code:} — 0, 1 (refused/failed), 4 (cleared while
      #   queued), 6 (ready check failed), or 75 (still queued after max_wait)
      # @raise [Workspace::Error] if no dev command is configured or no tmux session is found
      def up(wait: false, takeover: false, ready: true, max_wait: nil, working_dir: Dir.pwd)
        raise Workspace::UsageError, "--max-wait must be greater than 0." if max_wait && max_wait.to_f <= 0
        ctx = context(working_dir)
        raise Workspace::Error, NO_COMMAND unless ctx[:settings][:up]

        entry = entry(ctx[:store])
        holder = entry["holder"]
        if holder && !holder["stale"] && holder["worktree"] == ctx[:worktree]
          @output.puts "Dev environment is already running for #{describe(holder)}."
          return {exit_code: 0}
        end

        refused = clear_the_way(ctx, entry, wait: wait, takeover: takeover)
        return refused if refused

        session = session_for(ctx)
        wrapper = @tmux.new_window(session, name: WINDOW_NAME, cwd: ctx[:worktree], command: run_argv(wait), env: passthrough_env)
        raise Workspace::Error, "Could not open a #{WINDOW_NAME} window in tmux session #{session}." unless wrapper

        code = await_wrapper(ctx[:store], wrapper, wait: wait, max_wait: max_wait)
        code = await_ready(ctx, wrapper) if code.zero? && ready && ctx[:settings][:ready]
        return {exit_code: code} unless code.zero?

        @output.puts "Dev environment running for #{label(ctx[:worktree])} (#{ctx[:branch]}) in #{session}:#{WINDOW_NAME}."
        {exit_code: 0}
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

        unless holder["stale"]
          result = stop(ctx, holder)
          @output.puts "Stopped dev environment for #{describe(holder)}#{" (SIGKILL after #{format_seconds(ctx[:settings][:stop_timeout])})" if result == :killed}."
          return {exit_code: 0}
        end

        stop_orphan(ctx, holder, force: force)
      end

      # @param working_dir [String] any directory inside the repository
      # @return [Hash] {exit_code:}
      def status(working_dir: Dir.pwd)
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
      # pane with this worktree's configured command.
      #
      # @param wait [Boolean] queue for the lock instead of failing when it is held
      # @param working_dir [String] directory inside the worktree
      # @return [Hash] {exit_code:} — the dev command's own exit status
      def run(wait: false, working_dir: Dir.pwd)
        ctx = context(working_dir)
        raise Workspace::Error, NO_COMMAND unless ctx[:settings][:up]
        code = @dev_runner.call(store: ctx[:store], command: ctx[:settings][:up], worktree: ctx[:worktree],
          branch: ctx[:branch], wait: wait)
        {exit_code: code}
      end

      private

      def context(working_dir)
        lineage = @lineage.resolve(cwd: working_dir)
        worktree = git(working_dir, "rev-parse", "--show-toplevel") || File.expand_path(working_dir)
        {
          worktree: worktree,
          branch: git(worktree, "rev-parse", "--abbrev-ref", "HEAD"),
          config_name: lineage.worktree || lineage.name,
          settings: @dev_config.for_project(lineage.name),
          store: LockStore.new(dir: @lock_namespace.resolve(cwd: working_dir)[:dir], liveness: @lock_holder)
        }
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

      # @return [Hash, nil] an exit result if up must not proceed
      def clear_the_way(ctx, entry, wait:, takeover:)
        holder = entry["holder"]
        if holder && holder["stale"]
          return orphan_refusal(holder) if orphan_running?(holder) && !takeover
          stop_orphan(ctx, holder, force: true) if takeover
          return nil
        end

        if holder && takeover
          @output.puts "Taking over: stopping dev environment for #{describe(holder)}..."
          stop(ctx, holder)
          return nil
        end

        return nil if wait
        if holder
          @error_output.puts "Dev environment is running for #{describe(holder)}. Use --wait to queue or --takeover to switch."
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
        !!holder["pgid"] && @terminator.running?(holder["pgid"])
      end

      def stop_orphan(ctx, holder, force:)
        if orphan_running?(holder)
          return orphan_refusal(holder) unless force
          @terminator.terminate(holder["pgid"], stop_timeout: ctx[:settings][:stop_timeout])
          @output.puts "Killed orphaned dev process group #{holder["pgid"]} (wrapper pid #{holder["pid"]} was gone)."
        else
          @output.puts "Dev environment for #{describe(holder)} was not running; removed its stale lock."
        end
        # A dead holder is reaped by any mutating op; releasing its pid does exactly that.
        ctx[:store].release(LOCK_NAME, holder["pid"])
        {exit_code: 0}
      end

      # SIGTERM to the wrapper, which forwards it once to its group; SIGKILL to
      # the group after stop_timeout. Then waits briefly for the lock to free.
      def stop(ctx, holder)
        result = @terminator.stop_holder(holder, liveness: @lock_holder, stop_timeout: ctx[:settings][:stop_timeout])
        deadline = @clock.now + RELEASE_MARGIN
        while @lock_holder.alive?(pid: holder["pid"], started: holder["started"]) && @clock.now < deadline
          @sleeper.call(@poll)
        end
        ctx[:store].release(LOCK_NAME, holder["pid"]) unless @lock_holder.alive?(pid: holder["pid"], started: holder["started"])
        result
      end

      def session_for(ctx)
        pane = @env["TMUX_PANE"]
        session = @tmux.session_name_for_pane(pane) if pane && !pane.empty?
        return session if session
        fallback = @tmux.session_name_for(ctx[:config_name])
        return fallback if @tmux.sessions.include?(fallback)
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
      def await_wrapper(store, pid, wait:, max_wait:)
        limit = wait ? max_wait : @startup_timeout
        deadline = limit && @clock.now + limit
        seen_queued = false

        loop do
          entry = entry(store)
          holder = entry["holder"]
          return 0 if holder && holder["pid"] == pid && !holder["stale"]

          queued = (entry["queue"] || []).any? { |w| w["waiter_pid"] == pid }
          if queued && !seen_queued
            @output.puts "Trying to obtain workspace #{LOCK_NAME} lock (held by #{holder ? describe(holder) : "no one"})..."
            seen_queued = true
          end
          if seen_queued && !queued
            @error_output.puts "#{LOCK_NAME} lock was cleared while waiting."
            return 4
          end
          unless process_alive?(pid)
            @error_output.puts "The dev wrapper (pid #{pid}) exited before it acquired the #{LOCK_NAME} lock."
            return 1
          end
          return give_up(pid, queued, limit) if deadline && @clock.now >= deadline

          @sleeper.call(@poll)
        end
      end

      def give_up(pid, queued, limit)
        signal_wrapper(pid)
        if queued
          @error_output.puts "Still queued for #{LOCK_NAME} lock after --max-wait; re-run to keep waiting."
          return 75
        end
        @error_output.puts "The dev wrapper (pid #{pid}) did not acquire the #{LOCK_NAME} lock within #{format_seconds(limit)}; stopped it."
        1
      end

      def signal_wrapper(pid)
        Process.kill("TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def await_ready(ctx, pid)
        spec = ctx[:settings][:ready]
        deadline = @clock.now + @ready_timeout
        loop do
          return 0 if ready?(spec, ctx[:worktree])
          holder = entry(ctx[:store])["holder"]
          unless holder && holder["pid"] == pid && !holder["stale"]
            @error_output.puts "The dev command exited before its ready check (#{spec}) passed; see the #{WINDOW_NAME} window."
            return 6
          end
          if @clock.now >= deadline
            stop(ctx, holder)
            @error_output.puts "Ready check (#{spec}) did not pass within #{format_seconds(@ready_timeout)}; " \
              "stopped the dev environment and released the #{LOCK_NAME} lock."
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
