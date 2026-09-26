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

      cwd = Dir.pwd unless cwd && File.directory?(cwd)
      namespace = @lock_namespace.resolve(cwd: cwd)
      store = LockStore.new(dir: namespace[:dir], liveness: @lock_holder, clock: @clock, logger: @logger)
      pane = @env["TMUX_PANE"]
      return [] unless store.idle_change_possible?(pane: (pane.nil? || pane.empty?) ? nil : pane, idle: idle)

      identity = @lock_holder.current
      return [] unless identity

      changed = store.mark_idle(identity, idle: idle)
      @logger.debug { "session-event: marked #{changed.join(", ")} #{idle ? "idle" : "active"}" } unless changed.empty?
      changed
    rescue => e
      @logger.debug { "session-event: lock idle update failed (#{e.class}: #{e.message})" }
      []
    end
  end
end
