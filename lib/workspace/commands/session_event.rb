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
        # The turn ended on an API error; `error` says which kind.
        "StopFailure" => "turn_failed",
        "SubagentStop" => "subagent_stop",
        # A PreToolUse for the Agent (earlier Task) tool is "subagent_start" instead; see {#translate}.
        "PreToolUse" => "tool_start",
        "Notification" => "notification",
        "PostToolUse" => "tool_use",
        "PermissionRequest" => "permission_request",
        "PostToolUseFailure" => "tool_use"
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

      # The hooks that need the whole CLI's wiring (the instruction composer, the permission
      # policy, the dev-lock release), rather than the fast entry's; see {.full_wiring?}.
      FULL_WIRING_EVENTS = %w[SessionStart SessionEnd PermissionRequest].freeze

      # Whether a payload is one of {FULL_WIRING_EVENTS} in the agent's own table, so
      # `bin/workspace` hands it to the whole CLI instead of the fast entry. A payload that does not
      # parse as a JSON object, or an agent with no table, is not: the command drops those itself.
      #
      # @param raw [String, nil] the hook payload as read from stdin
      # @param agent [String, nil] the `--agent` value; nil is {DEFAULT_AGENT}
      # @return [Boolean]
      def self.full_wiring?(raw, agent)
        table = AGENT_EVENTS[agent.nil? ? DEFAULT_AGENT : agent.downcase]
        return false unless table && raw

        payload = JSON.parse(raw.dup.force_encoding(Encoding::UTF_8).scrub)
        hook = payload.is_a?(Hash) ? payload["hook_event_name"] : nil
        FULL_WIRING_EVENTS.include?(hook) && table.key?(hook)
      rescue JSON::ParserError
        false
      end

      # Longest notification message forwarded to the daemon. The message is
      # shown in `sessions --json` and handed to the notify command; a long
      # one is cut rather than dropped.
      MAX_MESSAGE_LENGTH = AgentProtocol::MAX_MESSAGE_LENGTH

      # Longest text of composed packs added to a binding's reminder; a longer one is cut.
      MAX_PACKS_CONTEXT = 12_000

      # Longest user prompt forwarded to the daemon. A prompt can be a pasted
      # file; a label only needs its opening, so the rest is cut.
      MAX_PROMPT_LENGTH = 1000

      # What a StopFailure's `error` must look like to be forwarded: a kind name, never text.
      ERROR_KIND = /\A[a-z_]+\z/

      # Longest stop reason forwarded to the daemon.
      MAX_STOP_REASON_LENGTH = 64
      MAX_BACKGROUND_TASKS = 32

      # The tools whose PreToolUse starts a sub-agent: "Agent" since Claude Code
      # 2.1.314, "Task" before.
      SUBAGENT_TOOLS = %w[Agent Task].freeze

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

      # The tools whose PostToolUse is hashed when they write a review round's verdict file.
      VERDICT_TOOLS = %w[Write Edit MultiEdit].freeze

      # The most a verdict file may hold for its hash to be taken.
      VERDICT_MAX_BYTES = 1_048_576

      # Longest sub-agent description forwarded.
      MAX_DESCRIPTION_LENGTH = 120

      # Seconds to wait for the daemon's socket to take the connection and the
      # line, and then for its reply. A daemon that is hung or restarting costs a hook
      # at most the two together; a line already written stays in the
      # socket's buffer and the daemon reads it when it gets to it.
      CONNECT_TIMEOUT = 0.2
      REPLY_TIMEOUT = 0.3

      # Whether a person's own `ask` rule (`<layer>:rules[i]`, `run:permissions[i]`) is guarded in a pane bound to a
      # live run, like a request no rule decided. In an unbound pane such a rule always shows the dialog; false shows
      # it in a bound pane too, leaving the guard to the fallbacks (`default`, `<layer>:default`) and no policy at all.
      GUARD_EXPLICIT_ASK = true

      # Tools that put a question to the person. The hang guard never denies them in a pane bound to no run.
      QUESTION_TOOLS = %w[AskUserQuestion ExitPlanMode].freeze

      # A Bash array assignment, `name=(...)`, which {BashCommandPieces} does not tell apart.
      ARRAY_ASSIGNMENT = /(?:\A|[\s;&|(])[A-Za-z_][A-Za-z0-9_]*=\(/

      # How to turn the hang guard off, which ends every hint: config in any pane, and also the workflow definition in a run's.
      HANG_GUARD_OFF = "To turn this guard off: `workspace config set agent.permissions.hang_guard off`."
      HANG_GUARD_RUN_OFF = "To turn this guard off: `workspace config set agent.permissions.hang_guard off`, or `hang_guard: off` in the workflow definition."

      # The shapes a compound Bash command should be rewritten without.
      SIMPLE_BASH = "run each command as its own Bash call, with no `$(...)`, backticks, arrays, `for`/`while` loops or pipes into loops"

      # The reply messages of a call the hang guard denied, by whether the pane is bound to a live run (nobody is
      # watching it) and whether the call is a compound Bash command (one a simpler form can get past the dialog).
      HANG_GUARD_HINTS = {
        [:bound, :compound] => "Denied by workspace's hang guard: this workflow step runs unattended, and this command would wait at a " \
          "permission dialog nobody answers. Instead, #{SIMPLE_BASH}; or write the steps to a script outside the checkout (the run's " \
          "artifacts or a temp dir) and run it with one `bash <path>` call. #{HANG_GUARD_RUN_OFF}",
        [:bound, :other] => "Denied by workspace's hang guard: this workflow step runs unattended, so this call can't be approved. " \
          "Record the question with `workspace ask \"<question>\" --default \"<choice>\"` and carry on with the default, or end your " \
          "turn with the line `WORKFLOW_STATUS: needs_input — <question>`. #{HANG_GUARD_RUN_OFF}",
        [:unbound, :compound] => "Held back by workspace's hang guard so you don't wait at a permission dialog: #{SIMPLE_BASH}, " \
          "or ask the person in chat. #{HANG_GUARD_OFF}",
        [:unbound, :other] => "Held back by workspace's hang guard so you don't wait at a permission dialog. Ask the person in chat to approve it, " \
          "or do without it. #{HANG_GUARD_OFF}"
      }.freeze

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
      # @param workflow_deny [Workspace::WorkflowDeny, nil] denies a Bash command the bound run's
      #   definition lists under `deny:`; nil skips it
      # @param review_write_guard [Workspace::ReviewWriteGuard, nil] denies a file write in a review pane
      #   that is not a sub-agent's write of its round's verdict file; nil skips it
      # @param reflection_write_guard [Workspace::ReflectionWriteGuard, nil] denies a file write in a reflection
      #   pane other than the run's `reflection.md`; nil skips it
      # @param session_ledger [Workspace::SessionLedger, nil] records each
      #   SessionStart and SessionEnd; nil skips the ledger
      # @param pane_bindings [Workspace::PaneBindings, nil] looked up on SessionStart to
      #   remind a bound pane of its subject; nil skips bindings
      # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs a
      #   binding lists, added after its subject; nil leaves them out
      # @param dev_session_release [Workspace::DevSessionRelease, nil] stops the dev environment a session
      #   started when that session ends (never on `clear`); nil leaves it running
      # @param workspace_for_session [#call] given the pane's tmux session name, returns the workspace
      #   whose agentd owns it (a worktree workspace's session is not named like the workspace), or nil
      #   for a session that is no workspace's, whose events are then dropped
      # @param permission_policy_config [Workspace::PermissionPolicyConfig, nil] builds the permission policy a
      #   PermissionRequest is decided by; nil decides nothing
      # @param hang_guard_counter [Workspace::HangGuardCounter, nil] counts the hang guard's denies, which deny a
      #   request the policy left undecided (see {PermissionPolicyConfig#hang_guard_context}), and cleared of the pane's
      #   unbound count on UserPromptSubmit and SessionStart; nil skips the guard
      # @param command_pieces [Workspace::BashCommandPieces, nil] tells a compound Bash command for the hang guard's hint;
      #   nil gives every Bash call the hint for a call that can't be approved
      # @param session_ambiguous [#call] given the pane's tmux session name, whether more than one workspace
      #   claims it; no permission decision is made for such a session
      # @param delivery_log [Workspace::DeliveryLog, nil] records an event the daemon of a resolved workspace
      #   never got; nil records nothing beyond the debug log
      # @param connect_timeout [Numeric] seconds to wait for the daemon's socket to take the connection
      # @param reply_timeout [Numeric] seconds to wait for the daemon's reply
      def initialize(config:, tmux:, input: $stdin, env: ENV, output: $stdout, error_output: $stderr, logger: Workspace::Logger.new,
        lock_idle_tracker: nil, lock_enforcer: nil, workflow_deny: nil, review_write_guard: nil, reflection_write_guard: nil, session_ledger: nil, pane_bindings: nil, instruction_composer: nil, dev_session_release: nil,
        workspace_for_session: ->(session) { session }, delivery_log: nil, permission_policy_config: nil, hang_guard_counter: nil, command_pieces: nil, session_ambiguous: ->(_session) { false },
        connect_timeout: CONNECT_TIMEOUT, reply_timeout: REPLY_TIMEOUT)
        @workspace_for_session = workspace_for_session
        @delivery_log = delivery_log
        @session_ambiguous = session_ambiguous
        @permission_policy_config = permission_policy_config
        @hang_guard_counter = hang_guard_counter
        @command_pieces = command_pieces
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
        @workflow_deny = workflow_deny
        @review_write_guard = review_write_guard
        @reflection_write_guard = reflection_write_guard
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
          deny = @lock_enforcer&.check(tool_name: payload["tool_name"], cwd: cwd) ||
            @review_write_guard&.check(tool_name: payload["tool_name"], tool_input: payload["tool_input"], cwd: cwd, agent_id: agent_id_for(payload)) ||
            @reflection_write_guard&.check(tool_name: payload["tool_name"], tool_input: payload["tool_input"], cwd: cwd, agent_id: agent_id_for(payload)) ||
            @workflow_deny&.check(tool_name: payload["tool_name"], tool_input: payload["tool_input"])
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

        @reflection_write_guard&.release(pane_id: pane_id, hook: hook, reason: text_field(payload, "reason"))
        # A new prompt or session starts a new turn, whose unbound-pane hang guard count starts again.
        clear_hang_guard(pane_id) if hook == "UserPromptSubmit" || hook == "SessionStart"

        name = workspace
        ambiguous = false
        unless name
          session = @tmux.session_name_for_pane(pane_id)
          return ok { "session-event: no session for #{pane_id}, dropped" } unless session
          begin
            name = @workspace_for_session.call(session)
          rescue => e
            return failed(session, hook, pane_id, e, "workspace lookup")
          end
          return ok { "session-event: session #{session} is no workspace's, dropped" } unless name
          begin
            ambiguous = hook == "PermissionRequest" && @session_ambiguous.call(session)
          rescue => e
            # Unknown counts as ambiguous: no permission decision is made, and the event is still delivered.
            ambiguous = true
            failed(session, hook, pane_id, e, "ambiguity check")
          end
        end

        # Decided before anything else for this event, and before delivery, so the daemon can't delay or change it.
        decision = (hook == "PermissionRequest" && !ambiguous) ? decide_permission(payload, name) : nil

        record_in_ledger(payload, pane_id, name)
        announce_binding(payload, pane_id)

        begin
          event = translate(payload, pane_id, name, decision)
        rescue => e
          return failed(name, hook, pane_id, e, "translate", message: false)
        end
        return ok { "session-event: ignoring #{hook}" } unless event

        deliver(name, event)
        ok
      end

      private

      def ok
        @logger.debug { yield } if block_given?
        {exit_code: 0}
      end

      # A step before delivery raised: recorded like an undeliverable event, and the hook still exits 0.
      # `message: false` keeps the error message out of both logs, for an error that can echo payload text.
      def failed(workspace, hook, pane_id, error, step, message: true)
        detail = message ? "#{error.class}: #{error.message}" : error.class.to_s
        @logger.debug { "session-event: #{step} failed on #{hook} (#{detail})" }
        record_undeliverable(workspace, {"event" => AGENT_EVENTS[@agent][hook] || hook, "pane_id" => pane_id}, nil, detail)
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
        # A workflow step review's reviewer: `restore` must not resume its conversation.
        entry["role"] = "reviewer" unless @env["WORKSPACE_REVIEW_RUN"].to_s.empty?
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
        return if @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane_id), pane_slot: @tmux.pane_slot(pane_id),
          server_pid: -> { @tmux.server_pid_for_pane(pane_id) })

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
        return nil if entry["role"] == "reviewer"
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

      def translate(payload, pane_id, workspace, decision = nil)
        hook = payload["hook_event_name"]
        name = AGENT_EVENTS.fetch(@agent)[hook]
        return nil unless name

        # Codex's approval prompt never shows for a call the policy decided, so it opens no wait.
        name = "permission_request" if codex? && hook == "PermissionRequest" && decided?(decision)

        return nil if name == "turn_failed" && agent_id_for(payload)

        name = "subagent_start" if claude? && hook == "PreToolUse" && SUBAGENT_TOOLS.include?(payload["tool_name"])

        AgentProtocol.session_event(
          workspace: workspace,
          event: name,
          agent_kind: @agent,
          pane_id: pane_id,
          session_id: payload["session_id"],
          cwd: payload["cwd"],
          transcript_path: text_field(payload, "transcript_path"),
          # Set only when the hook fired inside a sub-agent, so the daemon can
          # tell its events from the main agent's.
          agent_id: agent_id_for(payload),
          agent: agent_for(payload),
          message: message_for(payload, name),
          notification_type: notification_type_for(payload, name),
          prompt: prompt_for(payload),
          stop_reason: stop_reason_for(payload),
          error: error_kind_for(payload),
          background_tasks: background_tasks_for(payload),
          fields: tool_fields(payload, decision).merge(session_fields(payload), codex_subagent_fields(payload))
        )
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
      # once it has ended whether it worked. The rest of the input and the response
      # are read here and never forwarded.
      def tool_fields(payload, decision = nil)
        hook = payload["hook_event_name"]
        return permission_fields(payload, decision) if hook == "PermissionRequest"
        return {} unless hook == "PreToolUse" || hook == "PostToolUse" || hook == "PostToolUseFailure"

        fields = {
          "tool" => name_field(payload, "tool_name"),
          "tool_use_id" => name_field(payload, "tool_use_id"),
          "path" => relative_path(payload),
          "input" => ToolInputSummary.call(payload["tool_name"], payload["tool_input"])
        }
        if hook != "PreToolUse"
          fields["ok"] = hook == "PostToolUse" && tool_ok?(payload["tool_response"])
          duration = payload["duration_ms"]
          fields["duration_ms"] = duration.round if duration.is_a?(Numeric) && duration >= 0
        end
        if hook == "PostToolUse" && fields["ok"]
          sha = verdict_sha256(payload)
          fields["sha256"] = sha if sha
        end
        if claude? && SUBAGENT_TOOLS.include?(fields["tool"]) && hook == "PreToolUse" && payload["tool_input"].is_a?(Hash)
          fields["description"] = clean(payload["tool_input"]["description"], MAX_DESCRIPTION_LENGTH)
          fields["subagent_type"] = clean(payload["tool_input"]["subagent_type"], MAX_NAME_LENGTH)
        end
        fields
      end

      # The sha256 of a verdict file a review pane's Write, Edit or MultiEdit just
      # wrote, read from the disk and not from the tool's input (an Edit has no
      # whole content). Only a regular file, not a link, directly in or under the
      # pane's round directory (`.workflow/<run>/reviews/<step>.<attempt>.r<round>/`
      # in its checkout, from the reviewer binding) of at most VERDICT_MAX_BYTES;
      # anything else, or any trouble reading, gives nil.
      def verdict_sha256(payload)
        return nil unless VERDICT_TOOLS.include?(payload["tool_name"]) && @pane_bindings
        entry = @pane_bindings.binding_for(@env["TMUX_PANE"].to_s)
        return nil unless ReviewRoundPath.reviewer?(entry)
        input = payload["tool_input"]
        path = ReviewRoundPath.verdict_path(entry, input.is_a?(Hash) ? input["file_path"] : nil, text_field(payload, "cwd"))
        return nil unless path
        WorkflowProduced.digest(path, max_bytes: VERDICT_MAX_BYTES)&.sha256
      rescue
        nil
      end

      def permission_fields(payload, decision)
        {
          "tool" => name_field(payload, "tool_name"),
          "input" => ToolInputSummary.call(payload["tool_name"], payload["tool_input"]),
          "decision" => decision&.fetch(:action),
          "rule" => decision&.fetch(:rule)
        }
      end

      def decided?(decision)
        !decision.nil? && %w[allow deny].include?(decision[:action])
      end

      # Asks the permission policy about one PermissionRequest and, for an allow or deny, prints the one-line reply
      # the agent reads from stdout. Nothing else is written to stdout on this path (the logger writes to stderr),
      # and the reply never carries `updatedInput`, `updatedPermissions` or `interrupt`, which Codex reserves.
      # A request the policy left undecided (an ask, no policy, an error) goes to the hang guard ({#hang_guard}),
      # which may deny it with a hint; otherwise nothing is printed, so the agent's own dialog shows. This never exits 2.
      #
      # @return [Hash, nil] `{action:, rule:}` of the decision, nil when none was made
      def decide_permission(payload, workspace)
        return nil unless @permission_policy_config

        decision = policy_decision(payload, workspace)
        return reply(decision, "Denied by workspace permission policy (#{decision[:rule]})") if decided?(decision)

        hang_guard(payload, workspace, decision) || decision
      end

      def policy_decision(payload, workspace)
        policy = @permission_policy_config.policy(workspace: workspace, project: nil)
        return nil unless policy

        input = payload["tool_input"]
        result = policy.decide(tool_name: payload["tool_name"], tool_input: input.is_a?(Hash) ? input : {}, cwd: text_field(payload, "cwd"))
        decision = {action: result.fetch(:action).to_s, rule: result.fetch(:rule).to_s}
        %w[allow ask deny].include?(decision[:action]) ? decision : nil
      rescue => e
        @logger.debug { "session-event: permission decision failed (#{e.class}: #{e.message})" }
        nil
      end

      def clear_hang_guard(pane_id)
        @hang_guard_counter&.clear_pane(pane_id)
      rescue => e
        @logger.debug { "session-event: hang guard reset failed (#{e.class}: #{e.message})" }
      end

      def fallback?(decision)
        decision.nil? || decision[:rule] == "default" || decision[:rule].end_with?(":default")
      end

      # Denies an undecided request with a hint, so the agent tries again instead of waiting at a dialog, up to the
      # cap a turn ({HangGuardCounter}); past the cap it gives `ask` with `hang_guard:cap`, so the dialog shows and the
      # escalation desk raises it. Nil (the dialog shows) when the guard is off, for a person's own `ask` rule or a
      # question tool in a pane bound to no live run, when the count can't be taken, and on any error.
      def hang_guard(payload, workspace, decision)
        return nil unless @hang_guard_counter

        context = @permission_policy_config.hang_guard_context(workspace: workspace, project: nil)
        return nil if context[:mode] == "off"

        binding = context[:binding]
        tool = payload["tool_name"]
        return nil if !fallback?(decision) && !(binding && GUARD_EXPLICIT_ASK)
        return nil if binding.nil? && QUESTION_TOOLS.include?(tool)

        key = HangGuardCounter.key_for(binding: binding, pane_id: @env["TMUX_PANE"], session_id: text_field(payload, "session_id"))
        case @hang_guard_counter.take(key, max: context[:max_denies])
        when :deny then reply({action: "deny", rule: "hang_guard"}, HANG_GUARD_HINTS.fetch([binding ? :bound : :unbound, compound_bash?(payload) ? :compound : :other]))
        when :capped then {action: "ask", rule: "hang_guard:cap"}
        end
      rescue => e
        @logger.debug { "session-event: hang guard failed (#{e.class}: #{e.message})" }
        nil
      end

      # Whether a Bash call holds a shape a simpler form avoids: a substitution, a compound keyword such as a loop
      # (a pipe into a loop included), a command word that can't be read from its text, or an array.
      def compound_bash?(payload)
        input = payload["tool_input"]
        command = input.is_a?(Hash) ? input["command"] : nil
        return false unless @command_pieces && payload["tool_name"] == "Bash" && command.is_a?(String)

        @command_pieces.substitution?(command) || @command_pieces.opaque?(command) || command.match?(ARRAY_ASSIGNMENT)
      end

      def reply(decision, message)
        reply = {"behavior" => decision[:action]}
        reply["message"] = message if decision[:action] == "deny"
        @output.puts JSON.generate("hookSpecificOutput" => {"hookEventName" => "PermissionRequest", "decision" => reply})
        @output.flush if @output.respond_to?(:flush)
        decision
      rescue => e
        @logger.debug { "session-event: permission reply failed (#{e.class}: #{e.message})" }
        nil
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
        ReviewRoundPath.checkout_root(dir)
      end

      def name_field(payload, key)
        clean(payload[key], MAX_NAME_LENGTH)
      end

      def clean(value, limit)
        return nil unless value.is_a?(String)
        cleaned = value.gsub(/(?:[[:space:]]|[[:cntrl:]])+/, " ").strip[0, limit]
        cleaned unless cleaned.empty?
      end

      # Codex's approval prompt carries the command it asks about in its tool
      # input, which is never forwarded; the wait is described by the tool's name.
      def message_for(payload, name = nil)
        if codex? && payload["hook_event_name"] == "PermissionRequest"
          return nil if name == "permission_request"
          tool = name_field(payload, "tool_name")
          return tool ? "Approval requested for #{tool}" : "Approval requested"
        end

        message = payload["message"]
        return nil unless claude? && payload["hook_event_name"] == "Notification" && message.is_a?(String)

        message[0, MAX_MESSAGE_LENGTH]
      end

      # Claude Code's kind of notification (`idle_prompt`, `permission_prompt`, ...),
      # and `permission_request` for Codex's PermissionRequest, which reaches the
      # daemon as a notification so the monitor opens its wait, and which the
      # hook event log writes as `permission_requested`.
      def notification_type_for(payload, name = nil)
        return nil if name == "permission_request"
        return "permission_request" if codex? && payload["hook_event_name"] == "PermissionRequest"
        return nil unless claude? && payload["hook_event_name"] == "Notification"

        name_field(payload, "notification_type")
      end

      # A StopFailure's error kind (`rate_limit`, `server_error`, ...); anything
      # that is not a bare lowercase name is left out.
      def error_kind_for(payload)
        return nil unless payload["hook_event_name"] == "StopFailure"

        error = text_field(payload, "error")
        error if error&.match?(ERROR_KIND)
      end

      def stop_reason_for(payload)
        return "interrupted" if codex? && payload["hook_event_name"] == "Interrupt"
        return nil unless payload["hook_event_name"] == "Stop"

        text_field(payload, "stop_reason")&.then { |reason| reason[0, MAX_STOP_REASON_LENGTH] }
      end

      # The tasks a Claude Code Stop lists as still going: `id` and `type` of each allowlisted one,
      # nothing else (no description or command leaves here). Nil for any other event, a missing
      # field, or anything but an array, so the run reads "unknown" as it did before.
      def background_tasks_for(payload)
        return nil unless claude? && payload["hook_event_name"] == "Stop" && payload["agent_id"].nil?
        tasks = payload["background_tasks"]
        return nil unless tasks.is_a?(Array)

        tasks.first(MAX_BACKGROUND_TASKS).filter_map do |task|
          next unless task.is_a?(Hash)
          type, id = task["type"], task["id"]
          next unless type.is_a?(String) && IdPatterns::BACKGROUND_TASK_TYPES.include?(type)
          next unless id.is_a?(String) && id.match?(IdPatterns::BACKGROUND_TASK_ID)

          {"id" => id, "type" => type}
        end
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
        return nil unless payload["hook_event_name"] == "PreToolUse" && SUBAGENT_TOOLS.include?(payload["tool_name"]) && input.is_a?(Hash)

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
      rescue => e
        # Any failure, not only a dead daemon: a hook never fails the agent's turn (a PermissionRequest's reply is already on stdout).
        @logger.debug { "session-event: could not deliver to #{path} (#{e.class}: #{e.message})" }
        record_undeliverable(workspace, event, path, e)
      ensure
        socket&.close
      end

      # A daemon that is not running is normal, so only a workspace resolved by
      # name is recorded, and only once per workspace and event in a while.
      def record_undeliverable(workspace, event, path, error)
        detail = error.is_a?(String) ? error : "#{error.class}: #{error.message}"
        @delivery_log&.record(
          "undeliverable event=#{event["event"]} workspace=#{workspace} pane=#{event["pane_id"]}#{decision_note(event)} socket=#{path} (#{detail})",
          key: "#{workspace}/#{event["event"]}"
        )
      end

      def decision_note(event)
        return "" unless event["decision"]

        " decision=#{event["decision"]} rule=#{event["rule"]}"
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
