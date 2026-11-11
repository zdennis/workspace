# Reads and changes a stored workflow run through the typed WorkflowRunStore
# methods (#run, #going, #finished, #change), giving what the store's Hash
# methods (#find, #active, #archived, #update) give, so a spec can stop calling
# those. Included in every example group.
module RunFileReads
  # @return [Hash{String=>Object}] the run as {Workspace::WorkflowRunStore#find} gives it: a mutable copy
  # @raise [Workspace::Error] code `unknown_run`
  def stored_run(store, id)
    mutable_run_hash(store.run(id).to_h)
  end

  # @return [Array<Hash>] what {Workspace::WorkflowRunStore#active} gives
  def going_runs(store)
    store.going.map { |run| mutable_run_hash(run.to_h) }
  end

  # @return [Array<Hash>] what {Workspace::WorkflowRunStore#archived} gives
  def finished_runs(store)
    store.finished.map { |run| mutable_run_hash(run.to_h) }
  end

  # Changes a run through {Workspace::WorkflowRunStore#change}, the block
  # changing a mutable copy in place.
  #
  # @return [Object, nil] what {Workspace::WorkflowRunStore#update} returns: the block's value, nil when `nonblocking` finds the run busy
  def edit_run(store, id, nonblocking: false)
    result = nil
    stored = store.change(id, nonblocking: nonblocking) do |run|
      hash = mutable_run_hash(run.to_h)
      result = yield hash
      Workspace::WorkflowRun.from_h(hash)
    end
    stored && result
  end

  private

  def mutable_run_hash(hash)
    Marshal.load(Marshal.dump(hash))
  end
end

RSpec.configure { |config| config.include RunFileReads }
