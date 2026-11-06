# frozen_string_literal: true

module Workspace
  # The panes an agent daemon is restarting, one claim per pane id. A claim
  # keeps a second restart, a queued clear or a recovery attempt off the same
  # pane. Claims are made for a restart worker thread, a queued prompt's clear
  # (an opaque token) or a recovery attempt (its own thread).
  class RestartRegistry
    # @param spawn [#call] starts a worker thread from a block (default +Thread.new+)
    def initialize(spawn: ->(&work) { Thread.new(&work) })
      @spawn = spawn
      @claims = {}
      @lock = Mutex.new
      @shutting_down = false
    end

    # @return [Boolean] whether any claim holds the pane
    def held?(pane_id)
      @lock.synchronize { @claims.key?(pane_id) }
    end

    # Reserves a pane for a restart whose worker is not started yet.
    #
    # @return [Boolean] false when the pane is already held
    def claim_pending(pane_id)
      @lock.synchronize do
        next false if @claims.key?(pane_id)
        @claims[pane_id] = :starting
        true
      end
    end

    # Starts the worker for a pane reserved by {#claim_pending}; the block runs
    # on a new thread that is recorded as the pane's claim before it can release it.
    #
    # @return [Thread]
    def start_worker(pane_id, &work)
      @lock.synchronize { @claims[pane_id] = @spawn.call(&work) }
    end

    # Gives up a {#claim_pending} reservation whose worker never started.
    def abandon_pending(pane_id)
      @lock.synchronize { @claims.delete(pane_id) if @claims[pane_id] == :starting }
    end

    # Claims a pane for a queued prompt's clear, refusing (never waiting) when held.
    #
    # @return [Object, nil] the token for {#release}; nil when the pane is held
    def claim_for_queue(pane_id)
      @lock.synchronize do
        next nil if @claims.key?(pane_id)
        @claims[pane_id] = Object.new
      end
    end

    # Claims a pane for a recovery attempt, on the attempt's own thread, so
    # {#stop_all} kills it. Refused once {#shut_down!} was called, since that
    # sweep would never see it.
    #
    # @return [Thread, nil] the token for {#release}; nil when held or shutting down
    def claim_for_recovery(pane_id)
      @lock.synchronize do
        next nil if @shutting_down || @claims.key?(pane_id)
        @claims[pane_id] = Thread.current
      end
    end

    # Releases a claim, and only the one the token names.
    def release(pane_id, token = Thread.current)
      @lock.synchronize { @claims.delete(pane_id) if @claims[pane_id].equal?(token) }
    end

    # Makes later recovery claims refuse. Takes no lock, so a signal handler may call it.
    def shut_down!
      @shutting_down = true
    end

    # Kills the worker threads and waits up to a second for each.
    def stop_all
      workers = @lock.synchronize { @claims.values.grep(Thread) }
      workers.each(&:kill)
      workers.each { |worker| worker.join(1) }
    end
  end
end
