module Workspace
  # The one way a workflow run changes: under the run's lock, with the attempt record's reasons kept before and
  # after the change, `workflow_changed` written when what a reader sees moved, alerts fired once the lock is given
  # up, and then the line of a step the change started typed, through +deliver+. It never runs a check: a block that
  # registers one reads it back from its {Context} and the caller runs it.
  class WorkflowRunChange
    # What one change hands out of its block: the step line to type after the lock, and the check to run.
    # A new one is made for every {WorkflowRunChange#call}, so no follow-up outlives the change that made it.
    class Context
      # @return [Hash{String=>Object}, nil] the step line registered with {#deliver}
      attr_reader :delivery

      # @param delivery [Hash{String=>Object}] the line a dispatched attempt has to have typed
      # @return [Hash{String=>Object}]
      def deliver(delivery)
        @delivery = delivery
      end

      # With an argument, registers the check or proof to run once the lock is given up; without, the one registered.
      #
      # @param found [Hash{String=>Object}, nil]
      # @return [Hash{String=>Object}, nil]
      def check(found = nil)
        found ? @check = found : @check
      end
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

    # Runs one change to a run under its lock and announces it, then types the line of a step the change started.
    #
    # @param run_id [String]
    # @param nonblocking [Boolean] return nil at once when another process is changing the run
    # @yieldparam run [WorkflowRun] the stored run, with its reason history kept
    # @yieldparam ctx [Context] this change's follow-ups
    # @yieldreturn [WorkflowRun, nil] the run to store; nil stores the run as given
    # @return [WorkflowRun, Object, nil] the run afterwards, or what +deliver+ returned when a line was
    #   registered; nil when +nonblocking+ and the run is busy
    # @raise [Workspace::Error] code `unknown_run`, `run_not_active`, and what the block raises
    def call(run_id, nonblocking: false)
      ctx = Context.new
      before = nil
      alert_before = nil
      run = @store.change(run_id, nonblocking: nonblocking) do |read|
        before = WorkflowTransitions.fingerprint(read.to_h)
        alert_before = @alerts&.marks(read)
        was_open = @attempt_record.open_attempt(read.to_h)
        given = @attempt_record.reasons(run: read)
        changed = yield(given, ctx) || given
        raise TypeError, "a run change's block returned #{changed.class}, not a WorkflowRun" unless changed.is_a?(WorkflowRun)
        @attempt_record.reasons(run: changed, was_open: was_open)
      end
      return nil unless run
      changed(run.to_h) unless before == WorkflowTransitions.fingerprint(run.to_h)
      @alerts&.fire(alert_before, run)
      ctx.delivery ? @deliver.call(run_id, ctx.delivery) : run
    end

    # Appends one line to the run's history at once.
    #
    # @param run [Hash{String=>Object}, WorkflowRun] the run, for its id
    # @param type [String]
    # @param data [Hash{String=>Object}]
    # @return [void]
    def event(run, type, data = {})
      @store.record_event(run.is_a?(WorkflowRun) ? run.id : run["id"], type, data)
    end

    private

    def changed(run)
      @event_log&.record(type: "workflow_changed", project: run["workspace"],
        data: {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"],
               "state" => WorkflowTransitions.hold?(run["reason"]) ? "running" : run["state"],
               "step" => run["current"], "reason" => run["parked"] ? nil : run.dig("reason", "code")})
    end
  end
end
