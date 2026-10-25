require "socket"
require "io/wait"
require "json"

module Workspace
  module Commands
    # Receives one hook event from a coding agent and forwards it to that
    # workspace's agent daemon.
    #
    # This runs as a hook, inside the agent's own turn, so it holds two rules
    # above all else: never block, and never fail. A hook that errors or hangs
    # degrades the thing it is meant to observe, and session monitoring is not
    # worth interrupting someone's work for. Every failure path here exits 0.
    class SessionEvent
      # A step of the delivery to the daemon ran past its time limit.
      class DeliveryTimeout < StandardError; end

      # Maps each agent's own event names onto workspace's vocabulary. A new
      # agent adds a table here and an entry in {Workspace::AgentProvider}.
      CLAUDE_EVENTS = {
        "SessionStart" => "session_start",
        "SessionEnd" => "session_end",
        "UserPromptSubmit" => "user_prompt",
        "Stop" => "stop",
        "SubagentStop" => "subagent_stop",
        # A PreToolUse for the Task tool is "subagent_start" instead; see {#translate}.
        "PreToolUse" => "tool_start",
        "Notification" => "notification",
        "PostToolUse" => "tool_use"
      }.freeze

      # Codex's hooks (see {Workspace::AgentProvider::CODEX_EVENTS}). A
      # PermissionRequest is the approval prompt, so it starts a wait the way
      # Claude Code's Notification does; an Interrupt ends the turn.
      CODEX_EVENTS = {
        "SessionStart" => "session_start",
        "SessionEnd" => "session_end",
        "UserPromptSubmit" => "user_prompt",
        "Stop" => "stop",
        "Interrupt" => "stop",
        "SubagentStart" => "subagent_start",
        "SubagentStop" => "subagent_stop",
        "PreToolUse" => "tool_start",
        "PermissionRequest" => "notification",
        "PostToolUse" => "tool_use"
      }.freeze

      # Each agent's table, by the provider key `--agent` names.
      AGENT_EVENTS = {"claude" => CLAUDE_EVENTS, "codex" => CODEX_EVENTS}.freeze

      # The agent a payload is read as when `--agent` is not given: the hooks
      # installed before other agents had any run `session-event` bare.
      DEFAULT_AGENT = "claude"

      # The hooks recorded in the session ledger, as the names it stores.
      LEDGER_EVENTS = {"SessionStart" => "session_start", "SessionEnd" => "session_end"}.freeze

      # Longest notification message forwarded to the daemon. The message is
      # shown in `sessions --json` and handed to the notify command; a long
      # one is cut rather than dropped.
      MAX_MESSAGE_LENGTH = SessionMonitor::MAX_MESSAGE_LENGTH

      # Longest text of composed packs added to a binding's reminder; a longer one is cut.
      MAX_PACKS_CONTEXT = 12_000

      # Longest user prompt forwarded to the daemon. A prompt can be a pasted
      # file; a label only needs its opening, so the rest is cut.
      MAX_PROMPT_LENGTH = 1000

      # Longest stop reason forwarded to the daemon.
      MAX_STOP_REASON_LENGTH = 64

      # The tool whose PreToolUse starts a sub-agent.
      SUBAGENT_TOOL = "Task"

      # Tools that work on one file, named by `file_path` or `notebook_path`
      # in their input. Only these forward a path, made relative to the checkout.
      FILE_TOOLS = %w[Edit Write Read MultiEdit NotebookEdit NotebookRead].freeze

      # Longest tool name, tool use id and session source or reason forwarded.
      MAX_NAME_LENGTH = 64

      # Longest sub-agent id forwarded.
      MAX_ID_LENGTH = 128

      # Longest file path forwarded; a longer one is left out rather than cut,
      # since a cut path names a different file.
      MAX_PATH_LENGTH = 1024

      # Longest sub-agent description forwarded.
      MAX_DESCRIPTION_LENGTH = 120

      # Seconds to wait for the daemon's socket to take the connection and the
      # line, and then for its reply. A daemon that is hung or restarting costs a hook
      # at most the two together; a line already written stays in the
      # socket's buffer and the daemon reads it when it gets to it.
      CONNECT_TIMEOUT = 0.2
      REPLY_TIMEOUT = 0.3

      # Size past which the delivery log starts over.
      DELIVERY_LOG_LIMIT = 256 * 1024

      # @param config [Workspace::Config] socket path lookups
      # @param tmux [Workspace::Tmux] resolves the pane's session name
      # @param input [IO] stream the hook payload arrives on
      # @param env [Hash] process environment, for TMUX_PANE
      # @param output [IO] stream a bound pane's SessionStart context is written to
      # @param error_output [IO] stream a deny message is written to
      # @param logger [Workspace::Logger] debug logger
      # @param lock_idle_tracker [Workspace::LockIdleTracker, nil] marks the
      #   agent's locks idle/active; nil skips lock tracking
      # @param lock_enforcer [Workspace::LockEnforcer, nil] denies an edit while
      #   another agent holds the edit lock, and releases locks on session end;
      #   nil skips enforcement
      # @param session_ledger [Workspace::SessionLedger, nil] records each
      #   SessionStart and SessionEnd; nil skips the ledger
      # @param pane_bindings [Workspace::PaneBindings, nil] looked up on SessionStart to
      #   remind a bound pane of its subject; nil skips bindings
      # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs a
      #   binding lists, added after its subject; nil leaves them out
      # @param dev_session_release [Workspace::DevSessionRelease, nil] stops the dev environment a session
      #   started when that session ends (never on `clear`); nil leaves it running
      # @param workspace_for_session [#call] given the pane's tmux session name, returns the workspace
      #   whose agentd owns it (a worktree workspace's session is not named like the workspace)
      # @param delivery_log [String, nil] file an undeliverable event is recorded in, one line each,
      #   started over past {DELIVERY_LOG_LIMIT} bytes; nil records nothing beyond the debug log
      # @param connect_timeout [Numeric] seconds to wait for the daemon's socket to take the connection
      # @param reply_timeout [Numeric] seconds to wait for the daemon's reply
      def initialize(config:, tmux:, input: $stdin, env: ENV, output: $stdout, error_output: $stderr, logger: Workspace::Logger.new,
        lock_idle_tracker: nil, lock_enforcer: nil, session_ledger: nil, pane_bindings: nil, instruction_composer: nil, dev_session_release: nil,
        workspace_for_session: ->(session) { session }, delivery_log: nil,
        connect_timeout: CONNECT_TIMEOUT, reply_timeout: REPLY_TIMEOUT)
        @workspace_for_session = workspace_for_session
        @delivery_log = delivery_log
        @connect_timeout = connect_timeout
        @reply_timeout = reply_timeout
        @dev_session_release = dev_session_release
        @config = config
        @tmux = tmux
        @input = input
        @env = env
        @output = output
        @error_output = error_output
        @logger = logger
        @lock_idle_tracker = lock_idle_tracker
        @lock_enforcer = lock_enforcer
        @session_ledger = session_ledger
        @pane_bindings = pane_bindings
        @instruction_composer = instruction_composer
      end

      # Reads a hook payload, updates the agent's lock idle state, enforces
      # the edit lock, and forwards the event to the agent daemon.
      #
      # @param workspace [String, nil] overrides the workspace the event is sent
      #   to; normally derived from the pane the hook is running in
      # @param agent [String, nil] the agent whose hook this is (`claude`, `codex`),
      #   which says how its event names read; nil is {DEFAULT_AGENT}. An agent
      #   with no table here is dropped, rather than read by another agent's names.
      # @return [Hash] {exit_code:} — 2 when an edit is denied, 0 otherwise
      def call(workspace: nil, agent: nil)
        @agent = agent.nil? ? DEFAULT_AGENT : agent.downcase
        return ok { "session-event: unknown agent #{agent.inspect}, dropped" } unless AGENT_EVENTS.key?(@agent)

        payload = parse(@input.read)
        return ok unless payload.is_a?(Hash)

        hook = payload["hook_event_name"]
        cwd = payload["cwd"]

        @lock_idle_tracker&.update(hook, cwd: cwd)

        if hook == "PreToolUse"
          deny = @lock_enforcer&.check(tool_name: payload["tool_name"], cwd: cwd)
          if deny
            @error_output.puts deny
            return {exit_code: 2}
          end
        elsif hook == "SessionEnd" || (hook == "SessionStart" && payload["source"] == "clear")
          @lock_enforcer&.release_all(cwd: cwd)
        end
        @dev_session_release&.call(session_id: text_field(payload, "session_id"), cwd: cwd, reason: text_field(payload, "reason")) if hook == "SessionEnd"

        pane_id = @env["TMUX_PANE"]
        return ok { "session-event: not inside tmux, dropped" } unless pane_id

        name = workspace
        unless name
          session = @tmux.session_name_for_pane(pane_id)
          return ok { "session-event: no session for #{pane_id}, dropped" } unless session
          name = @workspace_for_session.call(session)
        end

        record_in_ledger(payload, pane_id, name)
        announce_binding(payload, pane_id)

        event = translate(payload, pane_id, name)
        return ok { "session-event: ignoring #{hook}" } unless event

        deliver(name, event)
        ok
      end

      private

      def ok
        @logger.debug { yield } if block_given?
        {exit_code: 0}
      end

      def parse(raw)
        return nil if raw.nil?

        # Invalid bytes would make strip and JSON.generate raise inside the
        # agent's turn; replacing them keeps the event deliverable. Hook stdin is UTF-8
        # whatever the locale tags it, so retag first.
        raw = raw.dup.force_encoding(Encoding::UTF_8).scrub
        return nil if raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        @logger.debug { "session-event: unparseable payload (#{e.message})" }
        nil
      end

      # Written before delivery so a missing daemon doesn't lose the record. The
      # slot, server and layout lookups shell out to tmux, so they run only for
      # the two events that are recorded. The layout lets `restore` put a pane
      # split by hand back where it was; the server's pid tells it whether the
      # recorded pane id can still name the pane.
      def record_in_ledger(payload, pane_id, workspace)
        hook = payload["hook_event_name"]
        return unless @session_ledger && LEDGER_EVENTS.key?(hook)

        entry = {
          "event" => LEDGER_EVENTS[hook],
          "workspace" => workspace,
          "pane_slot" => @tmux.pane_slot(pane_id),
          "pane_id" => pane_id,
          "tmux_server" => @tmux.server_pid_for_pane(pane_id),
          "layout" => @tmux.pane_layout(pane_id),
          "session_id" => text_field(payload, "session_id"),
          "transcript_path" => text_field(payload, "transcript_path"),
          "cwd" => text_field(payload, "cwd"),
          "source" => text_field(payload, "source"),
          "reason" => text_field(payload, "reason")
        }
        # Named only for an agent other than Claude Code, as before other agents
        # had hooks; `restore` resumes Claude Code sessions only.
        entry["kind"] = @agent unless claude?
        @session_ledger.record(entry)
      rescue => e
        @logger.debug { "session-event: ledger write failed (#{e.class}: #{e.message})" }
      end

      # A SessionStart for a bound pane prints Claude Code's `additionalContext`, so the
      # agent knows its subject again after startup, clear, resume and compact. Only a
      # binding made for this pane's own tmux session and slot counts, so a pane id
      # reused after a tmux restart doesn't inherit another pane's subject.
      def announce_binding(payload, pane_id)
        return unless @pane_bindings && payload["hook_event_name"] == "SessionStart"

        entry = @pane_bindings.binding_for(pane_id)
        return unless entry
        return if @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane_id), pane_slot: @tmux.pane_slot(pane_id))

        @output.puts JSON.generate("hookSpecificOutput" => {
          "hookEventName" => "SessionStart",
          "additionalContext" => [@pane_bindings.context_for(entry), packs_context(entry, payload)].compact.join("\n\n")
        })
      rescue => e
        @logger.debug { "session-event: binding context failed (#{e.class}: #{e.message})" }
      end

      # The packs a binding lists, composed again so `/clear` and compaction do not lose
      # them. A pack that can no longer be read leaves them out; the subject still prints.
      def packs_context(entry, payload)
        return nil unless @instruction_composer
        names = @pane_bindings.packs_for(entry)
        return nil if names.empty?

        composed = @instruction_composer.compose(packs: names, cwd: text_field(payload, "cwd") || Dir.pwd, binding: entry)
        text = composed["text"].strip
        text = "#{text[0, MAX_PACKS_CONTEXT]}\n[cut: run `workspace instructions compose` for the rest]" if text.length > MAX_PACKS_CONTEXT
        "Instructions you were sent when this pane started:\n\n#{text}"
      rescue => e
        @logger.debug { "session-event: packs failed (#{e.class}: #{e.message})" }
        nil
      end

      def translate(payload, pane_id, workspace)
        hook = payload["hook_event_name"]
        name = AGENT_EVENTS.fetch(@agent)[hook]
        return nil unless name

        name = "subagent_start" if claude? && hook == "PreToolUse" && payload["tool_name"] == SUBAGENT_TOOL

        {
          "type" => "session_event",
          "workspace" => workspace,
          "event" => name,
          "agent_kind" => @agent,
          "pane_id" => pane_id,
          "session_id" => payload["session_id"],
          "cwd" => payload["cwd"],
          "transcript_path" => text_field(payload, "transcript_path"),
          # Set only when the hook fired inside a sub-agent, so the daemon can
          # tell its events from the main agent's.
          "agent_id" => agent_id_for(payload),
          "agent" => agent_for(payload),
          "message" => message_for(payload),
          "notification_type" => notification_type_for(payload),
          "prompt" => prompt_for(payload),
          "stop_reason" => stop_reason_for(payload)
        }.merge(tool_fields(payload), session_fields(payload), codex_subagent_fields(payload)).compact
      end

      def claude?
        @agent == DEFAULT_AGENT
      end

      def codex?
        @agent == "codex"
      end

      # Codex's SubagentStart comes from the main agent and names the
      # sub-agent it starts in `agent_id`; that id goes out as `subagent_id`,
      # so the event still counts as the main agent's.
      def agent_id_for(payload)
        return nil if codex? && payload["hook_event_name"] == "SubagentStart"

        name_or_id(payload["agent_id"])
      end

      def codex_subagent_fields(payload)
        return {} if !codex? || payload["hook_event_name"] != "SubagentStart"

        {"subagent_id" => name_or_id(payload["agent_id"]), "subagent_type" => name_field(payload, "agent_type")}
      end

      def name_or_id(value)
        value.is_a?(String) ? clean(value, MAX_ID_LENGTH) : value
      end

      # What the events stream needs to know about a tool use: its name and id,
      # a file tool's path, a short summary of its input ({ToolInputSummary}), and
      # on PostToolUse whether it worked. The rest of the input and the response
      # are read here and never forwarded.
      def tool_fields(payload)
        hook = payload["hook_event_name"]
        return {} unless hook == "PreToolUse" || hook == "PostToolUse"

        fields = {
          "tool" => name_field(payload, "tool_name"),
          "tool_use_id" => name_field(payload, "tool_use_id"),
          "path" => relative_path(payload),
          "input" => ToolInputSummary.call(payload["tool_name"], payload["tool_input"])
        }
        if hook == "PostToolUse"
          fields["ok"] = tool_ok?(payload["tool_response"])
          duration = payload["duration_ms"]
          fields["duration_ms"] = duration.round if duration.is_a?(Numeric) && duration >= 0
        end
        if claude? && fields["tool"] == SUBAGENT_TOOL && hook == "PreToolUse" && payload["tool_input"].is_a?(Hash)
          fields["description"] = clean(payload["tool_input"]["description"], MAX_DESCRIPTION_LENGTH)
          fields["subagent_type"] = clean(payload["tool_input"]["subagent_type"], MAX_NAME_LENGTH)
        end
        fields
      end

      def session_fields(payload)
        case payload["hook_event_name"]
        when "SessionStart" then {"kind" => @agent, "source" => name_field(payload, "source")}
        when "SessionEnd" then {"kind" => @agent, "reason" => name_field(payload, "reason")}
        else {}
        end
      end

      # Claude Code runs PostToolUse after a tool returns, failed or not; the
      # response says which for the tools that report it.
      def tool_ok?(response)
        return true unless response.is_a?(Hash)
        !(response["is_error"] == true || response["success"] == false || response["interrupted"] == true)
      end

      # The file a file tool works on, relative to the checkout the hook ran in:
      # the nearest directory at or above `cwd` holding `.git`. A file outside it,
      # or a path with control characters in it, is left out.
      def relative_path(payload)
        return nil unless FILE_TOOLS.include?(payload["tool_name"])
        input = payload["tool_input"]
        return nil unless input.is_a?(Hash)
        raw = input["file_path"] || input["notebook_path"]
        cwd = text_field(payload, "cwd")
        return nil unless raw.is_a?(String) && !raw.empty? && cwd && !raw.match?(/[[:cntrl:]]/)

        root = checkout_root(File.expand_path(cwd))
        return nil unless root
        path = File.expand_path(raw, cwd)
        return nil unless path.start_with?("#{root}/")
        relative = path.delete_prefix("#{root}/")
        relative if relative.length <= MAX_PATH_LENGTH
      end

      def checkout_root(dir)
        loop do
          return dir if File.exist?(File.join(dir, ".git"))
          parent = File.dirname(dir)
          return nil if parent == dir
          dir = parent
        end
      end

      def name_field(payload, key)
        clean(payload[key], MAX_NAME_LENGTH)
      end

      def clean(value, limit)
        return nil unless value.is_a?(String)
        cleaned = value.gsub(/[[:space:][:cntrl:]]+/, " ").strip[0, limit]
        cleaned unless cleaned.empty?
      end

      # Codex's approval prompt carries the command it asks about in its tool
      # input, which is never forwarded; the wait is described by the tool's name.
      def message_for(payload)
        if codex? && payload["hook_event_name"] == "PermissionRequest"
          tool = name_field(payload, "tool_name")
          return tool ? "Approval requested for #{tool}" : "Approval requested"
        end

        message = payload["message"]
        return nil unless claude? && payload["hook_event_name"] == "Notification" && message.is_a?(String)

        message[0, MAX_MESSAGE_LENGTH]
      end

      # Claude Code's kind of notification (`idle_prompt`, `permission_prompt`, ...).
      def notification_type_for(payload)
        return nil unless claude? && payload["hook_event_name"] == "Notification"

        name_field(payload, "notification_type")
      end

      def stop_reason_for(payload)
        return "interrupted" if codex? && payload["hook_event_name"] == "Interrupt"
        return nil unless payload["hook_event_name"] == "Stop"

        text_field(payload, "stop_reason")&.then { |reason| reason[0, MAX_STOP_REASON_LENGTH] }
      end

      def text_field(payload, key)
        value = payload[key]
        value.is_a?(String) ? value : nil
      end

      # Only Claude Code's prompt is forwarded, for the pane label it falls
      # back to; no other agent's prompt text leaves the hook.
      def prompt_for(payload)
        prompt = payload["prompt"]
        return nil unless claude? && payload["hook_event_name"] == "UserPromptSubmit" && prompt.is_a?(String)

        prompt[0, MAX_PROMPT_LENGTH]
      end

      def agent_for(payload)
        if codex?
          type = name_field(payload, "agent_type") if payload["hook_event_name"] == "SubagentStart"
          return type ? {"name" => type} : nil
        end

        input = payload["tool_input"]
        return nil unless payload["hook_event_name"] == "PreToolUse" && payload["tool_name"] == SUBAGENT_TOOL && input.is_a?(Hash)

        name = input["subagent_type"] || input["description"]
        name ? {"name" => name} : nil
      end

      # A missing or dead socket is the normal case when no daemon is running,
      # so it is logged and swallowed rather than reported. Every step is
      # bounded ({CONNECT_TIMEOUT}, {REPLY_TIMEOUT}), since this now runs before
      # every tool call and a hung daemon must not stall the agent.
      def deliver(workspace, event)
        path = @config.agent_socket_path(workspace)
        socket = Socket.new(:UNIX, :STREAM)
        deadline = now + @connect_timeout
        connect(socket, path, deadline)
        write(socket, JSON.generate(event) + "\n", deadline)
        # The daemon answers every connection. Waiting a moment for the reply
        # keeps it from writing into a socket already dropped; a reply that
        # doesn't come in time is given up on, and the daemon logs that quietly.
        if socket.wait_readable(@reply_timeout)
          socket.read_nonblock(4096, exception: false)
          @logger.debug { "session-event: sent #{event["event"]} for #{event["pane_id"]}" }
        else
          @logger.debug { "session-event: sent #{event["event"]} for #{event["pane_id"]}; no reply in #{@reply_timeout}s" }
        end
      rescue SystemCallError, IOError, DeliveryTimeout => e
        @logger.debug { "session-event: could not deliver to #{path} (#{e.class}: #{e.message})" }
        record_undeliverable(workspace, event, path, e)
      ensure
        socket&.close
      end

      # One line per event the daemon never got, so a hook that reaches no daemon
      # is findable without --debug. Never raises: a hook must not fail over its own log.
      def record_undeliverable(workspace, event, path, error)
        return unless @delivery_log
        FileUtils.mkdir_p(File.dirname(@delivery_log))
        File.truncate(@delivery_log, 0) if File.size?(@delivery_log).to_i > DELIVERY_LOG_LIMIT
        File.open(@delivery_log, "a") do |f|
          f.puts "#{Time.now.utc.iso8601} undeliverable event=#{event["event"]} workspace=#{workspace} pane=#{event["pane_id"]} socket=#{path} (#{error.class}: #{error.message})"
        end
      rescue SystemCallError, IOError
        nil
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Connecting and writing share one deadline, so together they take at most {CONNECT_TIMEOUT}.
      def connect(socket, path, deadline)
        address = Socket.sockaddr_un(path)
        return if socket.connect_nonblock(address, exception: false) == 0
        raise DeliveryTimeout, "connect timed out" unless socket.wait_writable([deadline - now, 0].max)
        result = socket.connect_nonblock(address, exception: false)
        raise DeliveryTimeout, "connect timed out" if result == :wait_writable
      rescue Errno::EISCONN
        nil
      end

      def write(socket, line, deadline)
        until line.empty?
          written = socket.write_nonblock(line, exception: false)
          if written == :wait_writable
            remaining = deadline - now
            raise DeliveryTimeout, "write timed out" unless remaining > 0 && socket.wait_writable(remaining)
          else
            line = line.byteslice(written..)
          end
        end
      end
    end
  end
end
