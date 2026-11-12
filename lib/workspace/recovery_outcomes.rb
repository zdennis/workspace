module Workspace
  # What comes of a recovery desk's check or attempt, written to the entry and
  # reported. {#refuse} acts on a {AgentRecoveryDesk#check} answer but `:go`:
  # a defer costs no attempt and gives up `deferred` after {DEFER_LIMIT}
  # seconds of it, a clear deletes the entry while no attempt was made and
  # gives up `unconfirmed` after one, and `:never` gives up `cannot_restart`.
  # {#finish} is an attempt's step 6 and {#take_back} undoes a step 1 whose
  # signal never went out.
  #
  # A give-up is one `agent_recovery_gave_up` line and one inbox item
  # ({#report_give_up}), a finished attempt one `agent_recovery_attempt` line;
  # each is written after the {AgentRecoveryStore#update} that decided it.
  class RecoveryOutcomes
    # Seconds of unbroken deferring before giving up.
    DEFER_LIMIT = 1800

    # Event log line for a finished attempt.
    ATTEMPT_EVENT = "agent_recovery_attempt"

    # Event log line for a give-up.
    GAVE_UP_EVENT = "agent_recovery_gave_up"

    # Outcomes that may leave our text in the agent's input line.
    DRAFT_OUTCOMES = %w[not_submitted no_response].freeze
    private_constant :DRAFT_OUTCOMES

    # What hooks and step 3 leave on an entry for the end of an attempt.
    ATTEMPT_FIELDS = %w[turn_completed failed_during_attempt resumed_elsewhere attempt_session_id prompt_seen].freeze
    private_constant :ATTEMPT_FIELDS

    GIVE_UP_BODIES = {
      "attempts_exhausted" => "The API kept failing (%<error>s) through %<attempts>d recovery attempts, so workspace stopped trying.",
      "not_retryable" => "The turn failed with %<error>s, which trying again won't fix, so workspace won't try again.",
      "cannot_restart" => "The turn failed with %<error>s and workspace can't restart this pane: it has its own start command, " \
        "something other than a shell runs the agent, or the transcript is gone.",
      "fresh_conversation" => "A new conversation started in the pane in place of the one that failed (%<error>s). " \
        "Nothing was typed into it.",
      "deferred" => "The turn failed with %<error>s, and the pane stayed busy or unreadable for 30 minutes, so workspace " \
        "stopped trying. Nothing was stopped or typed in those 30 minutes.",
      "unconfirmed" => "After %<attempts>d recovery attempts workspace can no longer confirm the turn ended on the error " \
        "(%<error>s), so it stopped trying.",
      "unconfirmed_no_attempts" => "A turn failed with %<cause>s, then with %<error>s, and workspace can no longer confirm that " \
        "last failure, so it stopped watching. No recovery attempt was made."
    }.freeze
    private_constant :GIVE_UP_BODIES

    # @param workspace [String] the workspace the daemon serves; events and items go under it
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param facts [Workspace::RecoveryFacts] reads the agent in the pane at an attempt's end
    # @param inbox [#call] answers the workspace's {InboxStore}
    # @param runner [Workspace::RecoveryAttemptRunner] moves a pane's queued prompts to an agent found at the end
    # @param event_log [Workspace::EventLog, nil] where attempts and give-ups are recorded
    # @param max_attempts [Integer] attempts after which an attempt's end gives up
    # @param clock [#now] time source
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, store:, facts:, inbox:, runner:, event_log: nil, max_attempts: AgentRecoveryStore::MAX_ATTEMPTS,
      clock: Time, logger: Workspace::Logger.new)
      @workspace = workspace
      @store = store
      @facts = facts
      @inbox = inbox
      @runner = runner
      @event_log = event_log
      @max_attempts = max_attempts
      @clock = clock
      @logger = logger
    end

    # Acts on any {AgentRecoveryDesk#check} answer but `:go`, for the entry the
    # check read; an entry a hook changed since is left alone.
    #
    # @param pane_id [String]
    # @param seen [Hash] the entry the check read
    # @param answer [Symbol] +:defer+, +:clear+ or +:never+
    # @return [Object] what the write answered
    def refuse(pane_id, seen, answer)
      case answer
      when :defer then defer(pane_id, seen)
      when :clear then clear(pane_id, seen)
      when :never then give_up(pane_id, seen, "cannot_restart")
      end
    end

    # `:clear`, with one meaning everywhere: the entry goes while no attempt
    # was made, and after attempts the count is reported, never dropped.
    #
    # @param pane_id [String]
    # @param seen [Hash] the entry the decision read
    # @return [Object] what the write answered
    def clear(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        if RecoveryEntry.unreported?(entry)
          entry.clear
        else
          RecoveryEntry.give_up(entry, "unconfirmed")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # An inbox that can't be written must not end the worker or the scan: the
    # entry is `gave_up` by now and the event line says so.
    #
    # @param pane_id [String]
    # @param entry [Hash] the stored entry that gave up
    # @return [Object] what resolving a stale item answered, or nil
    def report_give_up(pane_id, entry)
      record(GAVE_UP_EVENT, "pane_id" => pane_id, "session_id" => entry["session_id"], "attempts" => entry["attempts"],
        "error" => entry["error"], "reason" => entry["give_up_reason"])
      @inbox.call.upsert(inbox_item(pane_id, entry), reopen: true)
      # A Stop may have come between the record and the item.
      current = @store.get(pane_id)
      resolve(entry["session_id"]) unless current && current["session_id"] == entry["session_id"]
    rescue Workspace::Error, SystemCallError => e
      @logger.debug { "agent recovery: no inbox item for #{pane_id} (#{e.class}: #{e.message})" }
    end

    # @param session_id [String]
    # @return [Object] the inbox's answer, or nil when it can't be written
    def resolve(session_id)
      @inbox.call.transition_by_key(inbox_key(session_id), to: "done", by: {"kind" => "agent_recovery"})
    rescue Workspace::Error, SystemCallError => e
      @logger.debug { "agent recovery: inbox item for #{session_id} not resolved (#{e.class}: #{e.message})" }
    end

    # Step 6: one update, so it can't overwrite a hook's write, then the line.
    # The queue moves before the update ends the hold, so no prune sees the old
    # pid. An entry that isn't this attempt's any more was picked up by
    # {RecoveryConfirmer#reconcile}, which wrote the line. A kill waits for the end of the span,
    # so a `gave_up` entry always gets its line and inbox item.
    #
    # @param attempt [RecoveryAttemptRunner::Attempt]
    # @param outcome [String]
    # @param agent [Hash, nil] with `person_resumed`, the agent found
    # @return [void]
    def finish(attempt, outcome, agent: nil)
      pane_id = attempt.pane_id
      live = agent || ((outcome == "fresh_agent") ? :unread : last_read(pane_id))
      @runner.rebind(pane_id) if live.is_a?(Hash) && !attempt.ours?(live)

      Thread.handle_interrupt(Object => :never) do
        seen = row = nil
        stored = @store.update(pane_id) do |entry|
          next unless attempt.current?(entry)
          seen = entry.dup
          row = hook_row(entry, live)
          next if row

          outcome = "agent_left" if live.nil? && %w[resumed typed].include?(outcome)
          row = close_attempt(entry, attempt, outcome, live)
        end
        next unless seen

        record(ATTEMPT_EVENT, "attempt" => attempt.number, "session_id" => attempt.session_id, "pane_id" => pane_id,
          "error" => seen["error"], "mode" => attempt.mode, "outcome" => outcome)
        close_row(attempt, row, stored)
      end
    end

    # No signal went out, so the attempt never happened: the entry goes back to
    # how step 1 found it, `defer_since` included, so the defer limit still
    # runs. What a hook wrote meanwhile is honoured as step 6 would.
    #
    # An empty pane answers `:clear`, so no entry waits with no agent, unless an
    # earlier signal may explain it.
    #
    # @param attempt [RecoveryAttemptRunner::Attempt]
    # @param seen [Hash] the entry step 1 read
    # @param answer [Symbol] what to act on when the pane still has an agent
    # @return [Symbol] the answer to act on; it finds a changed entry and does nothing
    def take_back(attempt, seen, answer)
      live = last_read(attempt.pane_id)
      row = nil
      restored = %w[phase attempts stopped last_signal_at defer_since].to_h { |key| [key, seen[key]] }
      stored = @store.update(attempt.pane_id) do |entry|
        next unless attempt.current?(entry)
        entry.merge!(restored)
        row = hook_row(entry, live)
      end
      close_row(attempt, row, stored)
      (RecoveryEntry.agent_gone?(seen, live) && !RecoveryEntry.signalled_lately?(seen, @clock)) ? :clear : answer
    end

    private

    def defer(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        since = RecoveryVerdicts.time_of(entry["defer_since"])
        if since.nil?
          entry["defer_since"] = AgentRecoveryStore.stamp(@clock.now)
        elsif @clock.now - since >= DEFER_LIMIT
          RecoveryEntry.give_up(entry, "deferred")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    def give_up(pane_id, seen, reason)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless RecoveryEntry.same_wait?(entry, seen)
        RecoveryEntry.give_up(entry, reason)
        gave_up = true
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # @return [Symbol, nil] +:resolved+, +:gave_up+, or nil when there is nothing to report
    def close_attempt(entry, attempt, outcome, live)
      case outcome
      when "resumed" then entry.merge!("phase" => "watching", "last_signal_at" => nil, "draft_text" => nil)
      when "typed"
        entry["phase"] = "watching"
        entry["draft_text"] = nil
      when "person_resumed"
        entry.merge!("phase" => "watching", "stopped" => false, "last_signal_at" => nil, "draft_text" => nil)
        RecoveryEntry.store_agent(entry, live)
      when "fresh_agent"
        RecoveryEntry.give_up(entry, "fresh_conversation")
        return :gave_up
      else
        RecoveryEntry.apply_read(entry, live)
        entry["draft_text"] = attempt.message if DRAFT_OUTCOMES.include?(outcome)
        if RecoveryEntry.agent_gone?(entry, live)
          RecoveryEntry.give_up(entry, "unconfirmed")
          return :gave_up
        end
        return :gave_up if RecoveryEntry.schedule_next(entry, max_attempts: @max_attempts, clock: @clock)
      end
      nil
    end

    # What hooks left for the end of the attempt, ahead of its outcome. Clears
    # the attempt's fields either way.
    #
    # @return [Symbol, nil] +:resolved+, +:gave_up+, +:rescheduled+, or nil when no hook decides
    def hook_row(entry, live)
      finished = entry["turn_completed"] == true || entry["resumed_elsewhere"] == true
      failed = entry["failed_during_attempt"] == true
      opened = entry["attempt_session_id"]
      ATTEMPT_FIELDS.each { |key| entry.delete(key) }
      if finished
        entry.clear
        return :resolved
      end
      if opened && opened != entry["session_id"]
        RecoveryEntry.give_up(entry, "fresh_conversation")
        return :gave_up
      end
      return nil unless failed

      RecoveryEntry.apply_read(entry, live)
      entry["phase"] = "watching"
      known = (live == :unread) ? {pid: entry["agent_pid"], started: entry["agent_started"], flags: entry["agent_flags"]} : live
      return :gave_up if RecoveryEntry.apply_failure(entry, entry["session_id"], entry["error"], entry["transcript_path"], known,
        max_attempts: @max_attempts, clock: @clock)
      return :rescheduled unless RecoveryEntry.agent_gone?(entry, live)

      RecoveryEntry.give_up(entry, "unconfirmed")
      :gave_up
    end

    def close_row(attempt, row, stored)
      resolve(attempt.session_id) if row == :resolved
      report_give_up(attempt.pane_id, stored) if row == :gave_up
    end

    # @return [Hash, nil, Symbol] the agent in the pane, nil when there is none
    #   or the pane is gone, or :unread when tmux or the process table can't be read
    def last_read(pane_id)
      detail = @facts.pane_detail(pane_id)
      return (@facts.tree.nil? || detail == :unknown) ? :unread : nil unless detail.is_a?(Hash)
      reading = @facts.agent(detail)
      reading ? reading.found : :unread
    end

    def inbox_item(pane_id, entry)
      attempts = entry["attempts"].to_i
      error = entry["error"] || "an unnamed error"
      reason = (entry["give_up_reason"] == "unconfirmed" && attempts.zero?) ? "unconfirmed_no_attempts" : entry["give_up_reason"]
      body = format(GIVE_UP_BODIES.fetch(reason), error: error, cause: entry["item_error"] || error, attempts: attempts)
      {
        "type" => "alert",
        "scope" => {"kind" => "workspace", "key" => @workspace, "name" => @workspace},
        "title" => "The agent in pane #{pane_id} needs you: workspace could not recover it from an API error",
        "body" => "#{body} Session #{entry["session_id"]}.",
        "source" => {"kind" => "session", "ref" => entry["session_id"], "url" => nil},
        "dedupe_key" => inbox_key(entry["session_id"]),
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"pane" => pane_id},
        "expires_at" => nil,
        "note" => nil
      }
    end

    def inbox_key(session_id)
      "agent-recovery:#{session_id}"
    end

    def record(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end
  end
end
