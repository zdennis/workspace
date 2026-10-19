module Workspace
  # The live locks of a repository that the caller holds, for `promote`'s
  # `locks_held` warning: an agent lock with the calling agent's pid and start
  # time, a process lock (the dev environment) started from the caller's pane,
  # or a run's lock when the caller's pane is bound to that run. When the
  # caller cannot be told (neither its agent nor a bound run found, which a
  # pane alone does not make up for), every live lock is listed and `own` is
  # false.
  class HeldLocks
    # @param lock_namespace [Workspace::LockNamespace] finds a repository's lock directory
    # @param lock_holder [Workspace::LockHolder] the caller's identity and the holders' liveness
    # @param bound_run [Workspace::BoundRun] the run the caller's pane is bound to
    # @param store_factory [#call] `(dir)` to a {LockStore}
    # @param env [Hash] environment lookup (TMUX_PANE)
    def initialize(lock_namespace:, lock_holder:, bound_run:, store_factory: ->(dir) { LockStore.new(dir: dir, liveness: lock_holder) }, env: ENV)
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @bound_run = bound_run
      @store_factory = store_factory
      @env = env
    end

    # @param root [String] a checkout of the repository
    # @return [Hash] `:names` (sorted) and `:own` (whether they are only the caller's)
    def call(root)
      dir = @lock_namespace.resolve(cwd: root)[:dir]
      return {names: [], own: true} unless Dir.exist?(dir)
      live = @store_factory.call(dir).status.select { |_, entry| entry["holder"] && !entry["holder"]["stale"] }
      identity = caller_identity
      return {names: live.keys.sort, own: false} unless identity
      {names: live.select { |_, entry| mine?(entry["holder"], identity) }.keys.sort, own: true}
    end

    private

    def caller_identity
      agent = begin
        @lock_holder.current
      rescue Workspace::Error
        nil
      end
      pane = @env["TMUX_PANE"].to_s
      identity = {agent: agent, pane: (pane unless pane.empty?), run: @bound_run.run_id}
      (agent || identity[:run]) ? identity : nil
    end

    def mine?(holder, identity)
      return holder["run_id"] == identity[:run] if LockStore.run?(holder)
      return !!identity[:pane] && holder["pane"] == identity[:pane] if holder["kind"] == "process"
      !!identity[:agent] && LockHolder.same_agent?(holder, identity[:agent])
    end
  end
end
