require "time"
require "json"

module Workspace
  module Commands
    # Coordinates agents sharing a resource (first: edits to a shared
    # worktree) through one flock-guarded lock store per repository.
    #
    # `acquire`, `release`, `status`, and `clear` are the whole public API,
    # each returning `{exit_code:}` (and any command-specific fields) so
    # `CLI#cmd_lock` can pick the process exit code without this class ever
    # calling `exit` itself.
    class Lock
      DEFAULT_POLL_SECONDS = 5
      SIGNAL_CHECK_SECONDS = 0.25
      # Exit code from `release` when this agent's hold was taken over by the
      # head waiter while the agent sat idle, leaving nothing to release.
      # `acquire` reports such a takeover too, then carries on as usual.
      EXIT_DISPLACED = 3
      # Lock names end up in file keys and in commands an agent is told to run
      # verbatim, so they are limited to characters that need no shell quoting.
      NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
      # `workspace lock status --json`'s schema version (see docs/README.lock.md).
      JSON_SCHEMA_VERSION = 1

      # Seconds on a clock that never jumps backward or forward with wall-clock
      # changes, so a --max-wait deadline cannot be stretched or cut short.
      module MonotonicClock
        # @return [Float]
        def self.now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # @param config [Workspace::Config] path configuration
      # @param lock_namespace [Workspace::LockNamespace] resolves the shared lock store directory
      # @param lock_holder [Workspace::LockHolder] identifies the calling agent and checks liveness
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for refusals and warnings
      # @param sleeper [#call] sleeps between polls, injectable for tests
      # @param clock [#now] provides the current time for --max-wait (monotonic by default), injectable for tests
      # @param pid_provider [#call] returns this invocation's own pid, injectable for tests
      #   (multiple simulated agents in one test process would otherwise all report the
      #   same real `Process.pid` as their waiter identity)
      # @param trap [#call] installs a signal handler, injectable so tests don't touch
      #   real process-wide signal state; called as `trap.call(signal, handler)`, exactly
      #   like `Signal.trap`, and must return the previous handler the same way
      # @param terminator [Workspace::ProcessGroupTerminator] stops a cleared `kind: "process"` holder
      # @param dev_config [Workspace::DevConfig, nil] supplies that holder's dev.stop_timeout
      # @param lock_config [Workspace::LockConfig, nil] supplies the project's locks.idle_grace
      # @param wall_clock [#call] current epoch seconds, for idle tracking in the store
      def initialize(config:, lock_namespace:, lock_holder:, output: $stdout, error_output: $stderr,
        sleeper: ->(seconds) { sleep(seconds) }, clock: MonotonicClock, pid_provider: -> { Process.pid },
        trap: ->(signal, handler) { Signal.trap(signal, handler) }, terminator: ProcessGroupTerminator.new, dev_config: nil,
        lock_config: nil, wall_clock: -> { Time.now.to_i })
        @config = config
        @lock_namespace = lock_namespace
        @lock_holder = lock_holder
        @output = output
        @error_output = error_output
        @sleeper = sleeper
        @clock = clock
        @pid_provider = pid_provider
        @trap = trap
        @terminator = terminator
        @dev_config = dev_config
        @lock_config = lock_config
        @wall_clock = wall_clock
      end

      # @param name [String] lock name
      # @param task [String, nil] free-text description shown to other waiters
      # @param wait [Boolean] enqueue and poll instead of refusing when busy
      # @param poll [Numeric] seconds between polls while waiting
      # @param max_wait [Numeric, nil] give up (exit 75) after this many seconds
      # @param working_dir [String] directory to resolve the lock namespace from
      # @return [Hash] {exit_code:}
      def acquire(name, task: nil, wait: false, poll: DEFAULT_POLL_SECONDS, max_wait: nil, working_dir: Dir.pwd)
        validate_name!(name)
        raise Workspace::UsageError, "--poll must be greater than 0." if poll.to_f <= 0
        raise Workspace::UsageError, "--max-wait must be greater than 0." if max_wait && max_wait.to_f <= 0
        store = store_for(working_dir)
        identity = require_identity!
        waiter_pid = @pid_provider.call
        waiter_started = @lock_holder.start_time(waiter_pid)
        raise Workspace::Error, "Could not read the start time of this process (pid #{waiter_pid}) to track its place in the queue." unless waiter_started

        report_displaced(store.pop_displaced(identity, name: name), "Trying to acquire it again.")

        result = store.acquire(name, identity: identity, waiter_pid: waiter_pid,
          waiter_started: waiter_started, task: task, wait: wait)

        case result[:status]
        when :acquired, :already_held
          acquired(name)
        when :deadlock
          @error_output.puts "Refusing to acquire #{name}: already holding or waiting for '#{result[:other]}'. " \
            "An agent may hold or wait for only one lock at a time."
          {exit_code: 5}
        when :held
          @error_output.puts "#{name} lock is held by #{describe_holder(result[:holder])}."
          {exit_code: 1}
        when :queued
          print_queue_message(name, result)
          poll_until_acquired(store, name, waiter_pid, poll: poll, max_wait: max_wait)
        end
      end

      # @param name [String, nil] lock name, or nil with all: true
      # @param all [Boolean] release every lock this agent holds
      # @param working_dir [String] directory to resolve the lock namespace from
      # @return [Hash] {exit_code:}
      def release(name, all: false, working_dir: Dir.pwd)
        validate_name!(name) unless name.nil?
        store = store_for(working_dir)
        identity = require_identity!
        displaced = store.pop_displaced(identity, name: all ? nil : name)
        report_displaced(displaced, "There is nothing to release.")

        if all && name.nil?
          released = store.release_all(identity)
          if released.empty?
            @output.puts "No locks held."
          else
            released.each { |n| @output.puts "Released #{n} lock." }
          end
        elsif store.release(name, identity[:pid])
          @output.puts "Released #{name} lock."
        elsif displaced.empty?
          @output.puts "#{name} lock is not held by this agent."
        end

        {exit_code: displaced.empty? ? 0 : EXIT_DISPLACED}
      end

      # Prints the agent prompt block that tells a coding agent how to use a
      # lock, versioned with the CLI so it always matches its commands.
      #
      # @param name [String] lock name substituted into the commands
      # @return [Hash] {exit_code:}
      def instructions(name = "edit")
        validate_name!(name)
        @output.puts "Before editing files, run `workspace lock acquire #{name} --wait --task \"<your task>\"` " \
          "using Bash with run_in_background. Do not edit anything until it reports \"Acquired\". " \
          "When your edits are complete, run `workspace lock release #{name}`. Never run `workspace lock clear`."
        {exit_code: 0}
      end

      # @param name [String, nil] a single lock name, or nil for every lock
      # @param working_dir [String] directory to resolve the lock namespace from
      # @param json [Boolean] emit the documented `--json` schema (see docs/README.lock.md)
      #   on stdout instead of the human-readable listing; a store error becomes
      #   a `{"error":}` JSON object on stdout (exit 1) rather than a raised error
      # @return [Hash] {exit_code:}
      def status(name = nil, working_dir: Dir.pwd, json: false)
        validate_name!(name) unless name.nil?
        return status_json(name, working_dir) if json

        store = store_for(working_dir)
        entries = store.status(name)

        if entries.empty?
          @output.puts name ? "#{name} lock is free." : "No locks held."
          return {exit_code: 0}
        end

        entries.each do |lock_name, entry|
          print_status_entry(lock_name, entry)
        end
        {exit_code: 0}
      end

      # Removes a lock's holder and queue unconditionally. A `kind: "process"`
      # holder (the dev-environment wrapper) is then stopped: SIGTERM to its
      # pid, SIGKILL to its recorded pgid after dev.stop_timeout, but only if
      # its pid is still running with its recorded start time, so a reused
      # pgid is never signalled. The holder is also yielded while the store is
      # still locked.
      #
      # @param name [String, nil] lock name, or nil with all: true
      # @param all [Boolean] clear every lock in this namespace
      # @param working_dir [String] directory to resolve the lock namespace from
      # @yieldparam holder [Hash, nil] the holder record being cleared
      # @return [Hash] {exit_code:}
      def clear(name, all: false, working_dir: Dir.pwd, &on_holder)
        validate_name!(name) unless name.nil?
        namespace = @lock_namespace.resolve(cwd: working_dir)
        store = LockStore.new(dir: namespace[:dir], liveness: @lock_holder)
        names = (all && name.nil?) ? store.names : [name]

        if names.empty?
          @output.puts "No locks to clear."
          return {exit_code: 0}
        end

        label = cleared_by_label
        names.each do |lock_name|
          removed = store.clear(lock_name, cleared_by: label, &on_holder)
          describe_cleared(lock_name, removed)
          holder = removed&.dig(:holder)
          stop_process_holder(holder, namespace[:display]) if holder && holder["kind"] == "process"
        end
        {exit_code: 0}
      end

      private

      # @return [Hash] {exit_code:} — 0 on success, 1 if the store itself
      #   could not be read (e.g. a corrupt `locks.json`)
      def status_json(name, working_dir)
        store = store_for(working_dir)
        entries = store.status(name)
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "locks" => entries})
        {exit_code: 0}
      rescue Workspace::Error => e
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      def validate_name!(name)
        raise Workspace::UsageError, "lock name must not be empty." if name.nil? || name.empty?
        return if NAME_PATTERN.match?(name)
        raise Workspace::UsageError, "invalid lock name #{name.inspect}: use letters, digits, '.', '_' and '-', starting with a letter or digit."
      end

      def store_for(working_dir)
        namespace = @lock_namespace.resolve(cwd: working_dir)
        idle_grace = @lock_config ? @lock_config.idle_grace_for(namespace[:display]) : LockStore::DEFAULT_IDLE_GRACE
        LockStore.new(dir: namespace[:dir], liveness: @lock_holder, clock: @wall_clock, idle_grace: idle_grace)
      end

      def report_displaced(records, advice)
        records.each do |record|
          by = record["by"] || {}
          idle_for = record["at"].to_i - record["idle_since"].to_i
          @error_output.puts "Your #{record["name"]} lock was taken over by #{describe_holder(by)} at #{format_epoch(record["at"])}, " \
            "after this agent had been idle for #{idle_for}s. #{advice}"
        end
      end

      def format_epoch(seconds)
        Time.at(seconds.to_i).utc.iso8601
      end

      def require_identity!
        identity = @lock_holder.current
        raise Workspace::Error, "Could not identify the calling agent (no coding-agent process found in this pane or its ancestors)." unless identity
        identity
      end

      def cleared_by_label
        identity = @lock_holder.current
        identity ? "pid #{identity[:pid]}" : "unknown"
      end

      # Signal handlers only record the signal: the store is flock-guarded, and a
      # handler that touched it while the loop held the flock would block forever.
      def poll_until_acquired(store, name, waiter_pid, poll:, max_wait:)
        deadline = max_wait ? @clock.now + max_wait : nil
        interrupted = nil
        old_int = @trap.call("INT", proc { interrupted ||= 130 })
        old_term = @trap.call("TERM", proc { interrupted ||= 143 })

        loop do
          result = store.poll(name, waiter_pid)
          return claimed(name, result) if result[:status] == :acquired
          return abandon_wait(store, name, waiter_pid, interrupted) if interrupted
          if result[:status] == :cleared
            @error_output.puts "#{name} lock was cleared while waiting."
            return {exit_code: 4}
          end

          return give_up_waiting(store, name, waiter_pid) if deadline && @clock.now >= deadline

          sleep_unless_interrupted(poll) { interrupted }
          return abandon_wait(store, name, waiter_pid, interrupted) if interrupted
        end
      ensure
        @trap.call("INT", old_int) if old_int
        @trap.call("TERM", old_term) if old_term
      end

      # A claimed lock is kept even when a signal arrived during the same
      # poll: the agent is told it holds the lock, and a takeover is never
      # undone after displacing the idle holder.
      def claimed(name, result)
        holder = result[:took_over]
        if holder
          @error_output.puts "Took over #{name} lock from #{describe_holder(holder)}, idle since #{format_epoch(holder["idle_since"])}."
        end
        acquired(name)
      end

      def acquired(name)
        @output.puts "Acquired #{name} lock. Release with: workspace lock release #{name}"
        {exit_code: 0}
      end

      # A promotion or an idle takeover can come due between the last poll and
      # the deadline check, so the claim-or-dequeue decision is made in one
      # step under the flock.
      def give_up_waiting(store, name, waiter_pid)
        result = store.claim_or_dequeue(name, waiter_pid)
        return claimed(name, result) if result[:status] == :acquired
        @error_output.puts "Still queued for #{name} lock after --max-wait; re-run to keep waiting."
        {exit_code: 75}
      end

      def abandon_wait(store, name, waiter_pid, exit_status)
        store.dequeue(name, waiter_pid)
        {exit_code: exit_status}
      end

      # Sleeps in short slices so a signal is acted on promptly: a trap handler
      # does not cut a Ruby `sleep` short.
      def sleep_unless_interrupted(seconds)
        slices = [(seconds / SIGNAL_CHECK_SECONDS).ceil, 1].max
        slices.times do
          break if yield
          @sleeper.call(seconds.to_f / slices)
        end
      end

      def print_queue_message(name, result)
        holder = result[:holder]
        @output.puts "Trying to obtain workspace #{name} lock (position #{result[:position]} of " \
          "#{result[:total]}, held by #{describe_holder(holder)})..."
      end

      def describe_holder(holder)
        return "no one (about to be reaped)" unless holder
        pane = holder["pane"] || "?"
        task = holder["task"]
        worktree = holder["worktree"] || "?"
        task ? "#{pane} \"#{task}\" in #{worktree}" : "#{pane} in #{worktree}"
      end

      def print_status_entry(name, entry)
        holder = entry["holder"]
        queue = entry["queue"] || []

        if holder
          stale = holder["stale"] ? " STALE" : ""
          idle = holder["idle_since"] ? " IDLE since #{format_epoch(holder["idle_since"])}" : ""
          @output.puts "#{name}: held by #{describe_holder(holder)} (pid #{holder["pid"]}, since #{holder["acquired_at"]})#{idle}#{stale}"
        else
          @output.puts "#{name}: free"
        end

        queue.each_with_index do |waiter, i|
          stale = waiter["stale"] ? " STALE" : ""
          @output.puts "  #{i + 1}. #{waiter["pane"]} \"#{waiter["task"]}\" in #{waiter["worktree"]} (pid #{waiter["agent_pid"]})#{stale}"
        end
      end

      # Runs after the store is unlocked: the wrapper needs the flock to
      # release, and would otherwise sit blocked until SIGKILL.
      def stop_process_holder(holder, project)
        pid = holder["pid"]
        pgid = holder["pgid"] || pid
        timeout = stop_timeout_for(project)
        case @terminator.stop_holder(holder, liveness: @lock_holder, stop_timeout: timeout)
        when :gone
          if @terminator.running?(pgid)
            @error_output.puts "Process group #{pgid} is still running, but its holder pid #{pid} is gone, so it was not signalled. " \
              "Stop it with: kill -TERM -#{pgid}"
          end
        when :killed
          @output.puts "Killed process group #{pgid} (pid #{pid}) after #{timeout}s."
        else
          @output.puts "Stopped process group #{pgid} (pid #{pid})."
        end
      rescue Workspace::Error => e
        @error_output.puts "Could not stop process group #{pgid} (pid #{pid}): #{e.message}"
      end

      def stop_timeout_for(project)
        return DevConfig::DEFAULT_STOP_TIMEOUT unless @dev_config
        @dev_config.for_project(project)[:stop_timeout]
      rescue Workspace::Error
        DevConfig::DEFAULT_STOP_TIMEOUT
      end

      def describe_cleared(name, removed)
        if removed.nil?
          @output.puts "#{name}: nothing to clear."
          return
        end
        holder = removed[:holder]
        queue_size = removed[:queue]&.size || 0
        if holder
          @output.puts "Cleared #{name}: was held by #{describe_holder(holder)}, #{queue_size} waiter(s) removed."
        else
          @output.puts "Cleared #{name}: was free, #{queue_size} waiter(s) removed."
        end
      end
    end
  end
end
