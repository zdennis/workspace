# Reads and changes a stored workflow run as a mutable Hash, through the typed
# WorkflowRunStore methods (#run, #going, #finished, #change), so a spec can
# read and edit a run file as the Hash it holds. Included in every example group.
module RunFileReads
  # @return [Hash{String=>Object}] a mutable copy of the run {Workspace::WorkflowRunStore#run} reads
  # @raise [Workspace::Error] code `unknown_run`
  def stored_run(store, id)
    mutable_run_hash(store.run(id).to_h)
  end

  # @return [Array<Hash>] mutable copies of the runs {Workspace::WorkflowRunStore#going} lists, oldest first
  def going_runs(store)
    store.going.map { |run| mutable_run_hash(run.to_h) }
  end

  # @return [Array<Hash>] mutable copies of the runs {Workspace::WorkflowRunStore#finished} lists, newest first
  def finished_runs(store)
    store.finished.map { |run| mutable_run_hash(run.to_h) }
  end

  # Changes a run through {Workspace::WorkflowRunStore#change}, the block
  # changing a mutable copy in place.
  #
  # @return [Object, nil] the block's value; nil when `nonblocking` finds the run busy
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
