module Workspace
  # The agent daemon's side of recovering a Claude Code agent whose turn ended
  # on an API error. It keeps one {AgentRecoveryStore} entry per pane, schedules
  # attempts, and gives up with one inbox item.
  #
  # {#session_event} only queues the hook event: one worker at a time takes the
  # queue in order, so the accept loop takes no file lock and runs no `ps`, and
  # a pane's events can't overtake each other. The worker reads an entry's
  # `phase` first, so an attempt's own events are never read as a person's.
  # Unless a rule says otherwise, an event from a session other than the
  # entry's is ignored: a fresh agent's Stop must not resolve the item that
  # reports it.
  #
  # {#scan}, on the monitor's scan thread, confirms a failure against the
  # transcript once {SETTLE} seconds have passed, runs {#check} on the entries
  # that are due, and picks up an attempt the daemon lost when it restarted.
  #
  # {#check} answers one of four things, and only `:go` starts an attempt:
  #
  # * `:go` — every condition holds. `mode` says which attempt: `:typed` with
  #   `attempts` 0, `:restart` after that, `:resume_only` when the agent is
  #   already gone.
  # * `:defer` — something may clear. It costs no attempt, and {DEFER_LIMIT}
  #   seconds of unbroken deferring gives up with reason `deferred`.
  # * `:clear` — the failure can't be confirmed any more. With `attempts` 0 the
  #   entry is deleted; above 0 it gives up with reason `unconfirmed`, so a
  #   count never vanishes without a word.
  # * `:never` — this pane can't be restarted: give up with reason
  #   `cannot_restart`.
  #
  # Whatever can't be read leaves the agent alone. That includes an agent in a
  # pane outside window 0, which always defers, because the monitor scans
  # window 0 only and so has no facts for it.
  #
  # A restart runs on its own thread, inside a claim on the pane: it stops the
  # agent, types the resume command, waits for the agent and types a message,
  # then one {AgentRecoveryStore#update} ends the attempt. A failed attempt
  # counts toward {AgentRecoveryStore::MAX_ATTEMPTS}, so nothing repeats
  # without bound. The only signal is one SIGINT per attempt, through
  # {AgentStopper#stop}. There is no escalation: any other signal starts a new,
  # empty conversation in a `claude ... || claude` pane.
  class AgentRecoveryDesk
    # The `error` kinds that go on the attempt schedule; any other gives up at once.
    RETRYABLE_ERRORS = %w[server_error overloaded rate_limit unknown].freeze

    # Seconds after the failure before the transcript is read: Claude Code may
    # still recover by itself, and the error line may follow the hook.
    SETTLE = 30

    # Seconds of unbroken deferring before giving up.
    DEFER_LIMIT = 1800

    # Seconds with no sub-agent event after which a sub-agent still recorded as
    # running stops holding off an attempt: an outage can kill one before it
    # sends SubagentStop.
    SUBAGENT_QUIET = 600

    # How long the screen must stay unchanged to count as quiet.
    QUIET_FOR = AgentRestart::QUIET_FOR

    # What Claude Code shows while it is retrying by itself, or still working.
    BUSY_SCREEN = /Retrying in|esc to interrupt/

    # Seconds a stopped agent has to leave the pane, read once a second.
    STOP_WAIT = 15

    # Reads in a row that must find the pane clear: on one, the wrapper may
    # have only just exited, or the `||` branch may be about to start.
    CLEAR_READS = 2

    # Seconds to wait for the SessionStart that names an agent's session.
    SESSION_WAIT = 10

    # Seconds a resumed agent has to show its prompt.
    READY_WAIT = 60

    # How many times the message is tried while the pane's state is unknown.
    TYPE_TRIES = 20

    # Seconds between polls and between typing tries.
    POLL_INTERVAL = 1

    # What the agent is told once it has been resumed.
    RESUMED_MESSAGE = "An API error stopped your last turn (%<error>s), so workspace restarted Claude Code and resumed this " \
      "conversation. Locks your old process held were released, so take them again before you use them. A dev server " \
      "started with `workspace dev up` is still running and keeps its lock. Continue where you left off."

    # Event log line for a finished attempt.
    ATTEMPT_EVENT = "agent_recovery_attempt"

    # Event log line for a give-up.
    GAVE_UP_EVENT = "agent_recovery_gave_up"

    # What {#check} answers.
    #
    # * +answer+ — +:go+, +:defer+, +:clear+ or +:never+
    # * +mode+ — with +:go+, +:typed+, +:restart+ or +:resume_only+
    # * +command+ — with +:go+ and a restart, the resume line to type
    Verdict = Struct.new(:answer, :mode, :command, keyword_init: true)

    # One attempt under way.
    #
    # * +mode+ — the event line's mode, "typed" or "restart"
    # * +number+ — the entry's `attempts` once this one is counted
    # * +pid+, +started+ — the agent the attempt began with, nil when it is gone
    # * +command+ — the resume line {#check} answered in step 1, flags included
    # * +message+ — the text typed to the agent
    # * +resume_only+ — no agent to stop, so no signal and no wait for an exit
    Attempt = Struct.new(:pane_id, :session_id, :number, :mode, :pid, :started, :command, :message, :resume_only, keyword_init: true)
    private_constant :Attempt

    # Outcomes that say what is in the pane, so step 6 takes no last read.
    SETTLED_OUTCOMES = %w[resumed typed person_resumed fresh_agent].freeze
    private_constant :SETTLED_OUTCOMES

    # Outcomes that may leave our text in the agent's input line.
    DRAFT_OUTCOMES = %w[not_submitted no_response].freeze
    private_constant :DRAFT_OUTCOMES

    # What hooks and step 3 leave on an entry for the end of an attempt.
    ATTEMPT_FIELDS = %w[turn_completed failed_during_attempt resumed_elsewhere attempt_session_id prompt_seen].freeze
    private_constant :ATTEMPT_FIELDS

    HANDLED_EVENTS = %w[turn_failed stop user_prompt tool_start tool_use subagent_start session_start session_end].freeze
    private_constant :HANDLED_EVENTS

    GIVE_UP_BODIES = {
      "attempts_exhausted" => "The API kept failing (%<error>s) through %<attempts>d recovery attempts, so workspace stopped trying.",
      "not_retryable" => "The turn failed with %<error>s, which trying again won't fix. Nothing was stopped.",
      "cannot_restart" => "The turn failed with %<error>s and workspace can't restart this pane: it has its own start command, " \
        "something other than a shell runs the agent, or the transcript is gone.",
      "fresh_conversation" => "A new conversation started in the pane in place of the one that failed (%<error>s). " \
        "Nothing was typed into it.",
      "deferred" => "The turn failed with %<error>s, and the pane stayed busy or unreadable for 30 minutes. " \
        "Nothing was stopped or typed.",
      "unconfirmed" => "After %<attempts>d recovery attempts workspace can no longer confirm the turn ended on the error " \
        "(%<error>s), so it stopped trying.",
      "unconfirmed_no_attempts" => "A turn failed with %<cause>s, then with %<error>s, and workspace can no longer confirm that " \
        "last failure, so it stopped watching. No recovery attempt was made."
    }.freeze
    private_constant :GIVE_UP_BODIES

    # @param tmux [Workspace::Tmux] pane lookups, screen reads, server pids
    # @param workspace [String] the workspace the daemon serves; events and items go under it
    # @param session_name [String] the workspace's tmux session
    # @param session_monitor [Workspace::SessionMonitor] pane facts
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param transcript [Workspace::TranscriptSummary] reads the last turn record
    # @param stopper [Workspace::AgentStopper] finds the agent's process and sends the SIGINT
    # @param detector [Workspace::AgentDetector] the workspace's way to name the agent
    # @param process_tree [Workspace::ProcessTree] reads the fresh snapshots the process checks use
    # @param ledger [Workspace::SessionLedger] the session open in a pane, and its directory
    # @param resume_command [Workspace::AgentResumeCommand] builds the resume line
    # @param prompt_typer [Workspace::PromptTyper] the input line check, and the message's typing
    # @param readiness [Workspace::AgentReadiness] waits for a resumed agent
    # @param marker [Workspace::RecoveryStopMarker] says a stop is ours
    # @param inbox [#call] answers the workspace's {InboxStore}
    # @param event_log [Workspace::EventLog, nil] where attempts and give-ups are recorded
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param restarting [#call] given a pane id, whether a restart holds the pane. Claims are released
    #   by token and refused while held, so during an attempt a true answer is the attempt's own claim.
    #   That holds while every write to the claim is guarded by `key?` or replaces its own `:starting`
    # @param claim_restart [#call] given a pane id, claims it; returns a token, or nil when it is held.
    #   Called on the attempt's own thread, so it can register +Thread.current+ for shutdown
    # @param release_restart [#call] given a pane id and a token, releases that claim
    # @param rebind_queue [#call] given a pane id and the monitor's agent pid, moves the pane's
    #   queued prompts to that agent
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    # @param spawn [#call] runs the given block on its own thread
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, workspace:, session_name:, session_monitor:, store:, transcript:, stopper:, detector:,
      process_tree:, ledger:, resume_command:, prompt_typer:, readiness:, marker:, inbox:, delivery_lock:, event_log: nil,
      restarting: ->(_pane_id) { false }, claim_restart: ->(_pane_id) { Object.new },
      release_restart: ->(_pane_id, _token) {}, rebind_queue: ->(_pane_id, _agent_pid) {}, clock: Time,
      sleeper: ->(seconds) { sleep(seconds) }, spawn: ->(&block) { Thread.new(&block) }, logger: Workspace::Logger.new)
      @tmux = tmux
      @workspace = workspace
      @session_name = session_name
      @session_monitor = session_monitor
      @store = store
      @transcript = transcript
      @stopper = stopper
      @detector = detector
      @process_tree = process_tree
      @ledger = ledger
      @resume_command = resume_command
      @prompt_typer = prompt_typer
      @readiness = readiness
      @marker = marker
      @inbox = inbox
      @event_log = event_log
      @delivery_lock = delivery_lock
      @restarting = restarting
      @claim_restart = claim_restart
      @release_restart = release_restart
      @rebind_queue = rebind_queue
      @clock = clock
      @sleeper = sleeper
      @spawn = spawn
      @logger = logger
      @queue = []
      @queue_guard = Mutex.new
      @draining = false
      @unmarked = nil
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

    # Runs from the monitor's scan: marks the failed panes once, then for each
    # entry confirms a settled failure, checks one that is due, and picks up an
    # attempt no claim holds any more.
    #
    # @return [void]
    def scan
      entries = @store.entries
      mark_failed_panes(entries)
      entries.each_key do |pane_id|
        scan_pane(pane_id)
      rescue => e
        @logger.debug { "agent recovery: scan of #{pane_id} failed (#{e.class}: #{e.message})" }
      end
    rescue Workspace::Error => e
      @logger.debug { "agent recovery: #{e.message}" }
    end

    # @param pane_id [String]
    # @return [Boolean] whether the pane's queued prompts must wait for the recovery
    def holding?(pane_id)
      @store.holding?(pane_id)
    end

    # Reads the pane as it is now and answers what may happen to the entry. It
    # costs no attempt, and it changes nothing but a missing pid.
    #
    # @param pane_id [String]
    # @param entry [Hash] the pane's stored entry
    # @param screen [String, nil] the screen a quiet wait already gave, compared
    #   with one capture so the delivery lock isn't held across that wait
    # @return [Verdict]
    def check(pane_id, entry, screen: nil)
      detail = pane_detail(pane_id)
      return verdict(:defer) unless detail.is_a?(Hash)
      tree = read_tree
      return verdict(:defer) unless tree

      agent = @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: tree)
      agent ? check_live(pane_id, entry, detail, tree, agent, screen) : check_gone(pane_id, entry, detail, tree, screen)
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
      live = live_agent(pane_id)
      seen = @store.get(pane_id)
      rebind(pane_id) if seen && seen["session_id"] == session_id && agent_came_back?(seen, live)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        gave_up = intake(entry, session_id, message["error"], message["transcript_path"], live)
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # Applies one failed turn to an entry, inside the caller's {AgentRecoveryStore#update}.
    #
    # @param entry [Hash] the pane's entry, changed in place
    # @param session_id [String] the session that failed
    # @param error [String, nil] the error kind
    # @param transcript_path [String, nil] the hook's transcript path
    # @param live [Hash, nil] {AgentStopper#find_agent}'s answer, read before the update
    # @return [Boolean] whether this gave up, which the caller reports after the update
    def intake(entry, session_id, error, transcript_path, live)
      same = entry["session_id"] == session_id
      if entry["phase"] == "attempting"
        if same
          entry["failed_during_attempt"] = true
          entry["error"] = error
        end
        return false
      end

      unless RETRYABLE_ERRORS.include?(error)
        return false if same && entry["phase"] == "gave_up" && entry["give_up_reason"] != "not_retryable"
        entry.clear unless same
        fill(entry, session_id, error, transcript_path)
        give_up_in(entry, "not_retryable")
        return true
      end

      return false unless transcript_path.is_a?(String) && !transcript_path.empty?
      entry.clear unless same
      if entry["phase"] == "gave_up"
        return false unless entry["give_up_reason"] == "not_retryable"
        entry["stopped"] = false
        entry["give_up_reason"] = nil
        entry["item_open"] = true
        entry["item_error"] = entry["error"]
      end
      fill(entry, session_id, error, transcript_path)
      schedule(entry, live)
    end

    def fill(entry, session_id, error, transcript_path)
      entry["session_id"] = session_id
      entry["error"] = error
      entry["transcript_path"] = transcript_path || entry["transcript_path"]
      entry["attempts"] = entry["attempts"].to_i
      entry["stopped"] = entry["stopped"] == true
    end

    # @return [Boolean] whether this gave up
    def schedule(entry, live)
      return true if schedule_next(entry)

      entry["failed_at"] = stamp
      entry["draft_text"] = nil
      entry["stopped"] = false if agent_came_back?(entry, live)
      store_agent(entry, live) if live || entry["stopped"] != true
      false
    end

    # Whether a stopped entry's agent has been replaced. The stopped process
    # itself doesn't count: after a signal that didn't stop it, its late hooks
    # must not end the recovery, and a pid that was never read proves nothing.
    def agent_came_back?(entry, live)
      return false unless live && entry["stopped"] == true && %w[waiting watching].include?(entry["phase"])
      !entry["agent_pid"].nil? && (live[:pid] != entry["agent_pid"] || live[:started] != entry["agent_started"])
    end

    def store_agent(entry, live)
      entry.merge!("agent_pid" => live&.fetch(:pid), "agent_started" => live&.fetch(:started))
    end

    def next_attempt(entry)
      stamp(@clock.now + AgentRecoveryStore.wait_before(entry["attempts"].to_i + 1))
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
      resolve(session_id) if finished
    end

    def agent_active(message)
      pane_id = message["pane_id"]
      seen = @store.get(pane_id)
      same = seen && seen["session_id"] == message["session_id"]
      live = live_agent(pane_id) if same && seen["stopped"] == true && %w[waiting watching].include?(seen["phase"])
      # Before the write that may end the hold, so no prune sees the old pid.
      rebind(pane_id) if same && agent_came_back?(seen, live)
      @store.update(pane_id) do |entry|
        next if entry.empty? || entry["session_id"] != message["session_id"]
        if entry["phase"] == "attempting"
          entry["prompt_seen"] = true if message["event"] == "user_prompt"
        elsif %w[waiting watching].include?(entry["phase"])
          if agent_came_back?(entry, live)
            entry["stopped"] = false
            store_agent(entry, live)
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
      live = live_agent(pane_id) if open_phase && same
      # Before the write that may end the hold, so no prune sees the old pid.
      rebind(pane_id) if open_phase && same && seen["stopped"] == true

      gave_up = false
      stored = @store.update(pane_id) do |entry|
        gave_up = apply_session_start(entry, session_id, message["source"], live)
      end
      report_give_up(pane_id, stored) if gave_up
      resolve(seen["session_id"]) if stored.nil? && message["source"] == "clear"
    end

    # @return [Boolean] whether this gave up
    def apply_session_start(entry, session_id, source, live)
      case entry["phase"]
      when "attempting"
        entry["attempt_session_id"] = session_id
      when "waiting", "watching"
        if entry["session_id"] != session_id
          return other_session_started(entry, source)
        end
        entry.merge!("stopped" => false, "phase" => "watching", "defer_since" => nil) if entry["stopped"] == true
        store_agent(entry, live)
      end
      false
    end

    # A person or a workflow cleared the conversation, or no stop of ours came
    # before this session: nothing is left to report. After attempts, a slow
    # exit may have reached a `||` branch, and this is the last place to say so.
    def other_session_started(entry, source)
      if source == "clear" || unreported?(entry)
        entry.clear
        return false
      end
      give_up_in(entry, "fresh_conversation")
      true
    end

    # Nothing has been tried and no item waits on this entry, so it can go silently.
    def unreported?(entry)
      entry["attempts"].to_i.zero? && entry["item_open"] != true
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
        resolve(session_id) if item_open
      end
    end

    # The queue compares the monitor's pid, which in an unwrapped pane is the
    # pane's shell and not the agent's own process.
    def rebind(pane_id)
      @session_monitor.rescan_pane(pane_id)
      agent_pid = @session_monitor.agent_pid(pane_id)
      @rebind_queue.call(pane_id, agent_pid) if agent_pid
    end

    def session_ended(message)
      deleted = false
      @store.update(message["pane_id"]) do |entry|
        next if entry.empty? || entry["session_id"] != message["session_id"]
        next unless %w[waiting watching].include?(entry["phase"]) && entry["stopped"] != true

        if entry["phase"] == "waiting" && signalled_lately?(entry)
          entry["stopped"] = true
        else
          entry.clear
          deleted = true
        end
      end
      resolve(message["session_id"]) if deleted
    end

    # The monitor's failed-turn flag isn't persisted, so the panes failed when
    # this desk started are marked again. Marking does nothing for a pane the
    # monitor doesn't know yet, so those stay listed for the next scan. Only
    # the first scan lists panes: a later failure's flag came from its hook,
    # and a prompt may have cleared it since.
    def mark_failed_panes(entries)
      @unmarked ||= entries.select { |_, entry| failed_turn_stands?(entry) }.keys
      @unmarked = @unmarked.select { |pane_id| entries[pane_id] && failed_turn_stands?(entries[pane_id]) }
      @unmarked.reject! do |pane_id|
        known = !@session_monitor.pane_kind(pane_id).nil?
        @session_monitor.mark_turn_failed(pane_id) if known
        known
      end
    end

    # Skips a `fresh_conversation` record: that pane holds a healthy agent.
    def failed_turn_stands?(entry)
      %w[waiting attempting].include?(entry["phase"]) ||
        (entry["phase"] == "gave_up" && entry["give_up_reason"] != "fresh_conversation")
    end

    def scan_pane(pane_id)
      entry = @store.get(pane_id)
      return unless entry

      case entry["phase"]
      when "waiting"
        entry = settle(pane_id, entry) unless entry["stopped"] == true
        attempt_if_due(pane_id, entry) if entry
      when "attempting"
        reconcile(pane_id) unless @restarting.call(pane_id)
      end
    end

    # Reads what the settle period was waiting for. A transcript or ledger that
    # can't be read yet is left for the next scan.
    #
    # @return [Hash, nil] the entry as it now stands; nil when it was cleared
    def settle(pane_id, entry)
      failed = parse_time(entry["failed_at"])
      return entry unless failed && @clock.now - failed >= SETTLE

      found = {}
      unless entry["last_turn_uuid"]
        record = @transcript.last_turn_record(entry["transcript_path"])
        if record && !record["api_error"]
          clear(pane_id, entry)
          return nil
        end
        found["last_turn_uuid"] = record["uuid"] if record
      end
      unless entry["agent_pid"]
        live = live_agent(pane_id)
        store_agent(found, live) if live
      end
      unless entry["cwd"]
        opened = open_record(pane_id)
        if opened.is_a?(Hash)
          if opened["session_id"] != entry["session_id"]
            clear(pane_id, entry)
            return nil
          end
          found["cwd"] = opened["cwd"]
        end
      end
      found.compact!
      return entry if found.empty?
      @store.update(pane_id) { |current| current.merge!(found) if same_wait?(current, entry) }
    end

    def attempt_if_due(pane_id, entry)
      return unless entry["phase"] == "waiting"
      due = parse_time(entry["next_attempt_at"])
      return unless due && @clock.now >= due && !@restarting.call(pane_id)

      answer = safe_check(pane_id, entry)
      return refuse(pane_id, entry, answer) unless answer.answer == :go

      # The screen wait gave a hook time to change the entry.
      current = @store.get(pane_id)
      start_attempt(pane_id, answer) if current && same_wait?(current, entry)
    end

    # Acts on any {#check} answer but `:go`.
    def refuse(pane_id, entry, answer)
      case answer.answer
      when :defer then defer(pane_id, entry)
      when :clear then clear(pane_id, entry)
      when :never then give_up(pane_id, entry, "cannot_restart")
      end
    end

    # A check that raises has read nothing, so it defers like any other unread
    # condition and the defer limit ends it.
    def safe_check(pane_id, entry, **options)
      check(pane_id, entry, **options)
    rescue => e
      @logger.debug { "agent recovery: check of #{pane_id} failed (#{e.class}: #{e.message})" }
      verdict(:defer)
    end

    def start_attempt(pane_id, answer)
      (answer.mode == :typed) ? typed_attempt(pane_id, answer) : restart_attempt(pane_id, answer)
    end

    # The attempt for `attempts` 0: the message typed at the live prompt. Not
    # built yet. `defer_since` is cleared only in the write that sets
    # `attempting`, so a scan's `:go` and step 1's `:defer` can't loop for good.
    def typed_attempt(_pane_id, _answer)
      nil
    end

    # The attempt for `attempts` above 0: stop, resume, wait, type.
    def restart_attempt(pane_id, _answer)
      @spawn.call { run_claimed(pane_id, method(:open_restart), method(:restart_steps)) }
    end

    # Runs one attempt inside a claim on the pane. An attempt that raises or is
    # killed stays `attempting` with no claim, for {#reconcile} to pick up, and
    # keeps its marker until then: the agent may be exiting right now.
    #
    # @param open [#call] given the pane id, step 1: answers an {Attempt}, or nil when none began
    # @param steps [#call] given the attempt, answers an outcome and any agent that outcome names
    def run_claimed(pane_id, open, steps)
      token = @claim_restart.call(pane_id)
      return unless token

      attempt = outcome = nil
      begin
        attempt = open.call(pane_id)
        return unless attempt
        outcome, agent = steps.call(attempt)
        finish(attempt, outcome, agent: agent)
      rescue => e
        quiet_debug { "agent recovery: attempt in #{pane_id} failed (#{e.class}: #{e.message})" }
      ensure
        @marker.clear(attempt.session_id) if outcome && outcome != "not_stopped"
        @release_restart.call(pane_id, token)
      end
    end

    # Step 1. A refusal costs no attempt and writes no line.
    def open_restart(pane_id)
      seen = @store.get(pane_id)
      return nil unless seen && seen["phase"] == "waiting"

      quiet = still_screen(pane_id)
      return refuse(pane_id, seen, verdict(:defer)) unless quiet

      opened = @delivery_lock.synchronize { begin_restart(pane_id, seen, quiet) }
      return opened if opened.is_a?(Attempt)
      refuse(pane_id, seen, opened) if opened
      nil
    end

    # @return [Attempt, Verdict, nil] the attempt under way; the answer to act
    #   on; or nil when a hook changed the entry and there is nothing to do
    def begin_restart(pane_id, seen, quiet)
      answer = safe_check(pane_id, seen, screen: quiet)
      return answer unless answer.answer == :go
      return nil if answer.mode == :typed
      return mark_attempting(pane_id, seen, answer) if answer.mode == :resume_only

      unconfirmed = confirmed_error(pane_id, seen)
      return verdict(unconfirmed) if unconfirmed
      detail = pane_detail(pane_id)
      return verdict(:defer) unless detail.is_a?(Hash)
      # The transcript and ledger reads above gave a prompt time to arrive.
      return verdict(:defer) if prompt_since_failure?(pane_id, seen)

      attempt = mark_attempting(pane_id, seen, answer, "stopped" => true, "last_signal_at" => stamp)
      attempt && signal_agent(attempt, seen, detail)
    end

    # Writes `attempting`. `defer_since` goes here and nowhere earlier, so a
    # scan's `:go` and step 1's `:defer` can't repeat without bound.
    def mark_attempting(pane_id, seen, answer, fields = {})
      number = seen["attempts"].to_i + 1
      opened = false
      @store.update(pane_id) do |entry|
        next unless same_wait?(entry, seen) && entry["attempts"] == seen["attempts"]
        entry.merge!(fields, "attempts" => number, "phase" => "attempting", "attempt_session_id" => nil, "defer_since" => nil)
        opened = true
      end
      return nil unless opened

      Attempt.new(pane_id: pane_id, session_id: seen["session_id"], number: number, mode: "restart", pid: seen["agent_pid"],
        started: seen["agent_started"], command: answer.command, message: format(RESUMED_MESSAGE, error: seen["error"]),
        resume_only: answer.mode == :resume_only)
    end

    # The marker and `stopped` are written before the signal, because the
    # SessionEnd it causes can arrive at once, and with no marker it would stop
    # the dev server. A stop that raises sent nothing.
    def signal_agent(attempt, seen, detail)
      return take_back(attempt, seen, :defer) unless @marker.mark(attempt.session_id)

      result = begin
        @stopper.stop(pid: attempt.pid, started: attempt.started, pane_pid: detail[:pid])
      rescue => e
        @logger.debug { "agent recovery: no signal for #{attempt.pane_id} (#{e.class}: #{e.message})" }
        :unread
      end
      case result
      when :signalled, :not_running then attempt
      when :stale then take_back(attempt, seen, :clear)
      else take_back(attempt, seen, :defer)
      end
    end

    # No signal went out, so the attempt never happened: the entry goes back to
    # how step 1 found it, `defer_since` included, so the defer limit still
    # runs. What a hook wrote meanwhile is honoured as step 6 would.
    #
    # @return [Verdict] the answer to act on; it finds a changed entry and does nothing
    def take_back(attempt, seen, answer)
      @marker.clear(attempt.session_id)
      live = last_read(attempt.pane_id)
      row = nil
      restored = %w[phase attempts stopped last_signal_at defer_since].to_h { |key| [key, seen[key]] }
      stored = @store.update(attempt.pane_id) do |entry|
        next unless attempt_current?(entry, attempt)
        entry.merge!(restored)
        row = hook_row(entry, live)
      end
      close_row(attempt, row, stored)
      verdict(answer)
    end

    # Steps 2 to 5. Each step answers nil to go on.
    def restart_steps(attempt)
      ended = attempt.resume_only ? nil : await_exit(attempt)
      ended ||= resume_in_pane(attempt) || await_agent(attempt)
      return ended if ended

      typed = type_message(attempt)
      return typed if typed.is_a?(Array)
      [(typed == "submitted") ? "resumed" : typed]
    end

    # Step 2.
    def await_exit(attempt)
      deadline = @clock.now + STOP_WAIT
      clear_reads = 0
      loop do
        look, agent = pane_look(attempt)
        return identify(attempt, agent) if look == :other
        clear_reads = (look == :clear) ? clear_reads + 1 : 0
        return nil if clear_reads >= CLEAR_READS
        return ["not_stopped"] if @clock.now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # @return [Array] +:same+ (the agent we stopped), +:other+ with the agent,
    #   +:clear+ (a shell holding the terminal), or +:none+ when the pane is
    #   neither or can't be read
    def pane_look(attempt)
      detail = pane_detail(attempt.pane_id)
      tree = detail.is_a?(Hash) ? read_tree : nil
      return [:none] unless tree

      agent = @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: tree)
      return ours?(agent, attempt) ? [:same] : [:other, agent] if agent
      clear = @stopper.pane_clear?(pane_pid: detail[:pid], command: detail[:command], detector: @detector, tree: tree)
      clear ? [:clear] : [:none]
    end

    def ours?(agent, attempt)
      agent[:pid] == attempt.pid && agent[:started] == attempt.started
    end

    # An agent we didn't start. The monitor keeps the old session id until a
    # new SessionStart, so only `attempt_session_id` can say a person resumed
    # this conversation.
    def identify(attempt, agent)
      (await_session(attempt) == attempt.session_id) ? ["person_resumed", agent] : ["fresh_agent"]
    end

    # @return [String, nil] the session a SessionStart reported since step 1
    def await_session(attempt)
      deadline = @clock.now + SESSION_WAIT
      loop do
        session = @store.get(attempt.pane_id)&.fetch("attempt_session_id", nil)
        return session if session || @clock.now >= deadline
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # Step 3. The wait in {#identify} runs outside the lock.
    def resume_in_pane(attempt)
      typed, agent = @delivery_lock.synchronize { type_resume(attempt) }
      (typed == :other) ? identify(attempt, agent) : typed && [typed]
    end

    # The shell's line is emptied first, in its own call: Enter would otherwise
    # run whatever already sits there, our own leftover or a person's half-typed
    # text. That text is lost, the accepted cost in a pane we stopped.
    #
    # @return [Array, nil] a refusal, or nil once the command landed. Through
    #   {Tmux#deliver}, because {PromptTyper} refuses a shell.
    def type_resume(attempt)
      pane_id = attempt.pane_id
      return ["resumed_elsewhere"] if @store.get(pane_id)&.fetch("resumed_elsewhere", false) == true
      return ["claim_lost"] unless @restarting.call(pane_id)

      # Read first, so the clear look is the last read before `C-u`, and acted
      # on after it, so a person's resume in this pane still reads as `:other`.
      held = session_held?(attempt.session_id)
      look, agent = pane_look(attempt)
      return [:other, agent] if look == :other
      return ["pane_not_clear"] unless look == :clear && !held
      return ["not_delivered"] unless @tmux.send_key(@session_name, pane_id, "C-u")

      @tmux.deliver(@session_name, pane_id, attempt.command).landed? ? nil : ["not_delivered"]
    end

    # A tree that can't be read counts as held.
    def session_held?(session_id)
      tree = read_tree
      tree.nil? || @stopper.session_held?(session_id: session_id, tree: tree)
    end

    # Step 4. The agent's pid is stored as soon as it is seen, whatever happens
    # next, so {#check} doesn't read our own agent as someone else's.
    def await_agent(attempt)
      pane_id = attempt.pane_id
      @readiness.wait(@session_name, deadline: @readiness.deadline_in(READY_WAIT), only_pane: pane_id, detector: @detector)
      @session_monitor.rescan_pane(pane_id)
      @marker.clear(attempt.session_id)
      agent = live_agent(pane_id)
      return ["not_ready"] unless agent

      attempt.pid, attempt.started = agent.values_at(:pid, :started)
      @store.update(pane_id) do |entry|
        next unless attempt_current?(entry, attempt)
        store_agent(entry, agent)
        entry["stopped"] = false
      end
      session = await_session(attempt)
      return ["fresh_agent"] if session && session != attempt.session_id
      rebind(pane_id)
      session ? nil : ["not_ready"]
    end

    # Step 5. The lock is held for one try, so the workspace's other deliveries
    # aren't held up. Text that may have landed is never typed again.
    #
    # @return [String, Array] "submitted", "not_submitted" or "not_typed"; or,
    #   when the pane isn't the attempt's any more, the outcome and any agent
    def type_message(attempt)
      TYPE_TRIES.times do |try|
        @sleeper.call(POLL_INTERVAL) unless try.zero?
        typed = @delivery_lock.synchronize { typing_refusal(attempt) || type_once(attempt) }
        return (typed.first == :other) ? identify(attempt, typed.last) : typed if typed.is_a?(Array)
        return typed unless typed == :retry
      end
      "not_typed"
    end

    # Each try's identity check, under the lock: nothing is typed unless the
    # claim holds and the pane still has the attempt's agent.
    #
    # @return [Array, nil] the refusal; +:other+ with an agent we didn't start
    def typing_refusal(attempt)
      return ["claim_lost"] unless @restarting.call(attempt.pane_id)

      look, agent = pane_look(attempt)
      case look
      when :same then nil
      when :other then [:other, agent]
      else ["pane_not_clear"]
      end
    end

    def type_once(attempt)
      pane_id = attempt.pane_id
      typed = @prompt_typer.type(session_name: @session_name, target: pane_id, pane_id: pane_id, text: attempt.message)
      case typed.outcome
      when :submitted then "submitted"
      when :not_submitted then press_enter(pane_id, attempt.message) ? "submitted" : "not_submitted"
      when :refused then (typed.reason == "unknown") ? :retry : "not_typed"
      else "not_typed"
      end
    end

    def press_enter(pane_id, message)
      @prompt_typer.check(pane_id, pasted: message).nil? && @tmux.deliver(@session_name, pane_id, "", enter: true).ok?
    end

    # Step 6: one update, so it can't overwrite a hook's write, then the line.
    # The queue moves before the update ends the hold, so no prune sees the old
    # pid. An entry that isn't this attempt's any more was picked up by
    # {#reconcile}, which wrote the line. A kill waits for the end of the span,
    # so a `gave_up` entry always gets its line and inbox item.
    #
    # @param attempt [Attempt]
    # @param outcome [String]
    # @param agent [Hash, nil] with `person_resumed`, the agent found
    # @return [void]
    def finish(attempt, outcome, agent: nil)
      pane_id = attempt.pane_id
      live = agent || (SETTLED_OUTCOMES.include?(outcome) ? :unread : last_read(pane_id))
      rebind(pane_id) if live.is_a?(Hash) && !ours?(live, attempt)

      Thread.handle_interrupt(Object => :never) do
        seen = row = nil
        stored = @store.update(pane_id) do |entry|
          next unless attempt_current?(entry, attempt)
          seen = entry.dup
          row = close_attempt(entry, attempt, outcome, live)
        end
        next unless seen

        record(ATTEMPT_EVENT, "attempt" => attempt.number, "session_id" => attempt.session_id, "pane_id" => pane_id,
          "error" => seen["error"], "mode" => attempt.mode, "outcome" => outcome)
        close_row(attempt, row, stored)
      end
    end

    # @return [Symbol, nil] +:resolved+, +:gave_up+, or nil when there is nothing to report
    def close_attempt(entry, attempt, outcome, live)
      row = hook_row(entry, live)
      return row if row

      case outcome
      when "resumed" then entry.merge!("phase" => "watching", "last_signal_at" => nil, "draft_text" => nil)
      when "typed"
        entry["phase"] = "watching"
        entry["draft_text"] = nil
      when "person_resumed"
        entry.merge!("phase" => "watching", "stopped" => false, "last_signal_at" => nil)
        store_agent(entry, live)
      when "fresh_agent"
        give_up_in(entry, "fresh_conversation")
        return :gave_up
      else
        apply_read(entry, live)
        entry["draft_text"] = attempt.message if DRAFT_OUTCOMES.include?(outcome)
        return :gave_up if schedule_next(entry)
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
        give_up_in(entry, "fresh_conversation")
        return :gave_up
      end
      return nil unless failed

      apply_read(entry, live)
      entry["phase"] = "watching"
      known = (live == :unread) ? {pid: entry["agent_pid"], started: entry["agent_started"]} : live
      intake(entry, entry["session_id"], entry["error"], entry["transcript_path"], known) ? :gave_up : :rescheduled
    end

    # From the last read: an agent is ours to stop next time, and none means
    # the next attempt is `resume_only`. A read that failed changes nothing.
    def apply_read(entry, live)
      return if live == :unread
      entry["stopped"] = live.nil?
      store_agent(entry, live) if live
    end

    def close_row(attempt, row, stored)
      resolve(attempt.session_id) if row == :resolved
      report_give_up(attempt.pane_id, stored) if row == :gave_up
    end

    def attempt_current?(entry, attempt)
      entry["phase"] == "attempting" && entry["session_id"] == attempt.session_id && entry["attempts"] == attempt.number
    end

    # @return [Hash, nil, Symbol] the agent in the pane, nil when there is none
    #   or the pane is gone, or :unread when tmux or the process table can't be read
    def last_read(pane_id)
      detail = pane_detail(pane_id)
      tree = read_tree
      return :unread if detail == :unknown || tree.nil?
      detail && @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: tree)
    end

    def defer(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless same_wait?(entry, seen)
        since = parse_time(entry["defer_since"])
        if since.nil?
          entry["defer_since"] = stamp
        elsif @clock.now - since >= DEFER_LIMIT
          give_up_in(entry, "deferred")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # `:clear`, with one meaning everywhere: the entry goes while no attempt
    # was made, and after attempts the count is reported, never dropped.
    def clear(pane_id, seen)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless same_wait?(entry, seen)
        if unreported?(entry)
          entry.clear
        else
          give_up_in(entry, "unconfirmed")
          gave_up = true
        end
      end
      report_give_up(pane_id, stored) if gave_up
    end

    def give_up(pane_id, seen, reason)
      gave_up = false
      stored = @store.update(pane_id) do |entry|
        next unless same_wait?(entry, seen)
        give_up_in(entry, reason)
        gave_up = true
      end
      report_give_up(pane_id, stored) if gave_up
    end

    # Whether an entry is still the one a decision was made on: a hook may have
    # written between that read and this write.
    def same_wait?(entry, seen)
      %w[phase session_id failed_at].all? { |key| entry[key] == seen[key] }
    end

    def give_up_in(entry, reason)
      entry.merge!("phase" => "gave_up", "give_up_reason" => reason, "next_attempt_at" => nil, "defer_since" => nil)
    end

    # An inbox that can't be written must not end the worker or the scan: the
    # entry is `gave_up` by now and the event line says so.
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

    def resolve(session_id)
      @inbox.call.transition_by_key(inbox_key(session_id), to: "done", by: {"kind" => "agent_recovery"})
    rescue Workspace::Error, SystemCallError => e
      @logger.debug { "agent recovery: inbox item for #{session_id} not resolved (#{e.class}: #{e.message})" }
    end

    # Picks up an attempt the daemon lost by restarting: says so, then looks at
    # the pane. Nothing is decided on a pane or process table that can't be
    # read; the next scan tries again.
    def reconcile(pane_id)
      detail = pane_detail(pane_id)
      return if detail == :unknown
      tree = read_tree
      return unless tree

      agent = detail && @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: tree)
      opened = open_record(pane_id)
      return if opened == :unreadable

      open_session = opened&.fetch("session_id")
      seen = nil
      gave_up = false
      finished = false
      stored = @store.update(pane_id) do |entry|
        next unless entry["phase"] == "attempting"
        seen = entry.dup
        finished = entry["turn_completed"] == true || entry["resumed_elsewhere"] == true
        next entry.clear if finished
        gave_up = reconcile_entry(entry, open_session, agent)
      end
      return unless seen

      record_interrupted(pane_id, seen)
      # A live agent may still exit from our signal: its marker is left to expire.
      @marker.clear(seen["session_id"]) unless agent
      resolve(seen["session_id"]) if finished
      report_give_up(pane_id, stored) if gave_up
    end

    # @return [Boolean] whether this gave up
    def reconcile_entry(entry, open_session, agent)
      failed = entry.delete("failed_during_attempt") == true
      %w[turn_completed attempt_session_id prompt_seen].each { |key| entry.delete(key) }
      if open_session && open_session != entry["session_id"]
        give_up_in(entry, "fresh_conversation")
        return true
      end
      if failed && !RETRYABLE_ERRORS.include?(entry["error"])
        give_up_in(entry, "not_retryable")
        return true
      end

      entry["stopped"] = agent.nil?
      store_agent(entry, agent) if agent
      entry["failed_at"] = stamp if failed
      schedule_next(entry)
    end

    # @return [Boolean] whether this gave up, the attempts being used up
    def schedule_next(entry)
      if entry["attempts"].to_i >= AgentRecoveryStore::MAX_ATTEMPTS
        give_up_in(entry, "attempts_exhausted")
        return true
      end
      entry.merge!("phase" => "waiting", "next_attempt_at" => next_attempt(entry), "last_turn_uuid" => nil, "defer_since" => nil)
      false
    end

    def record_interrupted(pane_id, entry)
      attempt = entry["attempts"].to_i
      record(ATTEMPT_EVENT, "attempt" => attempt, "session_id" => entry["session_id"], "pane_id" => pane_id,
        "error" => entry["error"], "mode" => (attempt == 1) ? "typed" : "restart", "outcome" => "interrupted")
    end

    # No agent in the pane. With `stopped` the agent is already gone and
    # nothing can be killed, so the checks that read a live agent don't apply.
    def check_gone(pane_id, entry, detail, tree, screen)
      unless entry["stopped"] == true
        return verdict(signalled_lately?(entry) ? :defer : :clear)
      end
      return verdict(:never) unless File.file?(entry["transcript_path"].to_s)

      command = resume_line(entry)
      return verdict(:defer) unless command && entry["session_id"].to_s.match?(AgentResumeCommand::SESSION_ID)
      clear = @stopper.pane_clear?(pane_pid: detail[:pid], command: detail[:command], detector: @detector, tree: tree)
      return verdict(:defer) if !clear || @stopper.session_held?(session_id: entry["session_id"], tree: tree)
      return verdict(:defer) unless still_screen(pane_id, screen)
      verdict(:go, mode: :resume_only, command: command)
    end

    # What may clear comes first, so an agent at work is deferred and never
    # read as a transcript that moved on.
    def check_live(pane_id, entry, detail, tree, agent, screen)
      return verdict(:defer) if entry["stopped"] == true || held_off?(pane_id, entry, screen)

      unless entry["agent_pid"]
        @store.update(pane_id) { |current| store_agent(current, agent) if same_wait?(current, entry) }
        return verdict(:defer)
      end
      return verdict(:clear) unless agent[:pid] == entry["agent_pid"] && agent[:started] == entry["agent_started"]

      confirmed = confirmed_error(pane_id, entry)
      return verdict(confirmed) if confirmed
      return verdict(:go, mode: :typed) if entry["attempts"].to_i.zero?

      restart_verdict(pane_id, entry, detail, tree, agent)
    end

    def held_off?(pane_id, entry, screen)
      !input_free?(pane_id, entry) || prompt_since_failure?(pane_id, entry) || subagents_running?(pane_id, entry) ||
        screen_busy?(pane_id, screen)
    end

    # @return [Symbol, nil] +:defer+ or +:clear+ unless the transcript and the
    #   ledger both still show the stored failure of the stored session
    def confirmed_error(pane_id, entry)
      record = @transcript.last_turn_record(entry["transcript_path"])
      return :defer unless record && entry["last_turn_uuid"]
      return :clear unless record["api_error"] && record["uuid"] == entry["last_turn_uuid"]

      opened = open_record(pane_id)
      return :defer unless opened.is_a?(Hash)
      (opened["session_id"] == entry["session_id"]) ? nil : :clear
    end

    def restart_verdict(pane_id, entry, detail, tree, agent)
      row = @tmux.pane_start_commands(@session_name).find { |pane| pane[:id] == pane_id }
      return verdict(:defer) unless row
      return verdict(:never) if row[:start_command]
      return verdict(:never) unless @stopper.restartable?(pid: agent[:pid], pane_pid: detail[:pid], tree: tree)

      command = resume_line(entry)
      command ? verdict(:go, mode: :restart, command: command) : verdict(:defer)
    end

    # A draft that is our own message doesn't count: the next attempt may stop
    # that agent with our text in its input line.
    def input_free?(pane_id, entry)
      draft = entry["draft_text"]
      return true if draft.is_a?(String) && @prompt_typer.check(pane_id, exact: draft).nil?
      @prompt_typer.check(pane_id).nil?
    end

    # The monitor records a prompt when its hook arrives, ahead of this desk's
    # queue, so a prompt just submitted can't get a signal while its event waits.
    def prompt_since_failure?(pane_id, entry)
      facts = @session_monitor.delivery_facts(pane_id)
      return true unless facts
      failed = parse_time(entry["failed_at"])
      return true unless failed
      prompt = facts[:last_user_prompt_at]
      !prompt.nil? && prompt.to_f > failed.to_f
    end

    def subagents_running?(pane_id, entry)
      running = @session_monitor.running_subagents(pane_id)
      return true if running.nil?
      return false unless running.positive?

      latest = [parse_time(entry["last_subagent_at"]), parse_time(entry["failed_at"])].compact.max
      latest.nil? || @clock.now - latest < SUBAGENT_QUIET
    end

    def screen_busy?(pane_id, quiet)
      screen = still_screen(pane_id, quiet)
      screen.nil? || BUSY_SCREEN.match?(screen)
    end

    # @param quiet [String, nil] a screen that already stood still, compared
    #   with one capture in place of the wait
    # @return [String, nil] the screen, when it stayed unchanged for {QUIET_FOR}
    def still_screen(pane_id, quiet = nil)
      before = quiet || @tmux.capture_screen(pane_id)
      return nil unless before
      @sleeper.call(QUIET_FOR) unless quiet
      (@tmux.capture_screen(pane_id) == before) ? before : nil
    end

    def resume_line(entry)
      return nil unless entry["cwd"].is_a?(String)
      @resume_command.call(workspace: @workspace, cwd: entry["cwd"], session_id: entry["session_id"],
        flags: @resume_command.flags_for(@workspace))
    end

    def signalled_lately?(entry)
      signalled = parse_time(entry["last_signal_at"])
      !signalled.nil? && @clock.now - signalled < AgentRecoveryStore::SIGNAL_HOLD
    end

    def live_agent(pane_id)
      detail = pane_detail(pane_id)
      return nil unless detail.is_a?(Hash)
      tree = read_tree
      tree && @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: tree)
    end

    # @return [ProcessTree::Snapshot, nil] nil when the table can't be read,
    #   which isn't the same as no agent
    def read_tree
      @process_tree.snapshot
    rescue Workspace::Error => e
      @logger.debug { "agent recovery: #{e.message}" }
      nil
    end

    # @return [Hash, nil, Symbol] the open session's entry, nil when none is
    #   open, or :unreadable when the ledger or the tmux server can't be read
    def open_record(pane_id)
      server = @tmux.server_pid_for_pane(pane_id)
      return :unreadable if server.to_s.empty?
      @ledger.read_open_record(pane_id: pane_id, tmux_server: server)
    rescue SystemCallError => e
      @logger.debug { "agent recovery: ledger not readable (#{e.class}: #{e.message})" }
      :unreadable
    end

    # The pane's details, nil when the session doesn't have it, or :unknown
    # when tmux listed no pane at all: a failed tmux call must not read as the
    # pane being gone.
    def pane_detail(pane_id)
      details = @tmux.pane_details(@session_name, window: nil)
      return :unknown if details.empty?
      details.find { |d| d[:id] == pane_id }
    end

    def verdict(answer, mode: nil, command: nil)
      Verdict.new(answer: answer, mode: mode, command: command)
    end

    def stamp(time = @clock.now)
      AgentRecoveryStore.stamp(time)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def record(type, data)
      @event_log&.record(type: type, project: @workspace, data: data)
    end
  end
end
