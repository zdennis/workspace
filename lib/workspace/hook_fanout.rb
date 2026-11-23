module Workspace
  # The agent daemon's fan-out of one workspace's hook events: a registry of subscribers that each hear the
  # events they have a method for. {#notify} calls `event` on every subscriber that responds to it, in the
  # order they were given, and a subscriber that raises is logged and does not stop the ones after it.
  #
  # The events, in the order a hook event meets them in {#session_event}: `before_record(message)` (before the
  # monitor records it: a /clear moves the pane's session_id there, and a poll in the gap would end a
  # handoff watch session_changed, not carried_out), then the monitor records it and the hook log writes it,
  # then `session_event(message)`. Besides these: `scan` (the session monitor's after-scan call, {#scan}),
  # `tick` (the socket watcher's, {#tick}) and `turn_ended` (a main agent's turn settled, {#turn_ended}).
  # A later event such as `wait_opened(pane)` is one more `notify(:wait_opened, pane)` call, with no change
  # to the subscribers that have no method of that name.
  class HookFanout
    # Spawns a thread for the owner report on a main agent's Stop.
    class OwnerFinished
      # @param report [Workspace::SpineOwnerReport] reports a stage owner's finished turn
      # @param spawn [#call] runs the given block on its own thread
      def initialize(report:, spawn: ->(&work) { Thread.new(&work) })
        @report = report
        @spawn = spawn
      end

      # The main agent's turn ended (the Stop hook): a stage the pane owns is reported as finished, on its own
      # thread. A sub-agent's event and any other event are ignored. It has no `turn_ended` method, since that
      # name is the registry's event for a turn that has settled.
      #
      # @param message [Hash] the `session_event` message
      # @return [void]
      def session_event(message)
        return unless message["agent_id"].nil? && message["event"] == "stop"

        pane_id = message["pane_id"]
        @spawn.call { @report.turn_ended(pane_id) }
      end
    end

    # @param monitor [Workspace::SessionMonitor] records each hook event
    # @param hook_log [Workspace::HookEventLog, nil] writes each hook event; nil writes none
    # @param subscribers [Array<Object>] told each event they respond to, in this order; nil ones are left out
    # @param logger [Workspace::Logger] debug logger
    def initialize(monitor:, hook_log: nil, subscribers: [], logger: Workspace::Logger.new)
      @monitor = monitor
      @hook_log = hook_log
      @subscribers = subscribers.compact
      @logger = logger
    end

    # Hands one hook event to the subscribers' `before_record`, the monitor, the hook log, then the
    # subscribers' `session_event`. A failure of the monitor or the hook log is raised to the caller.
    #
    # @param message [Hash] the `session_event` message
    # @return [void]
    def session_event(message)
      notify(:before_record, message)
      @monitor.record(message)
      @hook_log&.record(message)
      notify(:session_event, message)
    end

    # The session monitor's after-scan call: every subscriber's `scan`, in order.
    #
    # @return [void]
    def scan
      notify(:scan)
    end

    # The socket watcher's tick: every subscriber's `tick`.
    #
    # @return [void]
    def tick
      notify(:tick)
    end

    # A main agent's turn has settled (the workflow advance it woke has exited, or none was woken): every
    # subscriber's `turn_ended`.
    #
    # @return [void]
    def turn_ended
      notify(:turn_ended)
    end

    # Calls `event` with `args` on each subscriber that responds to it, in order. One that raises is logged
    # and the next still runs.
    #
    # @param event [Symbol] the method to call
    # @param args [Array] its arguments
    # @return [void]
    def notify(event, *args)
      @subscribers.each do |subscriber|
        next unless subscriber.respond_to?(event)

        subscriber.public_send(event, *args)
      rescue => e
        @logger.debug { "agent: #{subscriber.class.name.split("::").last} #{event} failed (#{e.class}: #{e.message})" }
      end
      nil
    end
  end
end
