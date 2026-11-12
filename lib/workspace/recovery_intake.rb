module Workspace
  # The recovery desk's intake of hook events. {#session_event} only queues
  # the event: one worker at a time takes the queue in order, so the accept
  # loop takes no file lock and runs no `ps`, and a pane's events can't
  # overtake each other. The worker reads an entry's `phase` first, so an
  # attempt's own events are never read as a person's. Unless a rule says
  # otherwise, an event from a session other than the entry's is ignored: a
  # fresh agent's Stop must not resolve the item that reports it.
  #
  # A give-up and a resolved item are reported through the callables it is
  # given, after the {AgentRecoveryStore#update} that decided them.
  class RecoveryIntake
    HANDLED_EVENTS = %w[turn_failed stop user_prompt tool_start tool_use subagent_start session_start session_end].freeze
    private_constant :HANDLED_EVENTS

    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param session_monitor [Workspace::SessionMonitor] rescans a pane and names its agent pid for the queue
    # @param facts [Workspace::RecoveryFacts] reads the agent in a pane
    # @param rebind_queue [#call] given a pane id and the monitor's agent pid, moves the pane's
    #   queued prompts to that agent
    # @param report_give_up [#call] given a pane id and the stored entry, reports a give-up
    # @param resolve [#call] given a session id, resolves its inbox item
    # @param max_attempts [Integer] attempts after which a failure gives up
    # @param clock [#now] time source
    # @param spawn [#call] runs the given block on its own thread
    # @param logger [Workspace::Logger] debug logger
    def initialize(store:, session_monitor:, facts:, report_give_up:, resolve:, rebind_queue: ->(_pane_id, _agent_pid) {},
      max_attempts: AgentRecoveryStore::MAX_ATTEMPTS, clock: Time, spawn: ->(&block) { Thread.new(&block) },
      logger: Workspace::Logger.new)
      @store = store
      @session_monitor = session_monitor
      @facts = facts
      @report_give_up = report_give_up
      @resolve = resolve
      @rebind_queue = rebind_queue
      @max_attempts = max_attempts
      @clock = clock
      @spawn = spawn
      @logger = logger
      @queue = []
      @queue_guard = Mutex.new
      @draining = false
    end

    # Takes in a hook event the daemon received. Only queues it; the work runs
    # on a worker thread, so the hook is answered at once.
    #
    # @param message [Hash] a "session_event" payload
    # @return [void]
    def session_event(message)
      return unless message["pane_id"].is_a?(String)
      return unless message["agent_id"] || HANDLED_EVENTS.include?(message["event"])

      start = @queue_guard.synchronize do
        @queue << message
        !@draining && (@draining = true)
      end
      start_worker if start
      nil
    end

    private

    def start_worker
      @spawn.call { drain }
    rescue => e
      @queue_guard.synchronize { @draining = false }
      quiet_debug { "agent recovery: could not start the worker (#{e.class}: #{e.message})" }
    end

    def drain
      while (message = next_message)
        begin
          take_in(message)
        rescue => e
          quiet_debug { "agent recovery: #{message["event"]} for #{message["pane_id"]} failed (#{e.class}: #{e.message})" }
        end
      end
    end

    # The worker's own logging: a logger that raises must not end it with
    # `@draining` still set, which would leave every later event unread.
    def quiet_debug(&block)
      @logger.debug(&block)
    rescue
      nil
    end

    # The check for an empty queue and the end of the worker are one step, so
    # an event queued just after can't be left with no worker.
    def next_message
      @queue_guard.synchronize do
        @draining = false if @queue.empty?
        @queue.shift
      end
    end

    def take_in(message)
      return stamp_subagent(message) if message["agent_id"]

      case message["event"]
      when "turn_failed" then turn_failed(message)
      when "stop" then turn_completed(message)
      when "user_prompt", "tool_start", "tool_use", "subagent_start" then agent_active(message)
      when "session_start" then session_started(message)
      when "session_end" then session_ended(message)
      end
    end

    def stamp_subagent(message)
      @store.update(message["pane_id"]) do |entry|
        entry["last_subagent_at"] = stamp if !entry.empty? && entry["session_id"] == message["session_id"]
      end
    end

    def turn_failed(message)
      session_id = message["session_id"]
      return unless session_id.to_s.match?(AgentResumeCommand::SESSION_ID)

      pane_id = message["pane_id"]
      live = @facts.live_agent(pane_id)
      seen = @store.get(pane_id)
      rebind(pane_id) if seen && seen["session_id"] == session_id && RecoveryEntry.agent_came_back?(seen, live)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        gave_up = RecoveryEntry.apply_failure(entry, session_id, message["error"], message["transcript_path"], live,
          max_attempts: @max_attempts, clock: @clock)
      end
      @report_give_up.call(pane_id, stored) if gave_up
    end

    def turn_completed(message)
      session_id = message["session_id"]
      finished = false
      @store.update(message["pane_id"]) do |entry|
        next if entry.empty? || entry["session_id"] != session_id
        if entry["phase"] == "attempting"
          entry["turn_completed"] = true
        else
          entry.clear
          finished = true
        end
      end
      @resolve.call(session_id) if finished
    end

    def agent_active(message)
      pane_id = message["pane_id"]
      seen = @store.get(pane_id)
      same = seen && seen["session_id"] == message["session_id"]
      live = @facts.live_agent(pane_id) if same && seen["stopped"] == true && %w[waiting watching].include?(seen["phase"])
      # Before the write that may end the hold, so no prune sees the old pid.
      rebind(pane_id) if same && RecoveryEntry.agent_came_back?(seen, live)
      @store.update(pane_id) do |entry|
        next if entry.empty? || entry["session_id"] != message["session_id"]
        if entry["phase"] == "attempting"
          entry["prompt_seen"] = true if message["event"] == "user_prompt"
        elsif %w[waiting watching].include?(entry["phase"])
          if RecoveryEntry.agent_came_back?(entry, live)
            entry["stopped"] = false
            RecoveryEntry.store_agent(entry, live)
          end
          entry.merge!("phase" => "watching", "defer_since" => nil) if entry["phase"] == "waiting" && entry["stopped"] != true
        end
      end
    end

    def session_started(message)
      pane_id = message["pane_id"]
      session_id = message["session_id"]
      forget_resumed_elsewhere(pane_id, session_id)
      seen = @store.get(pane_id)
      return unless seen

      open_phase = %w[waiting watching].include?(seen["phase"])
      same = seen["session_id"] == session_id
      live = @facts.live_agent(pane_id) if open_phase && same
      # Before the write that may end the hold, so no prune sees the old pid.
      rebind(pane_id) if open_phase && same && someone_resumed?(seen, live)

      gave_up = false
      stored = @store.update(pane_id) do |entry|
        gave_up = apply_session_start(entry, session_id, message["source"], live)
      end
      @report_give_up.call(pane_id, stored) if gave_up
      @resolve.call(seen["session_id"]) if stored.nil? && message["source"] == "clear"
    end

    # @return [Boolean] whether this gave up
    def apply_session_start(entry, session_id, source, live)
      case entry["phase"]
      when "attempting"
        entry["attempt_session_id"] = session_id
        # The new agent is known: what it does next owes nothing to our signal.
        RecoveryEntry.forget_signal(entry) if session_id == entry["session_id"]
      when "waiting", "watching"
        if entry["session_id"] != session_id
          return other_session_started(entry, source)
        end
        # Attempts run in `attempting`, so another agent here is someone else's resume, never to be signalled.
        entry.merge!("stopped" => false, "phase" => "watching", "defer_since" => nil) if someone_resumed?(entry, live)
        RecoveryEntry.store_agent(entry, live)
      end
      false
    end

    # Whether a same-id SessionStart outside an attempt is a new agent. After
    # attempts a blank pid proves it too: a `turn_failed` from a gone agent or a
    # failed `ps` can blank the stored one, and any agent here must not be signalled.
    def someone_resumed?(entry, live)
      return true if entry["stopped"] == true || RecoveryEntry.other_agent?(entry, live)
      !live.nil? && entry["agent_pid"].nil? && entry["attempts"].to_i.positive?
    end

    # A person or a workflow cleared the conversation, or no stop of ours came
    # before this session: nothing is left to report. After attempts, a slow
    # exit may have reached a `||` branch, and this is the last place to say so.
    def other_session_started(entry, source)
      if source == "clear" || RecoveryEntry.unreported?(entry)
        entry.clear
        return false
      end
      RecoveryEntry.give_up(entry, "fresh_conversation")
      true
    end

    # A stopped session opened in another pane must not be resumed twice. An
    # attempt holds its entry until its end, so it only gets the flag.
    def forget_resumed_elsewhere(pane_id, session_id)
      @store.entries.each do |other, seen|
        next if other == pane_id || seen["session_id"] != session_id
        item_open = false
        @store.update(other) do |entry|
          next unless entry["session_id"] == session_id && entry["phase"] != "gave_up" && entry["stopped"] == true
          next entry["resumed_elsewhere"] = true if entry["phase"] == "attempting"
          item_open = entry["item_open"] == true
          entry.clear
        end
        @resolve.call(session_id) if item_open
      end
    end

    # The queue compares the monitor's pid, which in an unwrapped pane is the
    # pane's shell and not the agent's own process.
    def rebind(pane_id)
      @session_monitor.rescan_pane(pane_id)
      agent_pid = @session_monitor.agent_pid(pane_id)
      @rebind_queue.call(pane_id, agent_pid) if agent_pid
    end

    # After attempts the count is reported, never dropped: a Stop has already
    # deleted the entry of an agent that finished a turn, so one still here ended
    # with its recovery unfinished. A `/clear` is a person moving on, as ever.
    def session_ended(message)
      deleted = gave_up = false
      stored = @store.update(message["pane_id"]) do |entry|
        next if entry.empty? || entry["session_id"] != message["session_id"]
        next unless %w[waiting watching].include?(entry["phase"]) && entry["stopped"] != true

        if entry["phase"] == "waiting" && RecoveryEntry.signalled_lately?(entry, @clock)
          entry["stopped"] = true
        elsif entry["attempts"].to_i.zero? || message["reason"] == "clear"
          entry.clear
          deleted = true
        else
          RecoveryEntry.give_up(entry, "unconfirmed")
          gave_up = true
        end
      end
      @resolve.call(message["session_id"]) if deleted
      @report_give_up.call(message["pane_id"], stored) if gave_up
    end

    def stamp
      AgentRecoveryStore.stamp(@clock.now)
    end
  end
end
