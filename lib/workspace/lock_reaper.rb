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

    # @param lock_namespace [Workspace::LockNamespace] resolves a directory's lock store
    # @param lock_holder [Workspace::LockHolder] checks whether a recorded pid is still alive
    # @param terminator [Workspace::ProcessGroupTerminator, nil] checks whether a
    #   kept holder's process group still runs
    # @param interval [Numeric] seconds between reaps
    # @param clock [#call] returns monotonic seconds
    # @param logger [Workspace::Logger] debug logger
    def initialize(lock_namespace:, lock_holder:, terminator: nil, interval: DEFAULT_INTERVAL,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, logger: Workspace::Logger.new)
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @terminator = terminator
      @interval = interval
      @clock = clock
      @logger = logger
      @last_reap = nil
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
    # `locks.json` is the user's to clear, and must not stop the daemon.
    #
    # @param cwds [Array<String, nil>] working directories of the workspace's panes
    # @return [Integer] how many holders and waiters were reaped
    def reap(cwds)
      namespace_dirs(cwds).sum { |dir| reap_dir(dir) }
    end

    private

    def namespace_dirs(cwds)
      cwds.compact.uniq.filter_map { |cwd| namespace_dir(cwd) }.uniq
    end

    def namespace_dir(cwd)
      return unless File.directory?(cwd)
      @lock_namespace.resolve(cwd: cwd)[:dir]
    rescue => e
      @logger.debug { "lock reaper: no namespace for #{cwd} (#{e.class}: #{e.message})" }
      nil
    end

    # A namespace no one has locked in has no `locks.json`; it is left alone
    # rather than having its directory created just to reap nothing.
    def reap_dir(dir)
      return 0 unless File.exist?(File.join(dir, "locks.json"))
      reaped = LockStore.new(dir: dir, liveness: @lock_holder, terminator: @terminator, logger: @logger).reap
      @logger.debug { "lock reaper: reaped #{reaped} from #{dir}" } if reaped > 0
      reaped
    rescue => e
      @logger.debug { "lock reaper: skipped #{dir} (#{e.class}: #{e.message})" }
      0
    end
  end
end
