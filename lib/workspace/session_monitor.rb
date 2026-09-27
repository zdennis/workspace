require "time"
require "digest"

module Workspace
  # Tracks which panes in a workspace are running a coding agent, whether each
  # one is working, idle, or waiting on a person, and what sub-agents they have
  # started.
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
  class SessionMonitor
    # A pane whose output has not changed for this long is reported idle. Agents
    # spend most of a turn blocked on the network, so CPU is not a usable
    # signal; changing output is.
    DEFAULT_IDLE_AFTER = 30

    # @param tmux [Workspace::Tmux] pane listing and capture
    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param session_name [String] tmux session to watch
    # @param providers [Array<Workspace::AgentProvider>] agents to recognize
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
    def initialize(tmux:, process_tree:, session_name:,
      providers: AgentProvider.all, poll_interval: 2, idle_after: DEFAULT_IDLE_AFTER,
      clock: Time, logger: Workspace::Logger.new, error_output: $stderr, lock_reaper: nil,
      notifier: nil, idle_alert_after: nil)
      @tmux = tmux
      @process_tree = process_tree
      @session_name = session_name
      @providers = providers
      @poll_interval = poll_interval
      @idle_after = idle_after
      @clock = clock
      @logger = logger
      @error_output = error_output
      @lock_reaper = lock_reaper
      @notifier = notifier
      @idle_alert_after = idle_alert_after
      @panes = {}
      @lock = Mutex.new
      @running = false
    end

    # Scans panes in a background thread until stopped.
    #
    # @return [Thread] the scanning thread
    def start
      @running = true
      @thread = Thread.new do
        while @running
          scan
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
    #
    # @return [void]
    def scan
      details = @tmux.pane_details(@session_name)
      begin
        tree = @process_tree.snapshot
      rescue Workspace::Error => e
        # The panes' output was not captured this time, so their activity is
        # stale; idle alerts wait for a scan that succeeds.
        @activity_stale = true
        return @logger.debug { "session monitor: skipping scan: #{e.message}" }
      end
      @activity_stale = false
      now = @clock.now

      @lock.synchronize do
        seen = details.map { |d| d[:id] }
        # A closed pane takes its sub-agent history with it; keeping the entry
        # would leave a row that can never update again.
        @panes.delete_if { |id, _| !seen.include?(id) }

        details.each { |detail| refresh_pane(detail, tree, now) }
      end
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
        pane[:session_id] = event["session_id"] || pane[:session_id]
        pane[:last_event_at] = @clock.now
        apply_event(pane, event)
      end
    end

    # @return [Hash] the current view, as `workspace sessions --json` prints it
    def snapshot
      now = @clock.now
      panes = @lock.synchronize { @panes.values.map { |pane| present(pane, now) } }
      {
        "workspace" => @session_name,
        "updated_at" => now.utc.iso8601,
        "panes" => panes.sort_by { |p| p["index"] || 0 }
      }
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
    # An alert counts as sent only once the notifier accepts it, so one that
    # raises is retried on the next scan and doesn't keep later ones from
    # going out. Anything raised here is logged and swallowed, so alerting can
    # never stall or end the scan thread.
    #
    # @return [Array<Hash>] the environment of each alert sent
    def send_alerts
      return [] unless @notifier
      now = @clock.now
      due = @lock.synchronize { @panes.values.filter_map { |pane| due_alert(pane, now) } }
      due.filter_map do |pane, mark, value, alert|
        @notifier.notify(alert)
        @lock.synchronize { pane[mark] = value }
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

    NOT_AGENTS = ["shell", "unknown"].freeze
    private_constant :NOT_AGENTS

    # @return [Array, nil] the pane, the key and value that mark it alerted,
    #   and the alert's environment; nil when no alert is due
    def due_alert(pane, now)
      return nil if NOT_AGENTS.include?(pane[:kind])

      if (since = pane[:waiting_since])
        return nil if pane[:alerted_waiting_since] == since
        return [pane, :alerted_waiting_since, since, alert_env(pane, "waiting", now - since, pane[:waiting_message])]
      end

      return nil if @activity_stale || !@idle_alert_after || !pane[:last_activity_at]
      idle_for = now - pane[:last_activity_at]
      return nil if idle_for < @idle_alert_after || pane[:alerted_idle_since] == pane[:last_activity_at]
      [pane, :alerted_idle_since, pane[:last_activity_at], alert_env(pane, "idle", idle_for, nil)]
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
      {pane_id: pane_id, agents: [], kind: "unknown", index: nil}
    end

    def refresh_pane(detail, tree, now)
      pane = (@panes[detail[:id]] ||= new_pane(detail[:id]))
      pane[:index] = detail[:index]
      pane[:title] = detail[:title]
      pane[:cwd] = detail[:cwd]
      pane[:pid] = detail[:pid]

      agent = detect_agent(detail, tree)
      pane[:kind] = agent ? agent[:provider].key : "shell"
      pane[:label] = agent ? agent[:provider].label : detail[:command]
      pane[:agent_pid] = agent && agent[:pid]
      # Nobody is left to answer a prompt once the agent has exited.
      clear_waiting(pane) unless agent

      refresh_activity(pane, now)
    end

    # The agent may be the pane's foreground command or buried under a shell
    # wrapper, so the pane's own command is checked before the tree is walked.
    def detect_agent(detail, tree)
      basename = File.basename(detail[:command].to_s).downcase
      direct = @providers.find { |p| p.executable == basename }
      return {provider: direct, pid: detail[:pid]} if direct

      @providers.each do |provider|
        exact_only = provider.path_segment_matching? ? [] : [provider.executable]
        match = tree.find_descendant(detail[:pid], [provider.executable],
          exclude: provider.background_markers, include_root: true, exact_only: exact_only)
        return {provider: provider, pid: match[:pid]} if match
      end
      nil
    end

    # Output is hashed rather than compared: a pane's scrollback is large, and
    # only the fact that it changed matters.
    def refresh_activity(pane, now)
      digest = Digest::SHA256.hexdigest(@tmux.capture_pane(@session_name, pane[:index]).to_s)

      if pane[:digest] != digest
        pane[:digest] = digest
        pane[:last_activity_at] = now
      end
      pane[:last_activity_at] ||= now
    end

    # Any event but a notification means the agent is moving again: a prompt
    # was submitted, a tool ran after a permission prompt, or the turn ended.
    def apply_event(pane, event)
      if event["event"] == "notification"
        # A repeat notification during one wait keeps the original start, so
        # the wait is timed (and alerted) once.
        pane[:waiting_since] ||= @clock.now
        pane[:waiting_message] = event["message"]
      else
        clear_waiting(pane)
      end

      case event["event"]
      when "subagent_start"
        pane[:agents] << {name: agent_name(event), state: "running", started_at: @clock.now}
      when "subagent_stop"
        # Claude Code's SubagentStop does not say which sub-agent finished, so
        # the oldest running one is closed. With sub-agents running in parallel
        # this can pair the wrong start with the wrong stop; the count stays
        # right, which is what the display needs.
        running = pane[:agents].find { |a| a[:state] == "running" }
        running&.merge!(state: "done", ended_at: @clock.now)
      when "stop", "session_end"
        pane[:agents].each do |agent|
          agent.merge!(state: "done", ended_at: @clock.now) if agent[:state] == "running"
        end
      end
    end

    def clear_waiting(pane)
      pane[:waiting_since] = nil
      pane[:waiting_message] = nil
    end

    def agent_name(event)
      event.dig("agent", "name") || "agent"
    end

    def state_of(pane, idle_for)
      return "waiting" if pane[:waiting_since]
      (idle_for < @idle_after) ? "working" : "idle"
    end

    def present(pane, now)
      idle_for = now - (pane[:last_activity_at] || now)
      waiting_since = pane[:waiting_since]
      {
        "pane_id" => pane[:pane_id],
        "index" => pane[:index],
        "kind" => pane[:kind],
        "label" => pane[:label],
        "title" => pane[:title],
        "cwd" => pane[:cwd],
        "state" => state_of(pane, idle_for),
        "idle_seconds" => idle_for.round,
        "waiting_since" => waiting_since&.utc&.iso8601,
        "waiting_seconds" => waiting_since && (now - waiting_since).round,
        "waiting_message" => pane[:waiting_message],
        "session_id" => pane[:session_id],
        "agents" => pane[:agents].map { |agent|
          {"name" => agent[:name], "state" => agent[:state],
           "started_at" => agent[:started_at]&.utc&.iso8601,
           "ended_at" => agent[:ended_at]&.utc&.iso8601}
        }
      }
    end
  end
end
