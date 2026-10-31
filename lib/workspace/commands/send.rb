require "json"

module Workspace
  module Commands
    # Types into one named pane of a workspace's tmux session, straight
    # through tmux (no agent daemon needed): either literal text, or tmux key
    # names such as `Escape` or `C-c`. Backs `agent-run send`, and
    # `ask answer --deliver`.
    #
    # The pane is always named by the caller and checked against the
    # workspace's own session by {Workspace::PaneLocator} before anything is
    # typed, so a wrong, ambiguous or stale reference is an error and never a
    # different pane. Keys are checked against a known set before the first
    # one is sent, so a typo can't type a word into the pane.
    class Send
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # The most key names one call sends.
      MAX_KEYS = 64

      # Key names tmux gives special keys, exactly as `tmux send-keys` spells them.
      KEY_NAMES = %w[Enter Escape Tab BTab Space BSpace Up Down Left Right Home End
        PageUp PageDown PgUp PgDn NPage PPage Delete DC IC].freeze

      # `F1` to `F12`.
      FUNCTION_KEY = /F(?:[1-9]|1[0-2])/

      # One printable character that isn't `-` (could read as a flag) or `;`
      # (tmux's command separator).
      CHARACTER = /[[:graph:]&&[^-;]]/

      # A key as `tmux send-keys` takes it: a named key, a function key, one
      # character, or any of those with `C-`, `M-` or `S-` modifiers.
      KEY = /\A(?:[CMS]-){0,3}(?:#{Regexp.union(KEY_NAMES)}|#{FUNCTION_KEY}|#{CHARACTER})\z/

      # Seconds to wait for the agent daemon to queue or type a `--when-idle`
      # or `--clear-first` prompt: a ready pane gets it typed during the
      # call, after a quiet wait, a clear's confirmation (up to 15s) and a
      # second quiet wait, possibly after a delivery already running for the pane.
      WHEN_IDLE_TIMEOUT = 90

      # `--clear-first` typed the clear, but no new conversation was
      # confirmed, so the text was not typed. Exits 75: nothing went wrong
      # that a retry can't fix, once the pane has been checked.
      class ClearUnconfirmedError < Workspace::Error
        EXIT_CODE = 75

        # @return [String] `"clear_unconfirmed"`
        def code
          @code || "clear_unconfirmed"
        end
      end

      # @param locator [Workspace::PaneLocator] validates the pane
      # @param tmux [Workspace::Tmux] delivers text and keys
      # @param client [Workspace::AgentSnapshotClient, nil] asks the agent
      #   daemon to queue a `--when-idle` or `--clear-first` prompt; nil refuses both
      # @param output [IO] stream for the result
      def initialize(locator:, tmux:, client: nil, output: $stdout)
        @locator = locator
        @tmux = tmux
        @client = client
        @output = output
      end

      # Splits a `--keys` value into key names and checks each one.
      #
      # @param value [String] whitespace-separated tmux key names
      # @return [Array<String>]
      # @raise [Workspace::Error] code `bad_keys` for an empty value, too many
      #   keys, or a name that isn't a tmux key name
      def self.parse_keys(value)
        keys = value.to_s.split
        raise Workspace::Error.new("--keys needs at least one tmux key name.", code: "bad_keys") if keys.empty?
        if keys.size > MAX_KEYS
          raise Workspace::Error.new("--keys takes at most #{MAX_KEYS} keys.", code: "bad_keys", details: {"count" => keys.size})
        end
        bad = keys.reject { |key| key.match?(KEY) }
        unless bad.empty?
          raise Workspace::Error.new(
            "Not tmux key names: #{bad.join(" ")}. Use --body to type text; --keys takes names like Escape, Enter, Up, C-c, y.",
            code: "bad_keys", details: {"keys" => bad}
          )
        end
        keys
      end

      # Checks that +pane+ names a live pane of the workspace, typing nothing.
      #
      # @param name [String] workspace name
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1")
      # @return [Hash] the pane's details, see {Workspace::PaneLocator#locate}
      # @raise [Workspace::Error] see {Workspace::PaneLocator#locate}
      def locate(name, pane)
        @locator.locate(name, pane)
      end

      # The id of the tmux server a pane lives in, for telling a pane from the
      # one that was recorded under the same id before tmux restarted.
      #
      # @param pane [String] a pane id ("%19")
      # @return [String, nil] nil when the pane is gone
      def server_pid(pane)
        @tmux.server_pid_for_pane(pane)
      end

      # Types into the pane and prints the result.
      #
      # @param name [String] workspace name
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1")
      # @param body [String, nil] literal text, pasted as is
      # @param keys [Array<String>, nil] tmux key names, from {.parse_keys}
      # @param enter [Boolean] with +body+, press Enter after the text; keys never add one
      # @param json [Boolean] print the result as JSON instead of a sentence
      # @return [Hash] see {#deliver}
      # @raise [Workspace::Error] see {#deliver}
      def call(name:, pane:, body: nil, keys: nil, enter: true, json: false)
        result = deliver(name: name, pane: pane, body: body, keys: keys, enter: enter)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(result))
        else
          @output.puts describe(result)
        end
        result
      end

      # Types into the pane.
      #
      # @param name [String] workspace name
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1")
      # @param body [String, nil] literal text, pasted as is
      # @param keys [Array<String>, nil] tmux key names, from {.parse_keys}
      # @param enter [Boolean] with +body+, press Enter after the text
      # @return [Hash] `"pane"` (the pane id), `"mode"` ("text" or "keys"),
      #   `"submitted"` (true when Enter was pressed and took effect, or the
      #   keys were sent; false for text sent without Enter), and `"keys"` for keys
      # @raise [Workspace::Error] code `not_delivered` when nothing (or only some
      #   of the keys) reached the pane, so it is safe to resend; `not_submitted`
      #   (a {Run::NotSubmittedError}, exit 2) when text may already be in the
      #   pane; the {Workspace::PaneLocator} codes for a bad pane
      def deliver(name:, pane:, body: nil, keys: nil, enter: true)
        raise ArgumentError, "send exactly one of body: and keys:" if body.nil? == keys.nil?

        detail = locate(name, pane)
        details = {"pane" => detail[:id], "workspace" => name}
        keys ? send_keys(detail, keys, details) : send_text(detail, body, enter, details)
      end

      # Hands the text to the workspace's agent daemon (`--when-idle`,
      # `--clear-first`), which types it now if the pane's turn has ended
      # and otherwise keeps it until it has (see {Workspace::PromptQueueDesk}),
      # then prints the answer.
      #
      # @param name [String] workspace name
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1")
      # @param body [String] the prompt, at most {PromptQueueStore::MAX_BYTES} bytes
      # @param when_idle [Boolean] queue the text when the turn hasn't ended;
      #   false (only with +clear_first+) refuses `pane_busy` instead
      # @param clear_first [Boolean] clear the conversation before the text
      # @param json [Boolean] print the result as JSON instead of a sentence
      # @return [Hash] the daemon's answer: `"delivered"` and `"submitted"`
      #   (and `"cleared"` after a clear), or `"queued"`, `"id"` and `"position"`
      #   (plus `"waiting_reason"` when the first try was refused)
      # @raise [Workspace::UsageError] for a body over the limit
      # @raise [Workspace::Error] `no_daemon`, `connection_failed`,
      #   `unreadable_reply`, the {Workspace::PaneLocator} codes, and the
      #   daemon's refusals (`pane_waiting`, `not_an_agent`,
      #   `unsupported_agent`, `clear_unsupported`, `queue_full`,
      #   `pane_busy`, `pane_not_ready`, `not_delivered`); `not_submitted`
      #   (exit 2) when the text was pasted but not confirmed submitted;
      #   {ClearUnconfirmedError} (exit 75) when the clear was typed but not confirmed
      def through_daemon(name:, pane:, body:, when_idle: true, clear_first: false, json: false)
        flag = when_idle ? "--when-idle" : "--clear-first"
        if body.bytesize > PromptQueueStore::MAX_BYTES
          raise Workspace::UsageError.new("--body is #{body.bytesize} bytes; #{flag} takes at most #{PromptQueueStore::MAX_BYTES}.",
            details: {"limit" => PromptQueueStore::MAX_BYTES})
        end
        raise Workspace::Error, "agent-run send #{flag} is not available in this build" unless @client

        detail = locate(name, pane)
        message = {"type" => "prompt_send", "pane_id" => detail[:id], "text" => body}
        if clear_first
          message["clear_first"] = true
          message["when_idle"] = when_idle
        end
        reply = exchange(name, message)
        fail_with(reply, name, detail[:id]) unless reply["ok"]

        result = reply.except("ok", "pane").merge("pane" => detail[:id])
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(result))
        elsif result["queued"]
          cleared = clear_first ? "clears the conversation and " : ""
          @output.puts "Queued for pane #{detail[:id]} at position #{result["position"]} (#{result["id"]}); " \
            "the agent daemon #{cleared}types it when the agent's turn ends (prompt_dequeued in workspace events says how it went)."
          @output.puts "The first try was refused (#{TerminalText.escape(result["waiting_reason"].to_s)}); agent-run queue list says why." if result["waiting_reason"]
        elsif result["cleared"]
          @output.puts "Pane #{detail[:id]} was idle; cleared the conversation, typed the text and pressed Enter."
        else
          @output.puts "Pane #{detail[:id]} was idle; typed the text and pressed Enter."
        end
        result
      end

      # Hands the text to the workspace's agent daemon with `--interrupt`: the
      # daemon presses the agent's interrupt keys, waits for its prompt to come
      # back and types the text, all under its delivery lock, so no other writer
      # types between the steps (see {Workspace::PromptQueueDesk#interrupt_send}).
      # Prints the answer.
      #
      # @param name [String] workspace name
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1")
      # @param body [String] the prompt, at most {PromptQueueStore::MAX_BYTES} bytes
      # @param json [Boolean] print the result as JSON instead of a sentence
      # @return [Hash] the daemon's answer: `"interrupted"`, `"keys"`, `"delivered"`, `"submitted"`
      # @raise [Workspace::UsageError] for a body over the limit
      # @raise [Workspace::Error] `no_daemon`, `connection_failed`, `unreadable_reply`,
      #   the {Workspace::PaneLocator} codes, and the daemon's refusals (`no_interrupt_key`,
      #   `not_ready` when the prompt did not come back, `pane_waiting`, `not_an_agent`,
      #   `unsupported_agent`, `pane_busy`, `pane_not_ready`, `not_delivered`);
      #   `not_submitted` (exit 2) when the text was pasted but not confirmed submitted
      def interrupt_through_daemon(name:, pane:, body:, json: false)
        if body.bytesize > PromptQueueStore::MAX_BYTES
          raise Workspace::UsageError.new("--body is #{body.bytesize} bytes; --interrupt takes at most #{PromptQueueStore::MAX_BYTES}.",
            details: {"limit" => PromptQueueStore::MAX_BYTES})
        end
        raise Workspace::Error, "agent-run send --interrupt is not available in this build" unless @client

        detail = locate(name, pane)
        reply = exchange(name, {"type" => "prompt_interrupt_send", "pane_id" => detail[:id], "text" => body}, flag: "--interrupt")
        fail_with(reply, name, detail[:id], flag: "--interrupt") unless reply["ok"]

        result = reply.except("ok", "pane").merge("pane" => detail[:id])
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(result))
        else
          @output.puts "Interrupted pane #{detail[:id]} (#{result["keys"].join(" ")}), waited for its prompt, typed the text and pressed Enter."
        end
        result
      end

      private

      def exchange(name, message, flag: nil)
        reply = @client.exchange_message(name, message, timeout: WHEN_IDLE_TIMEOUT)
        unless reply.is_a?(Hash)
          raise Workspace::Error.new("Unreadable reply from the agent daemon for '#{name}'. #{MAYBE_SENT}",
            code: "unreadable_reply", details: {"maybe_delivered" => true})
        end
        reply
      rescue AgentSnapshotClient::Unavailable => e
        if e.reason == :timeout
          raise Workspace::Error.new("#{e.message}. #{MAYBE_SENT}", code: "connection_failed", details: {"maybe_delivered" => true})
        end
        raise Workspace::Error.new("#{e.message}; #{flag || "--when-idle and --clear-first"} needs the workspace's agent daemon (workspace agentd --name #{name}). " \
          "Nothing was queued or typed.", code: "no_daemon")
      end

      # What a caller is told when the daemon had the prompt but its answer was lost.
      MAYBE_SENT = "The prompt may have been queued or typed; check the pane (or prompt_queued in workspace events) before sending it again."

      # The daemon's reply fields other than ok, error and message become
      # details, with `pane` the pane id as on success.
      def fail_with(reply, name, pane_id, flag: nil)
        code = reply["error"].to_s
        message = reply["message"] || code
        if code == "unknown_type"
          code = "error"
          message = "The agent daemon for '#{name}' predates #{flag || "--when-idle and --clear-first"}; restart it with: workspace agentd restart #{name}"
        end
        code = "error" unless ErrorCodes.known?(code)
        details = reply.except("ok", "error", "message")
        details["pane"] = pane_id if details.key?("pane")
        error_class = case code
        when "not_submitted" then Run::NotSubmittedError
        when "clear_unconfirmed" then ClearUnconfirmedError
        when "usage" then Workspace::UsageError
        else Workspace::Error
        end
        raise error_class.new(message, code: code, details: details.empty? ? nil : details)
      end

      def send_text(detail, body, enter, details)
        delivery = @tmux.deliver(detail[:session], detail[:id], body, enter: enter)
        unless delivery.ok?
          hint = if delivery.status == :unsubmitted
            " Do not send it again -- it is already in the pane; press Enter there instead."
          elsif delivery.landed?
            " Do not send it again -- it may already be in the pane; check before resending."
          elsif delivery.status == :not_landed
            " The text never reached the pane; it is safe to send again."
          else
            ""
          end
          message = "Failed to send to pane #{detail[:id]} of '#{details["workspace"]}': #{delivery.message}.#{hint}"
          raise Run::NotSubmittedError.new(message, details: details) if delivery.landed?
          raise Workspace::Error.new(message, code: "not_delivered", details: details)
        end

        {"pane" => detail[:id], "mode" => "text", "submitted" => enter}
      end

      def send_keys(detail, keys, details)
        keys.each_with_index do |key, sent|
          next if @tmux.send_key(detail[:session], detail[:id], key)
          raise Workspace::Error.new(
            "Failed to send key #{key} to pane #{detail[:id]} of '#{details["workspace"]}' after #{sent} of #{keys.size} keys. " \
            "The first #{sent} reached the pane; check it before resending.",
            code: "not_delivered", details: details.merge("keys_sent" => sent)
          )
        end

        {"pane" => detail[:id], "mode" => "keys", "submitted" => true, "keys" => keys}
      end

      def describe(result)
        case result["mode"]
        when "keys" then "Sent #{result["keys"].join(" ")} to pane #{result["pane"]}."
        else result["submitted"] ? "Sent text to pane #{result["pane"]} and pressed Enter." : "Typed text into pane #{result["pane"]} without pressing Enter."
        end
      end
    end
  end
end
