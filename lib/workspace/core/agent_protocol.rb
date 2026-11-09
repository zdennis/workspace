module Workspace
  # The messages and replies of the agentd socket, named in one place. Pure:
  # every method builds a frozen, string-keyed Hash and does no I/O. Each
  # builder writes the keys in the order the clients write them today, so
  # +JSON.generate+ output is byte-identical to the hand-built messages.
  # Optional keys are left out when nil. +workspace:+ is given by senders that
  # write it themselves (it follows +type+); a sender whose transport adds it
  # leaves it out.
  module AgentProtocol
    # Documentation and specs only; nothing on the wire carries it. A new
    # field is added only as an optional one, so an older daemon still reads
    # every message.
    VERSION = 1

    COMMAND = "command"
    INJECT = "inject"
    RESTART_AGENT = "restart_agent"
    SESSION_EVENT = "session_event"
    HANDOFF_WATCH = "handoff_watch"
    STATUS_REQUEST = "status_request"
    STATUS_POST = "status_post"
    PROMPT_SEND = "prompt_send"
    PROMPT_INTERRUPT_SEND = "prompt_interrupt_send"
    SESSIONS = "sessions"
    VERSION_REQUEST = "version"
    COORDINATOR_RESTART = "coordinator_restart"

    TYPES = [COMMAND, INJECT, RESTART_AGENT, SESSION_EVENT, HANDOFF_WATCH, STATUS_REQUEST, STATUS_POST,
      PROMPT_SEND, PROMPT_INTERRUPT_SEND, SESSIONS, VERSION_REQUEST, COORDINATOR_RESTART].freeze

    WRONG_WORKSPACE = "wrong_workspace"
    UNKNOWN_TYPE = "unknown_type"
    MALFORMED_MESSAGE = "malformed_message"
    INTERNAL_ERROR = "internal_error"

    ERRORS = [WRONG_WORKSPACE, UNKNOWN_TYPE, MALFORMED_MESSAGE, INTERNAL_ERROR].freeze

    # Default of +inject+'s +expected_token:+: the key is left out. Passing nil
    # writes "expected_token":null, as `pipeline advance` does with no token.
    NO_TOKEN = Object.new.freeze

    # Seconds to wait for the daemon's answer to `restart_agent`: a little
    # over the two minutes the daemon itself waits for a busy pane.
    RESTART_REPLY_TIMEOUT = 150

    # @param message [Object] a parsed message
    # @return [String, nil] its "type", nil when the message is not a Hash
    def self.type_of(message)
      message["type"] if message.is_a?(Hash)
    end

    # @param type [Object]
    # @return [Boolean] whether the daemon knows the type
    def self.known?(type)
      TYPES.include?(type)
    end

    def self.command(work_item_ref:, dispatch_id:, body:, workspace: nil)
      build(COMMAND, workspace, {"work_item_ref" => work_item_ref, "dispatch_id" => dispatch_id, "body" => body},
        keep: %w[work_item_ref dispatch_id body])
    end

    # @param expected_token [String, nil] the stage token a pipeline advance aims at;
    #   left out unless given, and nil given is written as null
    def self.inject(work_item_ref:, interrupt:, body:, workspace: nil, expected_token: NO_TOKEN)
      fields = {"work_item_ref" => work_item_ref, "interrupt" => interrupt}
      fields["expected_token"] = expected_token unless expected_token.equal?(NO_TOKEN)
      fields["body"] = body
      build(INJECT, workspace, fields, keep: %w[work_item_ref interrupt expected_token body])
    end

    def self.restart_agent(pane:, prompt:, force:, wait:, workspace: nil, timeout: nil, run_id: nil)
      build(RESTART_AGENT, workspace, {"pane" => pane, "prompt" => prompt, "force" => force, "wait" => wait,
        "timeout" => timeout, "run_id" => run_id},
        keep: %w[pane prompt force wait])
    end

    # @param fields [Hash{String=>Object}] the tool, session and sub-agent fields,
    #   merged after the base keys; a nil value anywhere is left out
    def self.session_event(event:, agent_kind:, pane_id:, session_id:, cwd:, transcript_path:, agent_id:, agent:,
      message:, notification_type:, prompt:, stop_reason:, error:, background_tasks:, workspace: nil, fields: {})
      build(SESSION_EVENT, workspace, "event" => event, "agent_kind" => agent_kind, "pane_id" => pane_id,
        "session_id" => session_id, "cwd" => cwd, "transcript_path" => transcript_path, "agent_id" => agent_id,
        "agent" => agent, "message" => message, "notification_type" => notification_type, "prompt" => prompt,
        "stop_reason" => stop_reason, "error" => error, "background_tasks" => background_tasks).merge(fields).compact.freeze
    end

    def self.handoff_watch(pane_id:, sent_at:, interval:, max:, text:, sent_text:, workspace: nil)
      build(HANDOFF_WATCH, workspace, {"pane_id" => pane_id, "sent_at" => sent_at, "interval" => interval,
        "max" => max, "text" => text, "sent_text" => sent_text},
        keep: %w[pane_id sent_at interval max text sent_text])
    end

    def self.status_request(pane_id:, workspace: nil)
      build(STATUS_REQUEST, workspace, {"pane_id" => pane_id}, keep: %w[pane_id])
    end

    def self.status_post(pane_id:, summary:, workspace: nil, task: nil, progress: nil, reply_to: nil)
      build(STATUS_POST, workspace, {"pane_id" => pane_id, "summary" => summary, "task" => task, "progress" => progress,
        "reply_to" => reply_to}, keep: %w[pane_id summary])
    end

    # @param clear_first [Boolean, nil] true adds "clear_first" and "when_idle"
    # @param when_idle [Boolean, nil] written only with +clear_first+
    def self.prompt_send(pane_id:, text:, workspace: nil, clear_first: nil, when_idle: nil)
      fields = {"pane_id" => pane_id, "text" => text}
      if clear_first
        fields["clear_first"] = true
        fields["when_idle"] = when_idle
      end
      build(PROMPT_SEND, workspace, fields, keep: %w[pane_id text when_idle])
    end

    def self.prompt_interrupt_send(pane_id:, text:, workspace: nil)
      build(PROMPT_INTERRUPT_SEND, workspace, {"pane_id" => pane_id, "text" => text}, keep: %w[pane_id text])
    end

    def self.sessions(workspace: nil)
      build(SESSIONS, workspace, {})
    end

    def self.version(workspace: nil)
      build(VERSION_REQUEST, workspace, {})
    end

    def self.coordinator_restart(workspace: nil)
      build(COORDINATOR_RESTART, workspace, {})
    end

    # @return [Hash] {"ok" => true} followed by the fields, as given
    def self.ok(**fields)
      {"ok" => true}.merge(fields.transform_keys(&:to_s)).freeze
    end

    # @param code [String] the error code
    # @param message [String, nil] written as "message" when given
    # @return [Hash] {"ok" => false, "error" => code}, then "message", then the extras
    def self.error(code, message = nil, **extra)
      reply = {"ok" => false, "error" => code}
      reply["message"] = message unless message.nil?
      reply.merge(extra.transform_keys(&:to_s)).freeze
    end

    # @param keep [Array<String>] keys the old clients always wrote, so nil stays on the wire as null
    def self.build(type, workspace, fields, keep: [])
      message = {"type" => type}
      message["workspace"] = workspace unless workspace.nil?
      fields.each { |key, value| message[key] = value unless value.nil? && !keep.include?(key) }
      message.freeze
    end
    private_class_method :build
  end
end
