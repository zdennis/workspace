require "time"

module Workspace
  # The agent daemon's side of `agent status request` and `agent status post`.
  #
  # A request checks the pane with {TypingSafety}, opens one
  # {AgentStatusRequests} entry for it, checks again under the daemon's
  # delivery lock with a fresh screen, and types {.prompt_for}: a fixed line
  # carrying the request id, never caller text.
  #
  # A post is written as an `agent_status` line in the daemon's
  # {HookEventLog}, so `events --follow` carries it. With a `reply_to` it is
  # accepted only from the pane that was asked, while that pane's pid is the
  # one recorded and the request is open.
  class AgentStatusDesk
    # Longest summary kept, in characters.
    MAX_SUMMARY = 500
    # Longest task id kept, in characters.
    MAX_TASK = 128

    # @param id [String] the request id
    # @return [String] the line typed into the pane
    def self.prompt_for(id)
      "Status request #{id}: run workspace agent status post --reply-to #{id} " \
        "--summary \"<one line: what you are doing and what is next>\" " \
        "(add --task ID and --progress N/M if you have them), then carry on."
    end

    # Runs of control, format (bidi overrides, zero-width) and whitespace
    # characters become one space, then the text is cut.
    #
    # @param value [Object]
    # @param limit [Integer]
    # @return [Array(String, Boolean)] the cleaned text (nil when nothing is
    #   left) and whether it was cut
    def self.clean(value, limit)
      return [nil, false] unless value.is_a?(String)
      cleaned = value.scrub.gsub(/[[:cntrl:][:space:]\p{Cf}\p{Zl}\p{Zp}]+/, " ").strip
      return [nil, false] if cleaned.empty?
      [cleaned[0, limit], cleaned.length > limit]
    end

    # @param tmux [Workspace::Tmux] pane lookups, screen reads and deliveries
    # @param session_name [String] the workspace's tmux session
    # @param workspace [String] the workspace the daemon serves
    # @param session_monitor [Workspace::SessionMonitor, nil] pane facts
    # @param hook_event_log [Workspace::HookEventLog, nil] where posts are written
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param requests [Workspace::AgentStatusRequests] the open requests
    # @param typer [Workspace::PromptTyper, nil] checks the pane and types the line; nil builds
    #   one from +tmux+ and +session_monitor+
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, session_name:, workspace:, session_monitor:, hook_event_log:, delivery_lock:,
      requests: AgentStatusRequests.new, typer: nil, logger: Workspace::Logger.new)
      @tmux = tmux
      @session_name = session_name
      @workspace = workspace
      @session_monitor = session_monitor
      @hook_event_log = hook_event_log
      @delivery_lock = delivery_lock
      @requests = requests
      @typer = typer || PromptTyper.new(tmux: tmux, session_monitor: session_monitor, logger: logger)
      @logger = logger
    end

    # Handles a "status_request" message.
    #
    # @param message [Hash] carries "pane_id"
    # @return [Hash] the reply
    def request(message)
      pane_id = message["pane_id"]
      detail = pane_detail(pane_id)
      return error("no_such_pane", "no pane #{pane_id.inspect} in tmux session #{@session_name}") unless detail
      target = "#{detail[:window]}.#{detail[:index]}"
      context = {"pane" => target, "pane_id" => pane_id}

      refused = refusal(pane_id)
      return refused.merge(context) if refused

      outcome, request = @requests.open(pane_id: pane_id, pane_pid: detail[:pid])
      if outcome == :open
        return error("status_request_open", "pane #{target} already has an open status request (#{request.id})",
          "request_id" => request.id, "expires_at" => request.expires_at.utc.iso8601).merge(context)
      end

      reply = nil
      begin
        reply = type_prompt(request)
      ensure
        # Also when typing raised: a request left open would refuse the pane for its whole lifetime.
        keep = reply && (reply["ok"] || reply["error"] == "not_submitted")
        @requests.cancel(request.id) unless keep
      end
      reply.merge(context)
    end

    # Handles a "status_post" message.
    #
    # @param message [Hash] carries "pane_id", "summary", and optionally
    #   "task", "progress" ({"done", "total"}) and "reply_to"
    # @return [Hash] the reply
    def post(message)
      pane_id = message["pane_id"]
      summary, truncated = self.class.clean(message["summary"], MAX_SUMMARY)
      return error("usage", "a status post needs a non-empty summary") unless summary
      task, = self.class.clean(message["task"], MAX_TASK)
      progress = progress_of(message["progress"])
      return error("usage", "progress must be {done, total} with 0 <= done <= total and total >= 1") if message["progress"] && !progress

      reply_to = message["reply_to"]&.to_s
      if reply_to
        code, request = @requests.claim(reply_to, pane_id: pane_id, pane_pid: pane_detail(pane_id)&.dig(:pid))
        return error(code, reply_refusal(code, reply_to, request), "request_id" => reply_to) if code
      end

      line = @hook_event_log&.append("agent_status", pane_id,
        "summary" => summary, "task" => task, "progress" => progress, "reply_to" => reply_to)
      unless line
        @requests.reopen(request) if request
        return error("status_not_logged", "the agent daemon could not write the agent_status line")
      end

      {"ok" => true, "truncated" => truncated}.merge(line.except("type"))
    end

    private

    def pane_detail(pane_id)
      return nil unless pane_id.is_a?(String)
      @tmux.pane_details(@session_name, window: nil).find { |d| d[:id] == pane_id }
    end

    def refusal(pane_id)
      result = @typer.check(pane_id)
      result && error(result[:code], "nothing was typed: #{result[:message]}", "reason" => result[:reason])
    end

    # The pane is looked up and checked again under the lock: it may have
    # closed, been replaced, or opened a dialog while the request was opening.
    # {PromptTyper} pastes the line without Enter and checks the pane once
    # more, so Enter is pressed only while the input prompt is still what's on screen.
    def type_prompt(request)
      @delivery_lock.synchronize do
        detail = pane_detail(request.pane_id)
        unless detail && detail[:pid] == request.pane_pid
          next error("no_such_pane", "pane #{request.pane_id} closed or was replaced; nothing was typed")
        end

        target = "#{detail[:window]}.#{detail[:index]}"
        opened = {"request_id" => request.id, "expires_at" => request.expires_at.utc.iso8601}
        typed = @typer.type(session_name: @session_name, target: target, pane_id: request.pane_id,
          text: self.class.prompt_for(request.id))
        @logger.debug { "status request #{request.id} in #{@session_name}:#{target}: #{typed.outcome}" }
        case typed.outcome
        when :refused then error(typed.code, "nothing was typed: #{typed.message}", "reason" => typed.reason)
        when :submitted then {"ok" => true}.merge(opened).merge("delivery" => typed.delivery.status.to_s)
        when :not_submitted
          unsubmitted(target, typed.message, typed.reason ? opened.merge("reason" => typed.reason) : opened, typed.delivery)
        else error("not_delivered", "the request was not typed into pane #{target}: #{typed.message}")
        end
      end
    end

    def unsubmitted(target, why, opened, delivery)
      error("not_submitted", "the request was pasted into pane #{target} but not submitted: #{why}; " \
        "it stays open, so check the pane before asking again", opened.merge("delivery" => delivery.status.to_s))
    end

    def progress_of(value)
      return nil unless value.is_a?(Hash)
      done, total = value.values_at("done", "total")
      return nil unless done.is_a?(Integer) && total.is_a?(Integer) && total >= 1 && done >= 0 && done <= total
      {"done" => done, "total" => total}
    end

    def reply_refusal(code, id, request)
      case code
      when "status_request_unknown" then "no open status request #{id} (already answered, never made, or the agent daemon restarted)"
      when "status_request_expired" then "status request #{id} expired at #{request.expires_at.utc.iso8601}"
      when "status_reply_wrong_pane" then "status request #{id} was sent to pane #{request.pane_id}, not this one"
      else "pane #{request.pane_id} is not the pane status request #{id} was sent to (its pane id was reused)"
      end
    end

    def error(code, message, extra = {})
      {"ok" => false, "error" => code, "message" => message}.merge(extra)
    end
  end
end
