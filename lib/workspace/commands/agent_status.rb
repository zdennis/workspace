require "json"

module Workspace
  module Commands
    # `agent status request` and `agent status post`: asking an agent pane for
    # a status line, and an agent answering. Both are handled by the
    # workspace's agent daemon ({Workspace::AgentStatusDesk}); this side finds
    # the pane, sends one message, and prints the reply.
    class AgentStatus
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # Seconds to wait for the daemon to check, type and confirm a request.
      REQUEST_TIMEOUT = 30
      # Seconds to wait for the daemon to write a post.
      POST_TIMEOUT = 5

      # `N/M`, whole numbers.
      PROGRESS = %r{\A(\d{1,9})/(\d{1,9})\z}

      # @param client [Workspace::AgentSnapshotClient] sends one message to a daemon
      # @param locator [Workspace::PaneLocator] finds the asked pane in the workspace's own session
      # @param tmux [Workspace::Tmux] names the posting pane's session
      # @param workspace_for_session [#call] given a tmux session name, returns the workspace whose
      #   session it is (a worktree's session name differs from its workspace name)
      # @param env [Hash] process environment, for TMUX_PANE
      # @param output [IO] stream for the result
      def initialize(client:, locator:, tmux:, workspace_for_session: ->(session) { session }, env: ENV, output: $stdout)
        @client = client
        @locator = locator
        @tmux = tmux
        @workspace_for_session = workspace_for_session
        @env = env
        @output = output
      end

      # Parses `--progress N/M`.
      #
      # @param value [String]
      # @return [Hash] {"done", "total"}
      # @raise [Workspace::UsageError] unless 0 <= N <= M and M >= 1
      def self.parse_progress(value)
        match = PROGRESS.match(value.to_s.strip)
        done, total = match && [match[1].to_i, match[2].to_i]
        unless done && total >= 1 && done <= total
          raise Workspace::UsageError, "--progress must be N/M with whole numbers, 0 <= N <= M and M >= 1 (got #{value.inspect})"
        end
        {"done" => done, "total" => total}
      end

      # Asks the agent in one pane for a status line.
      #
      # @param name [String] workspace name
      # @param pane [String] pane id ("%12") or "window.pane"
      # @param json [Boolean] print one JSON document
      # @return [Hash] the daemon's reply
      # @raise [Workspace::Error] when the daemon refused, or couldn't be asked
      def request(name:, pane:, json: false)
        detail = @locator.locate(name, pane)
        reply = send_message(name, {"type" => "status_request", "pane_id" => detail[:id]}, REQUEST_TIMEOUT)
        fail_with(reply, name) unless reply["ok"]

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(reply.except("ok")))
        else
          @output.puts "Asked pane #{reply["pane"]} (#{reply["pane_id"]}) for its status: request #{reply["request_id"]}, open until #{reply["expires_at"]}."
          @output.puts "The reply shows in: workspace events --follow --types agent_status"
        end
        reply
      end

      # Posts the calling pane's status.
      #
      # @param summary [String]
      # @param task [String, nil]
      # @param progress [Hash, nil] from {.parse_progress}
      # @param reply_to [String, nil] the request this answers
      # @param json [Boolean] print one JSON document
      # @return [Hash] the daemon's reply
      # @raise [Workspace::Error] when not run from a tmux pane, or the daemon refused
      def post(summary:, task: nil, progress: nil, reply_to: nil, json: false)
        pane_id = @env["TMUX_PANE"].to_s
        if pane_id.empty?
          raise Workspace::Error.new("agent status post must be run from a tmux pane ($TMUX_PANE is not set).", code: "no_pane")
        end
        session = @tmux.session_name_for_pane(pane_id)
        name = session && @workspace_for_session.call(session)
        raise Workspace::Error.new("Pane #{pane_id} is in no tmux session workspace knows.", code: "not_in_workspace") unless name

        message = {"type" => "status_post", "pane_id" => pane_id, "summary" => summary}
        message["task"] = task if task
        message["progress"] = progress if progress
        message["reply_to"] = reply_to if reply_to
        reply = send_message(name, message, POST_TIMEOUT)
        fail_with(reply, name) unless reply["ok"]

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION}.merge(reply))
        else
          cut = reply["truncated"] ? " (summary cut to #{AgentStatusDesk::MAX_SUMMARY} characters)" : ""
          answer = reply["reply_to"] ? ", answering #{reply["reply_to"]}" : ""
          @output.puts "Posted status for pane #{pane_id}#{answer}#{cut}."
        end
        reply
      end

      private

      def send_message(name, message, timeout)
        reply = @client.exchange_message(name, message, timeout: timeout)
        raise Workspace::Error.new("Unreadable reply from the agent daemon for '#{name}'.", code: "unreadable_reply") unless reply.is_a?(Hash)
        reply
      rescue AgentSnapshotClient::Unavailable => e
        code = (e.reason == :timeout) ? "connection_failed" : "no_daemon"
        raise Workspace::Error.new(e.message, code: code)
      end

      # The daemon's reply fields other than ok, error and message become details.
      def fail_with(reply, name)
        code = reply["error"].to_s
        if code == "unknown_type"
          reply = reply.merge("message" => "The agent daemon for '#{name}' predates agent status; restart it with: workspace agentd restart #{name}")
        end
        details = reply.except("ok", "error", "message")
        error_class = (code == "not_submitted") ? Run::NotSubmittedError : Workspace::Error
        error_class = Workspace::UsageError if code == "usage"
        raise error_class.new(reply["message"] || code, code: code, details: details.empty? ? nil : details)
      end
    end
  end
end
