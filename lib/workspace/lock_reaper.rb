module Workspace
  # Reaps crashed lock holders and waiters from the session-monitor daemon, so
  # `workspace lock status` and `workspace sessions` stop showing a dead
  # agent's hold even when no lock op comes along to reap it.
  #
  # It only runs {LockStore#reap}, the same pass every lock op starts with, so
  # it can never drop a holder an op would keep: a kept `devenv` holder stays
  # while its process group runs. The namespaces reaped are the ones the
  # workspace's panes are working in.
  class LockReaper
    # Seconds between reaps. Each one forks `git` per pane directory and `ps`
    # per namespace, so it runs far less often than the pane scan.
    DEFAULT_INTERVAL = 30

    # Consecutive failed reaps of the same directory before a warning goes to
    # +error_output+. Earlier failures are debug-only, so a one-off error (a
    # directory removed mid-scan) stays quiet.
    FAILURE_WARNING_THRESHOLD = 3

    # @param lock_namespace [Workspace::LockNamespace] resolves a directory's lock store
    # @param lock_holder [Workspace::LockHolder] checks whether a recorded pid is still alive
    # @param terminator [Workspace::ProcessGroupTerminator, nil] checks whether a
    #   kept holder's process group still runs
    # @param interval [Numeric] seconds between reaps
    # @param clock [#call] returns monotonic seconds
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] where a persistently failing directory is reported
    def initialize(lock_namespace:, lock_holder:, terminator: nil, interval: DEFAULT_INTERVAL,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, logger: Workspace::Logger.new, error_output: $stderr)
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @terminator = terminator
      @interval = interval
      @clock = clock
      @logger = logger
      @error_output = error_output
      @last_reap = nil
      @failures = Hash.new(0)
    end

    # Reaps on the first call and then once every +interval+ seconds; any
    # call in between returns without touching the filesystem.
    #
    # @param cwds [Array<String, nil>] working directories of the workspace's panes
    # @return [Integer] how many holders and waiters were reaped
    def tick(cwds)
      now = @clock.call
      return 0 if @last_reap && now - @last_reap < @interval
      @last_reap = now
      reap(cwds)
    end

    # Reaps every namespace the given directories resolve to, once each. A
    # namespace that cannot be read is skipped, never raised: a corrupt
    # `locks.json` is the user's to clear, and must not stop the daemon. A
    # directory that fails {FAILURE_WARNING_THRESHOLD} times in a row is
    # reported once to +error_output+, and again only after a success resets
    # its count. Reaps are audited with `"source" => "daemon"`.
    #
    # A cwd or namespace dir that fails and then stops appearing (its pane
    # closed, the directory vanished) would otherwise leave its failure count
    # in +@failures+ forever; both keys are pruned at the end of the tick to
    # whatever was actually seen, so a long-running daemon doesn't accumulate
    # stale entries.
    #
    # @param cwds [Array<String, nil>] working directories of the workspace's panes
    # @return [Integer] how many holders and waiters were reaped
    def reap(cwds)
      seen_cwds = cwds.compact.uniq
      dirs = namespace_dirs(seen_cwds)
      reaped = dirs.sum { |dir| reap_dir(dir) }
      prune_failures(seen_cwds + dirs)
      reaped
    end

    private

    def namespace_dirs(cwds)
      cwds.filter_map { |cwd| namespace_dir(cwd) }.uniq
    end

    def prune_failures(seen_keys)
      @failures.select! { |key, _| seen_keys.include?(key) }
    end

    def namespace_dir(cwd)
      return unless File.directory?(cwd)
      dir = @lock_namespace.resolve(cwd: cwd)[:dir]
      succeeded(cwd)
      dir
    rescue => e
      @logger.debug { "lock reaper: no namespace for #{cwd} (#{e.class}: #{e.message})" }
      failed(cwd, "could not resolve the lock namespace for #{cwd}", e)
      nil
    end

    # A namespace no one has locked in has no `locks.json`; it is left alone
    # rather than having its directory created just to reap nothing.
    def reap_dir(dir)
      return 0 unless File.exist?(File.join(dir, "locks.json"))
      reaped = LockStore.new(dir: dir, liveness: @lock_holder, terminator: @terminator, logger: @logger).reap(source: "daemon")
      @logger.debug { "lock reaper: reaped #{reaped} from #{dir}" } if reaped > 0
      succeeded(dir)
      reaped
    rescue => e
      @logger.debug { "lock reaper: skipped #{dir} (#{e.class}: #{e.message})" }
      failed(dir, "could not reap stale locks in #{dir}", e)
      0
    end

    def succeeded(key)
      @failures.delete(key)
    end

    def failed(key, what, error)
      @failures[key] += 1
      return unless @failures[key] == FAILURE_WARNING_THRESHOLD
      @error_output.puts "Warning: lock reaper #{what} #{FAILURE_WARNING_THRESHOLD} times in a row " \
        "(#{error.class}: #{error.message}); until fixed, stale holders there are only reaped by the next lock op"
    end
  end
end
