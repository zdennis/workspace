module Workspace
  # The one way a workflow run changes: under the run's lock, with the attempt record's reasons kept before and
  # after the change, the history lines its block wrote ({#event}) queued and written with `from_state`, `to_state`, `actor` and `cause`
  # once the run is stored and before the lock is given up, `workflow_changed` written when what a reader sees moved, alerts fired once the lock is given
  # up with what the block registered to follow it ({Context#after_lock}), and then the line of each step the change started typed, through +deliver+, one after another. It never runs a check, a review round or a window close: a
  # block that registers one reads it back from its {Context} and the caller runs it through
  # {WorkflowEvaluation#finish_follow_ups}.
  class WorkflowRunChange
    # Who a change can be made by: the run's agent, a person, the sweep and the agent daemon, or the engine itself.
    # The rule: a change carries the actor that began the action, including the checks and review-round decisions that
    # follow it once the lock is given up, so a step's `step_passed` reads the same with or without a `status:` check.
    # `engine` is kept only for changes no outside actor asks for: the settle after a line is typed, `record_remote`,
    # a review round's delivery and a round's rerun.
    ACTORS = %w[engine agent person sweep daemon].freeze

    # What one change hands out of its block: the step line to type after the lock, the check to run, the review round to
    # run, the ended round whose revision is computed again, the review window to close and the history lines queued.
    # A new one is made for every {WorkflowRunChange#call}, so no follow-up outlives the change that made it.
    class Context
      # @return [String] who made the change, one of {ACTORS}
      attr_reader :actor

      # @return [String] why the change was made, a short snake_case code; the default `cause` of the lines it queues
      attr_reader :cause

      # @param actor [String] one of {ACTORS}
      # @param cause [String] why the change is made
      def initialize(actor, cause)
        @actor = actor
        @cause = cause
      end

      # @return [Hash{String=>Object}, nil] the last step line registered with {#deliver}
      def delivery = deliveries.last

      # @return [Array<Hash{String=>Object}>] every step line registered with {#deliver}, in order: one, or one per
      #   sibling of a fan_out group the change dispatched
      def deliveries = @deliveries || []

      # Registers the one line to type, in place of any registered before, as a change that starts one step has.
      #
      # @param delivery [Hash{String=>Object}] the line a dispatched attempt has to have typed
      # @return [Hash{String=>Object}]
      def deliver(delivery)
        @deliveries = [delivery]
        delivery
      end

      # Registers a line to type after those registered before, in place of one for the same step only: each sibling
      # of a fan_out group the change starts has its own line, typed in turn.
      #
      # @param delivery [Hash{String=>Object}] the line a dispatched attempt has to have typed
      # @return [Hash{String=>Object}]
      def add_delivery(delivery)
        @deliveries = deliveries.reject { |each| each["step"] == delivery["step"] } << delivery
        delivery
      end

      # With an argument, registers the check or proof to run once the lock is given up; without, the one registered.
      #
      # @param found [Hash{String=>Object}, nil]
      # @return [Hash{String=>Object}, nil]
      def check(found = nil)
        found ? @check = found : @check
      end

      # With an argument, registers the review round to run once the lock is given up; without, the one registered.
      #
      # @param found [Hash{String=>Object}, nil]
      # @return [Hash{String=>Object}, nil]
      def review(found = nil)
        found ? @review = found : @review
      end

      # With an argument, registers the ended review round whose revision is computed again once the lock is given
      # up ({WorkflowEvaluation#finish_follow_ups}); without, the one registered.
      #
      # @param found [Hash{String=>Object}, nil] "step", "attempt", "round" and "try" of the round's `recompute` mark
      # @return [Hash{String=>Object}, nil]
      def review_end(found = nil)
        found ? @review_end = found : @review_end
      end

      # With an argument, registers the review window of an ended round to close once the lock is given up; without,
      # the one registered.
      #
      # @param found [Hash{String=>Object}, nil] "step", "round" and "pane" (nil when the round never recorded one)
      # @return [Hash{String=>Object}, nil]
      def close_review(found = nil)
        found ? @close_review = found : @close_review
      end

      # Registers a block {WorkflowRunChange#call} runs once the lock is given up and the change stored, given the run
      # as stored, as alerts fire: a notice to a person that must not hold the run's lock. A block that raises is
      # dropped; it never fails the change.
      #
      # @yieldparam run [WorkflowRun] the run as stored
      # @return [void]
      def after_lock(&block)
        (@after_lock ||= []) << block
      end

      # @return [Array<Proc>] the blocks registered with {#after_lock}, in order
      def after_locks = @after_lock || []

      # Queues a line of the run's history, written once the run is stored, with the change's `from_state` and
      # `to_state`; dropped when the change raises.
      #
      # @param type [String]
      # @param data [Hash{String=>Object}]
      # @return [void]
      def event(type, data = {})
        (@events ||= []) << [type, data]
      end

      # @return [Array<Array(String, Hash)>] the lines queued with {#event}, in order
      def events = @events || []
    end

    # @param store [Workspace::WorkflowRunStore]
    # @param attempt_record [Workspace::WorkflowAttemptRecord] keeps each attempt's reasons
    # @param deliver [#call] types a registered line, given the run id and the delivery; its result is the change's
    # @param alerts [Workspace::WorkflowAlerts, nil] reads the marks before and after, and fires what moved
    # @param event_log [Workspace::EventLog, nil] gets `workflow_changed`
    def initialize(store:, attempt_record:, deliver:, alerts: nil, event_log: nil)
      @store = store
      @attempt_record = attempt_record
      @deliver = deliver
      @alerts = alerts
      @event_log = event_log
    end

    # Runs one change to a run under its lock and announces it, then types the line of each step the change started.
    #
    # @param run_id [String]
    # @param actor [String] who makes the change, one of {ACTORS}; written on every history line the change queues
    # @param cause [String] why the change is made, a short snake_case code (`approve`, `turn_ended`, `tick`, ...);
    #   written on every history line the change queues that has no `cause` of its own
    # @param nonblocking [Boolean] return nil at once when another process is changing the run
    # @yieldparam run [WorkflowRun] the stored run, with its reason history kept
    # @yieldparam ctx [Context] this change's follow-ups
    # @yieldreturn [WorkflowRun, nil] the run to store; nil means no change: the run as given is stored
    # @return [WorkflowRun, Object, nil] the run afterwards, or what +deliver+ returned for the last line
    #   registered; nil when +nonblocking+ and the run is busy
    # @raise [ArgumentError] when +actor+ is not one of {ACTORS}, or +cause+ is not a non-empty String
    # @raise [Workspace::Error] code `unknown_run`, `run_not_active`, and what the block raises
    def call(run_id, actor:, cause:, nonblocking: false)
      raise ArgumentError, "unknown actor #{actor.inspect}, expected one of #{ACTORS.join(", ")}" unless ACTORS.include?(actor)
      raise ArgumentError, "a run change needs a cause, got #{cause.inspect}" unless cause.is_a?(String) && !cause.empty?
      ctx = Context.new(actor, cause)
      before = nil
      alert_before = nil
      from_state = nil
      after_write = ->(stored) { flush(run_id, ctx, from_state, stored.state) }
      run = @store.change(run_id, nonblocking: nonblocking, after_write: after_write) do |read|
        before = WorkflowTransitions.fingerprint(read.to_h)
        alert_before = @alerts&.marks(read)
        from_state = read.state
        was_open = @attempt_record.open_attempt(read.to_h)
        given = @attempt_record.reasons(run: read)
        changed = queueing(run_id, ctx) { yield(given, ctx) } || given
        raise TypeError, "a run change's block returned #{changed.class}, not a WorkflowRun" unless changed.is_a?(WorkflowRun)
        @attempt_record.reasons(run: changed, was_open: was_open)
      end
      return nil unless run
      changed(run.to_h) unless before == WorkflowTransitions.fingerprint(run.to_h)
      @alerts&.fire(alert_before, run)
      ctx.after_locks.each { |each| after_lock(each, run) }
      return run if ctx.deliveries.empty?
      ctx.deliveries.map { |delivery| @deliver.call(run_id, delivery) }.last
    end

    # Appends one line to the run's history. Inside the block of a {#call} for the same run on this thread, the line
    # is queued ({Context#event}) and written once the run is stored, still under the lock; anywhere else (another
    # run, an after-lock block, +deliver+) it is written at once. A change that raises writes none of its queued lines,
    # by design: a block that raises after a side effect (a pane bound, say) leaves no line for that side effect.
    #
    # @param run [Hash{String=>Object}, WorkflowRun] the run, for its id
    # @param type [String]
    # @param data [Hash{String=>Object}]
    # @return [void]
    def event(run, type, data = {})
      id = run.is_a?(WorkflowRun) ? run.id : run["id"]
      ctx = queues[id]
      ctx ? ctx.event(type, data) : @store.record_event(id, type, data)
    end

    private

    # Thread-local, not fiber-local (+Thread.current[]+), so a block that runs its work in a fiber still queues. It
    # assumes one WorkflowRunChange changes a given run on a thread at a time.
    def queues
      Thread.current.thread_variable_get(:workspace_run_change_queues) ||
        Thread.current.thread_variable_set(:workspace_run_change_queues, {})
    end

    def queueing(run_id, ctx)
      previous = queues[run_id]
      queues[run_id] = ctx
      yield
    ensure
      previous ? queues[run_id] = previous : queues.delete(run_id)
    end

    def flush(run_id, ctx, from_state, to_state)
      stamps = {"from_state" => from_state, "to_state" => to_state, "actor" => ctx.actor, "cause" => ctx.cause}
      ctx.events.each do |type, data|
        @store.record_event(run_id, type, data.merge(stamps) { |_, own, _| own })
      rescue
        nil
      end
    end

    def after_lock(block, run)
      block.call(run)
    rescue
      nil
    end

    def changed(run)
      @event_log&.record(type: "workflow_changed", project: run["workspace"],
        data: {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"],
               "state" => WorkflowTransitions.hold?(WorkflowRun.slot(run, run["current"], "reason")) ? "running" : run["state"],
               "step" => run["current"], "reason" => run["parked"] ? nil : WorkflowRun.slot_dig(run, run["current"], "reason", "code")})
    end
  end
end
