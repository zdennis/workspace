module Workspace
  # Follows up on a handoff prompt that landed in a Claude Code pane and then
  # went nowhere. {#arm} opens one watch per pane; while the pane sits quiet
  # with no handoff, {#poll} types the follow-up once per interval through
  # {PromptTyper}, under the daemon's delivery lock. Activity only pushes the
  # next follow-up back. A watch ends on `/clear` (`carried_out`), on a prompt
  # that isn't ours (`other_prompt`), when the session changes or ends, the
  # pane goes, the plan is paused, a follow-up can't be confirmed
  # (`not_submitted`), or the tries or {MAX_AGE} run out.
  #
  # Prompts are told apart by fingerprint, so neither when nor whether Claude
  # Code reports a queued save-state prompt matters. Watches live in memory: a
  # daemon restart drops them.
  #
  # The thread follows {SpineWatcher}. The watcher's mutex guards the watches
  # and is never held while typing or while taking the delivery lock.
  class HandoffWatcher
    # Seconds between looks at {#stop}.
    TICK = 0.25

    # Seconds between polls.
    POLL_EVERY = 5

    # Seconds a watch lasts from its first arm.
    MAX_AGE = 60 * 60

    # Seconds {#stop} waits for the thread: longer than one typing sequence, so
    # a stop can't land between the paste and Enter.
    STOP_WAIT = 10

    # Characters of a cleaned prompt a fingerprint keeps.
    FINGERPRINT_LENGTH = 120

    # Seconds a pane's agent pid may differ from the watch's before the watch
    # ends. {SessionMonitor#followup_facts} serves the last scan, so polls alone
    # can't tell a brief flap from a change.
    AGENT_CHANGE_GRACE = 30

    # The end reasons {#finish} alerts for.
    ALERTED = %w[stalled expired].freeze
    private_constant :ALERTED

    # What {PromptTyper} reports when the text is or may be in the pane.
    LANDED = [:submitted, :not_submitted].freeze
    private_constant :LANDED

    Watch = Struct.new(:pane_id, :pane_pid, :agent_pid, :session_id, :armed_at, :sent_at, :interval, :max, :text, :fingerprints,
      :tries, :last_sent_at, :held_at, :agent_changed_at, keyword_init: true)
    private_constant :Watch

    # @param tmux [Workspace::Tmux] pane lookups
    # @param session_name [String] the workspace's tmux session
    # @param workspace [String] the workspace the daemon serves
    # @param session_monitor [Workspace::SessionMonitor] pane facts and the stall alert
    # @param typer [Workspace::PromptTyper] checks the pane and types the follow-up
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param restarting [#call] given a pane id, whether a restart holds the pane
    # @param plan_paused [#call] whether the workspace's plan is paused
    # @param event_log [Workspace::EventLog, nil] gets the watch's events
    # @param clock [#call] returns the current Time
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, session_name:, workspace:, session_monitor:, typer:, delivery_lock:,
      restarting: ->(_pane_id) { false }, plan_paused: -> { false }, event_log: nil, clock: -> { Time.now },
      logger: Workspace::Logger.new)
      @tmux = tmux
      @session_name = session_name
      @workspace = workspace
      @session_monitor = session_monitor
      @typer = typer
      @delivery_lock = delivery_lock
      @restarting = restarting
      @plan_paused = plan_paused
      @event_log = event_log
      @clock = clock
      @logger = logger
      @mutex = Mutex.new
      @watches = {}
      @thread = nil
      @stopping = false
    end

    # Starts the watch thread.
    #
    # @return [void]
    def start
      return if @thread
      @thread = Thread.new do
        ticks = 0
        until @stopping
          sleep TICK
          ticks += 1
          next if ticks * TICK < POLL_EVERY
          ticks = 0
          begin
            poll
          rescue => e
            @logger.debug { "handoff watch: #{e.class}: #{e.message}" }
          end
        end
      end
    end

    # Stops the watch thread. An idle thread ends within one {TICK}; a typing
    # sequence in flight is left to finish, for up to {STOP_WAIT}.
    #
    # @return [void]
    def stop
      @stopping = true
      @thread&.join(STOP_WAIT)
      @thread&.kill
      @thread = nil
    end

    # Opens a watch on a pane, or for a pane already watched updates its
    # settings and text, adds to its fingerprints and moves +sent_at+ forward.
    # The first arm's time, the tries and the last follow-up stay, so running
    # `handoff check` again can't reset the cap or the hour. A different process,
    # agent or conversation in the pane is not a repeat: the old watch ends
    # (`pane_gone` or `session_changed`) and a new one opens.
    #
    # @param pane_id [String] tmux pane id
    # @param sent_at [Time] when the save-state prompt was typed; a later time counts as now
    # @param interval [Numeric] seconds of quiet before a follow-up
    # @param max [Integer] follow-ups before the watch ends `stalled`
    # @param text [String] the follow-up prompt
    # @param sent_text [String] the save-state prompt as typed
    # @return [Hash] `:watching`, and `:reason` (`invalid`, `not_scanned`,
    #   `not_claude`, `no_hooks`) when it is false
    def arm(pane_id:, sent_at:, interval:, max:, text:, sent_text:)
      return {watching: false, reason: "invalid"} unless valid_settings?(sent_at, interval, max)
      facts = @session_monitor.followup_facts(pane_id)
      refused = refusal(facts)
      return {watching: false, reason: refused} if refused

      now = @clock.call
      sent_at = [sent_at, now].min
      fingerprints = [text, sent_text].filter_map { |prompt| fingerprint(prompt) }
      replaced = change = nil
      opened = @mutex.synchronize do
        watch = @watches[pane_id]
        change = watch && identity_change(watch, facts)
        if watch && !change
          watch.sent_at = [watch.sent_at, sent_at].max
          watch.interval = interval
          watch.max = max
          watch.text = text
          watch.fingerprints |= fingerprints
          next false
        end
        replaced = watch
        @watches[pane_id] = Watch.new(pane_id: pane_id, pane_pid: facts[:pane_pid], agent_pid: facts[:agent_pid],
          session_id: facts[:session_id], armed_at: now, sent_at: sent_at, interval: interval, max: max, text: text,
          fingerprints: fingerprints, tries: 0)
        true
      end
      record_end(replaced, change) if replaced
      record(EventLog::HANDOFF_WATCH_STARTED, "pane_id" => pane_id) if opened
      {watching: true, reason: nil}
    end

    # Reads a main agent's hook event. A sub-agent's is ignored.
    #
    # @param message [Hash] a "session_event" message
    # @return [void]
    def session_event(message)
      return if message["agent_id"]
      watch = @mutex.synchronize { @watches[message["pane_id"]] }
      return unless watch
      case message["event"]
      when "user_prompt" then finish(watch, "other_prompt") if other_prompt?(watch, message["prompt"])
      when "session_start" then finish(watch, (message["source"] == "clear") ? "carried_out" : "session_changed")
      when "session_end" then finish(watch, "session_ended") unless message["reason"] == "clear"
      end
    end

    # One look at each watch: ends it, holds it, or types a due follow-up. A
    # watch that raises is logged and doesn't keep the others from their turn.
    #
    # @return [void]
    def poll
      @mutex.synchronize { @watches.values }.each do |watch|
        break if @stopping
        begin
          check(watch)
        rescue => e
          @logger.debug { "handoff watch: #{watch.pane_id}: #{e.class}: #{e.message}" }
        end
      end
    end

    private

    def valid_settings?(sent_at, interval, max)
      sent_at.is_a?(Time) && interval.is_a?(Numeric) && interval.positive? && max.is_a?(Integer) && max.positive?
    end

    def refusal(facts)
      return "not_scanned" unless facts
      return "not_claude" unless facts[:kind] == "claude"
      "no_hooks" unless facts[:hooks]
    end

    # @return [String, nil] the end reason for a pane no longer running what the watch was armed on
    def identity_change(watch, facts)
      return "pane_gone" unless facts[:pane_pid] == watch.pane_pid && facts[:agent_pid] == watch.agent_pid
      "session_changed" if session_moved?(watch, facts)
    end

    def session_moved?(watch, facts)
      watch.session_id && facts[:session_id] && watch.session_id != facts[:session_id]
    end

    # `:cut` says the prompt ran past {FINGERPRINT_LENGTH}, so only a prompt
    # starting with `:print` can be it. A short prompt must match whole, or a
    # save-state of "continue" would pass a person's "continue with the migration".
    def fingerprint(prompt)
      cleaned = SessionMonitor.clean_message(prompt)
      cleaned && {print: cleaned[0, FINGERPRINT_LENGTH], cut: cleaned.length > FINGERPRINT_LENGTH}
    end

    # No prompt string and the paste placeholder can't be told from ours, so
    # neither counts as another prompt.
    def other_prompt?(watch, prompt)
      cleaned = SessionMonitor.clean_message(prompt)
      return false if cleaned.nil? || cleaned.match?(/\A#{Tmux::PASTE_PLACEHOLDER.source}/)
      @mutex.synchronize do
        watch.fingerprints.none? { |print| print[:cut] ? cleaned.start_with?(print[:print]) : cleaned == print[:print] }
      end
    end

    def check(watch)
      now = @clock.call
      facts = @session_monitor.followup_facts(watch.pane_id)
      return finish(watch, "pane_gone") unless facts && facts[:pane_pid] == watch.pane_pid
      return finish(watch, "session_changed") if session_moved?(watch, facts)
      if facts[:agent_pid] != watch.agent_pid
        since = @mutex.synchronize { watch.agent_changed_at ||= now }
        return finish(watch, "pane_gone") if now - since >= AGENT_CHANGE_GRACE
        return
      end
      @mutex.synchronize { watch.agent_changed_at = nil }
      return finish(watch, "plan_paused") if @plan_paused.call

      state = @mutex.synchronize { watch.dup }
      return finish(watch, "expired") if now - state.armed_at > MAX_AGE
      return hold(watch, now) if @restarting.call(watch.pane_id)
      return unless quiet?(state, facts, now)
      return finish(watch, "stalled") if state.tries >= state.max
      follow_up(watch)
    end

    def hold(watch, now)
      @mutex.synchronize { watch.held_at = now }
    end

    def quiet?(state, facts, now)
      return false if facts[:open_tools].positive? || facts[:agents_running].positive?
      quiet_since = [state.sent_at, state.last_sent_at, state.held_at, facts[:last_activity_at]].compact.max
      now - quiet_since >= state.interval
    end

    def follow_up(watch)
      outcome = type_followup(watch)
      @logger.debug { "handoff watch: follow-up in #{watch.pane_id}: #{outcome}" }
      return if outcome == :aborted
      return finish(watch, "pane_gone") if outcome == :pane_gone

      now = @clock.call
      closed = false
      attempt = @mutex.synchronize do
        closed = !@watches[watch.pane_id].equal?(watch)
        next watch.tries + 1 if closed
        @watches.delete(watch.pane_id) if outcome == :not_submitted
        watch.last_sent_at = now
        watch.tries += 1
      end
      return if closed && !LANDED.include?(outcome)
      record(EventLog::HANDOFF_FOLLOWUP, "pane_id" => watch.pane_id, "attempt" => attempt, "outcome" => outcome.to_s)
      return unless outcome == :not_submitted
      record_end(watch, "not_submitted") unless closed
      alert(watch, attempt)
    end

    # The tests are made again under the lock and right before the paste, since
    # the wait for the lock can outlast them. A raise in the typing counts as a
    # try, so the interval and the cap still apply.
    def type_followup(watch)
      pane_id = watch.pane_id
      @delivery_lock.synchronize do
        next :aborted unless may_type?(watch)
        detail = pane_detail(pane_id)
        next :pane_gone unless detail && detail[:pid] == watch.pane_pid

        text = @mutex.synchronize { watch.text }
        begin
          @typer.type(session_name: @session_name, target: "#{detail[:window]}.#{detail[:index]}", pane_id: pane_id,
            text: text, before_paste: -> { may_type?(watch) }).outcome
        rescue => e
          @logger.debug { "handoff watch: typing in #{pane_id}: #{e.class}: #{e.message}" }
          :raised
        end
      end
    end

    # Whether a follow-up is still wanted, on fresh facts. This can't catch
    # another delivery whose text just went in: its `user_prompt` hook may not
    # have arrived, and until a scan sees the screen change `last_activity_at`
    # hasn't moved, so a follow-up can still land right behind it.
    def may_type?(watch)
      return false if @stopping || !open?(watch)
      now = @clock.call
      if @restarting.call(watch.pane_id)
        hold(watch, now)
        return false
      end
      facts = @session_monitor.followup_facts(watch.pane_id)
      return false unless facts
      state = @mutex.synchronize { watch.dup }
      !identity_change(state, facts) && quiet?(state, facts, now)
    end

    def open?(watch)
      @mutex.synchronize { @watches[watch.pane_id].equal?(watch) }
    end

    def pane_detail(pane_id)
      @tmux.pane_details(@session_name, window: nil).find { |d| d[:id] == pane_id }
    end

    # Only the caller that takes the watch out writes the event and sends the
    # alert, so each happens once whichever thread gets there first. The one
    # end the poll thread doesn't reach here, `not_submitted`, is `follow_up`'s.
    def finish(watch, reason)
      removed = @mutex.synchronize do
        @watches[watch.pane_id].equal?(watch) && @watches.delete(watch.pane_id)
      end
      return unless removed
      record_end(watch, reason)
      alert(watch, watch.tries) if ALERTED.include?(reason)
    end

    def alert(watch, followups)
      @session_monitor.alert_handoff_stalled(watch.pane_id, seconds: @clock.call - watch.armed_at, followups: followups)
    end

    def record_end(watch, reason)
      record(EventLog::HANDOFF_WATCH_ENDED, "pane_id" => watch.pane_id, "reason" => reason, "tries" => watch.tries)
    end

    def record(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end
  end
end
