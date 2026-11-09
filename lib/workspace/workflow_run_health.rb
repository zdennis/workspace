module Workspace
  # What `doctor` reports about workflow runs and the locks they hold. It only
  # reads: it takes no lock, reaps nothing and writes nothing, so a doctor run
  # never changes what `lock status` or `workflow status` would show.
  #
  # - An orphaned run is one still going (its state is not completed, failed or
  #   cancelled) whose checkout (`worktree`) is missing (gone, or on a volume
  #   that is not mounted) or was never recorded, so no step can run. A run
  #   that waits for a gate, a lock, a backoff, a token budget (`budget_spent`) or a stopped session is not
  #   orphaned while its checkout exists: `restore` or `workflow resume` can
  #   still move it.
  # - An unreadable run file is a file in the runs directory that can't be read
  #   as a run. The lock store counts such a run as alive, so what it held
  #   stays held.
  # - A leaked run lock is a `kind: "run"` holder or waiter, in any
  #   repository's lock store, whose run is no longer alive. The lock store
  #   reaps it on its next operation that takes or gives up a lock and the
  #   agent daemon sweeps periodically, so one seen here means neither has run
  #   since the run ended (a run that has only just ended shows the same way).
  class WorkflowRunHealth
    # A run still going that nothing can move: its checkout is missing, unmounted or never recorded.
    # {#to_h} is the string-keyed Hash `call` returned before this value existed.
    Orphan = Struct.new(:id, :workflow, :workspace, :state, :worktree, :why, keyword_init: true) do
      # @return [Hash{String=>Object}]
      def to_h
        {"id" => id, "workflow" => workflow, "workspace" => workspace, "state" => state, "worktree" => worktree, "why" => why}
      end
    end

    # @param store [Workspace::WorkflowRunStore] lists the runs still going and the run files it can't read
    # @param liveness [Workspace::RunLiveness] says whether a run is still going
    # @param lock_dir [String] the directory holding one lock store directory per repository ({Config#lock_dir})
    # @param lock_store_for [#call] given a lock store directory, returns the {LockStore} to read it with
    def initialize(store:, liveness:, lock_dir:, lock_store_for: ->(dir) { LockStore.new(dir: dir, liveness: liveness) })
      @store = store
      @liveness = liveness
      @lock_dir = lock_dir
      @lock_store_for = lock_store_for
    end

    # @return [Hash{Symbol=>Array}] `:orphans` ({Orphan} values),
    #   `:unreadable` (run file paths), `:leaked` (hashes with `namespace`, `dir`, `lock`, `run_id`, `role`, `worktree`, `delegate_pid`)
    #   and `:warnings` (strings for files that could not be read)
    def call
      warnings = []
      {orphans: orphaned_runs(warnings), unreadable: read_unreadable(warnings), leaked: leaked_locks(warnings), warnings: warnings}
    end

    private

    def orphaned_runs(warnings)
      @store.going.filter_map do |run|
        worktree = run.worktree
        why = if !worktree.is_a?(String) || worktree.empty?
          "it records no checkout"
        elsif !File.directory?(worktree)
          "its checkout #{worktree} is missing or unmounted"
        end
        next unless why
        Orphan.new(id: run.id, workflow: run.workflow, workspace: run.workspace, state: run.state, worktree: worktree, why: why)
      end
    rescue SystemCallError, Workspace::Error => e
      warnings << "could not list the workflow runs (#{e.class})"
      []
    end

    def read_unreadable(warnings)
      @store.unreadable
    rescue SystemCallError, Workspace::Error => e
      warnings << "could not list the workflow run files (#{e.class})"
      []
    end

    def leaked_locks(warnings)
      Dir.glob(File.join(@lock_dir, "*", "locks.json")).sort.flat_map do |path|
        dir = File.dirname(path)
        @lock_store_for.call(dir).run_records.filter_map do |entry|
          record = entry[:record]
          next unless record["run_id"].is_a?(String) && !alive?(record["run_id"])
          {"namespace" => File.basename(dir), "dir" => dir, "lock" => entry[:name], "run_id" => record["run_id"], "role" => entry[:role], "worktree" => record["worktree"],
           "delegate_pid" => (record["delegate"]["pid"] if record["delegate"].is_a?(Hash) && record["delegate"]["pid"].is_a?(Integer))}
        end
      rescue Workspace::Error, SystemCallError
        warnings << "could not read #{path} (not valid lock data)"
        []
      end
    end

    # A run file that can't be read counts as alive, as the lock store counts it; it has its own row.
    def alive?(run_id)
      @liveness.alive?(run_id)
    rescue Workspace::Error
      true
    end
  end
end
