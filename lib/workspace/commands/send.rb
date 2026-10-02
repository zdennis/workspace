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

      # @param locator [Workspace::PaneLocator] validates the pane
      # @param tmux [Workspace::Tmux] delivers text and keys
      # @param output [IO] stream for the result
      def initialize(locator:, tmux:, output: $stdout)
        @locator = locator
        @tmux = tmux
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

      private

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
