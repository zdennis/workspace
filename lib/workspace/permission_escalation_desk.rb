module Workspace
  # The daemon's inbox item for a permission request the policy left to the person. One per workspace, in
  # {HookFanout}'s desks.
  #
  # An escalated request is one the policy answered `ask` for (the hang guard's cap included), or one with no decision
  # while the person has configured a policy (a broken config included) or the pane is bound to a live run. A request
  # the hang guard denied (`decision` `deny`) opens nothing, as the agent was told. Claude sends it as a `permission_request` event and Codex as
  # a `notification` with `notification_type` `permission_request`; a request the policy allowed or denied opens
  # nothing, and neither does any other notification. The item is an `alert` keyed
  # `permission:<workspace>:<pane>:<agent_id or main>`, so a pane's sub-agents each get one.
  #
  # Any later event for that pane and agent other than `permission_request` and `notification` closes it, and
  # {#scan} closes the ones whose pane has stopped waiting, for a dialog answered with no hook. The item names
  # the tool, the first line of the input's {ToolInputSummary} and the rule; the raw input is never copied.
  #
  # Whatever goes wrong is logged and swallowed, so the desk never breaks the fan-out.
  class PermissionEscalationDesk
    # Whom an item is closed by.
    CLOSED_BY = {"kind" => "permission_escalation"}.freeze

    # Seconds an item is left open before {#scan} may close it for a pane showing no wait, since the monitor
    # opens a wait from a later notification.
    GRACE = 30

    # Seconds a read of whether a policy is configured is kept.
    CONFIGURED_TTL = 5

    # The agent part of a main agent's key.
    MAIN = "main"

    OPENING = %w[permission_request notification].freeze

    # Events that end a turn or a conversation, which close the item by key even when this process did not open it
    # (after a daemon restart). Closing by key locks and rewrites the inbox file, so a tool event, which is far more
    # frequent, closes only an item this process opened.
    TURN_ENDING = %w[stop turn_failed user_prompt session_start session_end subagent_stop].freeze
    private_constant :OPENING, :TURN_ENDING

    # @param inbox_store [Workspace::InboxStore] the workspace's inbox
    # @param policy_config [Workspace::PermissionPolicyConfig] says whether a policy is configured
    # @param workspace [String]
    # @param project [String, nil] the parent project
    # @param monitor [#snapshot] the workspace's session monitor, for {#scan}
    # @param pane_bindings [Workspace::PaneBindings, nil] says which run a pane is bound to; with `tmux:`, an undecided request from a pane bound to a live run escalates even when no policy is configured
    # @param tmux [Workspace::Tmux, nil] looks up a pane's session and slot, to tell a stale binding
    # @param clock [#call] returns the current Time
    # @param logger [#debug]
    def initialize(inbox_store:, policy_config:, workspace:, project:, monitor:, pane_bindings: nil, tmux: nil, clock: -> { Time.now }, logger: Workspace::Logger.new)
      @inbox_store = inbox_store
      @policy_config = policy_config
      @workspace = workspace
      @project = project
      @monitor = monitor
      @pane_bindings = pane_bindings
      @tmux = tmux
      @clock = clock
      @logger = logger
      @configured = nil
      @open = {}
    end

    # @param message [Hash] a `session_event` message
    # @return [void]
    def session_event(message)
      pane_id = message["pane_id"]
      return unless pane_id.is_a?(String)

      if escalated?(message)
        open_item(message, pane_id)
      elsif !OPENING.include?(message["event"])
        key = key_for(pane_id, message["agent_id"])
        # A SubagentStop without an agent_id would map to the main agent's key, whose dialog may be open.
        return if message["event"] == "subagent_stop" && message["agent_id"].nil?
        close_item(key) if TURN_ENDING.include?(message["event"]) || @open.key?(key)
      end
    rescue => e
      @logger.debug { "permission escalation: #{message["event"]} not handled (#{e.class}: #{e.message})" }
    end

    # Closes a pane's open items once the pane shows nothing a person could be asked: no wait of any kind (main,
    # sub-agent, filed under nil or found on the screen), not in state `waiting`, and no permission request the
    # monitor still holds while the pane is not idle (a deny or Esc sends no hook, so a count can stay up), and {GRACE} seconds after the item was last written. Judged by pane, not by agent, as
    # the wait that goes with a request may arrive late, never, or under another key.
    #
    # @return [void]
    def scan
      items = open_items
      return if items.empty?

      rows = @monitor.snapshot.fetch("panes").to_h { |row| [row["pane_id"], row] }
      now = @clock.call
      items.each do |item|
        next if now - Time.iso8601(item["updated_at"]) < GRACE
        close_item(item["dedupe_key"]) unless busy?(rows[item.dig("links", "pane")])
      rescue => e
        @logger.debug { "permission escalation: scan of #{item["dedupe_key"]} failed (#{e.class}: #{e.message})" }
      end
    rescue => e
      @logger.debug { "permission escalation: scan failed (#{e.class}: #{e.message})" }
    end

    private

    def escalated?(message)
      request = message["event"] == "permission_request" ||
        (message["event"] == "notification" && message["notification_type"] == "permission_request")
      return false unless request

      case message["decision"]
      when "ask" then true
      when nil then bound_to_run?(message["pane_id"]) || configured?
      else false
      end
    end

    # A pane bound to a live run has nobody to answer a dialog, so it escalates whatever the policy config says. A binding
    # that can't be read or checked counts as unbound. The daemon's own TMUX_PANE is cleared, so this checks the event's pane.
    def bound_to_run?(pane)
      return false unless @pane_bindings && @tmux && pane.is_a?(String)
      entry = @pane_bindings.binding_for(pane)
      return false unless entry && entry["kind"] == "run"
      !@pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
    rescue Workspace::Error, SystemCallError
      false
    end

    def configured?
      now = @clock.call
      if @configured.nil? || now - @configured[:at] >= CONFIGURED_TTL
        @configured = {at: now, value: @policy_config.configured?(workspace: @workspace, project: @project)}
      end
      @configured[:value]
    end

    def open_item(message, pane_id)
      key = key_for(pane_id, message["agent_id"])
      @inbox_store.upsert(item(message, pane_id, key), reopen: true)
      @open[key] = true
    end

    def close_item(key)
      @inbox_store.transition_by_key(key, to: "done", by: CLOSED_BY)
      @open.delete(key)
    end

    def open_items
      @inbox_store.list.select { |item| item["state"] == "open" && item["dedupe_key"].to_s.start_with?(key_prefix) }
        .each { |item| @open[item["dedupe_key"]] = true }
    end

    def busy?(row)
      return false unless row
      row["state"] == "waiting" || row.fetch("waits", []).any? || (row["pending_permissions"].to_i > 0 && row["state"] != "idle")
    end

    def key_prefix
      "permission:#{@workspace}:"
    end

    def key_for(pane_id, agent_id)
      "#{key_prefix}#{pane_id}:#{agent_id || MAIN}"
    end

    def item(message, pane_id, key)
      tool = ToolInputSummary.cap(message["tool"]) || "a tool"
      lines = [ToolInputSummary.cap(message["input"].to_s.lines.first), rule_line(message["rule"])].compact
      lines << "Sub-agent #{ToolInputSummary.cap(message["agent_id"])}." if message["agent_id"]
      {
        "type" => "alert",
        "scope" => {"kind" => "workspace", "key" => @workspace, "name" => @workspace},
        "title" => "#{@workspace} pane #{pane_id}: #{tool} needs permission",
        "body" => lines.join("\n"),
        "source" => {"kind" => "session", "ref" => message["session_id"], "url" => nil},
        "dedupe_key" => key,
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"pane" => pane_id},
        "expires_at" => nil,
        "note" => nil
      }
    end

    def rule_line(rule)
      text = ToolInputSummary.cap(rule)
      text ? "Escalated by rule: #{text}" : "No rule decided it."
    end
  end
end
