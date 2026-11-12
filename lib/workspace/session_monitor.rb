require "time"

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
  # other hook event; a wait that begins after that alerts as usual. Pending
  # permission requests are not logged, so a wait filed under a sub-agent can't
  # be matched to a Notification, which names no agent: if its dialog asks again
  # after a restart, it alerts again with a new start time.
  class SessionMonitor
    # What this daemon can do that an older one can't, listed in {#snapshot}:
    # `parked_resume` is the fields {WorkflowPanes} proves a turn's end from.
    FEATURES = ["parked_resume"].freeze

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
    #   `context_error`, and `context_updated_at` from {#snapshot}
    # @param label_reader [Workspace::TranscriptLabel, nil] reads a pane's
    #   transcript for its `display_label`; nil falls back to the last prompt
    #   the daemon saw
    # @param task_reader [#call, nil] given the project name, returns its active task
    #   record (a Hash with `id` and `title`) or nil; its title is the first
    #   `display_label` source and the snapshot reports the task. nil reports none.
    # @param scan_slots [Workspace::ScanSlotLimiter, nil] bounds how many
    #   monitors scan at once, machine-wide; a scan that can't take a slot is
    #   skipped rather than waited out. nil scans without a limit.
    # @param question_check [Workspace::QuestionClosedCheck] reads whether a
    #   question dialog is gone from a pane's screen
    # @param scanner [Workspace::PaneScanner, nil] the scan's pane, process and
    #   screen reads; nil builds one over +tmux+, +process_tree+, +providers+,
    #   +detector+, +question_check+ and +event_log+
    def initialize(tmux:, process_tree:, session_name:,
      providers: AgentProvider.all, detector: AgentDetector.new, poll_interval: DEFAULT_POLL_INTERVAL, idle_after: AgentProvider::DEFAULT_IDLE_AFTER,
      clock: Time, logger: Workspace::Logger.new, error_output: $stderr, lock_reaper: nil,
      notifier: nil, idle_alert_after: nil, event_log: nil, project: nil,
      context_reader: nil, label_reader: nil, task_reader: nil, scan_slots: nil, question_check: QuestionClosedCheck.new, scanner: nil)
      @session_name = session_name
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
      @view = PaneView.new(context_reader: context_reader, label_reader: label_reader, task_reader: task_reader,
        providers: providers, idle_after: idle_after, poll_interval: poll_interval, project: @project, logger: logger)
      @scan_slots = scan_slots
      @scanner = scanner || PaneScanner.new(tmux: tmux, process_tree: process_tree, session_name: session_name,
        providers: providers, detector: detector, question_check: question_check, idle_after: idle_after,
        clock: clock, logger: logger, error_output: error_output, event_log: event_log, project: @project)
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

    # Re-reads one pane now instead of waiting for the next {#scan}, so a
    # caller about to refuse on a stale reading (a shell seen just before an
    # agent started in the pane) can decide on a fresh one. Updates the pane's
    # cached kind and activity, ends a permission wait whose dialog is gone, and
    # closes a question whose dialog the screen proves gone (the same hold
    # applies); alerts and logged changes are left to the next scan. Reads once; a failed tmux or process listing leaves the cache
    # as it was. Takes no scan slot, which a busy scan thread or another
    # daemon would hold, so the rescan can answer under load. A scan that read
    # the process table before the agent started may still overwrite the fresh
    # kind; the next scan corrects it.
    #
    # @param pane_id [String] tmux pane id
    # @return [void]
    def rescan_pane(pane_id)
      detail = @scanner.pane_details.find { |d| d[:id] == pane_id }
      return unless detail
      tree = @scanner.process_snapshot
      now = @clock.now
      @lock.synchronize do
        @scanner.load_history
        refresh_pane(detail, tree, now)
      end
      nil
    rescue Workspace::Error => e
      @logger.debug { "session monitor: pane rescan skipped: #{e.message}" }
      nil
    end

    # Records a hook event reported by an agent.
    #
    # @param event [Hash] a "session_event" payload
    # @return [void]
    def record(event)
      pane_id = event["pane_id"]
      return @logger.debug { "session event without pane_id dropped" } unless pane_id

      @lock.synchronize do
        @panes[pane_id] = PaneEvents.apply(@panes[pane_id] || PaneEvents.new_pane(pane_id), event, now: @clock.now)
      end
      nil
    end

    # The current view, as `workspace sessions --json` prints it. The task
    # is read before the lock; each pane row is built by {PaneView#present}
    # while the lock is held, as new Hashes that share nothing with the pane.
    #
    # @return [Hash] {PaneView.document}
    def snapshot
      now = @clock.now
      task = @view.task
      panes = @lock.synchronize { @panes.values.map { |pane| @view.present(pane, now, task, scanned_at: @last_scan_at) } }
      PaneView.document(workspace: @session_name, now: now, features: FEATURES, task: task, panes: panes)
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
        pane && PaneStates.state_of(pane, now - (pane[:last_activity_at] || now), @idle_after)
      end
    end

    # @param pane_id [String] tmux pane id
    # @return [Integer, nil] how many sub-agents of the pane's agent are running,
    #   or nil when the pane hasn't been scanned yet
    def running_subagents(pane_id)
      @lock.synchronize { @panes[pane_id]&.fetch(:agents)&.count { |agent| agent[:state] == "running" } }
    end

    # @param pane_id [String] tmux pane id
    # @return [Integer, nil] how many sub-agents were started in the pane and not
    #   yet ended by their own SubagentStop, or nil when the pane hasn't been
    #   scanned yet. Unlike {#running_subagents}, a main-agent Stop leaves the
    #   count alone, so a background sub-agent outliving the turn still counts.
    #   A SessionStart or SessionEnd clears it; a missed stop can leave a stale
    #   entry until then.
    def background_subagents(pane_id)
      @lock.synchronize { @panes[pane_id]&.fetch(:background_subagents, nil)&.size || (@panes[pane_id] && 0) }
    end

    # Marks the pane's turn as failed without a hook event, as agentd does after
    # a restart that found the agent stopped on an error. Ends the turn, so a late
    # idle notification opens no wait. Does nothing for a pane not scanned yet.
    #
    # @param pane_id [String] tmux pane id
    # @return [void]
    def mark_turn_failed(pane_id)
      @lock.synchronize do
        pane = @panes[pane_id]
        next unless pane
        pane[:turn_failed] = {session_id: pane[:session_id]}
        pane[:turn_ended] = true
      end
      nil
    end

    # The state the restart busy check goes by. A pane's agent that has ended
    # its turn (a Stop hook) is idle here even though {#pane_state} still says
    # "working" until {AgentProvider::DEFAULT_IDLE_AFTER} of screen quiet; otherwise an agent
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
        PaneStates.state_of(pane, now - (pane[:last_activity_at] || now), @idle_after)
      end
    end

    # What the monitor knows of the main agent's turn being over: a main Stop
    # from hook-mode Claude Code, with no main tool, sub-agent start, prompt or
    # session event since, no wait, no open tool and no failed turn. Stopped
    # sub-agents and redraws say nothing about it. The times are this monitor's
    # own, so a daemon restart forgets them and reads `no_stop_seen`.
    #
    # @param pane_id [String] tmux pane id
    # @return [Hash] `:since` and `:transcript_path` with the proof, else
    #   `:missing`: the first thing that failed, by name
    def main_turn_evidence(pane_id)
      @lock.synchronize do
        pane = @panes[pane_id]
        missing = pane ? PaneStates.main_turn_missing(pane) : "pane_unknown"
        missing ? {missing: missing} : {since: pane[:main_stopped_at], transcript_path: pane[:transcript_path]}
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
      @lock.synchronize { (pane = @panes[pane_id]) && PaneStates.fresh_since(pane, now, @idle_after) }
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
         state: PaneStates.reported_state(pane, now - (pane[:last_activity_at] || now), @idle_after), fresh_since: PaneStates.fresh_since(pane, now, @idle_after),
         last_user_prompt_at: pane[:last_user_prompt_at], hooks: pane[:hook_kind] == pane[:kind],
         last_session_start: pane[:last_session_start]&.dup}
      end
    end

    # What a follow-up watch checks a pane against: the identity fields of
    # {#delivery_facts} plus how busy the pane is. `:agents_running` counts
    # sub-agents in state "running"; a main-thread Stop marks all of them done,
    # so a background sub-agent is not counted after one.
    #
    # @param pane_id [String] tmux pane id
    # @return [Hash, nil] `:kind`, `:pane_pid`, `:agent_pid`, `:session_id`,
    #   `:hooks`, `:last_activity_at`, `:open_tools` (how many tool calls are
    #   open) and `:agents_running`; nil when the pane hasn't been scanned yet
    def followup_facts(pane_id)
      @lock.synchronize do
        pane = @panes[pane_id]
        next unless pane && pane[:pid]
        {kind: pane[:kind], pane_pid: pane[:pid], agent_pid: pane[:agent_pid], session_id: pane[:session_id],
         hooks: pane[:hook_kind] == pane[:kind], last_activity_at: pane[:last_activity_at],
         open_tools: (pane[:open_tools] || {}).size,
         agents_running: pane[:agents].count { |agent| agent[:state] == "running" }}
      end
    end

    # Sends one `handoff_stalled` alert for a pane that has not handed off
    # after its follow-ups. Writes no `AGENT_ALERT` event, since restored
    # alert state reads only the waiting and idle kinds. Never raises.
    #
    # @param pane_id [String] tmux pane id
    # @param seconds [Numeric] how long the pane has been waited on
    # @param followups [Integer] how many follow-ups were sent
    # @return [Boolean] whether the notifier accepted the alert; false with
    #   no notifier, an unscanned pane, or a notifier that raised
    def alert_handoff_stalled(pane_id, seconds:, followups:)
      return false unless @notifier
      pane = @lock.synchronize { @panes[pane_id]&.dup }
      return false unless pane
      env = PaneAlerts.env(pane, "handoff_stalled", seconds, nil, session_name: @session_name, followups: followups)
      !!@notifier.notify(env)
    rescue => e
      log_alert_failure(e)
      false
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
    # the next scan, and doesn't keep later ones from going out. Which alerts
    # are due comes from {PaneAlerts.due}; each one sent is marked by its
    # +[pane_id, wait_key]+ on the pane found under that id now, through
    # {PaneAlerts.mark}. The stale flag and the failed-scan streak stay here:
    # they are scan state, which the rule takes as +stale:+. Anything
    # raised here is logged and swallowed, so alerting can never stall or end
    # the scan thread.
    #
    # @return [Array<Hash>] the environment of each alert sent
    def send_alerts
      return [] unless @notifier
      now = @clock.now
      due = @lock.synchronize do
        @panes.values.flat_map do |pane|
          PaneAlerts.due(pane, now, session_name: @session_name, idle_alert_after: @idle_alert_after, stale: @activity_stale)
        end
      end
      due.filter_map do |alert|
        next unless @notifier.notify(alert.env)
        pane_id, wait_key = alert.key
        @lock.synchronize { (pane = @panes[pane_id]) && (@panes[pane_id] = PaneAlerts.mark(pane, wait_key, alert.value)) }
        record_alert(alert.logged)
        alert.env
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

    # The body of {#scan}, run under a machine-wide scan slot when a limiter
    # is injected.
    def perform_scan
      details = @scanner.pane_details
      begin
        tree = @scanner.process_snapshot
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
      @scanner.load_history

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
        @panes.each_value { |pane| @view.refresh(pane, now) }
        closed.values.filter_map { |pane| PaneStates.gone_change(pane, "closed", now) } +
          @panes.values.filter_map { |pane| PaneStates.state_change(pane, now, @idle_after) }
      end
      record_changes(changes)
    end

    # Logged so a restarted daemon knows this stretch or wait already
    # alerted. EventLog#record doesn't raise on a failed write.
    def record_alert(data)
      return unless @event_log
      @event_log.record(type: EventLog::AGENT_ALERT, project: @project, data: data)
    end

    # Written outside the monitor's lock, so a slow disk never holds up hook
    # events or `sessions`. EventLog#record doesn't raise on a failed write.
    def record_changes(changes)
      return unless @event_log
      changes.each { |data| @event_log.record(type: EventLog::AGENT_STATE, project: @project, data: data) }
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

    def refresh_pane(detail, tree, now)
      @panes[detail[:id]] = @scanner.refresh(@panes[detail[:id]] || PaneEvents.new_pane(detail[:id]), detail, tree, now)
    end
  end
end
