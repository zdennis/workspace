module Workspace
  # The process that delivers a review round, as the round's `holder` names it: {#identity} is this process (pid and
  # `ps` start time) for a round start to store and its delivery to compare with, and {#alive?} says whether a
  # stored holder still runs, for a resume deciding whether a lapsed round's delivery may be taken over.
  class WorkflowRoundHolder
    # @param lock_holder [Workspace::LockHolder] reads start times and process liveness
    # @param pid [Integer] this process
    def initialize(lock_holder:, pid: Process.pid)
      @lock_holder = lock_holder
      @pid = pid
      @lock = Mutex.new
      @identity = nil
    end

    # This process. The start time is read until `ps` gives one, then kept; until then it is nil, and the
    # delivery matches its own rounds by pid alone ({WorkflowReviewRound}). Safe across threads.
    #
    # @return [Hash{String=>Object}] "pid" and "started" (nil while unread)
    def identity
      @lock.synchronize do
        next @identity if @identity
        started = begin
          @lock_holder.start_time(@pid)
        rescue Workspace::Error, SystemCallError
          nil
        end
        found = {"pid" => @pid, "started" => started}
        started ? (@identity = found) : found
      end
    end

    # Whether a round's holder still runs ({LockHolder#holder_alive?}: by start time, or by pid when none was read).
    # A process table that can't be read counts as alive, so a round is never delivered twice.
    #
    # @param holder [Hash{String=>Object}] a stored holder, "pid" and "started"
    # @return [Boolean]
    def alive?(holder)
      @lock_holder.holder_alive?(pid: holder["pid"], started: holder["started"])
    rescue Workspace::Error, SystemCallError
      true
    end
  end
end
