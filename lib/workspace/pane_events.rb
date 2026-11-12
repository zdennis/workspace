module Workspace
  # The hook-event reducer of {SessionMonitor}: what one hook event an agent
  # reported does to its pane's record. A pane is the symbol-keyed Hash
  # {.new_pane} builds; {.apply} answers a new pane and leaves the one it is
  # given, and every collection in it, unchanged.
  #
  # Nothing here takes a lock, reads the clock or does I/O: the time of the
  # event comes in as +now:+, and the monitor calls it while it holds its own
  # lock.
  class PaneEvents
    # Events that show the main agent active after a Stop, and how
    # {SessionMonitor#main_turn_evidence} names each one.
    MAIN_ACTIVITY = {
      "tool_start" => "main_tool_after_stop", "tool_use" => "main_tool_after_stop", "subagent_start" => "subagent_start_after_stop",
      "user_prompt" => "main_prompt_after_stop", "session_start" => "session_start_after_stop", "session_end" => "session_end_after_stop"
    }.freeze

    # Events that start, end, or restart a turn clear a wait whoever raised it.
    TURN_EVENTS = ["user_prompt", "stop", "session_start", "session_end", "turn_failed"].freeze
    private_constant :TURN_EVENTS

    # Events that leave no tool of the main agent running.
    TOOL_RESET_EVENTS = ["user_prompt", "stop", "session_start", "session_end", "turn_failed"].freeze
    private_constant :TOOL_RESET_EVENTS

    IDLE_INPUT_MESSAGE = "Claude is waiting for your input"
    private_constant :IDLE_INPUT_MESSAGE

    # Longest prompt kept as a label fallback.
    LABEL_PROMPT_LENGTH = TranscriptLabel::MAX_LENGTH
    private_constant :LABEL_PROMPT_LENGTH

    class << self
      # @param pane_id [String] tmux pane id
      # @return [Hash] the record of a pane no scan or event has filled in yet
      def new_pane(pane_id)
        {pane_id: pane_id, agents: [], waits: {}, permission_requests: {}, kind: "unknown", index: nil}
      end

      # Applies one hook event to a pane: its session, label source, open
      # tools, waits, permission requests, done mark, failed turn and
      # sub-agents.
      #
      # @param pane [Hash] the pane's record, left unchanged
      # @param event [Hash] a "session_event" payload
      # @param now [Time] when the event is recorded
      # @return [Hash] a new pane, sharing no Hash or Array with +pane+
      def apply(pane, event, now:)
        pane = copy(pane)
        forget_label_source(pane, event["session_id"])
        pane[:session_id] = event["session_id"] || pane[:session_id]
        note_label_source(pane, event)
        pane[:last_event_at] = now
        # Events from before agents other than Claude Code had hooks carry no kind.
        pane[:hook_kind] = event["agent_kind"] || "claude"
        track_tools(pane, event, now)
        apply_event(pane, event, now)
        pane
      end

      # Ends every wait in the pane, with the permission requests of the
      # agents that were waiting.
      #
      # @param pane [Hash] the pane's record, changed in place
      # @return [void]
      def clear_waiting(pane)
        pane[:waits].each_key { |agent_id| pane[:permission_requests].delete(agent_id) }
        pane[:waits].clear
        pane.delete(:alerted_waits)
      end

      # A new wait for an agent: one the last daemon alerted for keeps its
      # start and counts as alerted.
      #
      # @param pane [Hash] the pane's record; its alerted mark for +agent_id+ is taken
      # @param agent_id [String, Symbol, nil] whose wait it is (nil is the main agent)
      # @param now [Time] the start of a wait not carried over
      # @return [Hash] the wait
      def resumed_wait(pane, agent_id, now:)
        since = pane[:alerted_waits]&.delete(agent_id)
        since ? {since: since, alerted: true} : {since: now}
      end

      private

      # The pane's Hashes and Arrays copied all the way down, so the event is
      # applied to the copy. Times, Strings and Symbols are never changed in
      # place here, so they are shared.
      def copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, copy(item)] }
        when Array then value.map { |item| copy(item) }
        else value
        end
      end

      # A main Stop starts the count again. A sub-agent's tool says nothing of the
      # main agent, but any sub-agent start does, as it takes away the done mark.
      def note_main_turn(pane, event, now)
        name = event["event"]
        if name == "stop" && event["agent_id"].nil?
          pane[:main_stopped_at] = now
          pane.delete(:main_active_at)
          pane.delete(:main_active_event)
        elsif MAIN_ACTIVITY.key?(name) && (event["agent_id"].nil? || name == "subagent_start")
          pane[:main_active_at] = now
          pane[:main_active_event] = name
        end
      end

      # Waits are kept per agent, since the main agent and parallel sub-agents
      # can each be waiting on a person at once. Any other event from an agent
      # ends that agent's wait: a tool ran after a permission prompt, say. It
      # leaves the other agents' waits alone. Hooks mark a sub-agent's events
      # with its agent_id; SubagentStop always comes from one.
      #
      # A probe of Claude Code 2.1.316 showed what a permission prompt sends. Its
      # PermissionRequest names the tool, the input and a sub-agent's agent_id, no
      # tool call id, and opens no wait. Its Notification, about 6s later, names
      # none of them, even for a sub-agent, and may never come. An allow sends
      # nothing until the tool ends, and a deny or Esc nothing at all, so a stored
      # request may already be answered. So a permission_prompt Notification names
      # a tool only when exactly one request is pending, filing the wait under
      # that agent; otherwise it can't say whose dialog it is and the fields stay
      # null.
      def apply_event(pane, event, now)
        note_main_turn(pane, event, now)

        # A tool starting says nothing about a wait: with tools run side by side, one
        # can start while another waits on a permission prompt.
        return if event["event"] == "tool_start"

        return note_permission_request(pane, event) if event["event"] == "permission_request"

        # Claude Code says it is idle a minute after a Stop; nobody is asked.
        return if idle_input_notification?(pane, event)

        if event["event"] == "notification"
          # A repeat notification during one wait keeps the original start, so
          # the wait is timed (and alerted) once. So does the first one after a
          # restart, for a wait the last daemon alerted for.
          wait = permission_prompt?(event) ? bind_permission_wait(pane, event, now) : open_wait(pane, event["agent_id"], now).merge!(other_prompt: true)
          wait[:message] = SessionMonitor.clean_message(event["message"])
        elsif TURN_EVENTS.include?(event["event"])
          clear_waiting(pane)
          pane[:turn_ended] = (event["event"] != "user_prompt")
          update_turn_failed(pane, event)
        elsif event["event"] != "subagent_start"
          # Like a tool start, a sub-agent start (the Agent tool) leaves a wait alone.
          pane[:waits].delete(event_agent_id(event))
          pane[:alerted_waits]&.delete(event_agent_id(event))
        end
        clear_permission_requests(pane, event)

        case event["event"]
        when "stop"
          unless event["agent_id"]
            pane[:done] = done_mark(event, now)
            pane.delete(:restored_ready)
          end
        when "user_prompt", "session_start", "session_end" then pane.delete(:done)
        when "tool_use" then pane.delete(:done) unless event["agent_id"]
        end
        pane[:last_user_prompt_at] = now if event["event"] == "user_prompt"
        if event["event"] == "session_start"
          pane[:last_session_start] = {at: now, source: event["source"], session_id: event["session_id"]}
        end

        case event["event"]
        when "subagent_start"
          pane.delete(:done)
          agent = {
            name: agent_name(event), state: "running", started_at: now,
            description: SessionMonitor.clean_message(event["description"])&.slice(0, 120), tool_use_id: event["tool_use_id"]
          }
          # A sub-agent the agent names itself (Codex) is known by its id from the start.
          agent[:agent_id] = event["subagent_id"] if event["subagent_id"]
          pane[:agents] << agent
          (pane[:background_subagents] ||= []) << {agent_id: event["subagent_id"] || event["agent_id"]}
        when "subagent_stop"
          background = (pane[:background_subagents] ||= [])
          ended = background.find { |a| event["agent_id"] && a[:agent_id] == event["agent_id"] } ||
            background.find { |a| !a[:agent_id] } || background.first
          background.delete_at(background.index { |a| a.equal?(ended) }) if ended
          # Claude Code's SubagentStop does not say which sub-agent finished, so
          # the oldest running one is closed. With sub-agents running in parallel
          # this can pair the wrong start with the wrong stop; the count stays
          # right, which is what the display needs.
          # When the hook names the sub-agent (agent_id), that one is closed.
          running = pane[:agents].find { |a| a[:state] == "running" && event["agent_id"] && a[:agent_id] == event["agent_id"] } ||
            pane[:agents].find { |a| a[:state] == "running" && !a[:agent_id] } ||
            pane[:agents].find { |a| a[:state] == "running" }
          running&.merge!(state: "done", ended_at: now)
        when "session_start"
          pane[:background_subagents]&.clear
        when "stop", "session_end"
          pane[:background_subagents]&.clear if event["event"] == "session_end"
          pane[:agents].each do |agent|
            agent.merge!(state: "done", ended_at: now) if agent[:state] == "running"
          end
        end
      end

      # Keeps what `sessions` says about tools: the main agent's tools still
      # running (by tool_use_id, so tools run side by side finish one by one),
      # and the id of each sub-agent. Only the tool's name is kept, never its
      # input. A sub-agent is not ended by its Agent call's PostToolUse, since a
      # background Agent call returns at once while the sub-agent keeps running.
      def track_tools(pane, event, now)
        open = (pane[:open_tools] ||= {})
        main = event["agent_id"].nil?
        id = event["tool_use_id"]

        case event["event"]
        when "tool_start", "subagent_start"
          # A sub-agent the agent names itself (Codex's SubagentStart) has no
          # tool call to wait on; Claude Code's comes from its Agent (earlier Task) call.
          name = event["tool"] || ((event["event"] == "subagent_start" && !event["subagent_id"]) ? "Agent" : nil)
          if main && name
            open.delete(id || :anonymous)
            open[id || :anonymous] = {tool: SessionMonitor.clean_message(name)&.slice(0, 64), since: now}
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
      def done_mark(event, now)
        reason = SessionMonitor.clean_message(event["stop_reason"])
        {since: now, stop_reason: reason || "end_turn"}
      end

      # Claude Code's idle_prompt notification ("Claude is waiting for your
      # input") comes a minute after a Stop. It asks nothing of a person, so it
      # opens no wait once the turn has ended (or, after a daemon restart, once
      # the pane was read back as done or idle). Older hooks carry no
      # notification_type; the message tells them apart.
      def idle_input_notification?(pane, event)
        return false unless event["event"] == "notification"
        return false unless pane[:turn_ended] || pane[:done] || pane[:restored_ready]
        type = event["notification_type"]
        return type == "idle_prompt" if type
        event["message"].to_s.strip == IDLE_INPUT_MESSAGE
      end

      # A failed turn stays the pane's state until the person or the agent starts
      # another: a prompt, a Stop, or a new session. A Stop-less end of the session,
      # a resumed session with the same id and the agent leaving the pane keep it.
      def update_turn_failed(pane, event)
        case event["event"]
        when "turn_failed"
          pane[:turn_failed] = {session_id: event["session_id"] || pane[:session_id]}
        when "user_prompt", "stop"
          pane.delete(:turn_failed)
        when "session_start"
          failed = pane[:turn_failed]
          pane.delete(:turn_failed) if failed && event["session_id"] != failed[:session_id]
        end
      end

      def permission_prompt?(event)
        event["notification_type"] == "permission_prompt"
      end

      def note_permission_request(pane, event)
        agent_id = event["agent_id"]
        pane[:permission_requests].delete(agent_id)
        pane[:permission_requests][agent_id] = {
          tool: SessionMonitor.clean_message(event["tool"]), input: ToolInputSummary.cap(event["input"])
        }
      end

      def bind_permission_wait(pane, event, now)
        pane[:waits].each_value { |wait| wait.merge!(tool: nil, input: nil) }
        requests = pane[:permission_requests]
        return open_wait(pane, event["agent_id"], now) unless requests.size == 1

        agent_id, request = requests.first
        pane[:waits][agent_id] ||= take_unbound_permission_wait(pane) || resumed_wait(pane, agent_id, now: now)
        pane[:waits][agent_id].merge!(request)
      end

      # Only a permission wait moves: a main elicitation is still on screen and
      # ends on a main event, whatever a sub-agent does.
      def take_unbound_permission_wait(pane)
        pane[:waits].delete(nil) if pane[:waits][nil] && !pane[:waits][nil][:other_prompt]
      end

      def clear_permission_requests(pane, event)
        requests = pane[:permission_requests]
        case event["event"]
        when "user_prompt", "session_start", "session_end" then requests.clear
        when "stop", "turn_failed" then requests.delete(nil) unless event["agent_id"]
        when "subagent_stop" then requests.delete(event_agent_id(event))
        when "tool_use"
          request = requests[event["agent_id"]]
          requests.delete(event["agent_id"]) if request && request[:tool] == SessionMonitor.clean_message(event["tool"])
        end
      end

      def open_wait(pane, agent_id, now)
        pane[:waits][agent_id] ||= resumed_wait(pane, agent_id, now: now)
      end

      # nil is the main agent. A SubagentStop without an agent_id (older Claude
      # Code) still came from some sub-agent, so it never matches the main one.
      def event_agent_id(event)
        event["agent_id"] || ((event["event"] == "subagent_stop") ? :sub_agent : nil)
      end

      def agent_name(event)
        event.dig("agent", "name") || "agent"
      end

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

        pane[:last_prompt] = SessionMonitor.clean_message(prompt)&.slice(0, LABEL_PROMPT_LENGTH)
      end
    end
  end
end
