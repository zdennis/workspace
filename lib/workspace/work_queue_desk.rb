require "rbconfig"

module Workspace
  # The agent daemon's part in a workspace's work queue: it starts `workspace work-queue advance --name WORKSPACE`
  # as its own process, the very pass a person runs ({WorkQueueAdvance}), so a start (which types into a pane and
  # may take a while) never runs on the daemon's threads. Two things ask for a pass:
  #
  # - {#turn_ended}: a main agent's turn ended. When the turn woke a workflow run, the fan-out calls it only once
  #   the `workflow advance` that turn started has exited, since a run usually finishes in that process.
  # - {#scan}: the session monitor's scan (`agentd.poll_interval`), the backstop.
  #
  # At most one pass runs at a time; a turn end that arrives while one runs starts another right after it.
  # A queue with no items starts none. A scan starts one only when the queue file's revision or the run it waits
  # on changed since the last pass ended, or, with an item current, {BACKSTOP} seconds have gone by (a park's
  # time running out changes no file). Whether the queue is on, paused or blocked is the pass's own question.
  #
  # Nothing here raises: a pass that can't be started is logged at debug and tried again on the next ask.
  class WorkQueueDesk
    # Seconds after which a scan starts a pass for a current item even when nothing it reads has changed.
    BACKSTOP = 60

    # @param workspace [String] the workspace the daemon serves
    # @param store [Workspace::WorkQueueStore] its queue, read through {WorkQueueStore#snapshot} only
    # @param run_store [Workspace::WorkflowRunStore] the runs the queue waits on
    # @param executable [String] path to `bin/workspace`
    # @param log_path [#call] given the workspace, the file the pass writes to
    # @param spawner [#call, nil] starts a detached process: `(argv, log)`; returns the thread that reaps it
    #   (`#value`), or nil when it can not be waited on; nil spawns the real one
    # @param waiter [#call, nil] given a block, runs it off the caller; nil starts a Thread
    # @param clock [#call] returns the current Time
    # @param logger [Workspace::Logger]
    def initialize(workspace:, store:, run_store:, executable:, log_path:, spawner: nil, waiter: nil, clock: -> { Time.now }, logger: Workspace::Logger.new)
      @workspace = workspace
      @store = store
      @run_store = run_store
      @executable = executable
      @log_path = log_path
      @spawner = spawner || method(:spawn_detached)
      @waiter = waiter || ->(&block) { Thread.new(&block) }
      @clock = clock
      @logger = logger
      @lock = Mutex.new
      @running = false
      @again = false
      @last_facts = nil
      @last_pass = nil
    end

    # A main agent's turn ended (and the workflow advance it woke, if any, has exited): a pass now, or right
    # after the one running.
    #
    # @return [void]
    def turn_ended
      request(forced: true)
    end

    # The session monitor's after-scan call: a pass when something it reads changed.
    #
    # @return [void]
    def scan
      request(forced: false)
    end

    private

    def request(forced:)
      start = @lock.synchronize do
        if @running
          @again ||= forced
          next false
        end
        facts = queue_facts
        next false unless facts && due?(facts, forced)
        @running = true
        @last_pass = @clock.call
      end
      run_pass if start
    rescue => e
      @logger.debug { "work queue: could not look at the queue of #{@workspace} (#{e.class}: #{e.message})" }
    end

    def due?(facts, forced)
      return true if forced || facts != @last_facts
      facts[:current] && (@last_pass.nil? || @clock.call - @last_pass >= BACKSTOP)
    end

    # What a pass reads, nil for a queue with no items. With an item current: the revision and its run;
    # with none: the revision and the workspace's going runs, which block a start.
    def queue_facts
      snapshot = @store.snapshot
      return nil if snapshot["items"].empty?
      current = snapshot["items"].find { |item| WorkQueueStore::CURRENT_STATES.include?(item["state"]) }
      return {revision: snapshot["revision"], current: true, run: run_facts(current.dig("result", "run_id"))} if current
      {revision: snapshot["revision"], current: false, going: @run_store.going.select { |run| run.workspace == @workspace }.map(&:id)}
    end

    def run_facts(run_id)
      run_id && @run_store.run(run_id).to_h
    rescue Workspace::Error => e
      raise unless e.code == "unknown_run"
      :unknown
    end

    def run_pass
      thread = @spawner.call([RbConfig.ruby, @executable, "work-queue", "advance", "--name", @workspace], @log_path.call(@workspace))
      return pass_ended unless thread
      @waiter.call do
        thread.value
      rescue => e
        @logger.debug { "work queue: could not read how the pass ended (#{e.class}: #{e.message})" }
      ensure
        pass_ended
      end
    rescue => e
      @logger.debug { "work queue: could not start a pass for #{@workspace} (#{e.class}: #{e.message})" }
      pass_ended
    end

    # Notes what the pass left, so the next scan waits for a change, then runs the pass a turn end asked for meanwhile.
    def pass_ended
      again = @lock.synchronize do
        @running = false
        @last_facts = begin
          queue_facts
        rescue => e
          @logger.debug { "work queue: could not read the queue after a pass (#{e.class}: #{e.message})" }
          nil
        end
        asked = @again
        @again = false
        asked
      end
      request(forced: true) if again
    end

    def spawn_detached(argv, log)
      # The daemon may have been started from a pane: that pane is not this process's caller.
      Process.detach(Process.spawn({"TMUX_PANE" => nil}, *argv, in: File::NULL, out: [log, "a"], err: [log, "a"]))
    end
  end
end
