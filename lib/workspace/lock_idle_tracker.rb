module Workspace
  # Marks the calling agent's locks idle when its turn ends, and active again
  # when it gets a prompt or uses a tool, so a waiter can take over a lock an
  # idle agent is sitting on (see {LockStore#poll}).
  #
  # Runs from `workspace session-event` on every hook, so the common case has
  # to be nearly free: no lock directory, no `locks.json`, or no holder in this
  # pane whose state would change all return before the process table is
  # read or the store is locked. It never raises.
  class LockIdleTracker
    # Hook event => whether it marks the agent idle (true) or active (false).
    EVENTS = {"Stop" => true, "UserPromptSubmit" => false, "PreToolUse" => false}.freeze

    # @param config [Workspace::Config] supplies the lock directory
    # @param lock_namespace [Workspace::LockNamespace] resolves the store for a cwd
    # @param lock_holder [Workspace::LockHolder] identifies the calling agent
    # @param env [Hash] process environment, for TMUX_PANE
    # @param clock [#call] current epoch seconds, recorded as `idle_since`
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, lock_namespace:, lock_holder:, env: ENV, clock: -> { Time.now.to_i }, logger: Workspace::Logger.new)
      @config = config
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @env = env
      @clock = clock
      @logger = logger
    end

    # @param hook_event [String, nil] the agent's hook event name, e.g. "Stop"
    # @param cwd [String, nil] the agent's working directory, from the hook payload
    # @return [Array<String>] names of locks whose idle state changed
    def update(hook_event, cwd: nil)
      idle = EVENTS[hook_event]
      return [] if idle.nil?
      return [] unless Dir.exist?(@config.lock_dir)

      pane = @env["TMUX_PANE"]
      pane = nil if pane.nil? || pane.empty?

      # Namespace resolution shells out to `git`, so it only runs once a
      # locks.json under lock_dir is actually found holding this pane (a few
      # small file reads, no subprocess). Everywhere else in this repo's
      # panes stays a pure file-stat check.
      return [] unless any_pane_hold?(pane: pane, idle: idle)

      cwd = Dir.pwd unless cwd && File.directory?(cwd)
      namespace = @lock_namespace.resolve(cwd: cwd)
      store = LockStore.new(dir: namespace[:dir], liveness: @lock_holder, clock: @clock, logger: @logger)
      return [] unless store.idle_change_possible?(pane: pane, idle: idle)

      identity = @lock_holder.current
      return [] unless identity

      changed = store.mark_idle(identity, idle: idle)
      @logger.debug { "session-event: marked #{changed.join(", ")} #{idle ? "idle" : "active"}" } unless changed.empty?
      changed
    rescue => e
      @logger.debug { "session-event: lock idle update failed (#{e.class}: #{e.message})" }
      []
    end

    private

    # Scans every namespace directory under lock_dir for a matching hold,
    # without shelling out: {LockStore#idle_change_possible?} is a plain file
    # read. This repo's own namespace is always among these directories, so
    # a real match here can never be missed; a false positive from another
    # project's namespace just costs one extra (still cheap) resolve below.
    def any_pane_hold?(pane:, idle:)
      Dir.children(@config.lock_dir).any? do |name|
        dir = File.join(@config.lock_dir, name)
        next false unless File.directory?(dir)
        LockStore.new(dir: dir, liveness: @lock_holder, clock: @clock, logger: @logger)
          .idle_change_possible?(pane: pane, idle: idle)
      end
    rescue SystemCallError
      false
    end
  end
end
