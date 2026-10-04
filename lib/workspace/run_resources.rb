module Workspace
  # Holds a workflow step's named resources (its `uses:`) for the run, in the
  # repository's lock store, before the step's prompt is typed.
  #
  # The run holds them, not the agent: an agent's locks are released
  # whenever its session ends or is cleared, and an agent may hold only one
  # lock, so a resource a step needs across a fresh conversation has to
  # belong to the run. {#acquire} never blocks; the runner calls it again
  # until the run holds everything.
  class RunResources
    # A step may name the dev environment either way; both are the lock `dev up` takes.
    ALIASES = {"dev-env" => DevRunner::LOCK_NAME}.freeze

    # The edit lock guards an agent's own tool calls: the edit hook lets only
    # the agent holding it edit, so a run holding it would lock its own agent out.
    AGENT_ONLY = [LockEnforcer::LOCK_NAME].freeze

    # The lock names a step's `uses:` stands for: aliases resolved, sorted
    # (the order they are acquired in), each once.
    #
    # @param uses [Array<String>, String, nil] a step's `uses:` value
    # @return [Array<String>]
    # @raise [Workspace::UsageError] for a value that is not a lock name or a
    #   list of them, or a lock a run can't hold
    def self.names(uses)
      list = uses.is_a?(String) ? [uses] : uses
      list = [] if list.nil?
      unless list.is_a?(Array) && list.all? { |name| name.is_a?(String) && LockStore::NAME_PATTERN.match?(name) }
        raise UsageError, "uses: must be a lock name or a list of lock names (letters, digits, '.', '_' and '-'), " \
          "got #{uses.inspect[0, 80]}."
      end
      names = list.map { |name| ALIASES.fetch(name, name) }.uniq.sort
      refused = names & AGENT_ONLY
      return names if refused.empty?
      raise UsageError, "uses: #{refused.first} is not a resource a run can hold; it is taken by the agent that edits, " \
        "with `workspace lock acquire #{refused.first}`."
    end

    # @param lock_namespace [Workspace::LockNamespace] resolves a checkout's shared lock store
    # @param lock_holder [Workspace::LockHolder] checks holder, waiter and run liveness
    # @param lock_config [Workspace::LockConfig, nil] supplies the project's locks.idle_grace
    # @param terminator [Workspace::ProcessGroupTerminator, nil] checks a kept process holder's group
    # @param wall_clock [#call] current epoch seconds, for idle tracking in the store
    def initialize(lock_namespace:, lock_holder:, lock_config: nil, terminator: nil, wall_clock: -> { Time.now.to_i })
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @lock_config = lock_config
      @terminator = terminator
      @wall_clock = wall_clock
    end

    # Makes the run's holdings exactly this step's resources: takes each in
    # sorted order, queues for the first one that is busy, and releases what
    # the run held for an earlier step and this one does not use. A resource
    # both steps use stays held, with any dev environment running under it.
    #
    # @param run_id [String] the run
    # @param step [String, nil] the step the resources are for
    # @param uses [Array<String>, String, nil] the step's `uses:`
    # @param worktree [String] the run's checkout, which names the repository's lock store
    # @param workflow [String, nil] the workflow's name, shown to other waiters
    # @param workspace [String, nil] the run's workspace, shown to other waiters
    # @param pane [String, nil] the tmux pane the step runs in
    # @return [Hash] as {LockStore#acquire_run}: :status (:acquired,
    #   :waiting, or :not_alive when the run has no unfinished run file, and
    #   then nothing is taken), :held, :acquired, :released, :handed_over
    #   (released names a dev environment of the run still holds; stop it,
    #   or everyone queued for that name waits), :took_over and :waiting
    # @raise [Workspace::UsageError] for a bad run id, step or `uses:`
    def acquire(run_id:, step:, uses:, worktree:, workflow: nil, workspace: nil, pane: nil)
      names = self.class.names(uses)
      validate_run!(run_id, step)
      run = {run_id: run_id, step: step, workflow: workflow, workspace: workspace, worktree: worktree, pane: pane}
      store_for(worktree).acquire_run(names, run: run)
    end

    # Releases the run's resources (when a step ends at a gate, or the run
    # ends) and takes it out of any queue. A released `devenv` whose dev
    # environment is still running goes to that environment's wrapper, which
    # then holds it like one started outside a run.
    #
    # @param run_id [String] the run
    # @param worktree [String] the run's checkout
    # @param names [Array<String>, String, nil] only these resources; nil for all of them
    # @return [Array<String>] the lock names released
    def release(run_id:, worktree:, names: nil)
      names &&= self.class.names(names)
      namespace = @lock_namespace.resolve(cwd: worktree)
      return [] unless File.exist?(File.join(namespace[:dir], "locks.json"))
      store(namespace).release_run(run_id, names)
    end

    private

    def validate_run!(run_id, step)
      unless run_id.is_a?(String) && RunLiveness::ID_PATTERN.match?(run_id)
        raise UsageError, "invalid run id #{run_id.inspect[0, 80]}: use letters, digits, '.', '_' and '-', starting with a letter or digit."
      end
      return if step.nil? || (step.is_a?(String) && !step.empty? && !step.match?(/[[:cntrl:]]/))
      raise UsageError, "step must be one line of text."
    end

    def store_for(worktree)
      store(@lock_namespace.resolve(cwd: worktree))
    end

    def store(namespace)
      idle_grace = @lock_config ? @lock_config.idle_grace_for(namespace[:display]) : LockStore::DEFAULT_IDLE_GRACE
      LockStore.new(dir: namespace[:dir], liveness: @lock_holder, clock: @wall_clock, idle_grace: idle_grace, terminator: @terminator)
    end
  end
end
