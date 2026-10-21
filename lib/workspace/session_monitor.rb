require "time"
require "digest"

module Workspace
  # Tracks which panes in a workspace are running a coding agent, whether each
  # one is working, idle, waiting on a person, or done with its turn, and what
  # sub-agents they have started.
  #
  # Two sources feed it, and neither is sufficient alone:
  #
  # * tmux and the process table say *which pane hosts an agent* and whether its
  #   output is still moving. This works for every agent, including ones with no
  #   hook system.
  # * hook events say *what the agent is doing* — sub-agents in particular.
  #   Claude Code runs sub-agents in-process, so no amount of process-tree
  #   walking reveals them; only the agent can report them.
  #
  # Everything is keyed on the tmux pane id, which stays with a pane for its
  # whole life. Pane indices shift as panes are split and closed, so an entry
  # keyed on one would silently follow the wrong pane.
  #
  # Each agent pane's state changes (working, idle, waiting, done, and exited or
  # closed once its agent goes) are appended to the event log. A monitor
  # started after a daemon restart reads each pane's last logged state back,
  # so the state and when it began carry over rather than starting afresh.
  # A pending wait is not carried over: the hook event that would have ended
  # it may have arrived while no daemon was listening.
  #
  # Each alert sent is logged too, idle and waiting alike, so a restarted
  # daemon doesn't alert again for a quiet stretch or a wait the last one
  # already alerted for. A wait the last daemon alerted for counts as the
  # same wait if the agent that raised it asks again before sending any
  # other hook event; a wait that begins after that alerts as usual.
  class SessionMonitor
    # A pane whose output has not changed for this long is reported idle. Agents
    # spend most of a turn blocked on the network, so CPU is not a usable
    # signal; changing output is.
    DEFAULT_IDLE_AFTER = 30

    # Seconds between scans when no `agentd.poll_interval` says otherwise.
    # Each scan is one `tmux list-panes`, one `ps` snapshot and a
    # `capture-pane` per pane, so a short interval is real recurring CPU.
    DEFAULT_POLL_INTERVAL = 10

    # Longest waiting message kept. A long one is cut rather than dropped.
    MAX_MESSAGE_LENGTH = 200

    # Scans in a row that can't read the process table before a warning is
    # printed. One or two failures are routine (a slow `ps`); a streak means
    # idle alerts have quietly stopped.
    FAILED_SCANS_WARNING = 5

    # How many poll intervals a scan-time cache stays fresh for a request.
    # The scan refreshes it every interval, so this only matters when a scan
    # is late or the scan thread has died — then requests fall back to
    # reading for themselves rather than serving data gone stale.
    CACHE_GRACE_INTERVALS = 3

    # Makes an agent's message safe to print, log, or pass to a command:
    # each run of whitespace and control characters (newlines, terminal
    # escapes, bells) becomes one space, and the result is capped.
    #
    # @param message [String, nil] text from an agent's hook payload
    # @return [String, nil] the cleaned message, or nil if nothing is left
    def self.clean_message(message)
      return nil unless message.is_a?(String)
      cleaned = message.scrub.gsub(/[[:space:][:cntrl:]]+/, " ").strip[0, MAX_MESSAGE_LENGTH]
      cleaned unless cleaned.empty?
    end

    # @param tmux [Workspace::Tmux] pane listing and capture
    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param session_name [String] tmux session to watch
    # @param providers [Array<Workspace::AgentProvider>] agents to recognize
    # @param detector [#call] finds the agent in a pane; the caller reads the workspace's configured names once
    #   when the monitor is made (see {AgentCommands#detector})
    # @param poll_interval [Numeric] seconds between scans
    # @param idle_after [Numeric] seconds of unchanged output before idle
    # @param clock [#now] time source, injected for deterministic tests
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] stream for reporting an unexpected monitor death
    # @param lock_reaper [Workspace::LockReaper, nil] ticked after every scan with
    #   the panes' working directories, so stale lock holds are reaped
    # @param notifier [Workspace::Notifier, nil] runs the notify command when an
    #   agent pane starts waiting or stays idle too long; nil sends no alerts
    # @param idle_alert_after [Numeric, nil] seconds of idle before an agent
    #   pane alerts; nil alerts only on waiting
    # @param event_log [Workspace::EventLog, nil] where agent state changes are
    #   recorded and read back after a restart; nil keeps history in memory only
    # @param project [String, nil] the name events are recorded under;
    #   defaults to +session_name+
    # @param context_reader [Workspace::ContextReader, nil] resolves each
    #   coding-agent pane's context-window usage; nil omits `context_pct`,
    #   `context_error`, and `context_updated_at` from {#present}
    # @param label_reader [Workspace::TranscriptLabel, nil] reads a pane's
    #   transcript for its `display_label`; nil falls back to the last prompt
    #   the daemon saw
    # @param task_reader [#call, nil] given the project name, returns its active task
    #   record (a Hash with `id` and `title`) or nil; its title is the first
    #   `display_label` source and the snapshot reports the task. nil reports none.
    # @param scan_slots [Workspace::ScanSlotLimiter, nil] bounds how many
    #   monitors scan at once, machine-wide; a scan that can't take a slot is
    #   skipped rather than waited out. nil scans without a limit.
    def initialize(tmux:, process_tree:, session_name:,
      providers: AgentProvider.all, detector: AgentDetector.new, poll_interval: DEFAULT_POLL_INTERVAL, idle_after: DEFAULT_IDLE_AFTER,
      clock: Time, logger: Workspace::Logger.new, error_output: $stderr, lock_reaper: nil,
      notifier: nil, idle_alert_after: nil, event_log: nil, project: nil,
      context_reader: nil, label_reader: nil, task_reader: nil, scan_slots: nil)
      @tmux = tmux
      @process_tree = process_tree
      @session_name = session_name
      @providers = providers
      @detector = detector
      @poll_interval = poll_interval
      @idle_after = idle_after
      @clock = clock
      @logger = logger
      @error_output = error_output
      @lock_reaper = lock_reaper
      @notifier = notifier
      @idle_alert_after = idle_alert_after
      @event_log = event_log
      @project = project || session_name
      @history = nil
      @alert_history = {}
      @context_reader = context_reader
      @label_reader = label_reader
      @task_reader = task_reader
      @scan_slots = scan_slots
      @panes = {}
      @failed_scans = 0
      @last_scan_at = nil
      @lock = Mutex.new
      @running = false
    end

    # Called on the scan thread after each scan; set once by the daemon,
    # whose queued-prompt delivery is built after this monitor. Anything it
    # raises is logged and swallowed.
    #
    # @return [#call, nil]
    attr_writer :on_scan

    # Scans panes in a background thread until stopped.
    #
    # @return [Thread] the scanning thread
    def start
      @running = true
      @thread = Thread.new do
        while @running
          scan
          after_scan
          send_alerts
          reap_locks
          sleep @poll_interval
        end
      rescue => e
        @error_output.puts "workspace agent: stopped monitoring #{@session_name}: #{e.message}"
        @logger.debug { "session monitor backtrace: #{e.backtrace&.first(5)&.join("\n")}" }
      ensure
        @running = false
      end
    end

    # Stops scanning, and stops any notify command still running. Safe to
    # call more than once.
    #
    # @return [void]
    def stop
      @running = false
      thread = @thread
      @thread = nil
      thread.kill if thread && !thread.equal?(Thread.current)
      @notifier&.stop
    end

    # Refreshes every pane's kind and activity from tmux and the process table.
    # With a limiter injected, the scan runs under one of its machine-wide
    # slots; a scan that can't take a slot is skipped, so other monitors'
    # scans, alerts and lock reaps go ahead regardless. The slot is re-entrant
    # per directory, so the context reads this scan performs through the
    # reader's own limiter over the same slot files run under the slot this
    # scan already holds.
    #
    # @return [void]
    def scan
      return perform_scan unless @scan_slots

      @scan_slots.with_scan_slot { perform_scan }
    end

    # Records a hook event reported by an agent.
    #
    # @param event [Hash] a "session_event" payload
    # @return [void]
    def record(event)
      pane_id = event["pane_id"]
      return @logger.debug { "session event without pane_id dropped" } unless pane_id

      @lock.synchronize do
        pane = (@panes[pane_id] ||= new_pane(pane_id))
        forget_label_source(pane, event["session_id"])
        pane[:session_id] = event["session_id"] || pane[:session_id]
        note_label_source(pane, event)
        pane[:last_event_at] = @clock.now
        # Events from before agents other than Claude Code had hooks carry no kind.
        pane[:hook_kind] = event["agent_kind"] || "claude"
        track_tools(pane, event)
        apply_event(pane, event)
      end
    end

    # @return [Hash] the current view, as `workspace sessions --json` prints it
    def snapshot
      now = @clock.now
      task = active_task
      panes = @lock.synchronize { @panes.values.map { |pane| present(pane, now, task) } }
      {
        "workspace" => @session_name,
        "updated_at" => now.utc.iso8601,
        "task" => present_task(task, panes),
        "panes" => panes.sort_by { |p| p["index"] || 0 }
      }
    end

    # @param pane_id [String] tmux pane id
    # @return [Integer, nil] the pid of the coding agent running in the pane,
    #   or nil when the pane runs none or hasn't been scanned yet. Context
    #   readings recorded without $TMUX_PANE are keyed by this pid.
    def agent_pid(pane_id)
      @lock.synchronize { @panes[pane_id]&.dig(:agent_pid) }
    end

    # @param pane_id [String] tmux pane id
    # @return [String, nil] the pane's kind ("shell", "claude", ...), or nil
    #   when it hasn't been scanned yet
    def pane_kind(pane_id)
      @lock.synchronize { @panes[pane_id]&.fetch(:kind) }
    end

    # @param pane_id [String] tmux pane id
    # @return [String, nil] "working", "idle" or "waiting", or nil when the
    #   pane hasn't been scanned yet
    def pane_state(pane_id)
      now = @clock.now
      @lock.synchronize do
        pane = @panes[pane_id]
        pane && state_of(pane, now - (pane[:last_activity_at] || now))
      end
    end

    # The state the restart busy check goes by. A pane's agent that has ended
    # its turn (a Stop hook) is idle here even though {#pane_state} still says
    # "working" until `alerts.idle_after` of screen quiet; otherwise an agent
    # restarting itself would wait on its own last output. A pane with waits
    # is "waiting". With no turn event seen (or one still in progress) this
    # is {#pane_state}.
    #
    # @param pane_id [String] tmux pane id
    # @return [String, nil] "working", "idle" or "waiting", or nil when the
    #   pane hasn't been scanned yet
    def restart_state(pane_id)
      now = @clock.now
      @lock.synchronize do
        pane = @panes[pane_id]
        next unless pane
        next "waiting" unless pane[:waits].empty?
        next "idle" if pane[:turn_ended]
        state_of(pane, now - (pane[:last_activity_at] || now))
      end
    end

    # What {Workspace::TypingSafety} goes by for a pane: its kind, its
    # {#restart_state}, and the names of the main agent's tools still running.
    #
    # @param pane_id [String] tmux pane id
    # @return [Hash, nil] `:kind`, `:state`, `:open_tools`, or nil when the
    #   pane hasn't been scanned yet
    def typing_facts(pane_id)
      state = restart_state(pane_id)
      @lock.synchronize do
        pane = @panes[pane_id]
        next unless pane && state
        {kind: pane[:kind], state: state, open_tools: (pane[:open_tools] || {}).values.map { |t| t[:tool] }}
      end
    end

    # When the pane's current `done` or `idle` began, from evidence this
    # monitor saw itself; nil when the pane is not `done` or `idle`, has a
    # wait open, or runs no coding agent.
    #
    # A pane whose `done` or `idle` was restored from the event log after a
    # daemon restart may be stale: a turn may have started while no daemon
    # listened. Until this monitor hears a main-agent Stop from it, it reads
    # nil, or, once two of its own scans at least `idle_after` apart saw the
    # same screen, the time of the later one.
    #
    # @param pane_id [String] tmux pane id
    # @return [Time, nil]
    def fresh_since(pane_id)
      now = @clock.now
      @lock.synchronize { (pane = @panes[pane_id]) && fresh_since_of(pane, now) }
    end

    # What a queued-prompt delivery checks a pane against.
    #
    # @param pane_id [String] tmux pane id
    # @return [Hash, nil] `:kind`, `:pane_pid`, `:agent_pid`, `:session_id`,
    #   `:state` (as `sessions` reports it), `:fresh_since` ({#fresh_since}),
    #   `:last_user_prompt_at`, `:hooks` (whether the pane's current agent
    #   has sent this monitor a hook event: `hook_mode` "hooks" in `sessions`)
    #   and `:last_session_start` (`:at`, `:source` and `:session_id` of the
    #   last SessionStart this monitor heard from the pane, or nil); nil when
    #   the pane hasn't been scanned yet
    def delivery_facts(pane_id)
      now = @clock.now
      @lock.synchronize do
        pane = @panes[pane_id]
        next unless pane && pane[:pid]
        {kind: pane[:kind], pane_pid: pane[:pid], agent_pid: pane[:agent_pid], session_id: pane[:session_id],
         state: reported_state(pane, now - (pane[:last_activity_at] || now)), fresh_since: fresh_since_of(pane, now),
         last_user_prompt_at: pane[:last_user_prompt_at], hooks: pane[:hook_kind] == pane[:kind],
         last_session_start: pane[:last_session_start]&.dup}
      end
    end

    # Reaps stale lock holds in the namespaces the panes are working in, when
    # the reaper is due. Runs on the scan thread, never the agent's accept
    # loop, so a slow `git` only delays the next scan. A lock store another
    # process holds is skipped rather than waited on, and retried next time.
    # Anything the reaper raises is logged and swallowed, so reaping can never
    # end the scan thread, not even when the logger itself raises.
    #
    # @return [Integer] how many holders and waiters were reaped
    def reap_locks
      return 0 unless @lock_reaper
      cwds = @lock.synchronize { @panes.values.map { |pane| pane[:cwd] } }
      @lock_reaper.tick(cwds)
    rescue => e
      begin
        @logger.debug { "session monitor: lock reap failed (#{e.class}: #{e.message})" }
      rescue
        nil
      end
      0
    end

    # Runs the notify command for each agent pane that has started waiting, or
    # has stayed idle past the idle alert threshold, since it last alerted.
    # One wait, or one stretch of unchanged output, alerts once, however many
    # scans it spans. Shell panes never alert. The notifier returns at once.
    # An alert counts as sent only once the notifier accepts it, so one the
    # notifier skips (too many runs still going) or that raises is retried on
    # the next scan, and doesn't keep later ones from going out. Anything
    # raised here is logged and swallowed, so alerting can never stall or end
    # the scan thread.
    #
    # @return [Array<Hash>] the environment of each alert sent
    def send_alerts
      return [] unless @notifier
      now = @clock.now
      due = @lock.synchronize { @panes.values.flat_map { |pane| due_alerts(pane, now) } }
      due.filter_map do |target, mark, value, alert, logged|
        next unless @notifier.notify(alert)
        @lock.synchronize { target[mark] = value }
        record_alert(logged)
        alert
      rescue => e
        log_alert_failure(e)
        nil
      end
    rescue => e
      log_alert_failure(e)
      []
    end

    private

    def after_scan
      @on_scan&.call
    rescue => e
      begin
        @logger.debug { "session monitor: after-scan call failed (#{e.class}: #{e.message})" }
      rescue
        nil
      end
    end

    def fresh_since_of(pane, now)
      return nil if NOT_AGENTS.include?(pane[:kind]) || !pane[:waits].empty?
      state = reported_state(pane, now - (pane[:last_activity_at] || now))
      return nil unless %w[done idle].include?(state)
      return pane[:own_quiet_at] if pane[:restored_ready]
      return pane[:done][:since] if state == "done"
      pane[:last_activity_at] && pane[:last_activity_at] + @idle_after
    end

    # The body of {#scan}, run under a machine-wide scan slot when a limiter
    # is injected.
    def perform_scan
      details = @tmux.pane_details(@session_name)
      begin
        tree = @process_tree.snapshot
      rescue Workspace::Error => e
        # The panes' output was not captured this time, so their activity is
        # stale; idle alerts wait for a scan that succeeds.
        @activity_stale = true
        @failed_scans += 1
        warn_failed_scans(e) if @failed_scans == FAILED_SCANS_WARNING
        return @logger.debug { "session monitor: skipping scan: #{e.message}" }
      end
      @activity_stale = false
      @failed_scans = 0
      now = @clock.now
      @history ||= load_history

      changes = @lock.synchronize do
        seen = details.map { |d| d[:id] }
        # A closed pane takes its sub-agent history with it; keeping the entry
        # would leave a row that can never update again.
        closed = @panes.except(*seen)
        closed.each_key { |id| @panes.delete(id) }

        details.each { |detail| refresh_pane(detail, tree, now) }
        @last_scan_at = now
        # Each scan refreshes the per-pane caches that snapshot requests read,
        # so a request answers from what the scan already gathered instead of
        # capturing and reading again per request. Both cost a tmux capture or
        # a transcript read per agent pane, which a burst of requests would
        # otherwise multiply into a process storm.
        @panes.each_value { |pane| refresh_caches(pane, now) }
        closed.values.filter_map { |pane| gone_change(pane, "closed", now) } +
          @panes.values.filter_map { |pane| state_change(pane, now) }
      end
      record_changes(changes)
    end

    NOT_AGENTS = ["shell", "unknown"].freeze
    private_constant :NOT_AGENTS

    # Logged states that mean the pane no longer has an agent.
    GONE_STATES = ["closed", "exited"].freeze
    private_constant :GONE_STATES

    # Each pane's last logged state, keyed on pane id, along with each
    # pane's last idle alert and last waiting alert per agent. Read once, on
    # the first scan; nothing in the log is worth failing a scan over.
    def load_history
      return {} unless @event_log
      @alert_history = @event_log.latest_agent_alerts(@project)
      @event_log.latest_agent_states(@project)
    rescue => e
      @logger.debug { "session monitor: could not read state history (#{e.class}: #{e.message})" }
      {}
    end

    # Takes up a pane's logged state after a daemon restart. The pane's pid is
    # checked too, since a restarted tmux server hands out the same pane ids
    # again. An idle pane stays idle, and keeps the time it went idle, until
    # its output changes. A quiet stretch or a wait the last daemon already
    # alerted for counts as alerted, so a restart doesn't send its alert again.
    def restore_state(pane, detail)
      logged = @history.delete(detail[:id])
      alerts = @alert_history.delete(detail[:id]) || {}
      return unless logged["pane_pid"] == detail[:pid] && !GONE_STATES.include?(logged["state"])
      since = Time.iso8601(logged["since"].to_s)
      pane[:logged_state] = logged["state"]
      pane[:state_since] = since
      # Read back, not seen: {#fresh_since} waits for this monitor's own evidence.
      pane[:restored_ready] = true if %w[done idle].include?(logged["state"])
      case logged["state"]
      when "done" then restore_done(pane, detail, since, logged["stop_reason"], alerts["idle"])
      when "idle" then restore_idle(pane, detail, since, alerts["idle"])
      when "waiting" then restore_waits(pane, detail, since, alerts["waiting"] || {})
      end
    rescue ArgumentError
      nil
    end

    # A done pane still alerts for its quiet stretch, so the stretch the last
    # daemon already alerted for is not alerted for again.
    def restore_done(pane, detail, since, stop_reason, alert)
      pane[:done] = {since: since, stop_reason: stop_reason || "end_turn"}
      at = alert_time(detail, alert, "idle_since")
      return unless at

      pane[:last_activity_at] = at
      pane[:alerted_idle_since] = at
      pane[:quiet_since_restore] = true
    end

    def restore_idle(pane, detail, since, alert)
      pane[:last_activity_at] = since - @idle_after
      pane[:quiet_since_restore] = true
      at = alert_time(detail, alert, "idle_since")
      pane[:alerted_idle_since] = pane[:last_activity_at] if at && (at - pane[:last_activity_at]).abs < 0.002
    end

    # Remembers, per agent, each wait in the pane's logged waiting stretch
    # that the last daemon alerted for. The agent's next notification takes
    # that wait up again, already alerted, unless another hook event from
    # the agent ends it first. A notification that arrived before this first
    # scan is taken up here.
    def restore_waits(pane, detail, stretch_since, alerts)
      alerts.each do |agent_id, alert|
        waiting_since = alert_time(detail, alert, "waiting_since")
        next unless waiting_since && waiting_since - stretch_since > -0.002
        if (wait = pane[:waits][agent_id])
          wait.merge!(since: waiting_since, alerted: true) unless wait[:alerted]
        else
          (pane[:alerted_waits] ||= {})[agent_id] = waiting_since
        end
      end
    end

    # The time logged under +key+ (to the millisecond) of an alert sent for
    # this pane process, or nil.
    def alert_time(detail, alert, key)
      return nil unless alert && alert["pane_pid"] == detail[:pid]
      Time.iso8601(alert[key].to_s)
    rescue ArgumentError
      nil
    end

    def idle_alert_data(pane, idle_since)
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "kind" => "idle",
       "idle_since" => idle_since.utc.iso8601(3)}
    end

    def waiting_alert_data(pane, agent_id, wait)
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "kind" => "waiting",
       "agent_id" => agent_id, "waiting_since" => wait[:since].utc.iso8601(3)}
    end

    # Logged so a restarted daemon knows this stretch or wait already
    # alerted. EventLog#record doesn't raise on a failed write.
    def record_alert(data)
      return unless @event_log
      @event_log.record(type: EventLog::AGENT_ALERT, project: @project, data: data)
    end

    # The change to record when an agent pane's state differs from the one
    # last recorded, or nil. Keeps the pane's record up to date as it goes.
    def state_change(pane, now)
      return nil if pane[:kind] == "unknown"
      return gone_change(pane, "exited", now) if pane[:kind] == "shell"
      state = reported_state(pane, now - (pane[:last_activity_at] || now))
      return nil if state == pane[:logged_state]
      mark_state(pane, state, since_for(pane, state, now))
    end

    def gone_change(pane, state, now)
      return nil if pane[:logged_state].nil? || GONE_STATES.include?(pane[:logged_state])
      mark_state(pane, state, now)
    end

    def mark_state(pane, state, since)
      pane[:logged_state] = state
      pane[:state_since] = since
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "index" => pane[:index],
       "kind" => pane[:kind], "state" => state, "since" => since.utc.iso8601(3),
       "stop_reason" => pane[:done] && pane[:done][:stop_reason]}.compact
    end

    # When the pane entered +state+: a wait from when it was raised, idle from
    # when the output had been quiet long enough, working from its last change.
    def since_for(pane, state, now)
      case state
      when "done" then pane[:done][:since]
      when "waiting" then oldest_wait(pane)[:since]
      when "idle" then pane[:last_activity_at] + @idle_after
      else pane[:last_activity_at] || now
      end
    end

    # Written outside the monitor's lock, so a slow disk never holds up hook
    # events or `sessions`. EventLog#record doesn't raise on a failed write.
    def record_changes(changes)
      return unless @event_log
      changes.each { |data| @event_log.record(type: EventLog::AGENT_STATE, project: @project, data: data) }
    end

    # Each wait alerts on its own, so a second agent in the pane starting to
    # wait alerts even though the pane was already waiting.
    #
    # @return [Array<Array>] per alert due: the hash to mark alerted, the key
    #   and value that mark it, the alert's environment, and the event to log
    #   once it is sent
    def due_alerts(pane, now)
      return [] if NOT_AGENTS.include?(pane[:kind])

      unless pane[:waits].empty?
        return pane[:waits].reject { |_, wait| wait[:alerted] }.map do |agent_id, wait|
          [wait, :alerted, true, alert_env(pane, "waiting", now - wait[:since], wait[:message]),
            waiting_alert_data(pane, agent_id, wait)]
        end
      end

      return [] if @activity_stale || !@idle_alert_after || !pane[:last_activity_at]
      idle_for = now - pane[:last_activity_at]
      return [] if idle_for < @idle_alert_after || pane[:alerted_idle_since] == pane[:last_activity_at]
      [[pane, :alerted_idle_since, pane[:last_activity_at], alert_env(pane, "idle", idle_for, nil),
        idle_alert_data(pane, pane[:last_activity_at])]]
    end

    # Printed once per streak; a scan that succeeds starts a new one.
    def warn_failed_scans(error)
      @error_output.puts "workspace agent: can't read the process table for #{@session_name} " \
        "(#{FAILED_SCANS_WARNING} scans in a row: #{error.message}); idle alerts are paused until it can"
    rescue
      nil
    end

    def log_alert_failure(error)
      @logger.debug { "session monitor: alert failed (#{error.class}: #{error.message})" }
    rescue
      nil
    end

    def alert_env(pane, alert, seconds, message)
      where = "#{@session_name} pane 0.#{pane[:index]} (#{pane[:label]})"
      text = if alert == "waiting"
        "#{where} is waiting#{": #{message}" if message}"
      else
        "#{where} has been idle for #{Duration.humanize(seconds)}"
      end
      {
        "WORKSPACE_ALERT" => alert,
        "WORKSPACE_ALERT_WORKSPACE" => @session_name,
        "WORKSPACE_ALERT_PANE" => "0.#{pane[:index]}",
        "WORKSPACE_ALERT_PANE_ID" => pane[:pane_id].to_s,
        "WORKSPACE_ALERT_KIND" => pane[:kind].to_s,
        "WORKSPACE_ALERT_SECONDS" => seconds.round.to_s,
        "WORKSPACE_ALERT_MESSAGE" => message.to_s,
        "WORKSPACE_ALERT_TEXT" => text
      }.transform_values { |value| value.delete("\0") }
    end

    def new_pane(pane_id)
      {pane_id: pane_id, agents: [], waits: {}, kind: "unknown", index: nil}
    end

    def refresh_pane(detail, tree, now)
      pane = (@panes[detail[:id]] ||= new_pane(detail[:id]))
      restore_state(pane, detail) if @history.key?(detail[:id])
      pane[:index] = detail[:index]
      pane[:title] = detail[:title]
      pane[:cwd] = detail[:cwd]
      pane[:pid] = detail[:pid]

      agent = detect_agent(detail, tree)
      pane[:kind] = agent ? agent[:provider].key : "shell"
      pane[:label] = agent ? agent[:provider].label : detail[:command]
      pane[:agent_pid] = agent && agent[:pid]
      # Nobody is left to answer a prompt once the agent has exited.
      unless agent
        clear_waiting(pane)
        pane.delete(:done)
      end

      refresh_activity(pane, now)
    end

    def detect_agent(detail, tree)
      @detector.call(command: detail[:command], pid: detail[:pid], tree: tree, providers: @providers)
    end

    # Output is hashed rather than compared: a pane's scrollback is large, and
    # only the fact that it changed matters.
    def refresh_activity(pane, now)
      digest = Digest::SHA256.hexdigest(@tmux.capture_pane(@session_name, pane[:index]).to_s)

      if pane[:digest] != digest
        # The first capture after a restart is new to this monitor, not to the
        # pane: a pane restored as idle stays idle until its output changes.
        first_since_restore = pane[:digest].nil? && pane.delete(:quiet_since_restore)
        pane[:digest] = digest
        pane[:digest_seen_at] = now
        pane.delete(:own_quiet_at)
        pane[:last_activity_at] = now unless first_since_restore
      elsif pane[:restored_ready] && !pane[:own_quiet_at] && now - pane[:digest_seen_at] >= @idle_after
        # Two of this monitor's own scans, idle_after apart, saw the same screen.
        pane[:own_quiet_at] = now
      end
      pane[:last_activity_at] ||= now
    end

    # Events that start, end, or restart a turn clear a wait whoever raised it.
    TURN_EVENTS = ["user_prompt", "stop", "session_start", "session_end"].freeze
    private_constant :TURN_EVENTS

    # Waits are kept per agent, since the main agent and parallel sub-agents
    # can each be waiting on a person at once. Any other event from an agent
    # ends that agent's wait: a tool ran after a permission prompt, say. It
    # leaves the other agents' waits alone. Hooks mark a sub-agent's events
    # with its agent_id; SubagentStop always comes from one. Claude Code's
    # Notification payload carries no tool call id, so a wait can't be tied
    # to one prompt more tightly than to the agent that raised it.
    def apply_event(pane, event)
      # A tool starting says nothing about a wait: with tools run side by side, one
      # can start while another waits on a permission prompt.
      return if event["event"] == "tool_start"

      if event["event"] == "notification"
        # A repeat notification during one wait keeps the original start, so
        # the wait is timed (and alerted) once. So does the first one after a
        # restart, for a wait the last daemon alerted for.
        wait = (pane[:waits][event["agent_id"]] ||= resumed_wait(pane, event["agent_id"]))
        wait[:message] = self.class.clean_message(event["message"])
      elsif TURN_EVENTS.include?(event["event"])
        clear_waiting(pane)
        pane[:turn_ended] = (event["event"] != "user_prompt")
      else
        pane[:waits].delete(event_agent_id(event))
        pane[:alerted_waits]&.delete(event_agent_id(event))
      end

      case event["event"]
      when "stop"
        unless event["agent_id"]
          pane[:done] = done_mark(event)
          pane.delete(:restored_ready)
        end
      when "user_prompt", "session_start", "session_end", "tool_use" then pane.delete(:done)
      end
      pane[:last_user_prompt_at] = @clock.now if event["event"] == "user_prompt"
      if event["event"] == "session_start"
        pane[:last_session_start] = {at: @clock.now, source: event["source"], session_id: event["session_id"]}
      end

      case event["event"]
      when "subagent_start"
        pane.delete(:done)
        agent = {
          name: agent_name(event), state: "running", started_at: @clock.now,
          description: self.class.clean_message(event["description"])&.slice(0, 120), tool_use_id: event["tool_use_id"]
        }
        # A sub-agent the agent names itself (Codex) is known by its id from the start.
        agent[:agent_id] = event["subagent_id"] if event["subagent_id"]
        pane[:agents] << agent
      when "subagent_stop"
        # Claude Code's SubagentStop does not say which sub-agent finished, so
        # the oldest running one is closed. With sub-agents running in parallel
        # this can pair the wrong start with the wrong stop; the count stays
        # right, which is what the display needs.
        # When the hook names the sub-agent (agent_id), that one is closed.
        running = pane[:agents].find { |a| a[:state] == "running" && event["agent_id"] && a[:agent_id] == event["agent_id"] } ||
          pane[:agents].find { |a| a[:state] == "running" && !a[:agent_id] } ||
          pane[:agents].find { |a| a[:state] == "running" }
        running&.merge!(state: "done", ended_at: @clock.now)
      when "stop", "session_end"
        pane[:agents].each do |agent|
          agent.merge!(state: "done", ended_at: @clock.now) if agent[:state] == "running"
        end
      end
    end

    # Events that leave no tool of the main agent running.
    TOOL_RESET_EVENTS = ["user_prompt", "stop", "session_start", "session_end"].freeze
    private_constant :TOOL_RESET_EVENTS

    # Keeps what `sessions` says about tools: the main agent's tools still
    # running (by tool_use_id, so tools run side by side finish one by one),
    # and the id of each sub-agent. Only the tool's name is kept, never its
    # input. A sub-agent is not ended by its Task call's PostToolUse, since a
    # background Task returns at once while the sub-agent keeps running.
    def track_tools(pane, event)
      open = (pane[:open_tools] ||= {})
      main = event["agent_id"].nil?
      id = event["tool_use_id"]

      case event["event"]
      when "tool_start", "subagent_start"
        # A sub-agent the agent names itself (Codex's SubagentStart) has no
        # tool call to wait on; Claude Code's comes from its Task call.
        name = event["tool"] || ((event["event"] == "subagent_start" && !event["subagent_id"]) ? "Task" : nil)
        if main && name
          open.delete(id || :anonymous)
          open[id || :anonymous] = {tool: self.class.clean_message(name)&.slice(0, 64), since: @clock.now}
        end
      when "tool_use"
        if id
          open.delete(id)
        elsif main
          open.clear
        end
      when *TOOL_RESET_EVENTS
        open.clear if main
      end

      bind_subagent_id(pane, event["agent_id"]) if event["agent_id"] && event["event"] != "subagent_stop"
    end

    # A sub-agent is named only once it runs. It is paired with an id when
    # exactly one running sub-agent has none, which is the only case that
    # cannot pair the wrong two.
    def bind_subagent_id(pane, agent_id)
      running = pane[:agents].select { |a| a[:state] == "running" }
      return if running.any? { |a| a[:agent_id] == agent_id }

      unbound = running.reject { |a| a[:agent_id] }
      unbound.first[:agent_id] = agent_id if unbound.size == 1
    end

    # The Stop hook says whether the turn ended normally; Claude Code's does
    # not carry a reason today, so a bare Stop is an end of turn.
    def done_mark(event)
      reason = self.class.clean_message(event["stop_reason"])
      {since: @clock.now, stop_reason: reason || "end_turn"}
    end

    def clear_waiting(pane)
      pane[:waits].clear
      pane.delete(:alerted_waits)
    end

    def resumed_wait(pane, agent_id)
      since = pane[:alerted_waits]&.delete(agent_id)
      since ? {since: since, alerted: true} : {since: @clock.now}
    end

    # The pane reports its longest wait, so the time shown is how long a
    # person has been keeping some agent in it waiting.
    def oldest_wait(pane)
      pane[:waits].values.min_by { |wait| wait[:since] }
    end

    # nil is the main agent. A SubagentStop without an agent_id (older Claude
    # Code) still came from some sub-agent, so it never matches the main one.
    def event_agent_id(event)
      event["agent_id"] || ((event["event"] == "subagent_stop") ? :sub_agent : nil)
    end

    def agent_name(event)
      event.dig("agent", "name") || "agent"
    end

    # What `sessions` reports. A finished turn is "done" whatever the screen
    # or a late idle notification says; {#restart_state} and {#pane_state}
    # keep going by activity and waits.
    def reported_state(pane, idle_for)
      pane[:done] ? "done" : state_of(pane, idle_for)
    end

    def state_of(pane, idle_for)
      return "waiting" unless pane[:waits].empty?
      (idle_for < @idle_after) ? "working" : "idle"
    end

    def present(pane, now, task = nil)
      idle_for = now - (pane[:last_activity_at] || now)
      wait = oldest_wait(pane)
      waiting_since = wait&.dig(:since)
      state = reported_state(pane, idle_for)
      state_since = (state == pane[:logged_state]) ? pane[:state_since] : since_for(pane, state, now)
      result = {
        "pane_id" => pane[:pane_id],
        "index" => pane[:index],
        "kind" => pane[:kind],
        "label" => pane[:label],
        "title" => pane[:title],
        "cwd" => pane[:cwd],
        "state" => state,
        "state_since" => state_since&.utc&.iso8601,
        "idle_seconds" => idle_for.round,
        "waiting_since" => waiting_since&.utc&.iso8601,
        "waiting_seconds" => waiting_since && (now - waiting_since).round,
        "waiting_message" => wait&.dig(:message),
        "stop_reason" => pane[:done]&.dig(:stop_reason),
        "session_id" => pane[:session_id],
        "display_label" => display_label(pane, task, now),
        "agents" => pane[:agents].map { |agent|
          {"name" => agent[:name], "state" => agent[:state],
           "started_at" => agent[:started_at]&.utc&.iso8601,
           "ended_at" => agent[:ended_at]&.utc&.iso8601}
        }
      }
      unless pane[:kind] == "shell"
        apply_context(result, pane, now)
        apply_tool_status(result, pane)
        apply_hook_mode(result, pane)
      end
      result
    end

    # `hook_mode`: "hooks" once the daemon has had a hook event from the
    # pane's current kind of agent, "scrape" for a recognized agent it has
    # not (no hooks installed, not trusted yet, or none since a daemon
    # restart), "none" for a pane not yet identified. `hook_events`: the event
    # types that kind of agent's hooks can report, whatever the mode.
    def apply_hook_mode(result, pane)
      provider = @providers.find { |p| p.key == pane[:kind] }
      result["hook_mode"] = if provider.nil?
        "none"
      else
        (pane[:hook_kind] == pane[:kind]) ? "hooks" : "scrape"
      end
      result["hook_events"] = provider ? provider.hook_events.dup : []
    end

    # `last_event_at`, `current_tool` (the name of the main agent's most
    # recently started tool still running, else nil), `current_tool_since`
    # and the running `subagents`. A coding-agent pane no hook has reached
    # reports nulls and an empty list; a shell pane carries none of these.
    def apply_tool_status(result, pane)
      current = pane[:open_tools]&.values&.last
      result["last_event_at"] = pane[:last_event_at]&.utc&.iso8601
      result["current_tool"] = current&.dig(:tool)
      result["current_tool_since"] = current&.dig(:since)&.utc&.iso8601
      result["subagents"] = pane[:agents].select { |a| a[:state] == "running" }.map { |agent|
        {"agent_id" => agent[:agent_id], "description" => agent[:description] || agent[:name],
         "since" => agent[:started_at]&.utc&.iso8601}
      }
    end

    # Longest prompt kept as a label fallback.
    LABEL_PROMPT_LENGTH = TranscriptLabel::MAX_LENGTH

    # A different session in the same pane starts with no label source: the
    # old transcript and prompt describe someone else's work.
    def forget_label_source(pane, session_id)
      return unless session_id && pane[:session_id] && session_id != pane[:session_id]

      pane.delete(:transcript_path)
      pane.delete(:last_prompt)
    end

    # Keeps the transcript path and the last prompt, in memory only; neither
    # is written to the event log or anywhere else.
    def note_label_source(pane, event)
      path = event["transcript_path"]
      pane[:transcript_path] = path if path.is_a?(String)
      prompt = event["prompt"]
      return unless event["event"] == "user_prompt" && prompt.is_a?(String)

      pane[:last_prompt] = self.class.clean_message(prompt)&.slice(0, LABEL_PROMPT_LENGTH)
    end

    # What a person would call this pane: the task's title, else the transcript's
    # AI title, else the last prompt, else nil. A shell pane has none.
    #
    # The task's title is cheap to read, so it is read per request; the
    # transcript read is not, so it is served from the cache the scan thread
    # refreshes, read here only when the cache is missing, keyed to something
    # that changed (a new session, prompt or task), or past its freshness
    # grace because the scan is late.
    def display_label(pane, task = nil, now = @clock.now)
      return nil if pane[:kind] == "shell"

      title = task_title(task)
      return title if title

      cached = pane[:label_cache]
      key = label_cache_key(pane)
      if cached && cached[:key] == key && cache_fresh?(cached, now)
        cached[:label]
      else
        transcript = pane[:transcript_path] && @label_reader&.read(pane[:transcript_path])
        label = transcript&.dig(:title) || pane[:last_prompt] || transcript&.dig(:last_prompt)
        pane[:label_cache] = {label: label, key: key, at: now}
        label
      end
    end

    # Everything the cached label depends on: another value for any of these
    # means the cached label describes a different session or prompt. The
    # task's title never enters it — it is read per request and comes ahead
    # of the cache.
    def label_cache_key(pane)
      [pane[:session_id], pane[:transcript_path], pane[:last_prompt]]
    end

    # A cache is fresh while the scan thread is refreshing it on schedule,
    # and no cache is trusted before the first scan. Once it goes past this
    # grace, requests read for themselves again, so a dead or stalled scan
    # thread degrades to the old per-request reads rather than serving
    # ever-staler data.
    def cache_fresh?(cached, now)
      @last_scan_at && (now - cached[:at]) <= @poll_interval * CACHE_GRACE_INTERVALS
    end

    # What the scan thread calls per pane to refresh what requests read.
    # Runs under the monitor's lock like the rest of the scan, so a request
    # during a scan waits for it rather than interleaving its own captures.
    def refresh_caches(pane, now)
      return if pane[:kind] == "shell"

      refresh_context_cache(pane, now) if @context_reader
      pane[:label_cache] = {label: read_label(pane), key: label_cache_key(pane), at: now}
    end

    # Reads the label uncached, for the scan thread's refresh. A failure
    # reads as no transcript label — falling back to the last prompt — so a
    # bad transcript file never ends the scan thread, which would stop all
    # monitoring.
    def read_label(pane)
      transcript = pane[:transcript_path] && @label_reader&.read(pane[:transcript_path])
      transcript&.dig(:title) || pane[:last_prompt] || transcript&.dig(:last_prompt)
    rescue => e
      @logger.debug { "session monitor: label read failed (#{e.class}: #{e.message})" }
      pane[:last_prompt]
    end

    # The project's active task, or nil. A failing reader reads as no task: the
    # snapshot must never fail over a task file.
    def active_task
      @task_reader&.call(@project)
    rescue => e
      @logger.debug { "session monitor: task read failed (#{e.class}: #{e.message})" }
      nil
    end

    def task_title(task)
      title = task&.dig("title")
      title.is_a?(String) ? self.class.clean_message(title)&.slice(0, LABEL_PROMPT_LENGTH) : nil
    end

    # The task's identity plus a status derived from the coding-agent panes
    # when read, never stored: blocked when any agent waits, else working when
    # any works, else done when any has ended its turn, else idle.
    def present_task(task, panes)
      return nil unless task

      states = panes.reject { |p| p["kind"] == "shell" }.map { |p| p["state"] }
      status = %w[waiting working done].find { |s| states.include?(s) }
      {
        "id" => task["id"], "title" => task["title"], "ref" => task["ref"], "branch" => task["branch"],
        "status" => (status == "waiting") ? "blocked" : (status || "idle")
      }
    end

    # Stamps `context_pct`/`context_error`/`context_updated_at` onto a
    # coding-agent pane's presented hash. A pane whose kind is "shell" never
    # gets these fields at all — never guessed, and never confused with a
    # pane that legitimately has no coding agent to report on.
    #
    # The reading is served from the cache the scan thread refreshes, read
    # here only when the cache is missing, keyed to another session, or past
    # its freshness grace — in scrape mode a read is a tmux capture of the
    # pane, which a burst of requests would otherwise multiply.
    def apply_context(result, pane, now = @clock.now)
      return unless @context_reader

      reading = context_reading(pane, now)
      result["context_pct"] = reading[:pct]
      result["context_error"] = reading[:error]
      result["context_updated_at"] = reading[:updated_at]
    end

    # The pane's context reading, from the cache when fresh, read and cached
    # otherwise. A reading for another session of the same pane is stale even
    # when fresh: the reading describes that session's context window.
    def context_reading(pane, now = @clock.now)
      cached = pane[:context_cache]
      if cached && cached[:session_id] == pane[:session_id] && cache_fresh?(cached, now)
        return cached[:reading]
      end
      reading = read_context(pane)
      pane[:context_cache] = {reading: reading, session_id: pane[:session_id], at: now}
      reading
    end

    # What the scan thread calls per pane to refresh the context cache.
    def refresh_context_cache(pane, now)
      pane[:context_cache] = {reading: read_context(pane), session_id: pane[:session_id], at: now}
    end

    # Reads the context uncached. A failure reads as no reading, so neither a
    # scan nor a request ever fails over it.
    def read_context(pane)
      @context_reader.read(pane_id: pane[:pane_id], agent_pid: pane[:agent_pid], current_session_id: pane[:session_id], kind: pane[:kind])
    rescue => e
      @logger.debug { "session monitor: context read failed (#{e.class}: #{e.message})" }
      {pct: nil, error: ContextReasons::NO_READING, updated_at: nil}
    end
  end
end
