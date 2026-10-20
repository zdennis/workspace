module Workspace
  # The agent daemon's side of `agent-run send --when-idle`: it queues a
  # prompt for a coding-agent pane in the workspace's {PromptQueueStore} and
  # types it once the pane's turn has ended, one entry per turn end.
  #
  # {#deliver_next} is the only code that types queued text. Three things
  # start it: the send itself (an idle pane gets its text during the call),
  # a main-agent Stop hook ({#session_event}) and the monitor's scan
  # ({#scan}). For one pane it:
  #
  # 1. drops queued entries whose pane, tmux server, agent or conversation
  #    is no longer the one they were queued for, then claims the head entry
  #    in the store, only while {SessionMonitor#fresh_since} is later than
  #    the pane's last delivery and no restart holds the pane;
  # 2. waits for the screen to stay unchanged {QUIET_FOR}, outside every lock;
  # 3. under the delivery lock, checks the pane again: identity (a mismatch
  #    drops the entry), still `done` or `idle` since the same moment, no
  #    prompt submitted since;
  # 4. marks the paste as started in the store, unless a cancel was asked
  #    for (then nothing is typed);
  # 5. types through {PromptTyper};
  # 6. finishes the entry: removed once the text landed, back to `queued`
  #    when it never reached the pane or a check failed.
  #
  # An entry whose send answered `queued` is announced: `prompt_queued` is
  # recorded then, and `prompt_dequeued` when it leaves the queue. An entry
  # delivered during its own send reports on the call and records nothing.
  class PromptQueueDesk
    # How long the screen must stay unchanged before a queued prompt is typed.
    QUIET_FOR = AgentRestart::QUIET_FOR
    # Longest wait for that quiet; past it the entry stays queued.
    QUIET_TIMEOUT = 10
    # Seconds between screen reads while waiting for quiet.
    POLL_INTERVAL = 0.25

    # @param tmux [Workspace::Tmux] pane lookups, screen reads, server pids
    # @param session_name [String] the workspace's tmux session
    # @param workspace [String] the workspace the daemon serves, events are recorded under it
    # @param session_monitor [Workspace::SessionMonitor] pane facts and readiness
    # @param store [Workspace::PromptQueueStore] the workspace's queue
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param restarting [#call] given a pane id, whether a restart holds the pane
    # @param event_log [Workspace::EventLog, nil] where `prompt_queued` and `prompt_dequeued` go
    # @param typer [Workspace::PromptTyper, nil] nil builds one from +tmux+ and +session_monitor+
    # @param providers [Array<Workspace::AgentProvider>] the known agents
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    # @param spawn [#call] runs the given block on its own thread
    # @param daemon_pid [Integer] written into each claim
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, session_name:, workspace:, session_monitor:, store:, delivery_lock:,
      restarting: ->(_pane_id) { false }, event_log: nil, typer: nil, providers: AgentProvider.all,
      clock: Time, sleeper: ->(seconds) { sleep(seconds) }, spawn: ->(&block) { Thread.new(&block) },
      daemon_pid: Process.pid, logger: Workspace::Logger.new)
      @tmux = tmux
      @session_name = session_name
      @workspace = workspace
      @session_monitor = session_monitor
      @store = store
      @delivery_lock = delivery_lock
      @restarting = restarting
      @event_log = event_log
      @typer = typer || PromptTyper.new(tmux: tmux, session_monitor: session_monitor, logger: logger)
      @providers = providers
      @clock = clock
      @sleeper = sleeper
      @spawn = spawn
      @daemon_pid = daemon_pid
      @logger = logger
      @pane_locks = {}
      @pane_locks_guard = Mutex.new
    end

    # Handles a "prompt_send" message. Runs on a worker thread: when the
    # pane is ready the text is typed before the reply.
    #
    # @param message [Hash] carries "pane_id" and "text"
    # @return [Hash] `{"ok": true, "delivered": true, "submitted": true, ...}`,
    #   `{"ok": true, "queued": true, "id", "position", ...}`, or an error reply
    def send_prompt(message)
      pane_id = message["pane_id"]
      text = message["text"]
      unless text.is_a?(String) && !text.empty? && text.bytesize <= PromptQueueStore::MAX_BYTES
        return error("usage", "the text must be non-empty and at most #{PromptQueueStore::MAX_BYTES} bytes")
      end
      detail = pane_lookup(pane_id)
      return error("pane_not_ready", "tmux didn't list the session's panes; try again", "reason" => "unknown") if detail == :unknown
      return error("no_such_pane", "no pane #{pane_id.inspect} in tmux session #{@session_name}") unless detail
      context = {"pane" => "#{detail[:window]}.#{detail[:index]}", "pane_id" => pane_id}
      facts = @session_monitor.delivery_facts(pane_id)
      refused = refusal(pane_id, facts)
      return refused.merge(context) if refused

      # Without these a later restart of tmux or of the agent couldn't be told apart.
      server_pid = @tmux.server_pid_for_pane(pane_id)
      unless server_pid && facts[:agent_pid]
        return error("pane_not_ready", "the pane's tmux server or agent process can't be read yet; try again in a few seconds",
          "reason" => "unknown").merge(context)
      end
      identity = {"server_pid" => server_pid, "pane_pid" => detail[:pid],
                  "agent_pid" => facts[:agent_pid], "session_id" => facts[:session_id]}
      with_pane(pane_id) do
        outcome, entry = @store.add(pane_id: pane_id, text: text, identity: identity)
        if outcome == :queue_full
          next error("queue_full", "pane #{context["pane"]} already has #{PromptQueueStore::MAX_PER_PANE} prompts queued; nothing was queued",
            "limit" => PromptQueueStore::MAX_PER_PANE).merge(context)
        end

        result = (entry["position"] == 1) ? deliver_locked(pane_id) : nil
        send_reply(entry, result).merge(context)
      end
    end

    # Takes in a hook event the daemon received: binds a first-seen session
    # id to entries queued without one, drops the pane's queued entries when
    # its agent's session ended other than by a clear, and starts a delivery
    # when the main agent's turn ended. The work runs on its own thread, so
    # the hook is answered at once.
    #
    # @param message [Hash] a "session_event" payload
    # @return [void]
    def session_event(message)
      pane_id = message["pane_id"]
      return unless pane_id.is_a?(String)
      session_id = message["session_id"]
      # Most hook events carry the session id; a new conversation announces
      # itself with session_start, and each delivery binds it again first.
      bind = message["event"] == "session_start" && session_id.is_a?(String)
      ending = message["event"] == "session_end" && message["reason"] != "clear"
      turn_ended = message["event"] == "stop" && message["agent_id"].nil?
      return unless bind || ending || turn_ended

      @spawn.call do
        @store.bind_session(pane_id, session_id) if bind
        drop_all(pane_id, "session_ended") if ending
        deliver_next(pane_id) if turn_ended
      rescue => e
        @logger.debug { "prompt queue: hook event for #{pane_id} (#{e.class}: #{e.message})" }
      end
    end

    # Starts a delivery for every pane with entries whose last one isn't
    # still running, and which is ready or may have lost its agent or pane
    # (so its entries are dropped). A pane still at work costs no tmux call.
    #
    # @return [void]
    def scan
      @store.pane_ids.each do |pane_id|
        next if pane_lock(pane_id).locked?
        facts = @session_monitor.delivery_facts(pane_id)
        next if facts && facts[:kind] != "shell" && !facts[:fresh_since]
        @spawn.call { deliver_next(pane_id, wait: false) }
      end
    rescue Workspace::Error => e
      @logger.debug { "prompt queue: #{e.message}" }
    end

    # Delivers the pane's head entry if the pane is ready for it.
    #
    # @param pane_id [String]
    # @param wait [Boolean] wait for a delivery already running for the pane;
    #   false returns nil at once instead
    # @return [Hash, nil] what happened to the entry claimed (`:id`,
    #   `:outcome` and `:submitted` or `:reason`), or nil when none was claimed
    def deliver_next(pane_id, wait: true)
      lock = pane_lock(pane_id)
      return nil unless wait || lock.try_lock
      begin
        lock.lock if wait
        deliver_locked(pane_id)
      ensure
        lock.unlock if lock.owned?
      end
    rescue => e
      @logger.debug { "prompt queue: delivery to #{pane_id} failed (#{e.class}: #{e.message})" }
      nil
    end

    private

    def send_reply(entry, result)
      if result && result[:id] == entry["id"]
        case result[:outcome]
        when :delivered
          return {"ok" => true, "delivered" => true, "submitted" => true, "id" => entry["id"]}
        when :dropped
          if result[:reason] == "not_submitted" || result[:reason] == "interrupted"
            return error("not_submitted", "the prompt was pasted but not confirmed submitted: #{result[:message]}; " \
              "check the pane before sending it again", "id" => entry["id"], "delivered" => true, "submitted" => false)
          end
          return error("not_delivered", "the prompt was not typed: #{result[:reason]}", "id" => entry["id"], "reason" => result[:reason])
        when :cancelled
          return error("not_delivered", "the prompt was cancelled before it was typed", "id" => entry["id"], "reason" => "cancelled")
        end
      end

      announced = @store.announce(entry["id"])
      return error("not_delivered", "the prompt left the queue before it could be reported", "id" => entry["id"]) unless announced
      record(EventLog::PROMPT_QUEUED, "id" => entry["id"], "pane_id" => entry["pane_id"],
        "position" => announced["position"], "clear_first" => announced["clear_first"] == true)
      {"ok" => true, "queued" => true, "id" => entry["id"], "position" => announced["position"]}
    end

    def refusal(pane_id, facts)
      return error("pane_not_ready", "the agent daemon hasn't scanned this pane yet; try again in a few seconds", "reason" => "unknown") unless facts
      return error("not_an_agent", "the pane is running a shell, not a coding agent") if facts[:kind] == "shell"
      provider = @providers.find { |p| p.key == facts[:kind] }
      return error("pane_not_ready", "the agent daemon hasn't identified the agent in this pane yet", "reason" => "unknown") unless provider
      unless provider.ready_pattern
        return error("unsupported_agent", "#{provider.label}'s screen can't be checked for an open dialog or a draft, " \
          "so --when-idle only queues for Claude Code; nothing was queued", "kind" => provider.key)
      end
      typing = @session_monitor.typing_facts(pane_id)
      question = typing && (typing[:open_tools] & TypingSafety::QUESTION_TOOLS).first
      if typing&.dig(:state) == "waiting" || question
        why = question ? "is showing #{question}" : "is waiting on a permission prompt or a question"
        return error("pane_waiting", "#{provider.label} #{why}; a person must answer it first, so nothing was queued",
          "reason" => question ? "question_open" : "waiting")
      end
      nil
    end

    def deliver_locked(pane_id)
      prune(pane_id)
      entry, reaped = @store.claim(pane_id, daemon_pid: @daemon_pid) do
        @restarting.call(pane_id) ? nil : @session_monitor.fresh_since(pane_id)
      end
      reaped.each { |gone| dequeued(gone, "dropped", reason: "interrupted") }
      return nil unless entry

      deliver_claimed(pane_id, entry)
    end

    # Steps 2 to 6. Whatever happens, the entry doesn't stay `delivering`.
    def deliver_claimed(pane_id, entry)
      result = nil
      pasted = false
      begin
        result = finish(entry, :requeue, outcome: :requeued) unless wait_until_quiet(pane_id)
        result ||= @delivery_lock.synchronize do
          reason, detail = recheck(pane_id, entry)
          next finish(entry, :drop, outcome: :dropped, reason: reason) if reason && reason != :not_ready
          next finish(entry, :requeue, outcome: :requeued) if reason

          paste = nil
          typed = @typer.type(session_name: @session_name, target: "#{detail[:window]}.#{detail[:index]}", pane_id: pane_id,
            text: entry["text"], before_paste: -> { pasted = (paste = @store.start_paste(entry)) == :started })
          @logger.debug { "prompt queue: #{entry["id"]} to #{pane_id}: #{typed.outcome}" }
          case typed.outcome
          when :submitted then finish(entry, :delivered, outcome: :delivered, submitted: true)
          when :not_submitted
            finish(entry, :delivered, outcome: :dropped, reason: "not_submitted", submitted: false, message: typed.message)
          when :aborted
            @logger.debug { "prompt queue: #{entry["id"]} not pasted: the claim was #{paste}" }
            {id: entry["id"], outcome: (paste == :cancelled) ? :cancelled : :gone}
          else finish(entry, :requeue, outcome: :requeued)
          end
        end
      ensure
        result ||= pasted ? finish(entry, :drop, outcome: :dropped, reason: "interrupted") : finish(entry, :requeue, outcome: :requeued)
      end
      result
    end

    def finish(entry, how, outcome:, reason: nil, submitted: nil, message: nil)
      ended = @store.finish(entry, how)
      dequeued(ended, outcome.to_s, reason: reason, submitted: submitted) if ended && outcome != :requeued
      {id: entry["id"], outcome: outcome, reason: reason, submitted: submitted, message: message}
    end

    # The checks made again under the delivery lock, after the quiet wait.
    #
    # @return [Array] a drop reason, :not_ready or nil; and the pane's details
    def recheck(pane_id, entry)
      detail = pane_lookup(pane_id)
      return [:not_ready, nil] if detail == :unknown
      facts = @session_monitor.delivery_facts(pane_id)
      server_pid = detail && @tmux.server_pid_for_pane(pane_id)
      reason = identity_change(entry, detail, server_pid, facts)
      return [reason, detail] if reason
      return [:not_ready, detail] unless server_pid

      fresh = facts && PromptQueueStore.stamp(facts[:fresh_since])
      prompt = facts && facts[:last_user_prompt_at]
      ready = fresh && fresh == entry["claimed_fresh_since"] && (prompt.nil? || prompt <= facts[:fresh_since]) &&
        !@restarting.call(pane_id)
      [ready ? nil : :not_ready, detail]
    end

    # Why the entry can no longer go to this pane, or nil. What can't be
    # read (tmux not answering, the monitor not knowing an agent pid yet)
    # drops nothing.
    def identity_change(entry, detail, server_pid, facts)
      return nil if detail == :unknown
      return "pane_gone" unless detail && detail[:pid] == entry["pane_pid"]
      return "pane_gone" if server_pid && server_pid != entry["server_pid"]
      return nil unless facts
      return "session_ended" if facts[:kind] == "shell"
      return "session_ended" if facts[:agent_pid] && entry["agent_pid"] && facts[:agent_pid] != entry["agent_pid"]
      if entry["session_id"] && facts[:session_id] && facts[:session_id] != entry["session_id"] && !entry["clear_first"]
        return "conversation_changed"
      end
      nil
    end

    # Drops the pane's queued entries that can no longer go to it.
    def prune(pane_id)
      detail = pane_lookup(pane_id)
      server_pid = detail.is_a?(Hash) ? @tmux.server_pid_for_pane(pane_id) : nil
      facts = @session_monitor.delivery_facts(pane_id)
      @store.bind_session(pane_id, facts[:session_id]) if facts&.dig(:session_id)
      @store.drop_queued(pane_id) { |entry| identity_change(entry, detail, server_pid, facts) }
        .each { |gone, reason| dequeued(gone, "dropped", reason: reason) }
    end

    def drop_all(pane_id, reason)
      @store.drop_queued(pane_id) { reason }.each { |gone, why| dequeued(gone, "dropped", reason: why) }
    end

    # @return [Boolean] false when the screen never stayed unchanged
    #   {QUIET_FOR} within {QUIET_TIMEOUT}; true otherwise, including a
    #   pane that can't be read, which the re-check then deals with
    def wait_until_quiet(pane_id)
      deadline = @clock.now + QUIET_TIMEOUT
      screen = nil
      quiet_since = nil
      loop do
        current = @tmux.capture_screen(pane_id)
        return true if current.nil?
        now = @clock.now
        if current != screen
          screen = current
          quiet_since = now
        elsif now - quiet_since >= QUIET_FOR
          return true
        end
        return false if now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    def dequeued(entry, outcome, reason: nil, submitted: nil)
      return unless entry["announced"]
      data = {"id" => entry["id"], "pane_id" => entry["pane_id"], "outcome" => outcome}
      data["reason"] = reason if reason
      data["submitted"] = submitted unless submitted.nil?
      record(EventLog::PROMPT_DEQUEUED, data)
    end

    def record(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end

    def pane_detail(pane_id)
      found = pane_lookup(pane_id)
      found.is_a?(Hash) ? found : nil
    end

    # The pane's details, nil when the session doesn't have it, or
    # :unknown when tmux listed no pane at all (it failed, or the session is
    # gone): a failed tmux call must not read as every pane gone.
    def pane_lookup(pane_id)
      return nil unless pane_id.is_a?(String)
      details = @tmux.pane_details(@session_name, window: nil)
      return :unknown if details.empty?
      details.find { |d| d[:id] == pane_id }
    end

    def with_pane(pane_id, &block)
      pane_lock(pane_id).synchronize(&block)
    end

    def pane_lock(pane_id)
      @pane_locks_guard.synchronize { @pane_locks[pane_id] ||= Mutex.new }
    end

    def error(code, message, extra = {})
      {"ok" => false, "error" => code, "message" => message}.merge(extra)
    end
  end
end
